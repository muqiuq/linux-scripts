#!/usr/bin/env bash
#
# install-mosquitto.sh — install Mosquitto and provision authenticated users.
#
#   ./install-mosquitto.sh user1 otheruser2 superuser3
#
# Each username given gets a generated 16-character password ([a-z0-9]) and
# full read/write access to every topic. Anonymous access is disabled.
#
# Safe to re-run: existing users are left untouched (password preserved) and
# only the new names are added. The ACL file is rebuilt from the password file
# every run, so it can never drift out of sync with the actual user list.
#
# Options:
#   --reset            regenerate the password for users that already exist
#   --port N           listener port (default 1883)
#   --bind ADDR        bind the listener to one address (default: all interfaces)
#   --no-restart       write config but don't restart the broker
#   --remove           delete the named users instead of adding them
#   --list             list configured users and exit
#   -h, --help         this text
#
# Credentials are printed at the end and also written to a root-only file,
# because scrollback over a serial console is easy to lose.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
CONF_DIR=/etc/mosquitto
CONF_D="$CONF_DIR/conf.d"
MANAGED_CONF="$CONF_D/00-managed-auth.conf"
PASSWD_FILE="$CONF_DIR/passwd"
ACL_FILE="$CONF_DIR/aclfile"
BACKUP_ROOT=/root/mosquitto-backups
CRED_DIR=/root
LOCK_FILE=/run/install-mosquitto.lock
PW_LEN=16
PW_CHARS='a-z0-9'
PORT=1883
BIND_ADDR=""
DO_RESET=0
DO_RESTART=1
MODE=add
BACKUP_DIR=""
SERVICE=mosquitto

declare -a USERS=()
declare -a NEW_USERS=() NEW_PASSWORDS=() SKIPPED=() RESET_USERS=() REMOVED=()

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_BOLD=
fi
log()  { printf '%s\n' "$*"; }
info() { printf '%s[ .. ]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
die()  { err "$*"; exit 1; }
usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0; }

restore_and_die() {
  local msg="$1"
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    warn "rolling back from $BACKUP_DIR"
    "$BACKUP_DIR/revert.sh" >/dev/null 2>&1 || warn "automatic rollback failed — run $BACKUP_DIR/revert.sh by hand"
  fi
  die "$msg"
}

on_error() {
  local rc=$? line=${BASH_LINENO[0]:-?}
  err "aborted at line $line (exit $rc)"
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] && err "restore with: $BACKUP_DIR/revert.sh"
  exit "$rc"
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
LIST_ONLY=0
while (($#)); do
  case "$1" in
    --reset)      DO_RESET=1 ;;
    --no-restart) DO_RESTART=0 ;;
    --remove)     MODE=remove ;;
    --list)       LIST_ONLY=1 ;;
    --port)       shift; PORT="${1:?--port needs a value}" ;;
    --bind)       shift; BIND_ADDR="${1:?--bind needs a value}" ;;
    -h|--help)    usage ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            USERS+=("$1") ;;
  esac
  shift
done

[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT > 0 && PORT < 65536)) || die "invalid port: $PORT"

valid_username() {
  # Colons would corrupt the password file's user:hash format.
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$ ]]
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0 $*)"
exec 9>"$LOCK_FILE"
flock -n 9 || die "another instance is running (lock: $LOCK_FILE)"

have_systemd() { [[ -d /run/systemd/system ]]; }

install_broker() {
  if command -v mosquitto >/dev/null 2>&1 && command -v mosquitto_passwd >/dev/null 2>&1; then
    ok "mosquitto already installed ($(mosquitto -h 2>&1 | sed -n 1p || true))"
    return
  fi
  info "installing mosquitto and mosquitto-clients"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends mosquitto mosquitto-clients \
    || die "apt install failed"
  ok "mosquitto installed"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
gen_password() {
  # Read fixed-size chunks and filter them. Piping /dev/urandom straight into
  # head kills tr with SIGPIPE, which trips `set -o pipefail`.
  local pw="" chunk tries=0
  while ((${#pw} < PW_LEN)); do
    chunk="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc "$PW_CHARS" || true)"
    pw+="$chunk"
    ((++tries > 20)) && die "password generation failed (entropy source unusable?)"
  done
  printf '%s' "${pw:0:PW_LEN}"
}

user_exists() {
  [[ -f "$PASSWD_FILE" ]] && grep -q "^$1:" "$PASSWD_FILE"
}

list_users() {
  [[ -f "$PASSWD_FILE" ]] || return 0
  sed -n 's/^\([^:#][^:]*\):.*/\1/p' "$PASSWD_FILE" | sort
}

fix_perms() {
  # The broker opens the password and ACL files AFTER dropping privileges to
  # the mosquitto user, so root:root 0600 makes it fail to start with
  # "Unable to open pwfile". Group-read for mosquitto is required.
  local f="$1"
  if getent group mosquitto >/dev/null 2>&1; then
    chown root:mosquitto "$f"
    chmod 640 "$f"
  else
    chown root:root "$f"
    chmod 644 "$f"
  fi
}

prep_passwd_for_edit() {
  # mosquitto_passwd warns when the file's group is not root. Edit it as
  # root:root, then hand it back to the mosquitto group via fix_perms.
  [[ -f "$PASSWD_FILE" ]] || return 0
  chown root:root "$PASSWD_FILE"
  chmod 600 "$PASSWD_FILE"
}

make_backup() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
  local f
  for f in "$PASSWD_FILE" "$ACL_FILE" "$MANAGED_CONF"; do
    [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/$(basename "$f")"
  done
  {
    echo "date:   $(date -Is)"
    echo "host:   $(hostname)"
    echo "users:  $(list_users | tr '\n' ' ')"
  } > "$BACKUP_DIR/state.txt"

  cat > "$BACKUP_DIR/revert.sh" <<REVERT
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
here="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
for f in passwd aclfile 00-managed-auth.conf; do
  case "\$f" in
    passwd)                 dst="$PASSWD_FILE" ;;
    aclfile)                dst="$ACL_FILE" ;;
    00-managed-auth.conf)   dst="$MANAGED_CONF" ;;
  esac
  if [[ -f "\$here/\$f" ]]; then cp -a "\$here/\$f" "\$dst"; echo "restored \$dst"
  else rm -f "\$dst"; echo "removed \$dst (did not exist before)"; fi
done
if [[ -d /run/systemd/system ]]; then systemctl restart $SERVICE || true; fi
echo "reverted"
REVERT
  chmod 700 "$BACKUP_DIR/revert.sh"
  ok "backup: $BACKUP_DIR"
}

write_acl() {
  # Rebuilt from the password file every run — the ACL can never name a user
  # that doesn't exist, or miss one that does.
  local tmp; tmp="$(mktemp)"
  {
    echo "# Managed by install-mosquitto.sh — regenerated $(date -Is)."
    echo "# Every listed user has full read/write on all topics."
    echo "# Hand edits here will be overwritten; add a separate acl_file instead."
    echo
    local u
    while read -r u; do
      [[ -n "$u" ]] || continue
      echo "user $u"
      echo "topic readwrite #"
      # '#' does not match topics beginning with $, so $SYS needs naming.
      echo "topic read \$SYS/#"
      echo
    done < <(list_users)
  } > "$tmp"
  cat "$tmp" > "$ACL_FILE" 2>/dev/null || mv "$tmp" "$ACL_FILE"
  rm -f "$tmp"
  fix_perms "$ACL_FILE"
}

write_conf() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<CONF
# Managed by install-mosquitto.sh — regenerated $(date -Is).
# Remove this file and restart mosquitto to return to stock behaviour.

listener $PORT${BIND_ADDR:+ $BIND_ADDR}
protocol mqtt

# Authentication: no anonymous clients, password file + ACL enforced.
allow_anonymous false
password_file $PASSWD_FILE
acl_file $ACL_FILE

connection_messages true
max_queued_messages 1000

# Deliberately NOT set here: persistence, persistence_location and log_dest.
# The distro's /etc/mosquitto/mosquitto.conf already defines them, and
# mosquitto refuses to start on a duplicate persistence_location.
CONF
  cat "$tmp" > "$MANAGED_CONF" 2>/dev/null || mv "$tmp" "$MANAGED_CONF"
  rm -f "$tmp"
  chown root:root "$MANAGED_CONF"
  chmod 644 "$MANAGED_CONF"
}

validate_conf() {
  # Start the broker against the real config on a throwaway port. If it can't
  # parse the files it exits non-zero immediately, and we never touch the
  # running service.
  local test_dir test_conf
  test_dir="$(mktemp -d)"
  test_conf="$test_dir/test.conf"

  # The broker drops privileges before creating its socket and pid file, so the
  # scratch dir has to be writable by that user. Keeping the privilege drop in
  # play is deliberate: it also proves the passwd/ACL file modes are readable.
  if getent passwd mosquitto >/dev/null 2>&1; then
    chown mosquitto:mosquitto "$test_dir"
    chmod 750 "$test_dir"
  else
    chmod 777 "$test_dir"
  fi

  # Validate the MERGED configuration: the distro's mosquitto.conf plus every
  # fragment in conf.d, exactly as the real broker assembles it. Testing the
  # managed fragment alone would miss cross-file duplicate-key errors.
  #
  # Keys that would collide or interfere are filtered out of every source file
  # and then re-added once, so the test instance uses a unix socket instead of
  # the live TCP port and never writes over the real mosquitto.db.
  # NOTE: 'user' is deliberately NOT stripped. The broker opens the password
  # file *after* dropping privileges, so the test must drop them too or it
  # would happily validate a passwd file the real broker cannot read.
  # Strip ONLY what has to be overridden. Notably persistence_location stays,
  # so a genuine duplicate of it in someone else's fragment still gets caught —
  # stripping it would mask exactly the error class this check exists for.
  # 'persistence false' appended below is accepted as an override and stops the
  # test instance from writing over the real mosquitto.db; 'log_dest' is
  # additive in mosquitto, so appending stderr needs no strip either.
  local strip='^[[:space:]]*(include_dir|listener|port|bind_address|pid_file)[[:space:]]'
  local main_conf="$CONF_DIR/mosquitto.conf" f
  {
    [[ -f "$main_conf" ]] && grep -vE "$strip" "$main_conf"
    for f in "$CONF_D"/*.conf; do
      [[ -f "$f" ]] || continue
      echo "# --- from $f ---"
      grep -vE "$strip" "$f"
    done
    echo "listener 0 $test_dir/validate.sock"
    echo "persistence false"
    echo "log_dest stderr"
    echo "pid_file $test_dir/validate.pid"
  } > "$test_conf"
  chmod 644 "$test_conf"

  local out rc=0
  out="$(timeout 3 mosquitto -c "$test_conf" -v 2>&1 || rc=$?)"
  rm -rf "$test_dir"
  # 124 = timeout killed it, i.e. it started fine and kept running.
  if ((rc != 0 && rc != 124)); then
    err "configuration rejected by mosquitto:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  if printf '%s' "$out" | grep -qiE 'error|unable to open|invalid'; then
    err "configuration produced errors:"
    printf '%s\n' "$out" | grep -iE 'error|unable to open|invalid' | sed 's/^/    /' >&2
    return 1
  fi
  return 0
}

restart_broker() {
  if ! have_systemd; then
    warn "no systemd detected — start the broker yourself: mosquitto -c $CONF_DIR/mosquitto.conf -d"
    return
  fi
  info "restarting $SERVICE"
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE"; then
    err "$SERVICE failed to restart"
    systemctl status "$SERVICE" --no-pager -l | tail -20 >&2 || true
    restore_and_die "broker would not start — configuration rolled back"
  fi
  sleep 1
  if [[ "$(systemctl is-active "$SERVICE")" != "active" ]]; then
    journalctl -u "$SERVICE" -n 20 --no-pager >&2 || true
    restore_and_die "broker is not active after restart — configuration rolled back"
  fi
  ok "$SERVICE is active"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ((LIST_ONLY)); then
  hdr "Configured users"
  if [[ -f "$PASSWD_FILE" ]]; then list_users | sed 's/^/  /'
  else log "  (no password file yet)"; fi
  exit 0
fi

((${#USERS[@]})) || die "no usernames given. Example: $0 user1 otheruser2 superuser3"

for u in "${USERS[@]}"; do
  valid_username "$u" || die "invalid username '$u' (allowed: letters, digits, . _ @ -, max 64 chars)"
done

# Reject duplicates on the command line.
if [[ "$(printf '%s\n' "${USERS[@]}" | sort | uniq -d | wc -l)" -gt 0 ]]; then
  die "duplicate username on the command line: $(printf '%s\n' "${USERS[@]}" | sort | uniq -d | tr '\n' ' ')"
fi

hdr "Mosquitto setup"
install_broker
mkdir -p "$CONF_D" /var/lib/mosquitto
make_backup

prep_passwd_for_edit

if [[ "$MODE" == remove ]]; then
  for u in "${USERS[@]}"; do
    if user_exists "$u"; then
      mosquitto_passwd -D "$PASSWD_FILE" "$u"
      REMOVED+=("$u")
      ok "removed $u"
    else
      warn "$u does not exist — skipping"
    fi
  done
else
  for u in "${USERS[@]}"; do
    if user_exists "$u" && ((! DO_RESET)); then
      SKIPPED+=("$u")
      info "$u already exists — password preserved"
      continue
    fi
    pw="$(gen_password)"
    if [[ -f "$PASSWD_FILE" ]]; then
      mosquitto_passwd -b "$PASSWD_FILE" "$u" "$pw" \
        || restore_and_die "failed to add $u"
    else
      # -c creates the file; it would otherwise refuse on a missing path.
      mosquitto_passwd -b -c "$PASSWD_FILE" "$u" "$pw" \
        || restore_and_die "failed to create $PASSWD_FILE"
    fi
    if user_exists "$u" && ((DO_RESET)); then RESET_USERS+=("$u"); fi
    NEW_USERS+=("$u"); NEW_PASSWORDS+=("$pw")
    ok "provisioned $u"
  done
fi

fix_perms "$PASSWD_FILE"
write_acl
write_conf
ok "ACL rebuilt for: $(list_users | tr '\n' ' ')"

if ! validate_conf; then
  restore_and_die "configuration did not validate — nothing was changed"
fi
ok "configuration validated"

((DO_RESTART)) && restart_broker || warn "skipping restart (--no-restart)"

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
hdr "Result"
log "  broker:   port $PORT${BIND_ADDR:+ on $BIND_ADDR}, anonymous access disabled"
log "  users:    $(list_users | tr '\n' ' ')"
log "  config:   $MANAGED_CONF"
log "  acl:      $ACL_FILE"
log "  passwd:   $PASSWD_FILE"
log "  backup:   $BACKUP_DIR"
((${#SKIPPED[@]}))  && log "  unchanged: ${SKIPPED[*]}"
((${#REMOVED[@]}))  && log "  removed:   ${REMOVED[*]}"

if ((${#NEW_USERS[@]})); then
  CRED_FILE="$CRED_DIR/mosquitto-credentials-$(date +%Y%m%d-%H%M%S).txt"
  umask 077
  {
    echo "# Mosquitto credentials generated $(date -Is) on $(hostname)"
    echo "# Broker: port $PORT${BIND_ADDR:+ ($BIND_ADDR)}"
    for i in "${!NEW_USERS[@]}"; do
      printf '%s\t%s\n' "${NEW_USERS[$i]}" "${NEW_PASSWORDS[$i]}"
    done
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"

  hdr "New credentials"
  printf '  %-24s %s\n' "USERNAME" "PASSWORD"
  printf '  %-24s %s\n' "------------------------" "----------------"
  for i in "${!NEW_USERS[@]}"; do
    printf '  %-24s %s\n' "${NEW_USERS[$i]}" "${NEW_PASSWORDS[$i]}"
  done
  log ""
  log "  Also saved to $CRED_FILE (mode 600)."
  warn "These passwords cannot be recovered from the broker — the file stores hashes only."
  log ""
  log "  Test one of them:"
  log "    mosquitto_sub -h localhost -p $PORT -u ${NEW_USERS[0]} -P '${NEW_PASSWORDS[0]}' -t 'test/#' -v &"
  log "    mosquitto_pub -h localhost -p $PORT -u ${NEW_USERS[0]} -P '${NEW_PASSWORDS[0]}' -t 'test/hello' -m 'it works'"
else
  log ""
  ok "no new users to report"
fi