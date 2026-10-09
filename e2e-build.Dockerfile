# syntax=docker/dockerfile:1.7
# =============================================================================
# wire-test-cluster Docker Image
#
# Multi-stage build that compiles all native dependencies (wire-cdt, wire-sysio,
# wire-ethereum) and links the TypeScript harness into a single image exposing
# the `wire-test-cluster` CLI.
#
# Build (BuildKit required — `# syntax` directive above enables it). The
# GitHub token is supplied as a BuildKit secret (id: `github_token`) and is
# never persisted into any image layer or the resulting image:
#
#   # Pipe `gh auth token` straight into a build secret:
#   GITHUB_TOKEN=$(gh auth token) docker build \
#     --memory=64g --cpu-count=16 \
#     --secret id=github_token,env=GITHUB_TOKEN \
#     -t wire/dev-worktree -f e2e-build.Dockerfile .
#
#   # Or read from a file:
#   docker build \
#     --memory=64g --cpu-count=16 \
#     --secret id=github_token,src=$HOME/.config/wire/github_token \
#     -t wire/dev-worktree -f e2e-build.Dockerfile .
#
#   # If your Docker doesn't enable BuildKit by default, prefix with
#   # `DOCKER_BUILDKIT=1` (or use `docker buildx build`).
#
# Run:
#   docker run -it -wire-dev-worktree-001 \
#     --force --cluster-path=/opt/wire/chains/dev-001 \
#     create --build-path /opt/wire/build/wire-sysio/build/debug \
#     --ethereum-path /opt/wire/build/wire-ethereum -p 1
#
#   docker run --rm -it wire-test-cluster \
#     --cluster-path=/opt/wire/chains/dev-001 run
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: System base — OS packages, compilers, Rust, Foundry, Solana, Node
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS wire-e2e-env

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=/usr/bin/clang-18
ENV CXX=/usr/bin/clang++-18
ARG MP_COUNT=8
ENV MP_COUNT=${MP_COUNT}
ENV PKG_CACHE_PATH=/root/.pkg-cache

# GitHub token is supplied as a BuildKit secret (`--secret id=github_token`)
# on the individual `git clone` RUN steps below — never as a build arg, and
# never persisted into the image's git config.
RUN sed -i 's|http://archive.ubuntu.com|http://us-east-1.ec2.archive.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources
RUN apt-get update && apt-get install -y --no-install-recommends \
      lsb-release \
      wget \
      tini \
      software-properties-common \
    && apt-get install -y \
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
	    libssl-dev  \
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

# -- Rust (stable) --
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

# -- Foundry (Anvil) --
RUN curl -L https://foundry.paradigm.xyz | bash \
    && /root/.foundry/bin/foundryup
ENV PATH="/root/.foundry/bin:${PATH}"

# -- Solana CLI (solana-test-validator) --
RUN sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)" \
    && true
ENV PATH="/root/.local/share/solana/install/active_release/bin:${PATH}"


# Persist the fully-assembled PATH (nvm/pnpm + cargo + foundry + solana) into
# ${WIRE_ROOT}/.env so downstream tooling (devcontainer, IDE, shells) can
# source the same environment without re-running this script.
RUN echo "PATH=${PATH}" > "${WIRE_ROOT}/.env"

# -- AVM + Anchor --
RUN cargo install --git https://github.com/solana-foundation/anchor avm --force && \
	avm install latest && \
	avm use latest

# -- Node.js 24 via nvm + pnpm --
ENV NVM_DIR="/root/.nvm"
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV SHELL="/usr/bin/fish"

RUN mkdir -p $NVM_DIR $PNPM_HOME \
		&& chown -R root:root $NVM_DIR $PNPM_HOME
RUN bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
    && source "$NVM_DIR/nvm.sh" \
    && nvm install 24.14.1 \
    && nvm alias default 24.14.1 \
    && ln -s "$NVM_DIR/versions/node/$(nvm version default)" "$NVM_DIR/versions/node/default" \
    && corepack enable \
    && corepack prepare pnpm@10.32.1 --activate'
ENV PATH="$NVM_DIR/versions/node/default/bin:${PATH}"

# Set up pnpm global bin directory
ENV PATH="${PNPM_HOME}:${PATH}"
RUN pnpm setup || true

# SETUP PKG_CACHE_PATH FOR `@yao-pkg/pkg` & `pkg`
RUN mkdir -p ${PKG_CACHE_PATH}/v3.5/ && npx @yao-pkg/pkg-fetch node24 linux x64 && find ${PKG_CACHE_PATH}
COPY assets/pkg/* ${PKG_CACHE_PATH}/v3.5/

# Install prefix for all native Wire builds
ENV WIRE_ROOT=/opt/wire/build
ENV WIRE_OPP_ROOT=${WIRE_ROOT}/wire-opp
ENV WIRE_PREFIX=/opt/wire/prefix
RUN mkdir -p ${WIRE_PREFIX} ${WIRE_OPP_ROOT}

WORKDIR ${WIRE_ROOT}

# Clone every Wire repo in a single auth-scoped RUN.
#
# How auth works (and why this is safe):
#   1. The BuildKit secret is mounted read-only at /run/secrets/github_token
#      for the duration of *this RUN only*. After the RUN finishes the
#      mount is gone — it is never part of any image layer.
#   2. We read the token (stripping any stray CR/LF) into a shell variable,
#      then set a global `url.<authed-url>.insteadOf` rewrite so any clone
#      against `https://github.com/...` is fetched via
#      `https://x-access-token:${TOKEN}@github.com/...`. `insteadOf` rewrites
#      at the *network* layer; the cloned repo's `.git/config` records the
#      original (unauthenticated) URL, so submodules and the cloned repos
#      themselves never carry the token.
#   3. We `--unset-all` the rewrite before the RUN exits, so /root/.gitconfig
#      is clean in the resulting image layer. (If a clone fails mid-way the
#      RUN itself fails, so no layer is committed at all.)
#
# `set -e` (via `&&` chaining) ensures any failure aborts before the unset.

ARG GIT_BRANCH_CDT=master
ARG GIT_BRANCH_SYSIO=master
ARG GIT_BRANCH_SOLANA=next
ARG GIT_BRANCH_ETHEREUM=next
ARG GIT_BRANCH_LIBRARIES_TS=master
ARG GIT_BRANCH_TOOLS_TS=master
RUN --mount=type=secret,id=github_token,required=true \
    set -eu && \
    GH_TOKEN="$(tr -d '\r\n' < /run/secrets/github_token)" && \
    [ -n "${GH_TOKEN}" ] || { echo "github_token secret was empty" >&2; exit 1; } && \
    INSTEAD_OF_KEY="url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf" && \
    git config --global "${INSTEAD_OF_KEY}" "https://github.com/" && \
    git clone -b ${GIT_BRANCH_LIBRARIES_TS} --recursive \
    		https://github.com/Wire-Network/wire-libraries-ts.git && \
    git clone -b ${GIT_BRANCH_TOOLS_TS} --recursive \
    		https://github.com/Wire-Network/wire-tools-ts.git && \
    git clone -b ${GIT_BRANCH_ETHEREUM} --recursive \
        https://github.com/Wire-Network/wire-ethereum.git && \
    git clone -b ${GIT_BRANCH_SOLANA} --recursive \
        https://github.com/Wire-Network/wire-solana.git && \
    git clone -b ${GIT_BRANCH_CDT} --recursive \
        https://github.com/Wire-Network/wire-cdt.git && \
    git clone -b ${GIT_BRANCH_SYSIO} --recursive \
        https://github.com/Wire-Network/wire-sysio.git && \
    git config --global --unset-all "${INSTEAD_OF_KEY}"

ENV VCPKG_DEFAULT_BINARY_CACHE=/vcpkg-cache
ENV VCPKG_BINARY_SOURCES="clear;files,${VCPKG_DEFAULT_BINARY_CACHE},readwrite"

ENV CCACHE_DIR=/ccache \
  CCACHE=/usr/bin/ccache \
  CCACHE_MAXSIZE=25G \
  CCACHE_ALLOW_SOFT_FAILURES=1 \
  CCACHE_FALLBACK_NOT_ERROR=1

ENV	CMAKE_C_COMPILER_LAUNCHER=${CCACHE} \
	CMAKE_CXX_COMPILER_LAUNCHER=${CCACHE}


ENV ROOT_PREFIX=/root/.local
ENV ROOT_BIN=${ROOT_PREFIX}/bin

RUN for d in ${ROOT_BIN} ${CCACHE_DIR} ${VCPKG_DEFAULT_BINARY_CACHE};do \
   echo "Checking: ${d}"; \
    if [[ ! -d ${d} ]];then \
    	mkdir -p ${d}; \
    fi \
done

RUN ${CCACHE} -M ${CCACHE_MAXSIZE}

# vcpkg bootstraps don't need the GitHub token (the submodules were already
# fetched by `--recursive` above), so they run in their own RUNs without a
# secret mount.
RUN cd ${WIRE_ROOT}/wire-cdt   && ./vcpkg/bootstrap-vcpkg.sh
RUN cd ${WIRE_ROOT}/wire-sysio && ./vcpkg/bootstrap-vcpkg.sh

WORKDIR ${WIRE_ROOT}

RUN mkdir ${ROOT_PREFIX}/bin/
COPY scripts/wire-local-setup.bash /root/.local/bin/wire-local-setup.bash

RUN --mount=type=cache,id=vcpkg-bincache,target=/vcpkg-cache,sharing=locked \
    --mount=type=cache,id=ccache,target=/ccache,sharing=locked \
		echo "Starting (wire-local-setup.bash)" && \
    chmod +x /root/.local/bin/wire-local-setup.bash && \
    /root/.local/bin/wire-local-setup.bash \
    	--skip-apt \
    	--skip-clone \
      --ignore-docker \
    	"${WIRE_ROOT}"
ENTRYPOINT ["/usr/bin/fish"]

