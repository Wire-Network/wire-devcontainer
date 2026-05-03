# Local Setup Guide

End-to-end host setup for the full Wire stack — every repo cloned, native
toolchain (`wire-cdt`, `wire-sysio`) built, TypeScript / Hardhat / Solana
packages installed and linked. This is the host equivalent of
[`e2e-build.Dockerfile`](./e2e-build.Dockerfile), driven by a single
script: [`scripts/wire-local-setup.bash`](./scripts/wire-local-setup.bash).

## Quick Start

The script takes one required positional argument — `WIRE_ROOT`, the
directory every Wire repo will live under — plus a few optional flags that
let you tailor the run to your machine's state. See the [Flags](#flags)
section below for the full reference.

Replace `<wire-repo-clone-root>` with the path to the directory you want
the Wire repos cloned into.

```bash
# Usage:
# curl -fsSL https://raw.githubusercontent.com/Wire-Network/wire-devcontainer/master/scripts/wire-local-setup.bash \
#   | bash -s -- [--git-ssh] [--skip-apt] [--skip-clone] "<wire-repo-clone-root>"

# Example using `https` for git urls:
curl -fsSL https://raw.githubusercontent.com/Wire-Network/wire-devcontainer/master/scripts/wire-local-setup.bash \
  | bash -s -- "$HOME/code/wire"

# Example using `ssh` for git urls:
curl -fsSL https://raw.githubusercontent.com/Wire-Network/wire-devcontainer/master/scripts/wire-local-setup.bash \
  | bash -s -- --git-ssh "$HOME/code/wire"

# Example skipping apt + verifying clones already exist (CI / fully-provisioned host):
curl -fsSL https://raw.githubusercontent.com/Wire-Network/wire-devcontainer/master/scripts/wire-local-setup.bash \
  | bash -s -- --skip-apt --skip-clone "$HOME/code/wire"
```

If you've already cloned `wire-devcontainer` you can just run the script
locally:

```bash
# Usage:
# ./scripts/wire-local-setup.bash [--git-ssh] [--skip-apt] [--skip-clone] "<wire-repo-clone-root>"

# Example using `https` for git urls:
./scripts/wire-local-setup.bash "$HOME/code/wire"

# Example using `ssh` for git urls:
./scripts/wire-local-setup.bash --git-ssh "$HOME/code/wire"

# Example: verify repos already exist and skip apt + toolchain installation
./scripts/wire-local-setup.bash --skip-apt --skip-clone "$HOME/code/wire"
```

## Flags

| Flag           | Default       | What it does                                                                                                                                                                                                                                                                                       |
|----------------|---------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--git-ssh`    | _off_ (HTTPS) | Switches the GitHub URL prefix from `https://github.com/Wire-Network/<repo>.git` to `git@github.com:Wire-Network/<repo>.git`. Use when your machine is set up to push/pull via SSH and HTTPS would prompt for credentials. Selected transport is logged at startup.                                  |
| `--skip-apt`   | _off_         | Skips both `apt-get install` steps (the bootstrap packages and the full build/runtime toolchain). Use on hosts that are already provisioned (CI images, prior runs, customized base images). The `sudo` / `run_apt` setup is also skipped, so the script no longer needs root for this phase.        |
| `--skip-clone` | _off_         | Instead of cloning, verifies that every repo in `WIRE_REPOS` already exists as a git checkout under `WIRE_ROOT`. If any are missing, prints `[wire-local-setup][error] --skip-clone set but the following repos are missing under <WIRE_ROOT>:` followed by the missing repo names to stderr and exits non-zero. |
| `-h`, `--help` | —             | Prints usage and exits 0.                                                                                                                                                                                                                                                                          |

> **Note**
> Flags are parsed up-front (before the OS check, apt install, and nvm
> bootstrap), so `--help` works even if the host is not Ubuntu 24.04 and
> `--skip-apt` is honored before the script ever asks for `sudo`.

In addition to these flags, the rust + foundry + solana + avm install
section is **automatically skipped** when every tool it provides
(`cargo`, `rustc`, `forge`, `anvil`, `cast`, `solana`,
`solana-test-validator`, `avm`, `anchor`) is already resolvable on the
current `PATH`. If any one is missing, the full set is installed. There is
no flag to control this — the check is implicit.

A successful run leaves you with this layout under `WIRE_ROOT`:

```
$WIRE_ROOT/
├── local-prefix/          # WIRE_PREFIX — cmake install root for cdt/sysio
├── wire-cdt/
├── wire-sysio/
│   └── build/opp/         # WIRE_OPP_ROOT — generated TS + Solidity bundles
├── wire-libraries-ts/
├── wire-tools-ts/
├── wire-ethereum/
└── wire-solana/
```

### Quick Dev/Test Cluster

Once you've run the script successfully, you can start a local cluster
with the following commands:

```bash 
## Usage:
## Replace <wire-repo-clone-root> with the path to the Wire repo clone root.
# source "<wire-repo-clone-root>/.env"
# wire-test-cluster \
#  --cluster-path=$HOME/.local/share/wire/chains/dev-001 \
#  --force \
#    create \
#    --build-path=<wire-repo-clone-root>/wire-sysio/build/debug \
#    --prod-count=5 \
#    --pnodes=1 \
#    --batch-operators=3 \
#    --underwriters=1 \
#    --epoch-duration=60 \
#    --ethereum-path=<wire-repo-clone-root>/wire-ethereum \
#    --solana-path=<wire-repo-clone-root>/wire-solana \
#  && wire-test-cluster \
#    --cluster-path=$HOME/.local/share/wire/chains/dev-001 run

# Example with `$HOME/code/wire` as the Wire repo clone root:
source "$HOME/code/wire/.env"

wire-test-cluster \
  --cluster-path=$HOME/.local/share/wire/chains/dev-001 \
  --force \
    create \
    --build-path=$HOME/code/wire/wire-sysio/build/debug \
    --prod-count=5 \
    --pnodes=1 \
    --batch-operators=3 \
    --underwriters=1 \
    --epoch-duration=60 \
    --ethereum-path=$HOME/code/wire/wire-ethereum \
    --solana-path=$HOME/code/wire/wire-solana \
  && wire-test-cluster \
    --cluster-path=$HOME/.local/share/wire/chains/dev-001 run

```


## Prerequisites

The script fails fast if any of these are missing on `PATH`:

| Tool        | Purpose                                                       |
|-------------|---------------------------------------------------------------|
| `git`       | clone the Wire repos                                          |
| `cmake`     | configure `wire-cdt` / `wire-sysio`                           |
| `ninja`     | cmake generator used for both native builds                   |
| `clang-18`  | `CC` (also needed for `clang++-18`)                           |
| `clang++-18`| `CXX`                                                         |
| `pnpm`      | TypeScript monorepo installs (libraries-ts / tools-ts / opp)  |
| `npm`       | `wire-ethereum` install + `npm link` for OPP bundles          |
| `node`      | runtime for the JS / Hardhat builds                           |
| `cargo`     | builds `wire-solana`                                          |

You also need the native dev libraries that both `wire-cdt` and `wire-sysio`
link against (`libcurl4-openssl-dev`, `libbz2-dev`, `liblzma-dev`,
`libusb-1.0-0-dev`, `libgmp-dev`, `libzstd-dev`, `zlib1g-dev`,
`libstdc++-14-dev`, `libclang-18-dev`, `llvm-18`, `libncurses5-dev`,
`pkg-config`, `autoconf`, `autoconf-archive`, `automake`, `libtool`,
`build-essential`, `binutils`, `ccache`, `python3`-{`pip`,`venv`,`dev`}).
These are the same packages installed in the Dockerfile's `apt-get` block.

## Configuration

The script accepts a few environment variables; sensible defaults apply when
they're unset:

| Variable      | Default                                 | Notes                                          |
|---------------|-----------------------------------------|------------------------------------------------|
| `WIRE_ROOT`   | _(positional arg, required)_            | Resolved to absolute path; created if missing  |
| `WIRE_PREFIX` | `${WIRE_ROOT}/local-prefix`             | Hardcoded — cmake `INSTALL_PREFIX`             |
| `MP_COUNT`    | `min(nproc, 32)`, falls back to `8`     | Build parallelism for `cmake --build`          |
| `CC`          | `$(which clang-18)`                     | Required: clang-18 must be on `PATH`           |
| `CXX`         | `$(which clang++-18)`                   | Required: clang++-18 must be on `PATH`         |

## What the Script Does, Step by Step

### 0. Resolve `WIRE_ROOT` and prepare directories

```bash
mkdir -p "${WIRE_ROOT_ARG}"
WIRE_ROOT="$(cd "${WIRE_ROOT_ARG}" && pwd)"

export WIRE_PREFIX="${WIRE_ROOT}/local-prefix"
mkdir -p "${WIRE_PREFIX}"
```

`WIRE_ROOT` is created if missing and resolved to an absolute path. The
script is idempotent at the per-repo level (`clone_repo` skips and `git pull`s
existing checkouts), so re-running into an existing tree is safe. If you
explicitly want to assert that nothing has been cloned yet, pair `--skip-clone`
with a fresh directory — the verification step will fail with a list of
missing repos.

### 1. Clone every Wire repo (or verify them with `--skip-clone`)

The clone helper picks the URL prefix from `--git-ssh` (HTTPS by default,
SSH when set) and skips/`git pull`s targets that already have a `.git`
directory — re-runs after a mid-script failure don't re-download.

```bash
clone_repo "${GIT_REPO_BASE}/wire-libraries-ts.git" "wire-libraries-ts"
clone_repo "${GIT_REPO_BASE}/wire-tools-ts.git"     "wire-tools-ts"
clone_repo "${GIT_REPO_BASE}/wire-ethereum.git"     "wire-ethereum" "feature/protobufs-for-opp"
clone_repo "${GIT_REPO_BASE}/wire-solana.git"       "wire-solana"   "feature/opp-solana-outpost-integration"
clone_repo "${GIT_REPO_BASE}/wire-cdt.git"          "wire-cdt"
clone_repo "${GIT_REPO_BASE}/wire-sysio.git"        "wire-sysio"    "feature/opp-part2"
```

When `--skip-clone` is set, the six `clone_repo` calls are replaced with
a verification loop that walks `WIRE_REPOS=(wire-libraries-ts wire-tools-ts
wire-ethereum wire-solana wire-cdt wire-sysio)`, prints any missing ones
to stderr, and exits 1 if the list is non-empty.

Three repos use feature branches today:

| Repo            | Branch                                    |
|-----------------|-------------------------------------------|
| `wire-ethereum` | `feature/protobufs-for-opp`               |
| `wire-solana`   | `feature/opp-solana-outpost-integration`  |
| `wire-sysio`    | `feature/opp-part2`                       |

### 2. Bootstrap `vcpkg` for the native repos

```bash
( cd "${WIRE_ROOT}/wire-cdt"   && ./vcpkg/bootstrap-vcpkg.sh )
( cd "${WIRE_ROOT}/wire-sysio" && ./vcpkg/bootstrap-vcpkg.sh )
```

`vcpkg` is a submodule of both repos; this builds the `vcpkg` binary used
by the cmake toolchain file.

### 3. Install the global `@protobuf-ts/plugin`

`wire-libraries-ts` and `wire-tools-ts` invoke `protoc-gen-ts` during their
build; it has to be on `PATH`. Both `npm` and `pnpm` global installs are
done because different sub-builds resolve through different package
managers.

```bash
npm i -g @protobuf-ts/plugin
pnpm i -g @protobuf-ts/plugin
```

### 4. Build `wire-cdt`

`wire-cdt` is the contract development toolchain (the WASM compiler used
by `wire-sysio`). It installs into `${WIRE_PREFIX}/cdt`, which the next
stage points cmake at.

```bash
cd "${WIRE_ROOT}/wire-cdt"
cmake \
  -G Ninja \
  -DENABLE_CCACHE=ON \
  -DENABLE_DISTCC=OFF \
  -DENABLE_TESTS=ON \
  -DCMAKE_TOOLCHAIN_FILE="${PWD}/vcpkg/scripts/buildsystems/vcpkg.cmake" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}" \
  -DCMAKE_INSTALL_PREFIX="${WIRE_PREFIX}" \
  -DCMAKE_PREFIX_PATH="${WIRE_PREFIX}" \
  -DCMAKE_PARALLEL_LEVEL="${MP_COUNT}" \
  -S . \
  -B build/debug

cmake --build build/debug -j"${MP_COUNT}" --target all
cmake --install build/debug
```

### 5. Build `wire-sysio` (and emit OPP bundles)

Depends on the `wire-cdt` install prefix. `BUILD_OPP_BUNDLES=ON` causes
sysio's build to generate the `@wireio/opp-typescript-models` and
`@wireio/opp-solidity-models` packages under `build/opp/`.

```bash
cd "${WIRE_ROOT}/wire-sysio"
cmake \
  -G Ninja \
  -DENABLE_CCACHE=ON \
  -DENABLE_DISTCC=OFF \
  -DENABLE_TESTS=ON \
  -DBUILD_OPP_BUNDLES=ON \
  -DBUILD_SYSTEM_CONTRACTS=ON \
  -DBUILD_TEST_CONTRACTS=ON \
  -DCMAKE_TOOLCHAIN_FILE="${PWD}/vcpkg/scripts/buildsystems/vcpkg.cmake" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}" \
  -DCMAKE_INSTALL_PREFIX="${WIRE_PREFIX}" \
  -DCMAKE_PREFIX_PATH="${WIRE_PREFIX}/cdt" \
  -DCMAKE_PARALLEL_LEVEL="${MP_COUNT}" \
  -S . \
  -B build/debug

cmake --build build/debug -j"${MP_COUNT}" --target all
```

### 6. Install + `npm link` the OPP bundles

`wire-ethereum` consumes `@wireio/opp-solidity-models` via `npm link`,
which requires the package to first be globally registered. Same idea for
the typescript bundle (consumed by libraries-ts / tools-ts).

```bash
export WIRE_OPP_ROOT="${WIRE_ROOT}/wire-sysio/build/opp"

cd "${WIRE_OPP_ROOT}/typescript"
pnpm i --force --no-frozen-lockfile
npm link

cd "${WIRE_OPP_ROOT}/solidity"
pnpm i --force --no-frozen-lockfile
npm link
```

### 7. Build `wire-libraries-ts`

The `pnpm install` runs twice on purpose: the first install pulls deps
under `--no-frozen-lockfile` so workspace packages can resolve, the
build emits compiled outputs, and the second install re-links workspace
references against the built artifacts.

```bash
cd "${WIRE_ROOT}/wire-libraries-ts"
pnpm install --no-frozen-lockfile
pnpm run build
pnpm install
```

### 8. Build `wire-tools-ts` and globally link its CLIs

```bash
cd "${WIRE_ROOT}/wire-tools-ts"
pnpm install --force --no-frozen-lockfile
pnpm run build
pnpm install

( cd "${WIRE_ROOT}/wire-tools-ts/packages/test-cluster-tool" && pnpm link --global )
( cd "${WIRE_ROOT}/wire-tools-ts/packages/debugging-server"  && pnpm link --global )
```

After this step `test-cluster-tool` and `debugging-server` are on `PATH`
via pnpm's global bin directory.

### 9. Build `wire-ethereum` (Hardhat contracts)

```bash
cd "${WIRE_ROOT}/wire-ethereum"
npm i
npm link @wireio/opp-solidity-models
npm run build
npx hardhat compile
```

### 10. Build `wire-solana`

```bash
cd "${WIRE_ROOT}/wire-solana"
cargo build
```

## Re-Running and Troubleshooting

- **Resuming after a mid-script failure** — the script is idempotent at the
  per-step level. `clone_repo` skips and `git pull`s when `.git` exists;
  cmake / pnpm / cargo steps are incremental and won't redo cached work.
  Just re-invoke with the same `WIRE_ROOT`. If you've already provisioned
  the host and verified the repos in a previous run, add `--skip-apt
  --skip-clone` to short-circuit the slow upfront work.
- **`--skip-clone` reports missing repos** — exit code 1 with a list of
  repo names on stderr means the script expected `${WIRE_ROOT}/<repo>/.git`
  to exist but it didn't. Either drop `--skip-clone` so the script clones
  them for you, or clone the missing ones manually before re-running.
- **`unsupported OS: this script requires Ubuntu 24.04 (noble)`** — the OS
  check is strict (matches `ID=ubuntu`, `VERSION_ID=24.04`,
  `VERSION_CODENAME=noble`). On other distros, replicate the apt-package
  set manually and run the build steps directly; the script itself is
  Ubuntu-only.
- **`running as non-root user but 'sudo' is not installed`** — install
  `sudo` (or run as root) before re-invoking, or use `--skip-apt` if the
  host is already provisioned.
- **Build OOMs / slow** — lower `MP_COUNT`. The default is `nproc / 2`
  (capped lower on small hosts), but native builds (especially
  `wire-sysio`) are memory-hungry.
- **Missing OPP bundles** — the script aborts with `wire-opp bundles
  missing under …` if sysio didn't emit them. Verify
  `-DBUILD_OPP_BUNDLES=ON` was honored and that
  `wire-sysio/build/opp/{typescript,solidity}` exist after the sysio build.
- **`npm link` errors** — ensure your npm prefix is writable without
  `sudo`; `pnpm setup` (or `npm config set prefix "$HOME/.npm-global"`)
  fixes most cases.
- **Toolchain installer ran when I expected it to skip** — the rust /
  foundry / solana / avm block runs whenever **any** of `cargo`, `rustc`,
  `forge`, `anvil`, `cast`, `solana`, `solana-test-validator`, `avm`, or
  `anchor` is missing from `PATH`. The script prints the missing names at
  the start of the install block; check that list to identify which tool
  triggered the install.

## Reference: Build Order

```
wire-cdt → wire-sysio → wire-libraries-ts → wire-tools-ts
                     ↘ wire-ethereum
                     ↘ wire-solana
```

This matches `e2e-build.Dockerfile`'s multi-stage layout exactly; the
script is the host-side translation, with no Docker involved.
