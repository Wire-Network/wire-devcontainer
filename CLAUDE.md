# wire-devcontainer

> NOTE: This file may be a symlink placed in the root of
> a wire-task devcontainer. If appropriate or needed,
> it can be modified by rfiting the sym link which can be
> found in `/workspace/wire-devcontainer` from within the container.

Containerized task isolation for parallel Claude Code sessions on Wire blockchain repos.
## Context

At minimum, the repositories required to run the full stack,
all have git worktrees, under `/workspace`

- wire-sysio 
- wire-cdt 
- wire-libraries-ts 
- wire-e2e-tests 
- wire-ethereum 
- wire-solana 
- wire-vcpkg-registry 
- wire-devcontainer

### Setup (Devcontainer)

To use any of the code in the `devcontainer`,
your must first run the following:

```fish
devcontainer-e2e-build
```

> NOTE: This is already on `$PATH`. It builds all native dependencies (wire-cdt, wire-sysio) and links all local TypeScript packages. Only needed once per fresh container.

## Repo Structure

```
wire-devcontainer/
  Dockerfile                    # Main devcontainer image (Ubuntu 24.04)
  wire-e2e-tests.Dockerfile     # Multi-stage build for e2e test cluster (separate concern)
  .devcontainer/
    devcontainer.json           # Container config: mounts, resources, env
  scripts/
    devcontainer-setup          # One-time setup: validate repos, build image, symlink CLI
    claude-task-env             # Main CLI: `up` / `down` subcommands
  assets/pkg/
    fetched-v24.13.0-linux-x64  # Pre-built Node.js binary for @yao-pkg/pkg
```

## Scripts

Both scripts are Fish shell. They share a common preamble that resolves paths:

- `wireClaudeTaskScriptDir` -> `scripts/`
- `wireDevContainerRoot` -> this repo root
- `wireRepoRoot` -> parent dir containing all Wire repos
- `codeRoot` -> grandparent dir
- `wireTaskRoot` -> `$codeRoot/wire-tasks/`

### devcontainer-setup

Run once to validate the environment. Checks all default repos exist, builds the Docker image if missing, creates the task root, and symlinks `claude-task-env` into `~/.local/bin/`.

### devcontainer-e2e-build

**Must be run once inside a fresh `wire-task` devcontainer from a Fish login prompt.** Requires `IN_DEVCONTAINER`, `WIRE_WORKSPACE`, `CC`, and `CXX` env vars (all set by the container image).

Performs the full build and link sequence:

1. Installs `@protobuf-ts/plugin` globally (npm + pnpm)
2. Builds `wire-libraries-ts` and globally links shared packages (`sdk-core`, `shared`, `shared-node`, `shared-web`)
3. Builds + globally links protoc plugins (`protoc-gen-solidity`, `protoc-gen-solana`, `protobuf-bundler`) via `pnpm run dist`
4. Bootstraps vcpkg, configures + compiles `wire-cdt` (CMake/Ninja, installs to `~/.local`)
5. Bootstraps vcpkg, configures + compiles `wire-sysio` (CMake/Ninja, with system + test contracts)
6. Links `wire-opp` TypeScript and Solidity model packages if present

Uses `ccache` and `vcpkg` shared caches, so subsequent runs (or runs in new containers with the same volumes) are fast.

### claude-task-env

CLI with `up` and `down` subcommands. Uses Fish `argparse` for option parsing.

**`up TASK_ID BRANCH [REPO...]`** - Creates worktrees, inits submodules, copies wire-opp, pins CPUs, launches devcontainer + Claude.

**`down TASK_ID`** - Removes container, worktrees, and task directories.

## Default Repos

Always included in every task (defined in `_wireDefaultRepos`):

```
wire-sysio wire-cdt wire-libraries-ts wire-e2e-tests wire-ethereum wire-solana wire-vcpkg-registry
```

Extra repos can be passed as positional args to `up`. Duplicates are filtered.

## Dockerfile

Ubuntu 24.04 base with: clang-18, cmake, ninja, ccache, Rust (stable), Go, Python 3, Node.js 24.14.1 (nvm), pnpm 10.32.1, Foundry, Solana CLI, Claude Code. Non-root `dev` user (UID 1000). Entrypoint is tini + fish.

All caches under `/cache/` (ccache, vcpkg, pnpm, cargo) — mounted as Docker named volumes so they persist across tasks.

## devcontainer.json

- Workspace bind-mounted from `$TASK_WORKTREE` to `/workspace`
- Container named `claude-$TASK_ID`
- 32 GB memory, CPU pinning via `$TASK_CPUS`, 4096 PID limit
- Cache volumes: `wire-ccache`, `wire-vcpkg`, `wire-pnpm`, `wire-cargo`
- Task-specific Claude config: `~/.claude-tasks/$TASK_ID` -> `/home/dev/.claude-task`

## Code Style

- Fish shell scripts, no bash
- `argparse` for all CLI argument parsing
- `die` for fatal errors (exit 255)
- `run` wrapper for commands that must succeed
- Functional helpers: `set-default`, `set-or-default`

## Key Conventions

- All paths are resolved relative to script location, not cwd
- CPU pinning formula: `base = (task_num - 1) * cores`, range `base` to `base + cores - 1`
- `wire-opp` is copied (not worktree'd) since it may not be a standard git repo
- Submodules are auto-initialized after worktree creation
