# Railway cloud coding workspace
# ------------------------------
# Browser-based VS Code (code-server) + jcode + GitHub CLI + git and dev
# utilities. All user state is written to a Railway volume mounted at /data.
#
# Base image: the official code-server image (Debian 13). It already ships a
# non-root "coder" user (uid 1000) with passwordless sudo, plus git, curl,
# wget, openssh-client and dumb-init.
FROM codercom/code-server:4.130.0

# --------------------------------------------------------------------------- #
# Build-time installs run as root; the final runtime user is switched back to
# the non-root "coder" user near the bottom of this file.
# --------------------------------------------------------------------------- #
USER root
ENV DEBIAN_FRONTEND=noninteractive

# 1) Base utilities required by the workspace.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
      unzip \
      build-essential \
      openssh-client; \
    rm -rf /var/lib/apt/lists/*

# 2) GitHub CLI, installed from GitHub's official apt repository.
RUN set -eux; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    arch="$(dpkg --print-architecture)"; \
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version

# 3) jcode (third-party coding-agent harness) via its official installer.
#    The installer's target directory is NOT assumed: we ask it to install into
#    /usr/local/bin, then locate the resulting binary wherever it landed and
#    expose it on the system PATH so it is available to the runtime user.
RUN set -eux; \
    export HOME=/opt/jcode-install JCODE_INSTALL_DIR=/usr/local/bin; \
    mkdir -p "${HOME}"; \
    curl -fsSL https://jcode.sh/install | bash || \
      echo "jcode installer returned non-zero; verifying binary presence anyway"; \
    jbin="$(command -v jcode || true)"; \
    if [ -z "${jbin}" ]; then \
      jbin="$(find /usr/local/bin "${HOME}" /opt /root -maxdepth 5 -type f -name jcode 2>/dev/null | head -n1)"; \
    fi; \
    test -n "${jbin}" || { echo 'ERROR: jcode binary not found after install' >&2; exit 1; }; \
    if [ "${jbin}" != /usr/local/bin/jcode ]; then install -m 0755 "${jbin}" /usr/local/bin/jcode; fi; \
    chmod -R a+rX /opt/jcode-install 2>/dev/null || true; \
    /usr/local/bin/jcode --version || true

# --------------------------------------------------------------------------- #
# Startup script.
# --------------------------------------------------------------------------- #
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# --------------------------------------------------------------------------- #
# Runtime environment: every user-state path resolves under the /data volume so
# it persists across restarts and redeploys.
# --------------------------------------------------------------------------- #
ENV HOME=/data/home \
    XDG_CONFIG_HOME=/data/config \
    XDG_DATA_HOME=/data/share \
    XDG_STATE_HOME=/data/state \
    XDG_CACHE_HOME=/data/cache \
    EDITOR=nano \
    PORT=8080
# Prepend the persistent, user-writable bin dir used for runtime jcode reinstalls.
ENV PATH="/data/home/.local/bin:${PATH}"

# Run as the non-root user shipped by the base image (uid 1000, passwordless sudo).
USER coder

# Railway injects PORT at runtime; code-server binds 0.0.0.0:${PORT} (see start.sh).
# EXPOSE is informational only.
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/start.sh"]
