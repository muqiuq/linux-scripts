#!/usr/bin/env bash
#
# serial-console-setup.sh — audit, back up, and (optionally) fix the serial
# console configuration on a headless Debian box (PC Engines APU2/APU3/APU4).
#
# Default action is READ-ONLY. Nothing is changed unless you pass --apply.
#
#   ./serial-console-setup.sh                 # audit only, prints a report
#   ./serial-console-setup.sh --apply         # back up + fix what's broken
#   ./serial-console-setup.sh --apply --dry-run
#   ./serial-console-setup.sh --list-backups
#
# What it checks / fixes:
#   1. console=ttyS0,<baud> on the kernel cmdline (via /etc/default/grub)
#   2. GRUB's own menu redirected to serial (GRUB_TERMINAL / GRUB_SERIAL_COMMAND)
#   3. A visible GRUB menu with a timeout (your only rescue path when headless)
#   4. serial-getty@ttyS0 enabled so you get a login prompt
#
# Every change is written into a marked, self-documenting block in
# /etc/default/grub, and every run that modifies anything drops a timestamped
# backup plus a ready-to-run revert.sh next to it.
#
# It never reboots. It never writes /boot/grub/grub.cfg until a generated
# candidate has been validated first.

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Tunables
# ----------------------------------------------------------------------------
PORT="${PORT:-ttyS0}"           # serial device, without /dev/
BAUD="${BAUD:-115200}"          # APU boards: 115200. ALIX: 38400.
UNIT="${UNIT:-0}"               # GRUB serial unit; ttyS0 -> 0, ttyS1 -> 1
GRUB_TIMEOUT_WANT="${GRUB_TIMEOUT_WANT:-5}"

GRUB_DEFAULT_FILE=/etc/default/grub
GRUB_CFG=/boot/grub/grub.cfg
BACKUP_ROOT=/root/serial-console-backups
LOCK_FILE=/run/serial-console-setup.lock
BLOCK_BEGIN="# >>> serial-console-setup.sh managed block >>>"
BLOCK_END="# <<< serial-console-setup.sh managed block <<<"

MANAGED_KEYS=(
  GRUB_CMDLINE_LINUX
  GRUB_CMDLINE_LINUX_DEFAULT
  GRUB_TERMINAL
  GRUB_TERMINAL_INPUT
  GRUB_TERMINAL_OUTPUT
  GRUB_SERIAL_COMMAND
  GRUB_TIMEOUT
  GRUB_TIMEOUT_STYLE
  GRUB_GFXPAYLOAD_LINUX
)

APPLY=0
DRY_RUN=0
KEEP_QUIET=0
BACKUP_DIR=""
CHANGES_MADE=0
declare -a FINDINGS_OK=() FINDINGS_BAD=() ACTIONS=()

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
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

on_error() {
  local rc=$? line=${BASH_LINENO[0]:-?}
  err "aborted at line $line (exit $rc)"
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    err "originals are safe in: $BACKUP_DIR"
    err "roll back with:        $BACKUP_DIR/revert.sh"
  fi
  exit "$rc"
}
trap on_error ERR

usage() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  exit 0
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while (($#)); do
  case "$1" in
    --apply)        APPLY=1 ;;
    --dry-run|-n)   DRY_RUN=1 ;;
    --keep-quiet)   KEEP_QUIET=1 ;;
    --baud)         shift; BAUD="${1:?--baud needs a value}" ;;
    --port)         shift; PORT="${1:?--port needs a value}" ;;
    --list-backups)
        if [[ -d "$BACKUP_ROOT" ]]; then
          find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort
        else
          log "no backups yet ($BACKUP_ROOT does not exist)"
        fi
        exit 0 ;;
    -h|--help)      usage ;;
    *)              die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

((DRY_RUN)) && APPLY=1   # dry-run implies we walk the apply path, just don't write

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0 $*)"

  [[ -r /proc/cmdline ]] || die "/proc not mounted? cannot audit safely"
  [[ -f "$GRUB_DEFAULT_FILE" ]] || die "$GRUB_DEFAULT_FILE not found — is GRUB installed?"

  command -v update-grub >/dev/null 2>&1 || command -v grub-mkconfig >/dev/null 2>&1 \
    || die "neither update-grub nor grub-mkconfig found"

  # Don't let two copies race on /etc/default/grub.
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another instance is running (lock: $LOCK_FILE)"

  if [[ ! -e "/dev/$PORT" ]]; then
    warn "/dev/$PORT does not exist — check --port, or the board's BIOS serial setting"
  fi

  if [[ -d /sys/firmware/efi ]]; then
    warn "booted via UEFI; this script assumes the APU's BIOS/coreboot path"
  fi

  # Warn early if /boot is not writable — better now than mid-run.
  if ((APPLY)) && ! ((DRY_RUN)); then
    touch -c "$GRUB_CFG" 2>/dev/null || warn "$GRUB_CFG may not be writable"
  fi
}

grub_mkconfig_cmd() {
  if command -v grub-mkconfig >/dev/null 2>&1; then echo grub-mkconfig
  else echo grub2-mkconfig; fi
}

# ----------------------------------------------------------------------------
# Reading /etc/default/grub
#
# The file is sourced by grub-mkconfig, so for duplicate keys the LAST
# assignment wins. We read accordingly.
# ----------------------------------------------------------------------------
grub_var() {
  local key="$1" file="${2:-$GRUB_DEFAULT_FILE}"
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*"k"=" {
      line = $0
      sub("^[[:space:]]*"k"=", "", line)
      gsub(/^"|"$/, "", line)
      gsub(/^'"'"'|'"'"'$/, "", line)
      val = line
    }
    END { print val }
  ' "$file"
}

# Strip every console= token from a cmdline string, collapse whitespace.
strip_console() {
  local s="$1" out="" tok
  for tok in $s; do
    [[ "$tok" == console=* ]] && continue
    out+="${out:+ }$tok"
  done
  printf '%s' "$out"
}

strip_token() {
  local s="$1" drop="$2" out="" tok
  for tok in $s; do
    [[ "$tok" == "$drop" ]] && continue
    out+="${out:+ }$tok"
  done
  printf '%s' "$out"
}

# ----------------------------------------------------------------------------
# Audit
# ----------------------------------------------------------------------------
WANT_CONSOLE="console=tty0 console=${PORT},${BAUD}n8"
WANT_SERIAL_CMD="serial --unit=${UNIT} --speed=${BAUD} --word=8 --parity=no --stop=1"

NEED_CMDLINE=0
NEED_TERMINAL=0
NEED_SERIALCMD=0
NEED_MENU=0
NEED_GETTY=0

audit() {
  hdr "Running system"

  local live_cmdline; live_cmdline="$(tr -d '\0' < /proc/cmdline)"
  log "  /proc/cmdline: $live_cmdline"
  if [[ "$live_cmdline" == *"console=${PORT}"* ]]; then
    FINDINGS_OK+=("running kernel has console=${PORT}")
  else
    FINDINGS_BAD+=("running kernel has NO console=${PORT} — no boot messages on serial")
  fi

  if [[ -r /sys/class/tty/console/active ]]; then
    log "  active consoles: $(cat /sys/class/tty/console/active)"
  fi
  if [[ -r /proc/tty/driver/serial ]]; then
    log "  serial driver:"
    sed -n '2,4p' /proc/tty/driver/serial | sed 's/^/    /' || true
  fi

  hdr "$GRUB_DEFAULT_FILE"

  local cur_linux cur_default cur_term cur_termin cur_termout cur_serialcmd
  local cur_timeout cur_style
  cur_linux="$(grub_var GRUB_CMDLINE_LINUX)"
  cur_default="$(grub_var GRUB_CMDLINE_LINUX_DEFAULT)"
  cur_term="$(grub_var GRUB_TERMINAL)"
  cur_termin="$(grub_var GRUB_TERMINAL_INPUT)"
  cur_termout="$(grub_var GRUB_TERMINAL_OUTPUT)"
  cur_serialcmd="$(grub_var GRUB_SERIAL_COMMAND)"
  cur_timeout="$(grub_var GRUB_TIMEOUT)"
  cur_style="$(grub_var GRUB_TIMEOUT_STYLE)"

  log "  GRUB_CMDLINE_LINUX         = ${cur_linux:-<unset>}"
  log "  GRUB_CMDLINE_LINUX_DEFAULT = ${cur_default:-<unset>}"
  log "  GRUB_TERMINAL              = ${cur_term:-<unset>}"
  log "  GRUB_TERMINAL_INPUT        = ${cur_termin:-<unset>}"
  log "  GRUB_TERMINAL_OUTPUT       = ${cur_termout:-<unset>}"
  log "  GRUB_SERIAL_COMMAND        = ${cur_serialcmd:-<unset>}"
  log "  GRUB_TIMEOUT               = ${cur_timeout:-<unset>}"
  log "  GRUB_TIMEOUT_STYLE         = ${cur_style:-<unset>}"

  # 1. kernel cmdline
  if [[ "$cur_linux $cur_default" == *"console=${PORT},${BAUD}"* ]]; then
    FINDINGS_OK+=("console=${PORT},${BAUD} present in $GRUB_DEFAULT_FILE")
  else
    FINDINGS_BAD+=("console=${PORT},${BAUD} missing from $GRUB_DEFAULT_FILE")
    NEED_CMDLINE=1
  fi

  # A console= in _DEFAULT that disagrees with ours would win on normal
  # entries, because grub-mkconfig emits _DEFAULT after _LINUX.
  if [[ "$cur_default" == *console=* && "$cur_default" != *"console=${PORT},${BAUD}"* ]]; then
    FINDINGS_BAD+=("GRUB_CMDLINE_LINUX_DEFAULT holds a conflicting console= token")
    NEED_CMDLINE=1
  fi

  if [[ "$cur_default" == *quiet* ]] && ! ((KEEP_QUIET)); then
    FINDINGS_BAD+=("'quiet' is set — hides the boot messages you want on serial")
    NEED_CMDLINE=1
  fi

  # 2. GRUB's own terminal
  if [[ "$cur_term" == *serial* || ( "$cur_termin" == *serial* && "$cur_termout" == *serial* ) ]]; then
    FINDINGS_OK+=("GRUB menu is redirected to serial")
  else
    FINDINGS_BAD+=("GRUB menu is NOT on serial — you cannot pick an entry when headless")
    NEED_TERMINAL=1
  fi

  # 3. serial command sanity: unit and speed must match
  if [[ -z "$cur_serialcmd" ]]; then
    FINDINGS_BAD+=("GRUB_SERIAL_COMMAND unset")
    NEED_SERIALCMD=1
  elif [[ "$cur_serialcmd" != *"--unit=${UNIT}"* || "$cur_serialcmd" != *"--speed=${BAUD}"* ]]; then
    FINDINGS_BAD+=("GRUB_SERIAL_COMMAND does not match unit=${UNIT} speed=${BAUD}")
    NEED_SERIALCMD=1
  else
    FINDINGS_OK+=("GRUB_SERIAL_COMMAND matches unit=${UNIT} speed=${BAUD}")
  fi

  # 4. visible menu — the rescue path
  if [[ "$cur_style" == "hidden" || "$cur_timeout" == "0" ]]; then
    FINDINGS_BAD+=("GRUB menu is hidden or has a 0s timeout — no rescue path")
    NEED_MENU=1
  else
    FINDINGS_OK+=("GRUB menu is visible with a timeout")
  fi

  hdr "$GRUB_CFG"
  if [[ -f "$GRUB_CFG" ]]; then
    local n_menu n_console n_serial
    n_menu=$(grep -c '^\s*menuentry' "$GRUB_CFG" || true)
    n_console=$(grep -c "console=${PORT},${BAUD}" "$GRUB_CFG" || true)
    n_serial=$(grep -c "^\s*serial --unit=${UNIT}" "$GRUB_CFG" || true)
    log "  menuentries: $n_menu | kernel lines with console=${PORT}: $n_console | serial init lines: $n_serial"
    if ((n_console == 0)); then
      FINDINGS_BAD+=("generated grub.cfg has no console=${PORT} on its kernel lines")
    else
      FINDINGS_OK+=("generated grub.cfg carries console=${PORT}")
    fi
  else
    FINDINGS_BAD+=("$GRUB_CFG missing")
  fi

  hdr "Login prompt (getty)"
  local unit="serial-getty@${PORT}.service" state active
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  log "  $unit: enabled=${state:-unknown} active=${active:-unknown}"
  if [[ "$active" == "active" ]]; then
    FINDINGS_OK+=("$unit is running — you get a login prompt on serial")
  else
    FINDINGS_BAD+=("$unit is not running — no login prompt on serial")
    NEED_GETTY=1
  fi

  if [[ -f /etc/securetty ]] && ! grep -qx "$PORT" /etc/securetty 2>/dev/null; then
    warn "$PORT is not in /etc/securetty — direct root login over serial will be refused"
    warn "  (normal user + sudo still works; add the line yourself if you want root)"
  fi
}

# ----------------------------------------------------------------------------
# Backup
# ----------------------------------------------------------------------------
make_backup() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  if ((DRY_RUN)); then
    info "[dry-run] would create backup in $BACKUP_DIR"
    return
  fi
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"

  cp -a "$GRUB_DEFAULT_FILE" "$BACKUP_DIR/default-grub"
  [[ -f "$GRUB_CFG" ]] && cp -a "$GRUB_CFG" "$BACKUP_DIR/grub.cfg"

  {
    echo "host:        $(hostname)"
    echo "date:        $(date -Is)"
    echo "kernel:      $(uname -r)"
    echo "cmdline:     $(tr -d '\0' < /proc/cmdline)"
    echo "port/baud:   $PORT / $BAUD (unit $UNIT)"
    echo "getty state: $(systemctl is-enabled "serial-getty@${PORT}.service" 2>/dev/null || echo unknown)"
  } > "$BACKUP_DIR/state.txt"

  cat > "$BACKUP_DIR/revert.sh" <<REVERT
#!/usr/bin/env bash
# Restore the serial-console configuration captured on $(date -Is).
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
here="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cp -a "\$here/default-grub" "$GRUB_DEFAULT_FILE"
echo "restored $GRUB_DEFAULT_FILE"
if [[ -f "\$here/grub.cfg" ]]; then
  cp -a "\$here/grub.cfg" "$GRUB_CFG"
  echo "restored $GRUB_CFG verbatim"
else
  $(grub_mkconfig_cmd) -o "$GRUB_CFG"
fi
echo "done — reboot to return to the previous boot configuration"
REVERT
  chmod 700 "$BACKUP_DIR/revert.sh"
  ok "backup written: $BACKUP_DIR"
}

# ----------------------------------------------------------------------------
# Editing /etc/default/grub
#
# Strategy: comment out live assignments of the keys we manage, then append a
# single marked block. Since the file is sourced, last assignment wins, so the
# block is authoritative and the original lines stay visible for reference.
# Re-running is a no-op when the block already matches.
# ----------------------------------------------------------------------------
build_block() {
  local cur_linux cur_default new_linux new_default
  cur_linux="$(grub_var GRUB_CMDLINE_LINUX)"
  cur_default="$(grub_var GRUB_CMDLINE_LINUX_DEFAULT)"

  new_linux="$(strip_console "$cur_linux")"
  new_linux="${new_linux:+$new_linux }$WANT_CONSOLE"

  new_default="$(strip_console "$cur_default")"
  ((KEEP_QUIET)) || new_default="$(strip_token "$new_default" quiet)"

  cat <<BLOCK
$BLOCK_BEGIN
# Written $(date -Is). Sourced last, so these win over anything above.
# Undo: delete this block (or run the revert.sh in $BACKUP_ROOT/*/).
GRUB_CMDLINE_LINUX="$new_linux"
GRUB_CMDLINE_LINUX_DEFAULT="$new_default"
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="$WANT_SERIAL_CMD"
GRUB_TIMEOUT=$GRUB_TIMEOUT_WANT
GRUB_TIMEOUT_STYLE=menu
GRUB_GFXPAYLOAD_LINUX=text
$BLOCK_END
BLOCK
}

edit_grub_default() {
  local tmp new_block
  tmp="$(mktemp)"
  new_block="$(build_block)"

  # Drop any previous managed block, comment out live managed assignments.
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" -v keys="${MANAGED_KEYS[*]}" '
    BEGIN { n = split(keys, K, " ") }
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock { next }
    {
      for (i = 1; i <= n; i++) {
        if ($0 ~ "^[[:space:]]*"K[i]"=") {
          print "# [serial-console-setup] superseded: " $0
          next
        }
      }
      print
    }
  ' "$GRUB_DEFAULT_FILE" > "$tmp"

  printf '%s\n' "$new_block" >> "$tmp"

  if diff -q "$GRUB_DEFAULT_FILE" "$tmp" >/dev/null 2>&1; then
    ok "$GRUB_DEFAULT_FILE already correct — no change"
    rm -f "$tmp"
    return 1
  fi

  log ""
  log "--- proposed diff for $GRUB_DEFAULT_FILE ---"
  diff -u "$GRUB_DEFAULT_FILE" "$tmp" || true
  log "--- end diff ---"
  log ""

  if ((DRY_RUN)); then
    info "[dry-run] not writing $GRUB_DEFAULT_FILE"
    rm -f "$tmp"
    return 1
  fi

  # Write through the existing inode so ownership and mode survive.
  cat "$tmp" > "$GRUB_DEFAULT_FILE"
  rm -f "$tmp"
  ok "$GRUB_DEFAULT_FILE updated"
  ACTIONS+=("rewrote $GRUB_DEFAULT_FILE (managed block)")
  return 0
}

# ----------------------------------------------------------------------------
# Regenerate grub.cfg — validate a candidate before touching the real one
# ----------------------------------------------------------------------------
regen_grub_cfg() {
  local mkconfig candidate
  mkconfig="$(grub_mkconfig_cmd)"
  candidate="$(mktemp)"

  info "generating candidate grub.cfg (not installed yet)"
  if ! "$mkconfig" -o "$candidate" 2>"$candidate.log"; then
    err "$mkconfig failed:"
    sed 's/^/    /' "$candidate.log" >&2
    rm -f "$candidate" "$candidate.log"
    die "refusing to touch $GRUB_CFG — $GRUB_DEFAULT_FILE is backed up, nothing else changed"
  fi

  local n_menu n_console n_serial
  n_menu=$(grep -c '^\s*menuentry' "$candidate" || true)
  n_console=$(grep -c "console=${PORT},${BAUD}" "$candidate" || true)
  n_serial=$(grep -c "^\s*serial --unit=${UNIT}" "$candidate" || true)

  log "  candidate: menuentries=$n_menu console=$n_console serial_init=$n_serial"

  local bad=0
  ((n_menu   > 0)) || { err "candidate has no menuentry — would leave the box unbootable"; bad=1; }
  ((n_console > 0)) || { err "candidate has no console=${PORT},${BAUD} on kernel lines"; bad=1; }
  ((n_serial > 0)) || warn "candidate has no 'serial --unit=${UNIT}' line (GRUB menu may stay off serial)"

  if ((bad)); then
    rm -f "$candidate" "$candidate.log"
    die "candidate rejected — $GRUB_CFG left untouched"
  fi

  if ((DRY_RUN)); then
    info "[dry-run] candidate validated OK; not installing to $GRUB_CFG"
    rm -f "$candidate" "$candidate.log"
    return
  fi

  cat "$candidate" > "$GRUB_CFG"
  rm -f "$candidate" "$candidate.log"
  sync
  ok "$GRUB_CFG regenerated and validated"
  ACTIONS+=("regenerated $GRUB_CFG")
  CHANGES_MADE=1
}

# ----------------------------------------------------------------------------
# getty
# ----------------------------------------------------------------------------
fix_getty() {
  local unit="serial-getty@${PORT}.service"
  if ((DRY_RUN)); then
    info "[dry-run] would run: systemctl enable --now $unit"
    return
  fi
  info "enabling $unit"
  systemctl enable --now "$unit"
  sleep 1
  if [[ "$(systemctl is-active "$unit")" == "active" ]]; then
    ok "$unit is active — a login prompt is available on /dev/$PORT right now"
    ACTIONS+=("enabled $unit")
    CHANGES_MADE=1
  else
    warn "$unit did not come up; check: systemctl status $unit"
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
preflight "$@"

log "${C_BOLD}serial console audit — port=/dev/$PORT baud=$BAUD grub-unit=$UNIT${C_RESET}"
((APPLY)) || info "read-only mode; pass --apply to fix what's reported"
((DRY_RUN)) && info "dry-run: nothing will be written"

audit

hdr "Summary"
for f in "${FINDINGS_OK[@]:-}";  do [[ -n "$f" ]] && ok "$f";   done
for f in "${FINDINGS_BAD[@]:-}"; do [[ -n "$f" ]] && warn "$f"; done

NEED_GRUB_EDIT=$(( NEED_CMDLINE || NEED_TERMINAL || NEED_SERIALCMD || NEED_MENU ))

if (( ! NEED_GRUB_EDIT && ! NEED_GETTY )); then
  hdr "Result"
  ok "nothing to do — serial console is configured correctly"
  exit 0
fi

if ((! APPLY)); then
  hdr "Result"
  warn "issues found. Re-run with --apply (or --apply --dry-run to preview)."
  exit 1
fi

hdr "Applying"
make_backup

if ((NEED_GRUB_EDIT)); then
  if edit_grub_default; then
    regen_grub_cfg
  fi
fi

((NEED_GETTY)) && fix_getty

hdr "Result"
if ((DRY_RUN)); then
  info "dry-run complete — no changes made"
  exit 0
fi

if ((CHANGES_MADE)); then
  for a in "${ACTIONS[@]:-}"; do [[ -n "$a" ]] && ok "$a"; done
  log ""
  log "Verify before rebooting:"
  log "  grep -E 'serial --unit|console=${PORT}' $GRUB_CFG | head"
  log ""
  log "Roll back at any time (before or after reboot):"
  log "  $BACKUP_DIR/revert.sh"
  log ""
  warn "no reboot was performed. Keep your serial session attached across the"
  warn "next reboot so you can see SeaBIOS -> GRUB -> kernel -> login."
else
  ok "no changes were necessary"
fi