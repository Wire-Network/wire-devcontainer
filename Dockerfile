FROM ubuntu:24.04 AS wire-devcontainer

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=/usr/bin/clang-18
ENV CXX=/usr/bin/clang++-18
ENV MP_COUNT=14

#RUN echo "nameserver 8.8.8.8" > /etc/resolv.conf
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
      libc++-dev \
    	libc++-18-dev \
      libusb-1.0-0-dev \
      libzstd-dev \
      zlib1g-dev \
    	libclang-dev \
      llvm-18 \
    	llvm-18-dev \
	    llvm-18-tools \
	    llvm-18-runtime \
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
    	tmux \
      unzip \
      vim \
    	xclip \
      zip \
      ca-certificates

RUN groupmod -n dev ubuntu && \
    usermod -l dev -d /home/dev -m -s /usr/bin/fish ubuntu && \
    echo "dev ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev && \
    chmod 0440 /etc/sudoers.d/dev

RUN mkdir -p /cache /workspace /data/shared/code/wire && \
		chown -R dev:dev /cache /workspace /data/shared/code/wire

USER dev

ENV USER=dev
ENV HOME=/home/${USER}
ENV CCACHE=/usr/bin/ccache
ENV CCACHE_EXEC=${CCACHE}
ENV CCACHE_DIR=/cache/ccache
ENV CCACHE_SLOPPINESS=locale,time_macros,include_file_mtime
ENV CCACHE_MAXSIZE=100G
ENV CCACHE_ALLOW_SOFT_FAILURES=1
ENV CCACHE_FALLBACK_NOT_ERROR=1
ENV VCPKG_BINARY_CACHE_DIR=/cache/vcpkg
ENV VCPKG_BINARY_SOURCES="files,${VCPKG_BINARY_CACHE_DIR},readwrite"
ENV PNPM_STORE_DIR=/cache/pnpm
ENV PNPM_HOME=${PNPM_STORE_DIR}
ENV CARGO_HOME=/cache/cargo
ENV NVM_DIR="/cache/nvm"
ENV WIRE_WORKSPACE=/workspace
ENV IN_DEVCONTAINER=1

RUN mkdir -p \
    ${CCACHE_DIR} \
    ${PNPM_STORE_DIR} \
    ${CARGO_HOME} \
    ${VCPKG_BINARY_CACHE_DIR} \
    ${NVM_DIR} \
    ${WIRE_WORKSPACE}

# -- Rust (stable) --
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="${CARGO_HOME}/bin:${PATH}"

# -- Foundry (Anvil) --
RUN curl -L https://foundry.paradigm.xyz | bash \
    && ${HOME}/.foundry/bin/foundryup
ENV PATH="${HOME}/.foundry/bin:${PATH}"

# -- Solana CLI (solana-test-validator) --
RUN sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)" \
    && true
ENV PATH="${HOME}/.local/share/solana/install/active_release/bin:${PATH}"

# -- Node.js 24 via nvm + pnpm --

RUN mkdir -p ${NVM_DIR} ${PNPM_HOME} \
		&& chown -R ${USER}:dev ${NVM_DIR} ${PNPM_HOME}
RUN bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
    && source "${NVM_DIR}/nvm.sh" \
    && nvm install 24.14.1 \
    && nvm alias default 24.14.1 \
    && ln -s "${NVM_DIR}/versions/node/$(nvm version default)" "${NVM_DIR}/versions/node/default"'

ENV PATH="${NVM_DIR}/versions/node/default/bin:${PATH}"
ENV PATH="${PNPM_HOME}:${PATH}"
ENV PATH="/workspace/.devcontainer/bin:${PATH}"
ENV PATH="${HOME}/.local/cdt/bin:${HOME}/.local/bin:${PATH}"

ENV SHELL="/usr/bin/fish"

# CLAUDE CODE
# NOTE: The official install script for Claude Code doesn't work well in a non-interactive environment, so we install it via npm instead. The `pnpm setup`
# command is required to set up the necessary configuration files for Claude Code.
RUN npm install -g @anthropic-ai/claude-code pnpm tsc typescript@6

# PNPM SETUP
RUN pnpm setup || true

# SETUP PKG_CACHE_PATH FOR `@yao-pkg/pkg` & `pkg`
ENV PKG_CACHE_PATH=${HOME}/.pkg-cache
RUN mkdir -p ${PKG_CACHE_PATH}/v3.5/ && \
    npx @yao-pkg/pkg-fetch node24 linux x64 && \
    find ${PKG_CACHE_PATH}
COPY assets/pkg/* ${PKG_CACHE_PATH}/v3.5/

RUN echo "export PATH=${PATH}" >> ${HOME}/.profile && \
		echo "export PATH=${PATH}" >> ${HOME}/.bashrc && \
		echo "export PATH=${PATH}" >> ${HOME}/.config/fish/config.fish

WORKDIR /workspace

ARG HUGGING_FACE_HUB_TOKEN_ARG=""
RUN if [ -n "${HUGGING_FACE_HUB_TOKEN_ARG}" ]; then \
    curl -fsSL https://raw.githubusercontent.com/FarhanAliRaza/claude-context-local/main/scripts/install.sh | bash && \
		claude mcp add code-search \
	    --scope user -- \
	    uv run --directory \
	    ~/.local/share/claude-context-local \
	    python mcp_server/server.py; \
fi

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["fish"]
