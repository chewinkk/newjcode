#!/usr/bin/env bash
#
# start.sh — entrypoint for the Railway cloud coding workspace.
#
# Responsibilities:
#   * strict bash settings + useful failure logs
#   * create every persistent directory under the /data volume
#   * repair /data ownership when Railway mounts a fresh (root-owned) volume
#   * verify jcode is present and safely reinstall it if it is missing
#   * refuse to start without a password (no unauthenticated IDE access)
#   * launch code-server in the foreground on 0.0.0.0:${PORT}
#
# All user state (HOME, XDG dirs, gh/jcode auth, VS Code data, cloned repos)
# lives under /data so it survives container restarts and redeploys as long as
# the Railway volume stays attached.

set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# logging helpers
# --------------------------------------------------------------------------- #
log()  { printf '[start] %s\n'          "$*"; }
warn() { printf '[start][WARN] %s\n'    "$*" >&2; }
die()  { printf '[start][FATAL] %s\n'   "$*" >&2; exit 1; }

on_error() {
  local ec=$?
  warn "startup failed (exit ${ec}) at line ${BASH_LINENO[0]:-?}"
  warn "last command: ${BASH_COMMAND}"
  exit "${ec}"
}
trap on_error ERR

# Run a command as root when we are not already root (the base image grants the
# "coder" user passwordless sudo). Falls back gracefully if sudo is unavailable.
run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    warn "cannot elevate privileges to run: $*"
    return 1
  fi
}

# --------------------------------------------------------------------------- #
# configuration — every path resolves under the /data volume
# --------------------------------------------------------------------------- #
DATA_DIR="/data"
export HOME="${HOME:-/data/home}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/data/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/data/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-/data/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/data/cache}"

WORKSPACE_DIR="/data/workspace"
CS_USER_DATA="/data/code-server/user-data"
CS_EXTENSIONS="/data/code-server/extensions"

PORT="${PORT:-8080}"

# Make sure a persistent, user-writable bin dir is on PATH. This is where a
# runtime jcode reinstall lands, and it persists on the volume.
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

# --------------------------------------------------------------------------- #
# 0. sanity check — is /data actually a mounted Railway volume?
# --------------------------------------------------------------------------- #
if ! grep -qE "[[:space:]]${DATA_DIR}[[:space:]]" /proc/mounts 2>/dev/null; then
  warn "${DATA_DIR} does not look like a mounted Railway volume."
  warn "The IDE will still start, but nothing under ${DATA_DIR} will persist"
  warn "across redeploys until you attach a volume at ${DATA_DIR} in Railway."
fi

# --------------------------------------------------------------------------- #
# 1. create the /data mountpoint (if missing) and repair ownership
# --------------------------------------------------------------------------- #
if [ ! -d "${DATA_DIR}" ]; then
  run_as_root mkdir -p "${DATA_DIR}" || die "cannot create ${DATA_DIR}"
fi

if [ ! -w "${DATA_DIR}" ]; then
  log "repairing ownership of ${DATA_DIR} for uid=$(id -u) gid=$(id -g) ..."
  run_as_root chown -R "$(id -u):$(id -g)" "${DATA_DIR}" \
    || warn "ownership repair failed; some writes under ${DATA_DIR} may fail"
fi

# --------------------------------------------------------------------------- #
# 2. create every persistent directory we rely on
# --------------------------------------------------------------------------- #
log "ensuring persistent directories under ${DATA_DIR} ..."
persistent_dirs=(
  "${HOME}"
  "${XDG_CONFIG_HOME}"
  "${XDG_DATA_HOME}"
  "${XDG_STATE_HOME}"
  "${XDG_CACHE_HOME}"
  "${HOME}/.local/bin"
  "${XDG_CONFIG_HOME}/gh"
  "${WORKSPACE_DIR}"
  "${CS_USER_DATA}"
  "${CS_EXTENSIONS}"
)
for d in "${persistent_dirs[@]}"; do
  mkdir -p "${d}" 2>/dev/null || run_as_root mkdir -p "${d}" || die "cannot create ${d}"
done

# If a freshly-created dir still is not writable, force a final ownership repair.
if [ ! -w "${WORKSPACE_DIR}" ] || [ ! -w "${CS_USER_DATA}" ]; then
  run_as_root chown -R "$(id -u):$(id -g)" "${DATA_DIR}" \
    || warn "second ownership repair failed"
fi

# Avoid git "detected dubious ownership" errors on volume-backed clones.
if command -v git >/dev/null 2>&1; then
  git config --global --replace-all safe.directory '*' 2>/dev/null || true
fi

# --------------------------------------------------------------------------- #
# 3. verify jcode; safely reinstall into a persistent bin dir if missing
# --------------------------------------------------------------------------- #
if command -v jcode >/dev/null 2>&1; then
  log "jcode found at $(command -v jcode)"
else
  warn "jcode not found on PATH; attempting a safe reinstall ..."
  export JCODE_INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "${JCODE_INSTALL_DIR}"
  if curl -fsSL https://jcode.sh/install | bash; then
    hash -r 2>/dev/null || true
    if command -v jcode >/dev/null 2>&1; then
      log "jcode reinstalled at $(command -v jcode)"
    else
      warn "jcode installer ran but jcode is still not on PATH."
      warn "Open the terminal and run: curl -fsSL https://jcode.sh/install | bash"
    fi
  else
    warn "jcode reinstall failed (network policy or outage?)."
    warn "The IDE will start anyway; retry from the terminal when ready:"
    warn "  curl -fsSL https://jcode.sh/install | bash"
  fi
fi

# --------------------------------------------------------------------------- #
# 3b. verify Claude Code (Anthropic's official CLI); install it into the
#     persistent volume home if missing. The native installer manages a
#     self-updating launcher under ${HOME}/.local, so installing it here (on
#     the /data volume) lets it persist and auto-update across restarts.
# --------------------------------------------------------------------------- #
if command -v claude >/dev/null 2>&1; then
  log "Claude Code found at $(command -v claude)"
else
  warn "Claude Code not found; installing into ${HOME}/.local ..."
  if curl -fsSL https://claude.ai/install.sh | bash; then
    hash -r 2>/dev/null || true
    if command -v claude >/dev/null 2>&1; then
      log "Claude Code installed at $(command -v claude)"
    else
      warn "Claude Code installer ran but 'claude' is not on PATH yet."
      warn "Open the terminal and run: curl -fsSL https://claude.ai/install.sh | bash"
    fi
  else
    warn "Claude Code install failed (network policy or outage?)."
    warn "The IDE will start anyway; retry from the terminal when ready:"
    warn "  curl -fsSL https://claude.ai/install.sh | bash"
  fi
fi

# --------------------------------------------------------------------------- #
# 4. require authentication — never expose the IDE without a password
# --------------------------------------------------------------------------- #
if [ -z "${PASSWORD:-}" ] && [ -z "${HASHED_PASSWORD:-}" ]; then
  die "No PASSWORD (or HASHED_PASSWORD) set. Add a strong PASSWORD variable in Railway before deploying. Refusing to start an unauthenticated IDE."
fi

# --------------------------------------------------------------------------- #
# 5. resolve binaries
# --------------------------------------------------------------------------- #
CODE_SERVER_BIN="$(command -v code-server || echo /usr/bin/code-server)"
[ -x "${CODE_SERVER_BIN}" ] || die "code-server binary not found at ${CODE_SERVER_BIN}"

cd "${WORKSPACE_DIR}" 2>/dev/null || true

# --------------------------------------------------------------------------- #
# 6. environment summary (never prints the password)
# --------------------------------------------------------------------------- #
log "environment summary:"
log "  user         : $(id -un) (uid=$(id -u) gid=$(id -g))"
log "  HOME         : ${HOME}"
log "  workspace    : ${WORKSPACE_DIR}"
log "  code-server  : ${CODE_SERVER_BIN}"
log "  jcode        : $(command -v jcode 2>/dev/null || echo 'not installed')"
log "  claude       : $(command -v claude 2>/dev/null || echo 'not installed')"
log "  git          : $(git --version 2>/dev/null || echo 'missing')"
log "  gh           : $(gh --version 2>/dev/null | head -n1 || echo 'missing')"
log "  bind address : 0.0.0.0:${PORT}"

# --------------------------------------------------------------------------- #
# 7. launch code-server in the foreground (final long-running process)
#    - password auth (PASSWORD is read from the environment by code-server)
#    - telemetry + update checks disabled
#    - user data and extensions stored under /data
#    - opens /data/workspace by default
# --------------------------------------------------------------------------- #
set -- \
  --bind-addr "0.0.0.0:${PORT}" \
  --auth password \
  --user-data-dir "${CS_USER_DATA}" \
  --extensions-dir "${CS_EXTENSIONS}" \
  --disable-telemetry \
  --disable-update-check \
  "${WORKSPACE_DIR}"

log "starting code-server ..."
if command -v dumb-init >/dev/null 2>&1; then
  exec dumb-init "${CODE_SERVER_BIN}" "$@"
else
  exec "${CODE_SERVER_BIN}" "$@"
fi
