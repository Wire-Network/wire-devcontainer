# wire-devcontainer

Containerized, isolated environments for running parallel Claude Code sessions against Wire blockchain repos. Each task gets its own git worktrees and devcontainer while sharing build caches across tasks.

## Prerequisites

- Docker
- Fish shell
- [devcontainer CLI](https://github.com/devcontainers/cli) (`npm install -g @devcontainers/cli`)
- All required Wire repos cloned as siblings under the same parent directory:
  - `wire-sysio`, `wire-cdt`, `wire-libraries-ts`, `wire-e2e-tests`
  - `wire-ethereum`, `wire-solana`, `wire-vcpkg-registry`
  - `wire-opp` (optional, is not a repo, but rather a generated artifact for OPP Protobufs, copied into worktree if present, generated otherwise)

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
    wire-e2e-tests/
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

**`claude-task-env up TASK_ID BRANCH [REPO...]`**

1. Creates git worktrees for all default repos (+ any extras) at `wire-tasks/<TASK_ID>/`
2. Initializes git submodules where `.gitmodules` exists
3. Copies `wire-opp` into the worktree if the repo exists
4. Pins CPU cores to the task (based on TASK_ID number and `--cores`)
5. Launches a devcontainer and opens a Claude Code session inside it

**`claude-task-env down TASK_ID`**

1. Removes the docker container (`claude-<TASK_ID>`)
2. Removes all git worktrees
3. Cleans up task directories

### Shared Caches

Docker named volumes persist across tasks and container rebuilds:

| Volume | Mount | Purpose |
|--------|-------|---------|
| `wire-ccache` | `/cache/ccache` | C/C++ compiler cache (100GB max) |
| `wire-vcpkg` | `/cache/vcpkg` | vcpkg binary cache |
| `wire-pnpm` | `/cache/pnpm` | pnpm package store |
| `wire-cargo` | `/cache/cargo` | Rust/Cargo cache |

Task-specific Claude config is bind-mounted from `~/.claude-tasks/<TASK_ID>/`.

### Container Resources

Configured in `.devcontainer/devcontainer.json`:

- **Memory**: 32 GB
- **CPU**: Pinned via `--cpuset-cpus` (calculated from TASK_ID and core count)
- **PID limit**: 4096
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

| Script | Purpose |
|--------|---------|
| `scripts/devcontainer-setup` | One-time setup: validates repos, builds Docker image, symlinks `claude-task-env` to `~/.local/bin/` |
| `scripts/claude-task-env` | Main CLI: `up` and `down` subcommands for task lifecycle |

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
claude-task-env up [OPTIONS] TASK_ID BRANCH [REPO...]

Options:
  -h, --help        Show help
  -c, --cores NUM   CPU cores per task (default: 16)

Arguments:
  TASK_ID   Unique task identifier (must contain a number for CPU pinning)
  BRANCH    Git branch to checkout in all worktrees
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
