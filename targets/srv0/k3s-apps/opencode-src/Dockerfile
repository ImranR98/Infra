# The upstream ghcr.io/anomalyco/opencode image is Alpine/musl. Homebrew on
# Linux requires glibc, so this image is Debian trixie with the glibc opencode
# CLI build. Homebrew, nvm and the default Node version are baked in as seeds;
# the entrypoint copies them onto the PVC-backed tools volume on first start.
#
# Version ARGs are pinned. Renovate custom managers in renovate.json update
# them; rebuild and re-pin the image digest with build.sh after a bump.
ARG OPENCODE_VERSION=2.1.4
ARG NODE_VERSION=24.22.1

# --- opencode CLI -----------------------------------------------------------
FROM debian:trixie-slim AS opencode-bin
ARG OPENCODE_VERSION
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://registry.npmjs.org/@opencode/cli-linux-x64-baseline/-/cli-linux-x64-baseline-${OPENCODE_VERSION}.tgz" \
      | tar -xz -C /tmp \
 && install -D -m 0755 /tmp/package/bin/opencode /out/opencode \
 && rm -rf /tmp/package \
 && /out/opencode --version

# --- nvm + Node LTS ---------------------------------------------------------
FROM debian:trixie-slim AS nvm
ARG NVM_VERSION=0.40.8
ARG NODE_VERSION
ARG UID=1000
ARG GID=1000
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid "${GID}" opencode \
 && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash opencode
USER opencode
ENV HOME=/home/opencode \
    NVM_DIR=/home/opencode/.nvm
RUN /bin/bash -c 'git clone --depth=1 --branch "v${NVM_VERSION}" https://github.com/nvm-sh/nvm.git "${NVM_DIR}" \
 && . "${NVM_DIR}/nvm.sh" \
 && nvm install "${NODE_VERSION}" \
 && nvm alias default "${NODE_VERSION}" \
 && nvm use default \
 && node --version \
 && npm --version'

# --- Homebrew + portable Ruby ----------------------------------------------
FROM debian:trixie-slim AS brew
ARG UID=1000
ARG GID=1000
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl git file procps unzip xz-utils bzip2 \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid "${GID}" opencode \
 && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash opencode
USER opencode
ENV HOME=/home/opencode
RUN NONINTERACTIVE=1 CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" -- --path=/home/opencode/.linuxbrew
RUN /home/opencode/.linuxbrew/bin/brew --version

# --- final image ------------------------------------------------------------
FROM debian:trixie-slim
ARG NODE_VERSION
ARG UID=1000
ARG GID=1000

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget git git-lfs gnupg openssh-client openssl \
        build-essential pkg-config cmake ninja-build autoconf automake libtool bison flex patch \
        libssl-dev zlib1g-dev libffi-dev libreadline-dev libsqlite3-dev libyaml-dev \
        libxml2-dev libxslt1-dev libjpeg-dev libpq-dev \
        python3 python3-pip python3-venv python3-dev pipx \
        jq ripgrep fd-find bat fzf tree less neovim vim-tiny tmux htop procps psmisc \
        rsync tar gzip xz-utils bzip2 zstd unzip zip file which tzdata \
        shellcheck yamllint gh \
        bind9-dnsutils iputils-ping netcat-openbsd iproute2 traceroute socat \
        sqlite3 postgresql-client \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${GID}" opencode \
 && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash opencode

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && mkdir -p /home/linuxbrew /sandbox /usr/local/nvm \
 && chown "${UID}:${GID}" /home/linuxbrew /sandbox

COPY --from=opencode-bin /out/opencode /usr/local/bin/opencode
RUN ln -sf opencode /usr/local/bin/opencode2

COPY --from=brew /home/opencode/.linuxbrew /opt/homebrew-seed
COPY --from=nvm /home/opencode/.nvm /opt/nvm-seed

COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh
COPY profile-homebrew.sh /etc/profile.d/homebrew.sh
COPY profile-nvm.sh /etc/profile.d/nvm.sh
RUN chmod 0644 /etc/profile.d/homebrew.sh /etc/profile.d/nvm.sh

ENV NODE_VERSION=${NODE_VERSION} \
    NVM_DIR=/home/linuxbrew/.nvm \
    HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew \
    HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar \
    HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew \
    HOMEBREW_CACHE=/home/linuxbrew/.cache/Homebrew \
    HOMEBREW_NO_ANALYTICS=1 \
    PIPX_HOME=/home/opencode/.local/pipx \
    PIPX_BIN_DIR=/home/opencode/.local/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
ENV PATH=/usr/local/nvm/current/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/opencode/.local/bin:/home/opencode/.cargo/bin:/home/opencode/.bun/bin:/home/opencode/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN ln -sfn "/home/linuxbrew/.nvm/versions/node/v${NODE_VERSION}" /usr/local/nvm/current

USER opencode
ENV HOME=/home/opencode
WORKDIR /sandbox
EXPOSE 4096
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh", "opencode"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "4096"]
