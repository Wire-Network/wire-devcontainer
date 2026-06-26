# wire-devcontainer & other dev tools

# LOCAL Dev Setup

Use the [LOCAL_SETUP_GUIDE.md](./LOCAL_SETUP_GUIDE.md) to setup your local environment.

The setup is driven by [`scripts/wire-local-setup.bash`](./scripts/wire-local-setup.bash), which
takes a single positional argument `WIRE_ROOT` (the directory every Wire repo will live under)
plus a few optional flags:

| Flag             | Default        | Effect                                                                                                                                                              |
|------------------|----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--git-ssh`      | _off_ (HTTPS)  | Clone via `git@github.com:Wire-Network/<repo>.git` instead of HTTPS.                                                                                                |
| `--skip-apt`     | _off_          | Skip both `apt-get install` steps. Use on already-provisioned hosts (CI images, prior runs).                                                                        |
| `--skip-clone`   | _off_          | Don't clone — verify every Wire repo already exists under `WIRE_ROOT`. Missing repos are listed on stderr and the script exits non-zero.                            |
| `-h`, `--help`   | —              | Print usage and exit.                                                                                                                                                |

The rust + foundry + solana + avm install block is **automatically skipped** when every tool
it provides (`cargo`, `rustc`, `forge`, `anvil`, `cast`, `solana`, `solana-test-validator`,
`avm`, `anchor`) is already on `PATH`. There's no flag for this — the script probes `command
-v` for each name and only installs when something is missing.

Examples:

```bash
# Fresh setup over HTTPS
./scripts/wire-local-setup.bash "$HOME/code/wire"

# Fresh setup over SSH (when the host is configured for SSH-based GitHub auth)
./scripts/wire-local-setup.bash --git-ssh "$HOME/code/wire"

# Re-run on a fully-provisioned host with all repos already present
./scripts/wire-local-setup.bash --skip-apt --skip-clone "$HOME/code/wire"
```

See [LOCAL_SETUP_GUIDE.md](./LOCAL_SETUP_GUIDE.md) for the full step-by-step walkthrough,
prerequisites, and troubleshooting.


# LOCAL Docker E2E Cluster

Build a self-contained `wire-e2e-env` Docker image — every Wire repo cloned, native toolchain
compiled, OPP bundles emitted, TS/Hardhat/Solana stacks installed — then bring up an end-to-end
test cluster from inside it. The full walkthrough lives in
[LOCAL_DOCKER_E2E_CLUSTER_GUIDE.md](./LOCAL_DOCKER_E2E_CLUSTER_GUIDE.md); the essentials are:

**1. Build** (requires a `GITHUB_TOKEN` env var with permissions to clone every Wire-Network
repo — the token is passed as a BuildKit secret and never lands in any image layer):

```bash
export GITHUB_TOKEN=$(gh auth token)
docker buildx build \
  --cpu-quota=4 --memory=32g \
  --build-arg MP_COUNT=4 \
  --progress=plain \
  --secret id=github_token,env=GITHUB_TOKEN \
  --network=host \
  -f e2e-build.Dockerfile \
  -t wire-e2e-env:latest .
```

`--build-arg MP_COUNT=4` is optional — it controls cmake/ninja parallelism (`-j`). Bump it on
large workstations to maximize build speed; omit it to use the default (`8`).

**2. Run** the resulting image with `--privileged` (or, less invasively,
`--security-opt seccomp=unconfined`) — `wire-test-cluster` spawns processes that need elevated
kernel capabilities Docker's default seccomp profile blocks:

```bash
docker run --name wire-e2e-001 --privileged -it wire-e2e-env
```

**3. Bring up the cluster** from the fish shell inside the container:

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

**4. Smoke test** — once running, watch for ~4 pairs of OPP `.data` / `.metadata` files to appear
roughly every minute under `/opt/wire/chains/e2e-001/data/opp-debugging`. That confirms the
operator registry, batch-operator scheduling, and consensus are all functioning end to end.

See [LOCAL_DOCKER_E2E_CLUSTER_GUIDE.md](./LOCAL_DOCKER_E2E_CLUSTER_GUIDE.md) for flag-by-flag
explanations, leak-check commands, and troubleshooting.


# DEVCONTAINER Dev Setup
Containerized, isolated environments for running parallel Claude Code sessions against Wire blockchain repos. Each task
gets its own git worktrees and devcontainer while sharing build caches across tasks.

## Prerequisites

- Docker
- Fish shell
- [devcontainer CLI](https://github.com/devcontainers/cli) (`npm install -g @devcontainers/cli`)
- All required Wire repos cloned as siblings under the same parent directory:
    - `wire-sysio`, `wire-cdt`, `wire-libraries-ts`, `wire-tools-ts`
    - `wire-ethereum`, `wire-solana`, `wire-vcpkg-registry`
    - `wire-opp` (optional, is not a repo, but rather a generated artifact for OPP Protobufs, copied into worktree if
      present, generated otherwise)

## Quick Start

```bash
# 1. Run setup (validates repos, builds image, symlinks CLI)
./scripts/devcontainer-setup

# 2. Spin up a task
claude-task-env up task-1 my-feature-branch

# 3. Tear it down when done
claude-task-env down task-1
```

## How It Works

### Directory Layout

```
<codeRoot>/
  wire/
    wire-devcontainer/        # this repo
    wire-sysio/               # sibling repos
    wire-cdt/
    wire-libraries-ts/
    wire-tools-ts/
    wire-ethereum/
    wire-solana/
    wire-vcpkg-registry/
    wire-opp/                 # optional
  wire-tasks/               # created by CLI
    task-1/                 # worktrees for task 1
      wire-sysio/
      wire-cdt/
      ...
    task-2/                 # worktrees for task 2
      ...
```

### Task Lifecycle

**`claude-task-env up TASK_ID [REPO...]`**

1. Creates git worktrees for all default repos (+ any extras) at `wire-tasks/<TASK_ID>/`
2. Initializes git submodules where `.gitmodules` exists
3. Copies `wire-opp` into the worktree if the repo exists
4. Launches a devcontainer and opens a Claude Code session inside it without copying or mounting host Claude credentials/config

**`claude-task-env down TASK_ID`**

1. Removes the docker container (`claude-<TASK_ID>`)
2. Removes all git worktrees
3. Cleans up task directories

### Shared Caches

Docker named volumes persist across tasks and container rebuilds:

| Volume        | Mount           | Purpose                          |
|---------------|-----------------|----------------------------------|
| `wire-ccache` | `/cache/ccache` | C/C++ compiler cache (100GB max) |
| `wire-vcpkg`  | `/cache/vcpkg`  | vcpkg binary cache               |
| `wire-pnpm`   | `/cache/pnpm`   | pnpm package store               |
| `wire-cargo`  | `/cache/cargo`  | Rust/Cargo cache                 |

Host Claude credentials/config are not copied or bind-mounted into task containers. Claude state stays inside the
container filesystem for the lifetime of that task container.

### Container Resources

Configured in `.devcontainer/devcontainer.json`:

- **Memory**: 32 GB
- **CPU**: Pinned via `--cpuset-cpus` (calculated from TASK_ID and core count)
- **PID limit**: 1048576
- **tmpfs**: 8 GB at `/tmp`
- **User**: `dev` (non-root, UID 1000)

## Container Toolchain

The `wire-devcontainer:latest` image (Ubuntu 24.04) includes:

- **C/C++**: clang-18, cmake, ninja-build, ccache
- **Rust**: stable toolchain
- **Node.js**: 24.14.1 (nvm) + pnpm 10.32.1
- **Go**: system package
- **Python**: 3.x + pip + venv
- **Blockchain**: Foundry (Anvil), Solana CLI
- **Claude Code**: pre-installed
- **Shell**: Fish

## Scripts

| Script                            | Purpose                                                                                             |
|-----------------------------------|-----------------------------------------------------------------------------------------------------|
| `scripts/devcontainer-setup`      | One-time setup: validates repos, builds Docker image, symlinks `claude-task-env` to `~/.local/bin/` |
| `scripts/claude-task-env`         | Main CLI: `up` and `down` subcommands for task lifecycle                                            |
| `scripts/devcontainer-e2e-build`  | In-container full build: compiles wire-cdt, wire-sysio, wire-libraries-ts, and links all packages   |

## CLI Reference

```
claude-task-env [OPTIONS] COMMAND [ARGS...]

Options:
  -h, --help   Show help

Commands:
  up     Create worktrees and launch a devcontainer
  down   Tear down a task and remove worktrees
```

### up

```
claude-task-env up [OPTIONS] TASK_ID [REPO...]

Options:
  -h, --help        Show help

Arguments:
  TASK_ID   Unique task identifier (must contain a number for CPU pinning)
  REPO...   Additional repos beyond the defaults
```

### down

```
claude-task-env down [OPTIONS] TASK_ID

Options:
  -h, --help   Show help

Arguments:
  TASK_ID   Task identifier to tear down
```

## Build devcontainer image w/options

The base image is built automatically by `devcontainer-setup`, but you can also build it manually with
optional features:

```fish
# Basic build (no code search)
docker build --progress=plain --network=host -t wire-devcontainer:latest .

# With Claude Code Search (semantic code search MCP tool)
docker build --progress=plain --network=host \
  --build-arg HUGGING_FACE_HUB_TOKEN_ARG=hf_XXXXXXXXXXXXXXXX \
  -t wire-devcontainer:latest .
```

When `HUGGING_FACE_HUB_TOKEN_ARG` is provided, the build installs
[claude-context-local](https://github.com/FarhanAliRaza/claude-context-local) and registers the
`code-search` MCP tool for Claude Code. This gives Claude semantic code search across your workspace
using the `google/embeddinggemma-300m` embedding model.

### Hugging Face authentication

The embedding model requires accepting terms on Hugging Face before the token can download it:

1. **Accept model terms** — visit <https://huggingface.co/google/embeddinggemma-300m> and accept
   the license
2. **Create an access token** — go to <https://huggingface.co/settings/tokens> and create a token
   (read access is sufficient)
3. Pass the token as the `HUGGING_FACE_HUB_TOKEN_ARG` build arg (shown above)

After the first successful download (~1.2–2 GB), the model is cached inside the image and
subsequent container starts load it offline.

## Quick Start Build/Setup/Init

1. Launch a devcontainer, via `claude-task-env up <task-id>`
2. (this will be automated shortly) Start a fish shell inside the container (`docker exec -it claude-<task-id> fish`) and run:

```fish
devcontainer-e2e-build
```

This script (Fish, requires `IN_DEVCONTAINER` env):

1. Installs `@protobuf-ts/plugin` globally
2. Builds `wire-libraries-ts` and creates `pnpm link --global` for shared packages (`sdk-core`, `shared`, `shared-node`, `shared-web`)
3. Builds and globally links the protoc plugins (`protoc-gen-solidity`, `protoc-gen-solana`, `protobuf-bundler`)
4. Configures and compiles `wire-cdt` (CMake + Ninja, installs to `~/.local`)
5. Configures and compiles `wire-sysio` (CMake + Ninja, with system contracts)
6. Links `wire-opp` TypeScript and Solidity model packages if present

Only needed once per fresh container -- build caches (`ccache`, `vcpkg`) persist across containers via shared Docker volumes.
