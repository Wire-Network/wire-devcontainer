#!/usr/bin/env bash
# =============================================================================
# wire-local-setup.bash
#
# Host-side equivalent of e2e-build.Dockerfile: clones every Wire repo into
# WIRE_ROOT, builds the native toolchain (wire-cdt, wire-sysio), then builds
# and links the TypeScript / Hardhat / Solana stacks in dependency order:
#
#     wire-cdt -> wire-sysio -> wire-libraries-ts -> wire-tools-ts
#                            -> wire-ethereum    -> wire-solana
#
# Usage:
#     wire-local-setup.bash <WIRE_ROOT>
#
# WIRE_ROOT must be empty (or not yet exist). WIRE_PREFIX is fixed to
# ${WIRE_ROOT}/local-prefix and used as the cmake install prefix.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  printf '\033[1;36m[wire-local-setup]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[wire-local-setup][warn]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[wire-local-setup][error]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found on PATH: $1"
}

# Clone <url> into <dir-name> at $WIRE_ROOT, optionally checking out <branch>.
# If the target directory already exists, the clone is skipped (idempotent
# re-runs after a partial failure).
clone_repo() {
  local repo_url="$1"
  local repo_name="$2"
  local branch="${3:-}"

  local target_dir="${WIRE_ROOT}/${repo_name}"
  if [[ -d "${target_dir}/.git" ]]; then
    log "skip clone: ${repo_name} already present at ${target_dir}"
    pushd "${target_dir}"
    git pull
    log "pulling: ${repo_name}"
    popd
    return 0
  fi
  if [[ -e "${target_dir}" ]]; then
    die "${target_dir} exists but is not a git checkout — refusing to clone over it"
  fi

  log "cloning ${repo_name}${branch:+ (branch: ${branch})}"
  if [[ -n "${branch}" ]]; then
    git clone -b "${branch}" --recursive "${repo_url}" "${target_dir}"
  else
    git clone --recursive "${repo_url}" "${target_dir}"
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing & flag handling
#
# Parsed up-front so flags like --skip-apt, --skip-clone, and --help take
# effect before any privileged or long-running step (apt, nvm, rustup, …).
#
# Supported flags:
#   --git-ssh     Clone via git@github.com:Wire-Network/* (SSH) instead of
#                 the default https://github.com/Wire-Network/* (HTTPS).
#   --skip-apt    Skip the two apt-get install steps. Use when the host is
#                 already provisioned (CI image, prior run, etc).
#   --skip-clone  Don't clone — instead verify every Wire repo already
#                 exists under WIRE_ROOT. Missing repos are reported to
#                 stderr and the script exits non-zero.
#   -h, --help    Show usage and exit.
#
# Required positional:
#   WIRE_ROOT     Directory the Wire repos live (or will be cloned) under.
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [--git-ssh] [--skip-apt] [--skip-clone] [-h|--help] <WIRE_ROOT>

  WIRE_ROOT       Directory to clone every Wire repo into.
  --git-ssh       Use SSH (git@github.com:...) URLs instead of HTTPS.
  --skip-apt      Skip the apt-get installation steps.
  --skip-clone    Verify all Wire repos already exist under WIRE_ROOT
                  instead of cloning; exit non-zero with a list of any
                  that are missing.
  -h, --help      Show this help and exit.
EOF
}

GIT_SSH=0
SKIP_APT=0
SKIP_CLONE=0
WIRE_ROOT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-ssh)    GIT_SSH=1;    shift ;;
    --skip-apt)   SKIP_APT=1;   shift ;;
    --skip-clone) SKIP_CLONE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)
      shift
      [[ $# -eq 1 ]] || die "expected exactly one positional argument (WIRE_ROOT) after --"
      WIRE_ROOT_ARG="$1"
      shift
      ;;
    -*)
      die "unknown flag: $1 (run with --help for usage)"
      ;;
    *)
      [[ -z "${WIRE_ROOT_ARG}" ]] || die "unexpected extra positional argument: $1 (only WIRE_ROOT is accepted)"
      WIRE_ROOT_ARG="$1"
      shift
      ;;
  esac
done

[[ -n "${WIRE_ROOT_ARG}" ]] || { usage >&2; die "missing required positional argument: WIRE_ROOT"; }

# Resolve the GitHub URL prefix that clone_repo will compose against.
# SSH form:   git@github.com:Wire-Network/<repo>.git
# HTTPS form: https://github.com/Wire-Network/<repo>.git
if [[ ${GIT_SSH} -eq 1 ]]; then
  GIT_REPO_BASE="git@github.com:Wire-Network"
  log "git transport: SSH (${GIT_REPO_BASE})"
else
  GIT_REPO_BASE="https://github.com/Wire-Network"
  log "git transport: HTTPS (${GIT_REPO_BASE})"
fi

[[ ${SKIP_APT}   -eq 1 ]] && log "--skip-apt set: apt installation will be skipped"
[[ ${SKIP_CLONE} -eq 1 ]] && log "--skip-clone set: repos will be verified, not cloned"

# ---------------------------------------------------------------------------
# OS check: require Ubuntu 24.04 (noble)
# ---------------------------------------------------------------------------

[[ -r /etc/os-release ]] || die "cannot read /etc/os-release — unable to verify OS"
# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" || "${VERSION_CODENAME:-}" != "noble" ]]; then
  die "unsupported OS: this script requires Ubuntu 24.04 (noble); detected ID=${ID:-?} VERSION_ID=${VERSION_ID:-?} VERSION_CODENAME=${VERSION_CODENAME:-?}"
fi

log "OS check passed: ${PRETTY_NAME:-Ubuntu 24.04}"

# ---------------------------------------------------------------------------
# apt-get installs (mirrors the Dockerfile base stage)
#
# Two sequential install steps, matching e2e-build.Dockerfile:
#   1. Bootstrap packages with --no-install-recommends
#   2. Full build/runtime toolchain
#
# Run via sudo when invoked as a non-root user. DEBIAN_FRONTEND=noninteractive
# is forwarded explicitly so it survives the sudo env reset.
# ---------------------------------------------------------------------------

if [[ ${SKIP_APT} -eq 1 ]]; then
  log "skipping apt installation (--skip-apt)"
else
  SUDO=""
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 \
      || die "running as non-root user but 'sudo' is not installed — re-run as root or install sudo first"
    SUDO="sudo"
  fi

  run_apt() {
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"
  }

  log "apt-get update"
  run_apt update

  log "installing bootstrap apt packages"
  run_apt install -y --no-install-recommends \
    lsb-release \
    wget \
    software-properties-common

  log "installing build & runtime apt packages"
  run_apt install -y \
    build-essential \
    binutils \
    ccache \
    cmake \
    wget \
    curl \
    doxygen \
    fish \
    git \
    gnupg \
    golang \
    libbz2-dev \
    libcurl4-openssl-dev \
    libgmp-dev \
    liblzma-dev \
    libncurses5-dev \
    libssl-dev \
    libstdc++-14-dev \
    libusb-1.0-0-dev \
    libzstd-dev \
    zlib1g-dev \
    llvm-18 \
    clang-18 \
    clang-tools-18 \
    libclang-18-dev \
    ninja-build \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    autoconf \
    autoconf-archive \
    automake \
    libtool \
    sudo \
    tar \
    unzip \
    vim \
    zip \
    ca-certificates
fi

NVM_DIR="${HOME}/.nvm"
NVM_INIT_SCRIPT="${NVM_DIR}/nvm.sh"
NODE_VERSION="24.14.1"
PNPM_HOME="${HOME}/.local/share/pnpm"

export NVM_DIR PNPM_HOME NODE_VERSION

mkdir -p "${NVM_DIR}" "${PNPM_HOME}"

if [[ -e "${NVM_INIT_SCRIPT}" ]]; then
  echo "NVM is already installed"
else
  bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
fi

if [[ ! -e "${NVM_INIT_SCRIPT}" ]]; then
  die "${NVM_INIT_SCRIPT} does not exist, NVM is corrupt"
fi
# shellcheck disable=SC1090
source "${NVM_INIT_SCRIPT}"
nvm install ${NODE_VERSION}
nvm alias default ${NODE_VERSION}
if [[ ! -e "${NVM_DIR}/versions/node/default" ]]; then
  echo "Linking NVM default to ${NODE_VERSION}"
  ln -s "${NVM_DIR}/versions/node/$(nvm version default)" "${NVM_DIR}/versions/node/default"
  corepack enable
  corepack prepare pnpm@10.32.1 --activate
fi

PATH="${PNPM_HOME}:${NVM_DIR}/versions/node/default/bin:${PATH}"

export PATH
pnpm setup || true

# ---------------------------------------------------------------------------
# WIRE_ROOT resolution
#
# Args were parsed at the top of the script; here we just materialise the
# directory the rest of the build/clone steps will use.
# ---------------------------------------------------------------------------

# Resolve WIRE_ROOT to an absolute path; create the directory if missing.
mkdir -p "${WIRE_ROOT_ARG}"
WIRE_ROOT="$(cd "${WIRE_ROOT_ARG}" && pwd)"

export WIRE_ROOT
export WIRE_PREFIX="${WIRE_ROOT}/local-prefix"
mkdir -p "${WIRE_PREFIX}"

# ---------------------------------------------------------------------------
# Toolchain configuration (mirrors the Dockerfile base stage)
# ---------------------------------------------------------------------------

# Parallelism: fall back to nproc when MP_COUNT is unset, capped at 14 to
# match the Dockerfile default and avoid OOM on smaller hosts.
if [[ -z "${MP_COUNT:-}" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    MP_COUNT=$(($(nproc) / 2))
  else
    MP_COUNT=4
  fi
fi
export MP_COUNT

# Tools provided by rustup / foundry / solana / avm. If every one is already
# resolvable on the current PATH we skip the installer commands entirely; if
# any is missing we install the full set (rust + foundry + solana + avm).
TOOLCHAIN_REQUIRED_TOOLS=(cargo rustc forge anvil cast solana solana-test-validator avm anchor)

toolchain_missing=()
for cmd in "${TOOLCHAIN_REQUIRED_TOOLS[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || toolchain_missing+=("$cmd")
done

if [[ ${#toolchain_missing[@]} -eq 0 ]]; then
  log "rust/foundry/solana/avm tools already on PATH — skipping toolchain installation"
else
  log "installing rust/foundry/solana/avm (missing: ${toolchain_missing[*]})"

  # -- Rust (stable) --
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  PATH="${HOME}/.cargo/bin:${PATH}"

  # -- Foundry (Anvil) --
  curl -L https://foundry.paradigm.xyz | bash && "${HOME}/.foundry/bin/foundryup"
  PATH="${HOME}/.foundry/bin:${PATH}"

  # -- Solana CLI (solana-test-validator) --
  sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
  PATH="${HOME}/.local/share/solana/install/active_release/bin:${PATH}"

  export PATH

  # -- AVM + Anchor --
  cargo install --git https://github.com/solana-foundation/anchor avm --force
  avm install latest
  avm use latest
fi

# Persist the fully-assembled PATH (nvm/pnpm + cargo + foundry + solana) into
# ${WIRE_ROOT}/.env so downstream tooling (devcontainer, IDE, shells) can
# source the same environment without re-running this script. The .env is
# written unconditionally so it reflects whatever PATH ended up being —
# whether we installed the toolchain in this run or skipped because
# everything was already present.
log "writing ${WIRE_ROOT}/.env"
cat > "${WIRE_ROOT}/.env" <<EOF
PATH=${PATH}
EOF

# Sanity-check required host tooling up front so we fail fast.
for cmd in git cmake ninja pnpm npm node cargo anchor solana-test-validator clang-18 clang++-18; do
  require_cmd "$cmd"
done

CC=$(which clang-18)
CXX=$(which clang++-18)
export CC CXX

log "WIRE_ROOT=${WIRE_ROOT}"
log "WIRE_PREFIX=${WIRE_PREFIX}"
log "CC=${CC} CXX=${CXX} MP_COUNT=${MP_COUNT}"

# ---------------------------------------------------------------------------
# Stage 0: Clone every Wire repo
# ---------------------------------------------------------------------------

cd "${WIRE_ROOT}"

WIRE_REPOS=(wire-libraries-ts wire-tools-ts wire-ethereum wire-solana wire-cdt wire-sysio)

if [[ ${SKIP_CLONE} -eq 1 ]]; then
  log "verifying every Wire repo exists under ${WIRE_ROOT} (--skip-clone)"
  missing_repos=()
  for repo in "${WIRE_REPOS[@]}"; do
    [[ -d "${WIRE_ROOT}/${repo}/.git" ]] || missing_repos+=("${repo}")
  done
  if [[ ${#missing_repos[@]} -gt 0 ]]; then
    {
      printf '[wire-local-setup][error] --skip-clone set but the following repos are missing under %s:\n' "${WIRE_ROOT}"
      for repo in "${missing_repos[@]}"; do
        printf '  - %s\n' "${repo}"
      done
    } >&2
    exit 1
  fi
  log "all ${#WIRE_REPOS[@]} repos present — skipping clone step"
else
  clone_repo "${GIT_REPO_BASE}/wire-libraries-ts.git" "wire-libraries-ts"
  clone_repo "${GIT_REPO_BASE}/wire-tools-ts.git"     "wire-tools-ts"
  clone_repo "${GIT_REPO_BASE}/wire-ethereum.git"     "wire-ethereum" "feature/protobufs-for-opp"
  clone_repo "${GIT_REPO_BASE}/wire-solana.git"       "wire-solana"   "feature/opp-solana-outpost-integration"
  clone_repo "${GIT_REPO_BASE}/wire-cdt.git"          "wire-cdt"
  clone_repo "${GIT_REPO_BASE}/wire-sysio.git"        "wire-sysio"    "feature/opp-part2"
fi

# vcpkg bootstraps live alongside the cdt / sysio clones in the Dockerfile.
log "bootstrapping vcpkg for wire-cdt"
( cd "${WIRE_ROOT}/wire-cdt"   && ./vcpkg/bootstrap-vcpkg.sh )
log "bootstrapping vcpkg for wire-sysio"
( cd "${WIRE_ROOT}/wire-sysio" && ./vcpkg/bootstrap-vcpkg.sh )

# ---------------------------------------------------------------------------
# Stage 1: Build wire-cdt
# ---------------------------------------------------------------------------

log "configuring wire-cdt"
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

log "building wire-cdt"
cmake --build build/debug -j"${MP_COUNT}" --target all
cmake --install build/debug

# ---------------------------------------------------------------------------
# Stage 2: Build wire-sysio (depends on wire-cdt prefix; emits OPP bundles)
# ---------------------------------------------------------------------------

log "installing global @protobuf-ts/plugin for OPP"
npm i -g @protobuf-ts/plugin
pnpm i -g @protobuf-ts/plugin

log "wire-sysio setup & build"
cd "${WIRE_ROOT}/wire-sysio"

log "wire-sysio: Building OPP Bundles"
pushd ./libraries/opp/tools
pnpm install
pnpm --filter "proto*" dist

for p in protoc-gen-solidity protoc-gen-solana protobuf-bundler
do
  echo "Global Link: ${p}"
  pushd ${p} && pnpm link --global && popd
done

echo "wire-protobuf-bundler,protoc-gen-solana,protoc-gen-solidity are on the PATH"
./scripts/generate-opp-bundles.fish
popd

log "wire-sysio: CMake configure & build"
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

log "building wire-sysio"
cmake --build build/debug -j"${MP_COUNT}" --target opp_cdt_models.protos
cmake --build build/debug -j"${MP_COUNT}" --target all

export WIRE_OPP_ROOT="${WIRE_ROOT}/wire-sysio/build/opp"
[[ -d "${WIRE_OPP_ROOT}/typescript" && -d "${WIRE_OPP_ROOT}/solidity" ]] \
  || die "wire-opp bundles missing under ${WIRE_OPP_ROOT} — sysio build did not emit them"

log "installing & npm-linking wire-opp typescript bundle"
cd "${WIRE_OPP_ROOT}/typescript"
pnpm i --force --no-frozen-lockfile
npm link

log "installing & npm-linking wire-opp solidity bundle"
cd "${WIRE_OPP_ROOT}/solidity"
pnpm i --force --no-frozen-lockfile
npm link

# ---------------------------------------------------------------------------
# Stage 3: Build wire-libraries-ts (pnpm monorepo)
# ---------------------------------------------------------------------------

log "building wire-libraries-ts"
cd "${WIRE_ROOT}/wire-libraries-ts"
pnpm install --no-frozen-lockfile
pnpm run build
pnpm install

# ---------------------------------------------------------------------------
# Stage 4: Build wire-tools-ts (depends on wire-libraries-ts)
# ---------------------------------------------------------------------------

log "building wire-tools-ts"
cd "${WIRE_ROOT}/wire-tools-ts"
pnpm install --force --no-frozen-lockfile
pnpm run build
pnpm install

PKGS_TO_LINK="debugging-client-tool debugging-client-tool-tui debugging-server test-cluster-tool"
#log "globally linking wire-tools-ts: ${PKGS_TO_LINK}"
for p in $PKGS_TO_LINK; do
  echo "Configuring tool: ${p}"
  pnpm --filter "@wireio/${p}" run dist
  pnpm --filter "@wireio/${p}" exec pnpm link --global
done

# ---------------------------------------------------------------------------
# Stage 5: Build wire-ethereum (Hardhat contracts)
# ---------------------------------------------------------------------------

log "building wire-ethereum"
cd "${WIRE_ROOT}/wire-ethereum"
npm i
npm link @wireio/opp-solidity-models
npm run build
npx hardhat compile

# ---------------------------------------------------------------------------
# Stage 6: Build wire-solana
# ---------------------------------------------------------------------------

log "building wire-solana"
cd "${WIRE_ROOT}/wire-solana"
cargo build

log "wire-local setup complete — WIRE_ROOT=${WIRE_ROOT}"
