# =============================================================================
# wire-test-cluster Docker Image
#
# Multi-stage build that compiles all native dependencies (wire-cdt, wire-sysio,
# wire-ethereum) and links the TypeScript harness into a single image exposing
# the `wire-test-cluster` CLI.
#
# Build:
#   docker build --memory=64g --cpu-count=16 --build-arg GITHUB_TOKEN=$(gh auth token) -t wire/dev-worktree -f wire-dev-worktree.wire-dev-worktree.Dockerfile .
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
FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=/usr/bin/clang-18
ENV CXX=/usr/bin/clang++-18
ENV MP_COUNT=14
ENV PKG_CACHE_PATH=/root/.pkg-cache

# GitHub token for private repo access (passed via --build-arg).
# Used only during build for git clone of private repos.
ARG GITHUB_TOKEN

RUN apt-get update && apt-get install -y --no-install-recommends \
      lsb-release \
      wget \
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

# Configure git to use HTTPS + token for all github.com clones (private repos)
RUN git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

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
RUN git clone --recursive https://github.com/Wire-Network/wire-libraries-ts.git
RUN git clone --recursive https://github.com/Wire-Network/wire-tools-ts.git
RUN git clone -b feature/protobufs-for-opp --recursive \
      https://github.com/Wire-Network/wire-ethereum.git

RUN git clone -b feature/opp-solana-outpost-integration --recursive \
      https://github.com/Wire-Network/wire-solana.git

RUN git clone --recursive https://github.com/Wire-Network/wire-cdt.git && \
		cd wire-cdt && \
    ./vcpkg/bootstrap-vcpkg.sh

RUN git clone -b feature/opp-part2 --recursive https://github.com/Wire-Network/wire-sysio.git && \
    cd wire-sysio && \
    ./vcpkg/bootstrap-vcpkg.sh


# ---------------------------------------------------------------------------
# Stage 1: Build wire-cdt
# ---------------------------------------------------------------------------
FROM base AS build-cdt

# Global protoc-gen plugin (required by wire-libraries-ts / wire-tools-ts builds).
RUN npm i -g @protobuf-ts/plugin && pnpm i -g @protobuf-ts/plugin

WORKDIR ${WIRE_ROOT}/wire-cdt

RUN cmake \
      -G Ninja \
      -DENABLE_CCACHE=ON \
      -DENABLE_DISTCC=OFF \
      -DENABLE_TESTS=ON \
      -DCMAKE_TOOLCHAIN_FILE=$PWD/vcpkg/scripts/buildsystems/vcpkg.cmake \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_COMPILER=/usr/bin/clang-18 \
      -DCMAKE_CXX_COMPILER=/usr/bin/clang++-18 \
      -DCMAKE_INSTALL_PREFIX=${WIRE_PREFIX} \
      -DCMAKE_PREFIX_PATH=${WIRE_PREFIX} \
      -DCMAKE_PARALLEL_LEVEL=${MP_COUNT} \
      -S . \
      -B build/debug

RUN cmake --build build/debug -j${MP_COUNT} --target all
RUN cmake --install build/debug


# ---------------------------------------------------------------------------
# Stage 2: Build wire-sysio (depends on wire-cdt prefix; emits OPP bundles)
# ---------------------------------------------------------------------------
FROM build-cdt AS build-sysio

WORKDIR ${WIRE_ROOT}/wire-sysio

ENV PATH="/root/.local/share/pnpm:${PATH}"
RUN git pull && mkdir -p build/opp && cd ./libraries/opp/tools && \
    pnpm install &&  \
    pnpm --filter "proto*" dist && \
    cd protoc-gen-solidity && pnpm link --global && cd .. && \
    cd protoc-gen-solana && pnpm link --global && cd .. && \
    cd protobuf-bundler && pnpm link --global && cd .. && \
    which wire-protobuf-bundler &&  \
    which protoc-gen-solana && \
    which protoc-gen-solidity && \
    echo "wire-protobuf-bundler,protoc-gen-solana,protoc-gen-solidity are on the PATH"
RUN cd ./libraries/opp/tools && ./scripts/generate-opp-bundles.fish
RUN cmake \
      -DENABLE_CCACHE=ON \
      -DENABLE_DISTCC=OFF \
      -DENABLE_TESTS=ON \
      -DBUILD_OPP_BUNDLES=ON \
      -DBUILD_SYSTEM_CONTRACTS=ON \
      -DBUILD_TEST_CONTRACTS=ON \
      -DCMAKE_TOOLCHAIN_FILE=$PWD/vcpkg/scripts/buildsystems/vcpkg.cmake \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DCMAKE_BUILD_TYPE=Debug \
    	-DCMAKE_C_COMPILER=/usr/bin/clang-18 \
      -DCMAKE_CXX_COMPILER=/usr/bin/clang++-18 \
      -DCMAKE_INSTALL_PREFIX=${WIRE_PREFIX} \
      -DCMAKE_PREFIX_PATH=${WIRE_PREFIX}/cdt \
      -DCMAKE_PARALLEL_LEVEL=${MP_COUNT} \
      -S . \
      -B build/debug

RUN cmake --build build/debug -j${MP_COUNT} --target all

# wire-opp bundles are produced by sysio's BUILD_OPP_BUNDLES target.
# Override the base-stage WIRE_OPP_ROOT to match the sysio build output path.
ENV WIRE_OPP_ROOT=${WIRE_ROOT}/wire-sysio/build/opp

RUN test -d ${WIRE_OPP_ROOT}/typescript -a -d ${WIRE_OPP_ROOT}/solidity \
    && cd ${WIRE_OPP_ROOT}/typescript \
    && npm i  \
    && npm link \
    && cd ${WIRE_OPP_ROOT}/solidity \
    && npm i  \
    && npm link


# ---------------------------------------------------------------------------
# Stage 3: Build wire-libraries-ts (pnpm monorepo)
# ---------------------------------------------------------------------------
FROM build-sysio AS build-libraries-ts

WORKDIR ${WIRE_ROOT}/wire-libraries-ts

RUN pnpm install --no-frozen-lockfile
RUN pnpm run build
RUN pnpm install


# ---------------------------------------------------------------------------
# Stage 4: Build wire-tools-ts (depends on wire-libraries-ts)
# ---------------------------------------------------------------------------
FROM build-libraries-ts AS build-tools-ts

WORKDIR ${WIRE_ROOT}/wire-tools-ts

RUN pnpm install --force --no-frozen-lockfile
RUN pnpm run build
RUN pnpm install

RUN cd ${WIRE_ROOT}/wire-tools-ts/packages/test-cluster-tool && pnpm link --global
RUN cd ${WIRE_ROOT}/wire-tools-ts/packages/debugging-server && pnpm link --global


# ---------------------------------------------------------------------------
# Stage 5: Build wire-ethereum (Hardhat contracts)
# ---------------------------------------------------------------------------
FROM build-tools-ts AS build-ethereum

WORKDIR ${WIRE_ROOT}/wire-ethereum

RUN npm i
RUN npm link @wireio/opp-solidity-models
RUN npm run build
RUN npx hardhat compile


# ---------------------------------------------------------------------------
# Stage 6: Build wire-solana
# ---------------------------------------------------------------------------
FROM build-ethereum AS build-solana

WORKDIR ${WIRE_ROOT}/wire-solana

RUN cargo build

WORKDIR ${WIRE_ROOT}

ENTRYPOINT ["/usr/bin/fish"]
#CMD ["--help"]
