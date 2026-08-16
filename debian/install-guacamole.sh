#!/usr/bin/env bash
#
# install-guacamole.sh — install Apache Guacamole on Debian 13 via Docker Compose.
#
#   sudo ./install-guacamole.sh
#
# Sets up a complete Guacamole stack (guacd + Guacamole web app + PostgreSQL)
# under /opt/guacamole, installing Docker Engine and the Compose plugin first if
# they are missing.
#
# Safe to re-run. Every step checks the current state before changing anything:
# existing secrets, image versions and the database are preserved, the compose
# file is rebuilt from the recorded settings, and the database schema is only
# created when it is actually absent.
#
# The default guacadmin password is replaced with a generated one BEFORE the web
# container is ever started, so the well-known guacadmin/guacadmin login is never
# reachable over the network.
#
# Options:
#   --dir PATH         install directory (default /opt/guacamole)
#   --port N           host port for the web UI (default 8080)
#   --bind ADDR        host address to publish on (default 0.0.0.0)
#   --version VER      Guacamole image tag (default 1.6.0)
#   --pg-image IMAGE   PostgreSQL image (default postgres:16-alpine)
#   --reset-admin      generate a new guacadmin password
#   --no-pull          don't contact the registry, use local images only
#   --no-start         write the configuration but don't start the stack
#   --status           show stack status and exit
#   --down             stop the stack (data is kept) and exit
#   --restart          restart the stack and exit
#   --force            continue even if the OS is not Debian 13
#   -h, --help         this text
#
# Credentials and a full transcript of the run are written next to this script:
#   guacamole-credentials.txt   (mode 600, appended to — never overwritten)
#   install-guacamole.log

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
INSTALL_DIR=/opt/guacamole
HTTP_PORT=8080
HTTP_BIND=0.0.0.0
GUAC_VERSION=1.6.0
PG_IMAGE=postgres:16-alpine
PG_DB=guacamole_db
PG_USER=guacamole_user
PROJECT=guacamole
LOCK_FILE=/run/install-guacamole.lock

DO_PULL=1
DO_START=1
DO_RESET_ADMIN=0
FORCE=0
MODE=install

PW_LEN_ADMIN=20
PW_LEN_DB=32
PW_CHARS='A-Za-z0-9'

PG_READY_TIMEOUT=120   # seconds to wait for PostgreSQL to accept connections
WEB_READY_TIMEOUT=240  # seconds to wait for Tomcat to deploy the web app

# Set by the run; used by the summary and the credentials file.
BACKUP_DIR=""
ADMIN_PASSWORD=""
ADMIN_PASSWORD_IS_NEW=0
SCHEMA_CREATED=0
CHANGED=0
HASHING_OK=1

readonly GUAC_ADMIN=guacadmin

# ---------------------------------------------------------------------------
# Where this script lives — the log and the credentials file go next to it.
# ---------------------------------------------------------------------------
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
else
  # Piped in from stdin (curl | bash): there is no script directory.
  SCRIPT_PATH="$PWD/install-guacamole.sh"
fi
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"

OUT_DIR="$SCRIPT_DIR"
OUT_DIR_NOTE=""
if ! ( : > "$OUT_DIR/.guac-write-test" ) 2>/dev/null; then
  OUT_DIR=/root
  OUT_DIR_NOTE="$SCRIPT_DIR is not writable — log and credentials go to $OUT_DIR instead"
  mkdir -p "$OUT_DIR" 2>/dev/null || true
fi
rm -f "$SCRIPT_DIR/.guac-write-test" 2>/dev/null || true

LOG_FILE="$OUT_DIR/install-guacamole.log"
CRED_FILE="$OUT_DIR/guacamole-credentials.txt"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
# Decide on colour BEFORE stdout is redirected into the log pipeline, otherwise
# the tty test below would always fail and the output would be plain.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_CYA=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_CYA=; C_DIM=; C_BOLD=
fi

STEP_NO=0
log()  { printf '%s\n' "$*"; }
info() { printf '%s[ .. ]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s[%d]%s %s%s%s\n' "$C_CYA" "$STEP_NO" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
die()  { err "$*"; exit 1; }
usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$SCRIPT_PATH" 2>/dev/null || true; exit 0; }

# --help must work before anything is logged or any lock is taken.
for _a in "$@"; do
  [[ "$_a" == "-h" || "$_a" == "--help" ]] && usage
done
unset _a

# ---------------------------------------------------------------------------
# Logging: everything on stdout/stderr is mirrored into the log file with the
# colour escapes stripped, so the log stays greppable.
# ---------------------------------------------------------------------------
LOGGING=0
setup_logging() {
  # One transcript per run is appended forever, so cap it. Rotating beats
  # truncating: the previous runs stay available in .log.1.
  if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0) > 5242880 )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi

  # The header goes in before the redirect, so it can never be interleaved
  # with the tee'd output of the run itself.
  {
    printf '\n'
    printf '=%.0s' {1..76}; printf '\n'
    printf 'install-guacamole.sh — %s on %s\n' "$(date -Is)" "$(hostname)"
    printf 'invocation: %s %s\n' "$SCRIPT_PATH" "${ORIG_ARGS:-}"
    printf '=%.0s' {1..76}; printf '\n'
  } >> "$LOG_FILE" || die "cannot write to $LOG_FILE"

  local esc=$'\033'
  exec 3>&1 4>&2
  exec > >(tee >(sed -u "s/${esc}\[[0-9;]*[a-zA-Z]//g" >> "$LOG_FILE")) 2>&1
  LOG_PID=$!
  LOGGING=1
}

close_logging() {
  # Runs from the EXIT trap, including on paths that died before logging was
  # ever set up — hence the flag rather than blind fd juggling.
  ((LOGGING)) || return 0
  exec 1>&3 2>&4 || true
  if [[ -n "${LOG_PID:-}" ]]; then
    wait "$LOG_PID" 2>/dev/null || true
  fi
  :
}

on_error() {
  local rc=$? line=${BASH_LINENO[0]:-?}
  err "aborted at line $line (exit $rc)"
  log ""
  log "  Full transcript: $LOG_FILE"
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    log "  Previous configuration: $BACKUP_DIR (restore with $BACKUP_DIR/revert.sh)"
  fi
  if [[ -d "$INSTALL_DIR" ]] && command -v docker >/dev/null 2>&1; then
    log "  Container logs:  docker compose -f $INSTALL_DIR/docker-compose.yml logs --tail=50"
  fi
  exit "$rc"
}

ORIG_ARGS="$*"
trap on_error ERR
trap close_logging EXIT

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
while (($#)); do
  case "$1" in
    --dir)          shift; INSTALL_DIR="${1:?--dir needs a value}" ;;
    --port)         shift; HTTP_PORT="${1:?--port needs a value}"; PORT_OVERRIDE=1 ;;
    --bind)         shift; HTTP_BIND="${1:?--bind needs a value}"; BIND_OVERRIDE=1 ;;
    --version)      shift; GUAC_VERSION="${1:?--version needs a value}"; VERSION_OVERRIDE=1 ;;
    --pg-image)     shift; PG_IMAGE="${1:?--pg-image needs a value}"; PGIMAGE_OVERRIDE=1 ;;
    --reset-admin)  DO_RESET_ADMIN=1 ;;
    --no-pull)      DO_PULL=0 ;;
    --no-start)     DO_START=0 ;;
    --status)       MODE=status ;;
    --down)         MODE=down ;;
    --restart)      MODE=restart ;;
    --force)        FORCE=1 ;;
    -*)             die "unknown option: $1 (try --help)" ;;
    *)              die "unexpected argument: $1 (try --help)" ;;
  esac
  shift
done

[[ "$INSTALL_DIR" == /* ]] || die "--dir must be an absolute path (got: $INSTALL_DIR)"
INSTALL_DIR="${INSTALL_DIR%/}"
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && ((HTTP_PORT > 0 && HTTP_PORT < 65536)) || die "invalid port: $HTTP_PORT"
[[ "$GUAC_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid image tag: $GUAC_VERSION"
[[ "$PG_IMAGE" =~ ^[A-Za-z0-9./:_-]+$ ]] || die "invalid postgres image: $PG_IMAGE"
# A bad bind address only surfaces as an opaque compose error at 'up' time.
[[ "$HTTP_BIND" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$HTTP_BIND" =~ ^[0-9A-Fa-f:]+$ ]] \
  || die "--bind expects an IP address (got: $HTTP_BIND)"

COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DATA_DIR="$INSTALL_DIR/data"
PGDATA_DIR="$DATA_DIR/postgres/pgdata"
INIT_DIR="$INSTALL_DIR/init"
INIT_SQL="$INIT_DIR/001-initdb.sql"
BACKUP_ROOT="$INSTALL_DIR/backups"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root (try: sudo $SCRIPT_PATH ${ORIG_ARGS})"

umask 022
setup_logging
[[ -n "$OUT_DIR_NOTE" ]] && warn "$OUT_DIR_NOTE"

# A plain flock is not enough on its own. The descriptor is inherited by every
# child, and bash cannot mark it close-on-exec, so anything that daemonises
# keeps the lock alive after this script exits — and every later run would then
# refuse to start, for good. The owning pid is recorded inside the file so a
# lock with no live owner can be told apart from a genuine concurrent run and
# cleared instead of wedging the installer permanently.
acquire_lock() {
  local attempt owner i
  for attempt in 1 2; do
    exec 9>>"$LOCK_FILE"          # append: never truncate a live owner's pid
    if flock -n 9; then
      printf '%s\n' "$$" > "$LOCK_FILE"
      return 0
    fi

    owner="$(head -1 "$LOCK_FILE" 2>/dev/null || true)"

    # An empty file may be an instance that has locked but not yet written its
    # pid. Give it a moment rather than racing it for the lock.
    if [[ -z "$owner" ]]; then
      for i in 1 2 3; do
        sleep 1
        if flock -n 9; then printf '%s\n' "$$" > "$LOCK_FILE"; return 0; fi
        owner="$(head -1 "$LOCK_FILE" 2>/dev/null || true)"
        [[ -n "$owner" ]] && break
      done
    fi

    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
      die "another instance is already running (pid $owner, lock: $LOCK_FILE)"
    fi

    ((attempt == 2)) && break
    warn "clearing a stale lock — its recorded owner (${owner:-unknown}) is no longer running"
    exec 9>&-
    rm -f "$LOCK_FILE"            # a new inode is not covered by the leaked fd
  done
  die "could not acquire the lock at $LOCK_FILE"
}
acquire_lock

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
have_systemd() { [[ -d /run/systemd/system ]]; }

gen_password() {
  # Read fixed-size chunks and filter them. Piping /dev/urandom straight into
  # head kills tr with SIGPIPE, which trips `set -o pipefail`.
  local want="$1" pw="" chunk tries=0
  while ((${#pw} < want)); do
    chunk="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc "$PW_CHARS" || true)"
    pw+="$chunk"
    ((++tries > 20)) && die "password generation failed (entropy source unusable?)"
  done
  printf '%s' "${pw:0:want}"
}

# Guacamole stores SHA-256(password || uppercase-hex-of-salt), hashed over the
# UTF-8 text of that concatenation — the salt is appended as its hex STRING,
# not as raw bytes. Getting this wrong produces a valid-looking row that simply
# never authenticates, so guac_hash_selftest() checks it against the vector
# shipped in Guacamole's own schema before we rely on it.
guac_hash() {
  local password="$1" salt_hex="$2"
  printf '%s%s' "$password" "$salt_hex" | sha256sum | cut -d' ' -f1 | LC_ALL=C tr 'a-f' 'A-F'
}

guac_hash_selftest() {
  local known_salt='FE24ADC5E11E2B25288D1704ABE67A79E342ECC26064CE69C5B3177795A82264'
  local known_hash='CA458A7D494E3BE824F5E1E175A1556C0F8EEF2C2D7DF3633BEC4A29C4411960'
  [[ "$(guac_hash 'guacadmin' "$known_salt")" == "$known_hash" ]]
}

gen_salt_hex() {
  head -c 32 /dev/urandom | od -An -tx1 | LC_ALL=C tr -d ' \n' | LC_ALL=C tr 'a-f' 'A-F'
}

# Read one KEY=VALUE from the .env file. Deliberately not `source` — the file
# must never be able to execute anything.
env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

atomic_write() {
  # Write stdin to $1 without ever leaving a half-written file behind.
  local dest="$1" mode="${2:-644}" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
}

# --env-file is passed explicitly rather than relying on compose's implicit
# lookup, so the stack behaves identically no matter which directory the
# script is invoked from.
dc() {
  docker compose --project-directory "$INSTALL_DIR" \
    -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# psql inside the postgres container. The official image trusts local socket
# connections, so no password round-trip is needed for maintenance queries.
psql_q() {
  dc exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" "$@"
}

container_running() {
  local name="$1"
  [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)" == "true" ]]
}

# ---------------------------------------------------------------------------
# Step: system checks
# ---------------------------------------------------------------------------
check_system() {
  step "Checking the system"

  local pretty="unknown" id="" vid=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pretty="${PRETTY_NAME:-unknown}"; id="${ID:-}"; vid="${VERSION_ID:-}"
  fi
  info "OS: $pretty  (kernel $(uname -r), $(dpkg --print-architecture 2>/dev/null || uname -m))"

  if [[ "$id" == "debian" && "$vid" == "13" ]]; then
    ok "Debian 13 detected"
  elif ((FORCE)); then
    warn "not Debian 13 — continuing because --force was given"
  elif [[ "$id" == "debian" || "$id" == "ubuntu" ]]; then
    warn "this script targets Debian 13; $pretty is close enough to try, continuing"
  else
    die "unsupported OS: $pretty (override with --force)"
  fi

  have dpkg || die "dpkg not found — this is not a Debian-based system"

  local arch; arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ok "architecture $arch has official Guacamole images" ;;
    *) warn "architecture $arch has no official Guacamole images — the pull will probably fail" ;;
  esac

  local mem_kb; mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if ((mem_kb > 0 && mem_kb < 900000)); then
    warn "only $((mem_kb / 1024)) MB RAM — Tomcat plus PostgreSQL wants ~1 GB, expect swapping"
  else
    ok "memory: $((mem_kb / 1024)) MB"
  fi

  local free_mb; free_mb="$(df -Pm "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  if ((free_mb > 0 && free_mb < 2048)); then
    warn "only ${free_mb} MB free on $(dirname "$INSTALL_DIR") — the images need about 1.5 GB"
  else
    ok "disk: ${free_mb} MB free on $(dirname "$INSTALL_DIR")"
  fi

  have_systemd || warn "no systemd — Docker will not be started at boot automatically"

  if guac_hash_selftest; then
    ok "password hashing verified against Guacamole's reference vector"
  else
    HASHING_OK=0
    warn "password hash self-test FAILED — the admin password cannot be set safely"
    warn "the stack will still be installed, but you must change guacadmin's password by hand"
  fi
}

# ---------------------------------------------------------------------------
# Step: base packages
# ---------------------------------------------------------------------------
APT_UPDATED=0
apt_update_once() {
  ((APT_UPDATED)) && return 0
  info "refreshing the package index"
  apt-get update -qq || die "apt-get update failed — check network and /etc/apt/sources.list"
  APT_UPDATED=1
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

install_base_packages() {
  step "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive

  local want=(ca-certificates curl gnupg) missing=()
  local p
  for p in "${want[@]}"; do
    pkg_installed "$p" || missing+=("$p")
  done

  if ((${#missing[@]} == 0)); then
    ok "ca-certificates, curl and gnupg are already installed"
  else
    apt_update_once
    info "installing: ${missing[*]}"
    apt-get install -y -qq --no-install-recommends "${missing[@]}" \
      || die "failed to install: ${missing[*]}"
    ok "installed: ${missing[*]}"
    CHANGED=1
  fi
}

# ---------------------------------------------------------------------------
# Step: Docker Engine + Compose plugin
# ---------------------------------------------------------------------------
docker_repo_codename() {
  # Docker publishes per-codename suites. If trixie is not published yet (or the
  # host is a derivative with an unknown codename), fall back to the newest
  # suite that actually exists rather than writing a sources entry that 404s.
  local candidates=() c
  local codename=""
  if [[ -r /etc/os-release ]]; then
    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"
  fi
  [[ -n "$codename" ]] && candidates+=("$codename")
  candidates+=(trixie bookworm)

  for c in "${candidates[@]}"; do
    if curl -fsSL --max-time 15 -o /dev/null "https://download.docker.com/linux/debian/dists/$c/Release" 2>/dev/null; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

install_docker_repo() {
  local codename
  codename="$(docker_repo_codename)" \
    || die "cannot reach download.docker.com — check DNS and outbound HTTPS"
  local os_codename; os_codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"
  [[ "$codename" == "$os_codename" ]] || warn "Docker has no '$os_codename' suite yet — using '$codename' packages"

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    info "fetching the Docker signing key"
    curl -fsSL --max-time 30 https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc.tmp || die "failed to download the Docker GPG key"
    # A captive portal or proxy happily returns an HTML error page with 200.
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/apt/keyrings/docker.asc.tmp \
      || { rm -f /etc/apt/keyrings/docker.asc.tmp; die "downloaded Docker key is not a PGP key — a proxy is interfering"; }
    mv -f /etc/apt/keyrings/docker.asc.tmp /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    ok "Docker signing key installed"
  else
    ok "Docker signing key already present"
  fi

  local arch; arch="$(dpkg --print-architecture)"
  local line="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $codename stable"
  if [[ -f /etc/apt/sources.list.d/docker.list ]] && grep -qxF "$line" /etc/apt/sources.list.d/docker.list; then
    ok "Docker apt repository already configured ($codename)"
  else
    printf '%s\n' "$line" | atomic_write /etc/apt/sources.list.d/docker.list 644
    ok "Docker apt repository configured ($codename)"
    APT_UPDATED=0
    CHANGED=1
  fi
}

install_docker() {
  step "Installing Docker Engine and the Compose plugin"
  export DEBIAN_FRONTEND=noninteractive

  if have docker && docker compose version >/dev/null 2>&1; then
    ok "Docker $(docker --version | sed 's/,.*//; s/Docker version //') with Compose $(docker compose version --short 2>/dev/null || echo '?') already installed"
  elif have docker; then
    # Docker is here but the v2 Compose plugin is not. Prefer the distro package
    # so an existing docker.io installation is not swapped out underneath the user.
    warn "Docker is installed but the Compose v2 plugin is missing"
    apt_update_once
    local candidate=""
    local p
    for p in docker-compose-plugin docker-compose-v2; do
      if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^(]'; then candidate="$p"; break; fi
    done
    if [[ -z "$candidate" ]]; then
      install_docker_repo
      apt_update_once
      candidate=docker-compose-plugin
    fi
    info "installing $candidate"
    apt-get install -y -qq "$candidate" || die "failed to install the Compose plugin ($candidate)"
    CHANGED=1
    ok "Compose plugin installed"
  else
    install_docker_repo
    apt_update_once
    info "installing docker-ce, docker-ce-cli, containerd.io and the Compose plugin"
    apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || die "Docker installation failed — see $LOG_FILE"
    CHANGED=1
    ok "Docker installed"
  fi

  docker compose version >/dev/null 2>&1 \
    || die "'docker compose' still does not work — Compose v2 is required"

  if have_systemd; then
    if [[ "$(systemctl is-enabled docker 2>/dev/null || true)" != "enabled" ]]; then
      systemctl enable docker >/dev/null 2>&1 || warn "could not enable docker.service at boot"
      CHANGED=1
    fi
    if [[ "$(systemctl is-active docker 2>/dev/null || true)" != "active" ]]; then
      info "starting docker.service"
      systemctl start docker || die "docker.service would not start — see: journalctl -u docker -n 50"
      CHANGED=1
    fi
    ok "docker.service is active and enabled at boot"
  fi

  docker info >/dev/null 2>&1 || die "the Docker daemon is not responding to 'docker info'"
  ok "Docker daemon is responding"
}

# ---------------------------------------------------------------------------
# Step: install directory, backups, secrets
# ---------------------------------------------------------------------------
make_backup() {
  # Only the configuration is backed up. The database is deliberately left
  # alone — copying a live PGDATA would produce a corrupt copy, not a backup.
  [[ -f "$COMPOSE_FILE" || -f "$ENV_FILE" ]] || return 0

  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
  local f
  for f in "$COMPOSE_FILE" "$ENV_FILE"; do
    [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/$(basename "$f")"
  done

  cat > "$BACKUP_DIR/revert.sh" <<REVERT
#!/usr/bin/env bash
# Restore the Guacamole configuration captured before the run on $(date -Is).
# The database is untouched by both the backup and this restore.
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
here="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
for f in docker-compose.yml .env; do
  if [[ -f "\$here/\$f" ]]; then cp -a "\$here/\$f" "$INSTALL_DIR/\$f"; echo "restored $INSTALL_DIR/\$f"
  else rm -f "$INSTALL_DIR/\$f"; echo "removed $INSTALL_DIR/\$f (did not exist before)"; fi
done
chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" up -d
echo "reverted"
REVERT
  chmod 700 "$BACKUP_DIR/revert.sh"
  ok "configuration backed up to $BACKUP_DIR"
}

prune_backups() {
  # Keep the ten most recent; unbounded backup dirs are their own failure mode.
  [[ -d "$BACKUP_ROOT" ]] || return 0
  local old
  old="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +11)"
  [[ -n "$old" ]] || return 0
  local d
  while read -r d; do
    [[ -n "$d" ]] && rm -rf -- "$d"
  done <<< "$old"
}

setup_directories() {
  step "Preparing $INSTALL_DIR"

  if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
    die "$INSTALL_DIR exists but is not a directory"
  fi
  if [[ -d "$INSTALL_DIR" ]]; then
    ok "$INSTALL_DIR already exists"
  else
    mkdir -p "$INSTALL_DIR"
    ok "created $INSTALL_DIR"
    CHANGED=1
  fi
  chmod 750 "$INSTALL_DIR"
  mkdir -p "$DATA_DIR/postgres" "$INIT_DIR" "$BACKUP_ROOT"
  chmod 700 "$DATA_DIR" "$BACKUP_ROOT"
  chmod 755 "$INIT_DIR"

  make_backup
  prune_backups
}

load_or_create_settings() {
  step "Resolving settings"

  # Anything already recorded in .env wins over the built-in defaults, so a
  # bare re-run can never silently change the port, the images or the database
  # password out from under a running installation. Command-line flags still win.
  local prev
  prev="$(env_get GUAC_VERSION)";  [[ -n "$prev" && -z "${VERSION_OVERRIDE:-}" ]] && GUAC_VERSION="$prev"
  prev="$(env_get POSTGRES_IMAGE)"; [[ -n "$prev" && -z "${PGIMAGE_OVERRIDE:-}" ]] && PG_IMAGE="$prev"
  prev="$(env_get HTTP_PORT)";     [[ -n "$prev" && -z "${PORT_OVERRIDE:-}" ]] && HTTP_PORT="$prev"
  prev="$(env_get HTTP_BIND)";     [[ -n "$prev" && -z "${BIND_OVERRIDE:-}" ]] && HTTP_BIND="$prev"
  prev="$(env_get POSTGRES_DB)";   [[ -n "$prev" ]] && PG_DB="$prev"
  prev="$(env_get POSTGRES_USER)"; [[ -n "$prev" ]] && PG_USER="$prev"

  # Changing the PostgreSQL major version under an existing data directory makes
  # the server refuse to start. Catch it here rather than in a restart loop.
  if [[ -f "$PGDATA_DIR/PG_VERSION" ]]; then
    local on_disk want
    on_disk="$(cat "$PGDATA_DIR/PG_VERSION" 2>/dev/null || true)"
    want="$(printf '%s' "$PG_IMAGE" | sed -n 's/.*:\([0-9][0-9]*\).*/\1/p')"
    if [[ -n "$on_disk" && -n "$want" && "$on_disk" != "$want" ]]; then
      die "existing database is PostgreSQL $on_disk but $PG_IMAGE is major version $want.
       An in-place major upgrade is not something this script will attempt.
       Dump the database first, or keep --pg-image at postgres:$on_disk-alpine."
    fi
    [[ -n "$on_disk" ]] && ok "existing database: PostgreSQL $on_disk"
  fi

  PG_PASSWORD="$(env_get POSTGRES_PASSWORD)"
  if [[ -z "$PG_PASSWORD" ]]; then
    PG_PASSWORD="$(gen_password "$PW_LEN_DB")"
    if [[ -f "$PGDATA_DIR/PG_VERSION" ]]; then
      # Data survived but .env did not. The password in the database is now
      # unknown, so generate a fresh one and push it into the running server
      # later (sync_db_password) instead of failing.
      warn "database exists but $ENV_FILE has no password — a new one will be set on the server"
    fi
    ok "generated a new database password"
  else
    ok "reusing the database password from $ENV_FILE"
  fi

  local tz=UTC
  if have timedatectl; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  elif [[ -r /etc/timezone ]]; then
    tz="$(cat /etc/timezone)"
  fi
  TZ_VALUE="${tz:-UTC}"

  info "Guacamole $GUAC_VERSION | $PG_IMAGE | http://$HTTP_BIND:$HTTP_PORT | TZ=$TZ_VALUE"
}

check_port_free() {
  # Only meaningful when our own stack is not the thing holding the port.
  container_running "${PROJECT}-web" && return 0
  have ss || return 0
  if ss -Hltn "sport = :$HTTP_PORT" 2>/dev/null | grep -q .; then
    local who
    who="$(ss -Hltnp "sport = :$HTTP_PORT" 2>/dev/null | sed -n 's/.*users:((\("[^"]*"\).*/\1/p' | head -1)"
    die "port $HTTP_PORT is already in use${who:+ by $who} — pick another with --port N"
  fi
  ok "port $HTTP_PORT is free"
}

write_env() {
  local content
  content="$(cat <<ENVFILE
# Managed by install-guacamole.sh — regenerated $(date -Is).
# Every value the compose file reads lives here. Edit this file, then re-run
# the script (or 'docker compose up -d') to apply the change.
#
# Contains the database password: keep mode 600.

GUAC_VERSION=$GUAC_VERSION
POSTGRES_IMAGE=$PG_IMAGE

POSTGRES_DB=$PG_DB
POSTGRES_USER=$PG_USER
POSTGRES_PASSWORD=$PG_PASSWORD

HTTP_BIND=$HTTP_BIND
HTTP_PORT=$HTTP_PORT

TZ=$TZ_VALUE
ENVFILE
  )"

  # Compare on everything but the regenerated timestamp, so an unchanged re-run
  # is reported as unchanged instead of always looking like an edit.
  if [[ -f "$ENV_FILE" ]] \
    && diff -q <(grep -v '^# Managed by' <<< "$content") <(grep -v '^# Managed by' "$ENV_FILE") >/dev/null 2>&1; then
    ok ".env unchanged"
  else
    printf '%s\n' "$content" | atomic_write "$ENV_FILE" 600
    ok "wrote $ENV_FILE (mode 600)"
    CHANGED=1
  fi
  chmod 600 "$ENV_FILE"
}

write_compose() {
  # Everything variable is referenced from .env, so this file is byte-identical
  # across runs and hosts — which is what makes the "unchanged" check reliable.
  local content
  content="$(cat <<'COMPOSE'
# Managed by install-guacamole.sh. All values come from the .env file beside it.
# Hand edits are overwritten on the next run; change .env instead.
name: guacamole

services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: guacamole-db
    restart: unless-stopped
    stop_grace_period: 1m
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      # A sub-directory of the mount point: PostgreSQL refuses to initialise a
      # data directory that is a mount root with anything else in it.
      PGDATA: /var/lib/postgresql/data/pgdata
      TZ: ${TZ}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -q -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - guacamole
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  guacd:
    image: guacamole/guacd:${GUAC_VERSION}
    container_name: guacamole-guacd
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    # guacd talks only to the web app; it is never published to the host.
    networks:
      - guacamole
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  guacamole:
    image: guacamole/guacamole:${GUAC_VERSION}
    container_name: guacamole-web
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      guacd:
        condition: service_started
    environment:
      GUACD_HOSTNAME: guacd
      GUACD_PORT: "4822"
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_PORT: "5432"
      POSTGRESQL_DATABASE: ${POSTGRES_DB}
      POSTGRESQL_USER: ${POSTGRES_USER}
      POSTGRESQL_PASSWORD: ${POSTGRES_PASSWORD}
      # Never let an unknown username create an account by logging in.
      POSTGRESQL_AUTO_CREATE_ACCOUNTS: "false"
      # Serve at / instead of /guacamole.
      WEBAPP_CONTEXT: ROOT
      TZ: ${TZ}
    ports:
      - "${HTTP_BIND}:${HTTP_PORT}:8080"
    networks:
      - guacamole
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

networks:
  guacamole:
    name: guacamole
    driver: bridge
COMPOSE
  )"

  if [[ -f "$COMPOSE_FILE" ]] && diff -q <(printf '%s\n' "$content") "$COMPOSE_FILE" >/dev/null 2>&1; then
    ok "docker-compose.yml unchanged"
  else
    printf '%s\n' "$content" | atomic_write "$COMPOSE_FILE" 640
    ok "wrote $COMPOSE_FILE"
    CHANGED=1
  fi
}

write_configuration() {
  step "Writing the compose configuration"
  write_env
  write_compose
  info "validating the compose file"
  local out
  if ! out="$(dc config -q 2>&1)"; then
    err "compose rejected the configuration:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    die "configuration is invalid — nothing was started"
  fi
  ok "compose configuration is valid"
}

# ---------------------------------------------------------------------------
# Step: images
# ---------------------------------------------------------------------------
pull_images() {
  step "Fetching container images"
  if ((! DO_PULL)); then
    warn "skipping the registry (--no-pull) — local images will be used"
    return 0
  fi

  local guac_ok=1
  info "pulling guacamole/guacamole:$GUAC_VERSION and guacamole/guacd:$GUAC_VERSION"
  docker pull -q "guacamole/guacamole:$GUAC_VERSION" >/dev/null 2>&1 || guac_ok=0
  ((guac_ok)) && { docker pull -q "guacamole/guacd:$GUAC_VERSION" >/dev/null 2>&1 || guac_ok=0; }

  if ((! guac_ok)); then
    if [[ "$GUAC_VERSION" == "latest" ]]; then
      die "cannot pull guacamole/guacamole:latest — check outbound HTTPS to docker.io"
    fi
    warn "tag '$GUAC_VERSION' is not available — falling back to 'latest'"
    GUAC_VERSION=latest
    docker pull -q "guacamole/guacamole:latest" >/dev/null \
      || die "cannot pull guacamole/guacamole — check outbound HTTPS to docker.io"
    docker pull -q "guacamole/guacd:latest" >/dev/null \
      || die "cannot pull guacamole/guacd — check outbound HTTPS to docker.io"
    # The tag changed, so .env and the summary have to reflect reality.
    write_env
    CHANGED=1
  fi
  ok "Guacamole images ready ($GUAC_VERSION)"

  info "pulling $PG_IMAGE"
  docker pull -q "$PG_IMAGE" >/dev/null || die "cannot pull $PG_IMAGE"
  ok "PostgreSQL image ready"
}

# ---------------------------------------------------------------------------
# Step: database
# ---------------------------------------------------------------------------
generate_init_sql() {
  # Generated by the image itself, so the schema always matches the version
  # being installed rather than a copy pinned in this script.
  local stamp="$INIT_DIR/.version"
  if [[ -s "$INIT_SQL" && "$(cat "$stamp" 2>/dev/null || true)" == "$GUAC_VERSION" ]]; then
    ok "schema SQL for $GUAC_VERSION already generated"
    return 0
  fi
  info "generating the PostgreSQL schema from guacamole/guacamole:$GUAC_VERSION"
  local tmp errf; tmp="$(mktemp)"; errf="$(mktemp)"
  if ! docker run --rm "guacamole/guacamole:$GUAC_VERSION" \
        /opt/guacamole/bin/initdb.sh --postgresql > "$tmp" 2>"$errf"; then
    err "initdb.sh failed inside the Guacamole image:"
    sed 's/^/    /' "$errf" >&2 || true
    rm -f "$tmp" "$errf"
    die "could not generate the database schema"
  fi
  rm -f "$errf"
  # A truncated or empty schema would create a half-working database.
  if ! grep -q 'CREATE TABLE guacamole_user' "$tmp"; then
    rm -f "$tmp"
    die "generated schema looks wrong (no guacamole_user table) — refusing to load it"
  fi
  mv -f "$tmp" "$INIT_SQL"
  chmod 644 "$INIT_SQL"
  printf '%s\n' "$GUAC_VERSION" > "$stamp"
  ok "schema written to $INIT_SQL ($(wc -l < "$INIT_SQL") lines)"
}

wait_for_postgres() {
  info "waiting for PostgreSQL to accept connections"
  local deadline=$((SECONDS + PG_READY_TIMEOUT))
  while ((SECONDS < deadline)); do
    if dc exec -T postgres pg_isready -q -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
      ok "PostgreSQL is ready"
      return 0
    fi
    sleep 2
  done
  err "PostgreSQL did not become ready within ${PG_READY_TIMEOUT}s"
  dc logs --tail=40 postgres || true
  die "database did not start"
}

sync_db_password() {
  # Makes the server agree with .env no matter which one drifted. The password
  # is alphanumeric by construction, so a plain SQL literal is safe here.
  psql_q -c "ALTER USER \"$PG_USER\" WITH PASSWORD '$PG_PASSWORD';" >/dev/null \
    || warn "could not synchronise the database password (continuing)"
}

schema_present() {
  local res
  res="$(psql_q -tAc "SELECT to_regclass('public.guacamole_user');" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$res" == "guacamole_user" ]]
}

setup_database() {
  step "Starting PostgreSQL and preparing the schema"

  info "starting the database container"
  dc up -d postgres >/dev/null || die "could not start the postgres container"
  wait_for_postgres
  sync_db_password

  if schema_present; then
    ok "Guacamole schema is already present — leaving it untouched"
  else
    generate_init_sql
    info "loading the Guacamole schema"
    # ON_ERROR_STOP means a partially applied schema aborts the run instead of
    # producing a database that half-works.
    if ! dc exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" < "$INIT_SQL"; then
      die "loading the schema failed — inspect $INIT_SQL and 'docker compose -f $COMPOSE_FILE logs postgres'"
    fi
    schema_present || die "schema load reported success but guacamole_user is missing"
    SCHEMA_CREATED=1
    CHANGED=1
    ok "schema created"
  fi
}

admin_exists() {
  local n
  n="$(psql_q -tAc "SELECT COUNT(*) FROM guacamole_entity WHERE name = '$GUAC_ADMIN' AND type = 'USER';" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  [[ "$n" == "1" ]]
}

set_admin_password() {
  # Deliberately runs while only postgres is up. By the time the web container
  # can serve a login form, guacadmin/guacadmin is already gone.
  step "Securing the $GUAC_ADMIN account"

  if ((! HASHING_OK)); then
    warn "hash self-test failed earlier — leaving the stock password in place"
    warn "log in with $GUAC_ADMIN/$GUAC_ADMIN and change it immediately"
    ADMIN_PASSWORD="$GUAC_ADMIN"
    return 0
  fi

  if ! admin_exists; then
    warn "no '$GUAC_ADMIN' account in the database — it was renamed or removed"
    warn "leaving accounts alone; use your existing administrator login"
    return 0
  fi

  if ((! SCHEMA_CREATED)) && ((! DO_RESET_ADMIN)); then
    ok "existing installation — password left as it is (use --reset-admin to change it)"
    return 0
  fi

  local password salt hash
  password="$(gen_password "$PW_LEN_ADMIN")"
  salt="$(gen_salt_hex)"
  [[ ${#salt} -eq 64 ]] || die "salt generation failed (got ${#salt} chars, expected 64)"
  hash="$(guac_hash "$password" "$salt")"
  [[ ${#hash} -eq 64 ]] || die "hash generation failed (got ${#hash} chars, expected 64)"

  psql_q <<SQL >/dev/null || die "could not update the $GUAC_ADMIN password"
UPDATE guacamole_user
   SET password_hash = decode('$hash', 'hex'),
       password_salt = decode('$salt', 'hex'),
       password_date = CURRENT_TIMESTAMP
 WHERE entity_id = (SELECT entity_id FROM guacamole_entity
                     WHERE name = '$GUAC_ADMIN' AND type = 'USER');
SQL

  # Verify the row actually holds the hash we computed; a silent no-op here
  # would lock the administrator out of a brand-new installation.
  local check
  check="$(psql_q -tAc "SELECT upper(encode(password_hash, 'hex')) FROM guacamole_user u
             JOIN guacamole_entity e ON e.entity_id = u.entity_id
            WHERE e.name = '$GUAC_ADMIN';" | tr -d '[:space:]')"
  [[ "$check" == "$hash" ]] || die "password verification failed — the stored hash does not match"

  ADMIN_PASSWORD="$password"
  ADMIN_PASSWORD_IS_NEW=1
  CHANGED=1
  if ((DO_RESET_ADMIN)) && ((! SCHEMA_CREATED)); then
    ok "$GUAC_ADMIN password reset"
  else
    ok "$GUAC_ADMIN password replaced before the web app was ever started"
  fi
}

# ---------------------------------------------------------------------------
# Step: bring the stack up
# ---------------------------------------------------------------------------
probe_url() {
  # Prints the HTTP status, or nothing at all when the connection never
  # completed (curl reports that as 000, which reads like a real status).
  local url="$1" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
  [[ "$code" == "000" ]] && code=""
  printf '%s' "$code"
}

start_stack() {
  step "Starting the Guacamole stack"
  info "docker compose up -d"
  dc up -d --remove-orphans || die "'docker compose up' failed — see 'docker compose -f $COMPOSE_FILE logs'"
  ok "containers started"

  local probe_host="$HTTP_BIND"
  [[ "$probe_host" == "0.0.0.0" || "$probe_host" == "::" ]] && probe_host=127.0.0.1
  local url="http://$probe_host:$HTTP_PORT/"

  info "waiting for the web app on $url (Tomcat takes a moment on first boot)"
  local deadline=$((SECONDS + WEB_READY_TIMEOUT)) code=""
  while ((SECONDS < deadline)); do
    if ! container_running "${PROJECT}-web"; then
      sleep 2
      # A crash-looping container will never answer; surface the reason now.
      if ! container_running "${PROJECT}-web"; then
        err "the guacamole-web container is not running"
        dc logs --tail=40 guacamole || true
        die "the web container stopped — see the log above"
      fi
    fi
    code="$(probe_url "$url")"
    case "$code" in
      200|302|303) ok "web app answered HTTP $code"; WEB_URL="$url"; return 0 ;;
    esac
    sleep 3
  done

  err "no usable response from $url within ${WEB_READY_TIMEOUT}s (last status: ${code:-none})"
  dc ps || true
  dc logs --tail=40 guacamole || true
  die "Guacamole did not come up"
}

verify_login() {
  # The one check that proves the whole chain works: the REST endpoint the login
  # form itself calls, exercising Tomcat, the JDBC extension, PostgreSQL and the
  # password hash in a single request.
  [[ -n "${WEB_URL:-}" ]] || return 0
  [[ -n "$ADMIN_PASSWORD" ]] || return 0
  ((HASHING_OK)) || return 0

  info "verifying the administrator login end to end"
  local body
  body="$(curl -sS --max-time 15 -X POST \
            --data-urlencode "username=$GUAC_ADMIN" \
            --data-urlencode "password=$ADMIN_PASSWORD" \
            "${WEB_URL}api/tokens" 2>/dev/null || true)"
  if grep -q '"authToken"' <<< "$body"; then
    ok "login as $GUAC_ADMIN succeeded"
    # Do not leave a live session token lying around.
    local token
    token="$(sed -n 's/.*"authToken":"\([^"]*\)".*/\1/p' <<< "$body")"
    [[ -n "$token" ]] && curl -sS --max-time 10 -X DELETE \
        "${WEB_URL}api/tokens/$token" >/dev/null 2>&1 || true
  else
    warn "could not verify the login through the API — the stack is up, but check it by hand"
  fi
}

# ---------------------------------------------------------------------------
# Credentials file
# ---------------------------------------------------------------------------
firewall_note() {
  # Docker inserts its DNAT rules ahead of the filter chains ufw manages, so a
  # published container port stays reachable even when ufw says it is denied.
  # People rely on ufw here and get caught out by it, so say so explicitly.
  have ufw || return 0
  ufw status 2>/dev/null | grep -qi 'Status: active' || return 0
  [[ "$HTTP_BIND" == "127.0.0.1" || "$HTTP_BIND" == "::1" ]] && return 0
  log ""
  warn "ufw is active, but Docker publishes ports via DNAT and bypasses it:"
  warn "  port $HTTP_PORT is reachable from the network whatever your ufw rules say."
  warn "  To close it off, re-run with --bind 127.0.0.1 and front it with a proxy."
}

primary_address() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
  [[ -n "$ip" ]] && { printf '%s' "$ip"; return; }
  hostname -I 2>/dev/null | awk '{print $1}' | grep . || printf '%s' "$(hostname)"
}

write_credentials() {
  local addr; addr="$(primary_address)"
  local url="http://$addr:$HTTP_PORT/"
  [[ "$HTTP_BIND" != "0.0.0.0" && "$HTTP_BIND" != "::" ]] && url="http://$HTTP_BIND:$HTTP_PORT/"

  umask 077
  {
    printf '\n'
    printf '=%.0s' {1..72}; printf '\n'
    printf 'Apache Guacamole — %s\n' "$(date -Is)"
    printf 'host: %s   install dir: %s\n' "$(hostname)" "$INSTALL_DIR"
    printf '=%.0s' {1..72}; printf '\n'
    printf '%-22s %s\n' "URL:" "$url"
    printf '%-22s %s\n' "Admin username:" "$GUAC_ADMIN"
    if ((ADMIN_PASSWORD_IS_NEW)); then
      printf '%-22s %s\n' "Admin password:" "$ADMIN_PASSWORD"
    elif [[ "$ADMIN_PASSWORD" == "$GUAC_ADMIN" ]]; then
      printf '%-22s %s\n' "Admin password:" "$GUAC_ADMIN  <-- STOCK PASSWORD, CHANGE IT NOW"
    else
      printf '%-22s %s\n' "Admin password:" "(unchanged by this run — see an earlier entry)"
    fi
    printf '\n'
    printf '%-22s %s\n' "Database:" "$PG_DB"
    printf '%-22s %s\n' "Database user:" "$PG_USER"
    printf '%-22s %s\n' "Database password:" "$PG_PASSWORD"
    printf '\n'
    printf '%-22s %s\n' "Guacamole version:" "$GUAC_VERSION"
    printf '%-22s %s\n' "PostgreSQL image:" "$PG_IMAGE"
    printf '%-22s %s\n' "Compose file:" "$COMPOSE_FILE"
    printf '\n'
    printf 'This file is appended to on every run; older entries above remain valid\n'
    printf 'unless a later entry replaces the same credential.\n'
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  umask 022
  CRED_URL="$url"
}

# ---------------------------------------------------------------------------
# Simple modes: --status / --down / --restart
# ---------------------------------------------------------------------------
require_installed() {
  [[ -f "$COMPOSE_FILE" ]] || die "no installation found at $INSTALL_DIR (run without --status/--down/--restart first)"
  have docker && docker compose version >/dev/null 2>&1 || die "docker compose is not available"
}

do_status() {
  require_installed
  hdr "Guacamole status"
  log "  install dir:  $INSTALL_DIR"
  log "  version:      $(env_get GUAC_VERSION)"
  log "  listening on: $(env_get HTTP_BIND):$(env_get HTTP_PORT)"
  log ""
  dc ps || true
  local port bind probe
  port="$(env_get HTTP_PORT)"; bind="$(env_get HTTP_BIND)"
  [[ "$bind" == "0.0.0.0" || "$bind" == "::" || -z "$bind" ]] && bind=127.0.0.1
  probe="$(probe_url "http://$bind:$port/")"
  log ""
  case "$probe" in
    200|302|303) ok "web app responding (HTTP $probe) on http://$bind:$port/" ;;
    "")          err "web app not responding on http://$bind:$port/" ;;
    *)           warn "web app returned HTTP $probe on http://$bind:$port/" ;;
  esac
  log ""
  log "  credentials:  $CRED_FILE"
  log "  log:          $LOG_FILE"
  exit 0
}

do_down() {
  require_installed
  hdr "Stopping Guacamole"
  info "the database directory ($PGDATA_DIR) is kept"
  dc down || die "'docker compose down' failed"
  ok "stack stopped — bring it back with: $SCRIPT_PATH"
  exit 0
}

do_restart() {
  require_installed
  hdr "Restarting Guacamole"
  dc restart || die "'docker compose restart' failed"
  ok "restarted"
  local port bind
  port="$(env_get HTTP_PORT)"; bind="$(env_get HTTP_BIND)"
  [[ "$bind" == "0.0.0.0" || "$bind" == "::" || -z "$bind" ]] && bind=127.0.0.1
  info "waiting for the web app"
  local deadline=$((SECONDS + WEB_READY_TIMEOUT)) code=""
  while ((SECONDS < deadline)); do
    code="$(probe_url "http://$bind:$port/")"
    case "$code" in 200|302|303) ok "web app responding (HTTP $code)"; exit 0 ;; esac
    sleep 3
  done
  die "web app did not respond within ${WEB_READY_TIMEOUT}s"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$MODE" in
  status)  do_status ;;
  down)    do_down ;;
  restart) do_restart ;;
esac

hdr "Apache Guacamole installer"
log "  install dir:  $INSTALL_DIR"
log "  log file:     $LOG_FILE"
log "  credentials:  $CRED_FILE"

check_system
install_base_packages
install_docker
setup_directories
load_or_create_settings
check_port_free
write_configuration
pull_images

if ((! DO_START)); then
  hdr "Result"
  warn "--no-start given: configuration written, nothing was started"
  log ""
  log "  Start it yourself with:"
  log "    docker compose -f $COMPOSE_FILE up -d"
  log ""
  log "  Note that the $GUAC_ADMIN password is still the stock one until this"
  log "  script runs without --no-start."
  exit 0
fi

setup_database
set_admin_password
start_stack
verify_login
write_credentials

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hdr "Result"
printf '  %-18s %s\n' "Web UI" "${CRED_URL:-http://$(primary_address):$HTTP_PORT/}"
printf '  %-18s %s\n' "Username" "$GUAC_ADMIN"
if ((ADMIN_PASSWORD_IS_NEW)); then
  printf '  %-18s %s%s%s\n' "Password" "$C_BOLD" "$ADMIN_PASSWORD" "$C_RESET"
elif [[ "$ADMIN_PASSWORD" == "$GUAC_ADMIN" ]]; then
  printf '  %-18s %s%s (STOCK — CHANGE IT)%s\n' "Password" "$C_RED" "$GUAC_ADMIN" "$C_RESET"
else
  printf '  %-18s %s\n' "Password" "unchanged by this run (--reset-admin to replace it)"
fi
log ""
printf '  %-18s %s\n' "Version" "Guacamole $GUAC_VERSION, $PG_IMAGE"
printf '  %-18s %s\n' "Install dir" "$INSTALL_DIR"
printf '  %-18s %s\n' "Compose file" "$COMPOSE_FILE"
printf '  %-18s %s\n' "Database dir" "$PGDATA_DIR"
printf '  %-18s %s\n' "Credentials" "$CRED_FILE (mode 600)"
printf '  %-18s %s\n' "Log" "$LOG_FILE"
[[ -n "$BACKUP_DIR" ]] && printf '  %-18s %s\n' "Config backup" "$BACKUP_DIR"

log ""
if ((CHANGED)); then
  ok "installation complete"
else
  ok "already up to date — nothing needed changing"
fi

firewall_note

hdr "Next steps"
log "  1. Log in and add a connection: Settings -> Connections -> New Connection."
log "     guacd reaches your targets from inside the container network, so use"
log "     real IPs or hostnames, not 'localhost'."
log ""
log "  2. The UI is served over plain HTTP. Anything typed into a session —"
log "     including passwords — crosses the network in the clear. Put a TLS"
log "     terminating reverse proxy in front of it before exposing this host,"
log "     or restrict it to a VPN with: $SCRIPT_PATH --bind 127.0.0.1"
log ""
log "  Handy commands:"
log "     $SCRIPT_PATH --status        show stack health"
log "     $SCRIPT_PATH --restart       restart the containers"
log "     $SCRIPT_PATH --down          stop the stack (data is kept)"
log "     $SCRIPT_PATH --reset-admin   issue a new $GUAC_ADMIN password"
log "     docker compose -f $COMPOSE_FILE logs -f"
log ""

exit 0
