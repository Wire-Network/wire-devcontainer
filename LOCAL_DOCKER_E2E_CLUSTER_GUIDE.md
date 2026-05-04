# Local Docker E2E Cluster Guide

Build the `wire-e2e-env` Docker image (every Wire repo cloned, native
toolchain compiled, OPP bundles emitted, TypeScript / Hardhat / Solana
stacks installed and linked) and run an end-to-end Wire test cluster from
inside the resulting container.

The image is produced from [`e2e-build.Dockerfile`](./e2e-build.Dockerfile).
Cloning the private Wire repos requires a GitHub token, which is supplied
to the build as a BuildKit secret — never as a build arg or layer file.

## 1. Build the image

You need a `GITHUB_TOKEN` environment variable in the shell that runs the
build, with permissions to clone every Wire-Network repo. The simplest
source is `gh auth token`:

```bash
export GITHUB_TOKEN=$(gh auth token)
```

Then build with `docker buildx`:

```bash
docker buildx build \
  --cpu-quota=4 \
  --memory=32g \
  --build-arg MP_COUNT=4 \
  --progress=plain \
  --secret id=github_token,env=GITHUB_TOKEN \
  --network=host \
  -f e2e-build.Dockerfile \
  -t wire-e2e-env:latest .
```

### Notes on the flags

| Flag                                            | Why                                                                                                                                                  |
|-------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--secret id=github_token,env=GITHUB_TOKEN`     | Mounts the value of `$GITHUB_TOKEN` at `/run/secrets/github_token` for the clone RUN only. The token is never written to any image layer.            |
| `--network=host`                                | Lets the build reach the apt mirror / GitHub / npm registry / cargo crates without going through Docker's NAT — avoids slow / flaky network on some hosts. |
| `--cpu-quota=4 --memory=32g`                    | Caps the build's resource usage. Tune to taste; the values shown are conservative defaults that work on most laptops.                                |
| `--build-arg MP_COUNT=4`                        | **Optional.** Sets the parallelism (`-j`) used by every cmake/ninja stage. Bump it on large workstations to speed up the native builds. Defaults to `8` when omitted. |
| `--progress=plain`                              | Streams full build output instead of the collapsed TTY view — recommended so you can actually see failures.                                          |

> **`MP_COUNT` is purely a speed knob.** You can omit it entirely; it only
> exists to let large workstations max out their cores during the cmake /
> ninja phases.

### Verifying the token didn't leak

After a successful build, the token should not appear anywhere in the image:

```bash
# /root/.gitconfig should be empty (or absent):
docker run --rm wire-e2e-env:latest cat /root/.gitconfig 2>/dev/null

# No token strings in build history:
docker history --no-trunc wire-e2e-env:latest | grep -iE 'token|bearer|x-access-token'

# Spot-check a cloned repo's remote config:
docker run --rm wire-e2e-env:latest cat /opt/wire/build/wire-libraries-ts/.git/config
```

All three commands should produce no token-bearing output.

## 2. Run the container

Cluster bring-up uses `wire-test-cluster`, which spawns several `nodeos`
processes and a local Anvil + Solana validator. These need extended kernel
capabilities (mostly around `mmap`, `setrlimit`, and seccomp filtering)
that Docker's default profile blocks. The simplest workaround is
`--privileged`:

```bash
docker run --name wire-e2e-001 --privileged -it wire-e2e-env
```

If you don't want full privileges, the narrower equivalent is to disable
just the seccomp filter:

```bash
docker run --name wire-e2e-001 --security-opt seccomp=unconfined -it wire-e2e-env
```

Either drops you into a fish shell at `/opt/wire/build` with everything
pre-built — `WIRE_ROOT=/opt/wire/build`, the wire toolchain on `PATH`, and
all six Wire repos checked out and ready.

## 3. Bring up the cluster

From inside the container:

```bash
export WIRE_ROOT=/opt/wire/build
export CHAIN=/opt/wire/chains/e2e-001

wire-test-cluster \
  --cluster-path=$CHAIN \
  --force \
  create \
  --build-path=$WIRE_ROOT/wire-sysio/build/debug \
  --prod-count=5 \
  --pnodes=1 \
  --batch-operators=3 \
  --underwriters=1 \
  --epoch-duration=60 \
  --ethereum-path=$WIRE_ROOT/wire-ethereum \
  --solana-path=$WIRE_ROOT/wire-solana \
  && wire-test-cluster \
    --cluster-path=$CHAIN run
```

What each option does, briefly:

| Option                  | Meaning                                                                       |
|-------------------------|-------------------------------------------------------------------------------|
| `--cluster-path`        | Where on disk the chain's data, logs, and config live.                         |
| `--force`               | Wipe any existing chain data at `--cluster-path` before creating.              |
| `--build-path`          | Path to the compiled `wire-sysio` build (used to locate `nodeos`, contracts). |
| `--prod-count`          | Total producer nodes in the cluster (here: 5).                                 |
| `--pnodes`              | Producer-node count subset (1 of the 5 produces blocks).                       |
| `--batch-operators`     | Number of OPP batch operators participating.                                   |
| `--underwriters`        | Number of OPP underwriters.                                                    |
| `--epoch-duration=60`   | Epoch length in seconds — keep low to surface OPP cadence quickly.             |
| `--ethereum-path`       | Path to the compiled wire-ethereum repo (Hardhat artifacts + Anvil config).    |
| `--solana-path`         | Path to the compiled wire-solana repo.                                         |

The trailing `&& wire-test-cluster --cluster-path=$CHAIN run` boots the
cluster after creation. `create` and `run` are deliberately separate
subcommands so you can inspect the generated config under
`$CHAIN/config/` before starting.

## 4. Confirm OPP is actually running

The smoke test for "everything works end to end" is OPP bundle output.
Once the cluster is running you should see new pairs of `.data` /
`.metadata` files appear roughly every minute under
`/opt/wire/chains/e2e-001/data/opp-debugging`:

```bash
watch -n 5 'ls -lh /opt/wire/chains/e2e-001/data/opp-debugging | tail -20'
```

Within ~4 minutes you should have **4 pairs** (`.data` + `.metadata`).
Their existence confirms three things working in concert:

1. **Operator registry** — operators came up and registered against the
   chain.
2. **Batch operator scheduling** — the scheduler is rotating work through
   the configured `--batch-operators=3`.
3. **Consensus** — the cluster is producing blocks and the OPP epoch
   boundary (`--epoch-duration=60`) is firing on cadence.

If the directory stays empty, see Troubleshooting below.

## Troubleshooting

- **`fatal: could not read Username for 'https://github.com'` during the
  build** — `GITHUB_TOKEN` is unset / empty in the shell that ran
  `docker buildx build`. Re-run `export GITHUB_TOKEN=$(gh auth token)`
  before invoking the build, and double-check with `echo
  "${#GITHUB_TOKEN}"` (should print a non-zero length).
- **`Operation not permitted` during cluster `create`/`run`** — you forgot
  `--privileged` (or `--security-opt seccomp=unconfined`). Stop the
  container, recreate with the flag, and retry.
- **No `.data` / `.metadata` files appearing in `opp-debugging`** —
  inspect `$CHAIN/data/<node>/stderr.txt` for crashes or missed slots.
  Common causes: not enough CPU quota during build (clamp `--cpu-quota`
  higher), stale Anvil state under `$WIRE_ROOT/wire-ethereum`
  (rebuild via `npx hardhat compile`), or a too-aggressive
  `--epoch-duration`.
- **Build fails on `apt-get update`** — usually transient mirror flakiness;
  the Dockerfile rewrites the default Ubuntu mirror to `us-east-1.ec2`,
  which is fast from most cloud regions but slower from some non-US
  networks. Edit the `sed` line in `e2e-build.Dockerfile` to point at a
  closer mirror if needed.
- **Build seems CPU-starved** — bump `--cpu-quota` and `--build-arg
  MP_COUNT`. The two should usually move together (e.g. `--cpu-quota=16
  --build-arg MP_COUNT=8` for an 8-core build).

## Related

- [LOCAL_SETUP_GUIDE.md](./LOCAL_SETUP_GUIDE.md) — host-native equivalent
  of this image (no Docker), driven by
  [`scripts/wire-local-setup.bash`](./scripts/wire-local-setup.bash).
- [`e2e-build.Dockerfile`](./e2e-build.Dockerfile) — the multi-stage
  Dockerfile this guide builds.
