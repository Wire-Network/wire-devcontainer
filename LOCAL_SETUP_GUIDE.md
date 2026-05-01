# Local Setup Guide

End-to-end host setup for the full Wire stack — every repo cloned, native
toolchain (`wire-cdt`, `wire-sysio`) built, TypeScript / Hardhat / Solana
packages installed and linked. This is the host equivalent of
[`e2e-build.Dockerfile`](./e2e-build.Dockerfile), driven by a single
script: [`scripts/wire-local-setup.bash`](./scripts/wire-local-setup.bash).

## Quick Start

The script accepts a single positional argument: `WIRE_ROOT`, the directory
everything will be cloned and built under. It must be empty (or not yet
exist) — the script refuses to clobber an existing checkout.

Replace `<wire-repo-clone-root>` with the path to a directory where you want
to clone the Wire repos into.

```bash
# Usage:
# curl -fsSL https://raw.githubusercontent.com/Wire-Network/wire-devcontainer/master/scripts/wire-local-setup.bash \
#  | bash -s -- [--git-ssh] "<wire-repo-clone-root>"

# Example using `https` for git urls:
curl -fsSL https://raw.githubusercontent.com/Wire-Network/wire-devcontainer/master/scripts/wire-local-setup.bash \
  | bash -s -- "$HOME/code/wire"
  
# Example using `ssh` for git urls:
curl -fsSL https://raw.githubusercontent.com/Wire-Network/wire-devcontainer/master/scripts/wire-local-setup.bash \
  | bash -s -- --git-ssh "$HOME/code/wire"  
```

If you've already cloned `wire-devcontainer` you can just run the script
locally:

```bash
# Usage:
# ./scripts/wire-local-setup.bash [--git-ssh] "<wire-repo-clone-root>"

# Example using `https` for git urls:
./scripts/wire-local-setup.bash "$HOME/code/wire"

# Example using `ssh` for git urls:
./scripts/wire-local-setup.bash --git-ssh "$HOME/code/wire"
```

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

### 0. Validate `WIRE_ROOT` and prepare directories

```bash
mkdir -p "${WIRE_ROOT_ARG}"
WIRE_ROOT="$(cd "${WIRE_ROOT_ARG}" && pwd)"

# Reject any pre-existing content (including dotfiles).
shopt -s dotglob nullglob
existing_entries=( "${WIRE_ROOT}"/* )
shopt -u dotglob nullglob
[[ ${#existing_entries[@]} -eq 0 ]] || die "WIRE_ROOT (${WIRE_ROOT}) is not empty"

export WIRE_PREFIX="${WIRE_ROOT}/local-prefix"
mkdir -p "${WIRE_PREFIX}"
```

If `WIRE_ROOT` contains anything (visible or hidden), the script aborts with
`WIRE_ROOT (...) is not empty`. This is deliberate — re-running into a
half-built tree silently is worse than failing loudly. To restart, delete
or rename the directory and invoke again.

### 1. Clone every Wire repo

Each clone is wrapped in a helper that skips the clone if the target
already contains a `.git` directory (lets you safely re-run after fixing a
mid-script failure without re-downloading).

```bash
clone_repo "https://github.com/Wire-Network/wire-libraries-ts.git" "wire-libraries-ts"
clone_repo "https://github.com/Wire-Network/wire-tools-ts.git"     "wire-tools-ts"
clone_repo "https://github.com/Wire-Network/wire-ethereum.git"     "wire-ethereum" "feature/protobufs-for-opp"
clone_repo "https://github.com/Wire-Network/wire-solana.git"       "wire-solana"   "feature/opp-solana-outpost-integration"
clone_repo "https://github.com/Wire-Network/wire-cdt.git"          "wire-cdt"
clone_repo "https://github.com/Wire-Network/wire-sysio.git"        "wire-sysio"    "feature/opp-part2"
```

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

- **`WIRE_ROOT (...) is not empty`** — by design. Either point the script
  at a fresh directory, or delete the existing one. If you want to resume
  a partially failed run, see the next bullet.
- **Resuming after a mid-script failure** — `clone_repo` is idempotent (it
  skips if `.git` exists), but the *initial* empty-check still applies
  because it runs before any clones. To resume, comment out the
  empty-check block in the script for that one run, fix the underlying
  failure, and re-invoke. The cmake / pnpm / cargo steps are themselves
  incremental and won't redo work that's already cached.
- **Build OOMs / slow** — lower `MP_COUNT`. The default caps at the host's
  `nproc` but native builds (especially `wire-sysio`) are memory-hungry.
- **Missing OPP bundles** — the script aborts with `wire-opp bundles
  missing under …` if sysio didn't emit them. Verify
  `-DBUILD_OPP_BUNDLES=ON` was honored and that
  `wire-sysio/build/opp/{typescript,solidity}` exist after the sysio
  build.
- **`npm link` errors** — ensure your npm prefix is writable without
  `sudo`; `pnpm setup` (or `npm config set prefix "$HOME/.npm-global"`)
  fixes most cases.

## Reference: Build Order

```
wire-cdt → wire-sysio → wire-libraries-ts → wire-tools-ts
                     ↘ wire-ethereum
                     ↘ wire-solana
```

This matches `e2e-build.Dockerfile`'s multi-stage layout exactly; the
script is the host-side translation, with no Docker involved.
