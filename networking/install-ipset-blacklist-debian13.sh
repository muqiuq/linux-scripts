#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

INSTALL_DIR=/etc/ipset-blacklist
CONFIG_FILE=${INSTALL_DIR}/ipset-blacklist.conf
UPDATE_SCRIPT=/usr/local/sbin/update-blacklist.sh
FIREWALL_SCRIPT=/usr/local/sbin/ipset-blacklist-firewall.sh
UPDATE_SERVICE=/etc/systemd/system/ipset-blacklist-update.service
UPDATE_TIMER=/etc/systemd/system/ipset-blacklist-update.timer
FIREWALL_SERVICE=/etc/systemd/system/ipset-blacklist-firewall.service

if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  MAGENTA=$'\033[35m'
  CYAN=$'\033[36m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED=
  GREEN=
  YELLOW=
  BLUE=
  MAGENTA=
  CYAN=
  BOLD=
  RESET=
fi

title() { printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$1" "${RESET}"; }
info() { printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$1"; }
ok() { printf '%s[ OK ]%s %s\n' "${GREEN}" "${RESET}" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "${RED}" "${RESET}" "$1" >&2; exit 1; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    fail "Run this installer as root, for example: sudo $0"
  fi
}

check_debian_13() {
  if [[ ! -r /etc/os-release ]]; then
    warn "Cannot read /etc/os-release; continuing because this may still be Debian-like."
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ ${ID:-} != debian || ${VERSION_ID:-} != 13 ]]; then
    warn "This installer is written for Debian 13. Detected: ${PRETTY_NAME:-unknown}."
  else
    ok "Detected ${PRETTY_NAME}."
  fi
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

install_packages() {
  local packages=(ca-certificates curl iprange ipset iptables)
  local missing=()

  for package_name in "${packages[@]}"; do
    if ! package_installed "${package_name}"; then
      missing+=("${package_name}")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    ok "Required packages are already installed."
    return
  fi

  info "Installing missing packages: ${missing[*]}"
  apt-get update
  apt-get install --no-install-recommends -y "${missing[@]}"
  ok "Package installation finished."
}

write_managed_file() {
  local target=$1
  local mode=$2
  local tmp_file
  local backup_file

  mkdir -p "$(dirname "${target}")"
  tmp_file=$(mktemp)
  cat > "${tmp_file}"

  if [[ -f ${target} ]] && cmp -s "${tmp_file}" "${target}"; then
    rm -f "${tmp_file}"
    ok "Already current: ${target}"
    return
  fi

  if [[ -f ${target} ]]; then
    backup_file="${target}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${target}" "${backup_file}"
    warn "Existing file backed up: ${backup_file}"
  fi

  install -o root -g root -m "${mode}" "${tmp_file}" "${target}"
  rm -f "${tmp_file}"
  ok "Installed: ${target}"
}

ensure_config_line() {
  local pattern=$1
  local line=$2

  if grep -Eq "${pattern}" "${CONFIG_FILE}"; then
    return
  fi

  printf '\n%s\n' "${line}" >> "${CONFIG_FILE}"
  ok "Added config setting: ${line}"
}

install_config() {
  mkdir -p "${INSTALL_DIR}"

  if [[ -f ${CONFIG_FILE} ]]; then
    ok "Keeping existing config: ${CONFIG_FILE}"
  else
    write_managed_file "${CONFIG_FILE}" 0644 <<'CONFIG_EOF'
IPSET_BLACKLIST_NAME=blacklist
IPSET_TMP_BLACKLIST_NAME=${IPSET_BLACKLIST_NAME}-tmp
IPTABLES_MANAGED_CHAIN=IPSET-BLACKLIST

IP_BLACKLIST_DIR="${IP_BLACKLIST_DIR:-/etc/ipset-blacklist}"
IP_BLACKLIST_RESTORE=${IP_BLACKLIST_DIR}/ip-blacklist.restore
IP_BLACKLIST=${IP_BLACKLIST_DIR}/ip-blacklist.list
IP_BLACKLIST_REMOTE=${IP_BLACKLIST_DIR}/ip-blacklist-remote.list
IP_BLACKLIST_LOCAL=${IP_BLACKLIST_DIR}/ip-blacklist-local.list
IP_WHITELIST_LOCAL=${IP_BLACKLIST_DIR}/ip-whitelist-local.list

FORCE=yes
IGNORE_CURL_ERRORS=yes
VERBOSE=${VERBOSE:-no}
IPTABLES_IPSET_RULE_NUMBER=1
MAXELEM=131072

PRIVATE_NETWORK_EXCEPTIONS=(
  "10.0.0.0/8"
  "172.16.0.0/12"
  "192.168.0.0/16"
)

BLACKLISTS=(
  "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"
)

BLACKLISTS_LOCAL=(
)

WHITELISTS_LOCAL=(
)
CONFIG_EOF
  fi

  ensure_config_line '^FORCE=' 'FORCE=yes'
  ensure_config_line '^IPTABLES_MANAGED_CHAIN=' 'IPTABLES_MANAGED_CHAIN=IPSET-BLACKLIST'
  if ! grep -Eq '^PRIVATE_NETWORK_EXCEPTIONS=' "${CONFIG_FILE}"; then
    cat >> "${CONFIG_FILE}" <<'CONFIG_APPEND_EOF'

PRIVATE_NETWORK_EXCEPTIONS=(
  "10.0.0.0/8"
  "172.16.0.0/12"
  "192.168.0.0/16"
)
CONFIG_APPEND_EOF
    ok "Added private network exceptions to config."
  fi
}

install_firewall_script() {
  write_managed_file "${FIREWALL_SCRIPT}" 0755 <<'FIREWALL_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE=${1:-/etc/ipset-blacklist/ipset-blacklist.conf}

if [[ ! -r ${CONFIG_FILE} ]]; then
  echo "Error: cannot read configuration file: ${CONFIG_FILE}" >&2
  exit 1
fi

set +u
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set -u

IPSET_BLACKLIST_NAME=${IPSET_BLACKLIST_NAME:-blacklist}
IPTABLES_MANAGED_CHAIN=${IPTABLES_MANAGED_CHAIN:-IPSET-BLACKLIST}
IPTABLES_IPSET_RULE_NUMBER=${IPTABLES_IPSET_RULE_NUMBER:-1}
HASHSIZE=${HASHSIZE:-16384}
MAXELEM=${MAXELEM:-65536}
IP_BLACKLIST_RESTORE=${IP_BLACKLIST_RESTORE:-/etc/ipset-blacklist/ip-blacklist.restore}

if ! declare -p PRIVATE_NETWORK_EXCEPTIONS >/dev/null 2>&1; then
  PRIVATE_NETWORK_EXCEPTIONS=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
fi

restore_ipset_file() {
  local restore_file=$1

  if [[ ! -s ${restore_file} ]]; then
    return 1
  fi

  ipset restore -file "${restore_file}" 2>/dev/null || ipset -file "${restore_file}" restore
}

if ! restore_ipset_file "${IP_BLACKLIST_RESTORE}"; then
  ipset create "${IPSET_BLACKLIST_NAME}" -exist hash:net family inet hashsize "${HASHSIZE}" maxelem "${MAXELEM}"
fi

iptables -N "${IPTABLES_MANAGED_CHAIN}" 2>/dev/null || true
iptables -F "${IPTABLES_MANAGED_CHAIN}"

for private_network in "${PRIVATE_NETWORK_EXCEPTIONS[@]}"; do
  iptables -A "${IPTABLES_MANAGED_CHAIN}" -s "${private_network}" -j RETURN
done

iptables -A "${IPTABLES_MANAGED_CHAIN}" -m set --match-set "${IPSET_BLACKLIST_NAME}" src -j DROP
iptables -A "${IPTABLES_MANAGED_CHAIN}" -j RETURN

if ! iptables -C INPUT -j "${IPTABLES_MANAGED_CHAIN}" 2>/dev/null; then
  iptables -I INPUT "${IPTABLES_IPSET_RULE_NUMBER}" -j "${IPTABLES_MANAGED_CHAIN}"
fi
FIREWALL_EOF
}

install_update_script() {
  write_managed_file "${UPDATE_SCRIPT}" 0755 <<'UPDATE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

exists() { command -v "$1" >/dev/null 2>&1; }

CONFIG_FILE=${1:-}
if [[ -z ${CONFIG_FILE} ]]; then
  echo "Error: please specify a configuration file, e.g. $0 /etc/ipset-blacklist/ipset-blacklist.conf" >&2
  exit 1
fi

if [[ ! -r ${CONFIG_FILE} ]]; then
  echo "Error: cannot read configuration file: ${CONFIG_FILE}" >&2
  exit 1
fi

set +u
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set -u

required_commands=(curl grep ipset iptables sed sort wc mktemp)
missing_commands=()
for required_command in "${required_commands[@]}"; do
  if ! exists "${required_command}"; then
    missing_commands+=("${required_command}")
  fi
done

if (( ${#missing_commands[@]} > 0 )); then
  echo "Error: missing required executables: ${missing_commands[*]}" >&2
  exit 1
fi

IPSET_BLACKLIST_NAME=${IPSET_BLACKLIST_NAME:-blacklist}
IPSET_TMP_BLACKLIST_NAME=${IPSET_TMP_BLACKLIST_NAME:-${IPSET_BLACKLIST_NAME}-tmp}
IP_BLACKLIST_DIR=${IP_BLACKLIST_DIR:-/etc/ipset-blacklist}
IP_BLACKLIST=${IP_BLACKLIST:-${IP_BLACKLIST_DIR}/ip-blacklist.list}
IP_BLACKLIST_RESTORE=${IP_BLACKLIST_RESTORE:-${IP_BLACKLIST_DIR}/ip-blacklist.restore}
HASHSIZE=${HASHSIZE:-16384}
MAXELEM=${MAXELEM:-65536}
VERBOSE=${VERBOSE:-no}
IGNORE_CURL_ERRORS=${IGNORE_CURL_ERRORS:-yes}
FIREWALL_SCRIPT=${FIREWALL_SCRIPT:-/usr/local/sbin/ipset-blacklist-firewall.sh}

mkdir -p "$(dirname "${IP_BLACKLIST}")" "$(dirname "${IP_BLACKLIST_RESTORE}")"

if [[ -x ${FIREWALL_SCRIPT} ]]; then
  "${FIREWALL_SCRIPT}" "${CONFIG_FILE}"
elif [[ ${FORCE:-no} == yes ]]; then
  ipset create "${IPSET_BLACKLIST_NAME}" -exist hash:net family inet hashsize "${HASHSIZE}" maxelem "${MAXELEM}"
else
  if ! ipset list -n | grep -Fxq "${IPSET_BLACKLIST_NAME}"; then
    echo "Error: ipset does not exist yet: ${IPSET_BLACKLIST_NAME}" >&2
    exit 1
  fi
fi

ip_blacklist_tmp=$(mktemp)
ip_download_tmp=
cleanup() {
  rm -f "${ip_blacklist_tmp}"
  if [[ -n ${ip_download_tmp} ]]; then
    rm -f "${ip_download_tmp}"
  fi
}
trap cleanup EXIT

extract_ips_from_file() {
  local source_file=$1
  grep -Eo '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "${source_file}" \
    | sed -E 's/^[^0-9]*//' \
    | sed -E 's/^0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)$/\1.\2.\3.\4/' || true
}

append_ips_from_file() {
  local source_file=$1
  extract_ips_from_file "${source_file}" >> "${ip_blacklist_tmp}"
}

if declare -p BLACKLISTS >/dev/null 2>&1; then
  for blacklist_url in "${BLACKLISTS[@]}"; do
    ip_download_tmp=$(mktemp)
    http_rc=$(curl -L -A "ipset-blacklist-update/debian13" --connect-timeout 10 --max-time 30 -o "${ip_download_tmp}" -s -w "%{http_code}" "${blacklist_url}" || true)
    if [[ ${http_rc} == 200 || ${http_rc} == 302 || ${http_rc} == 000 ]]; then
      append_ips_from_file "${ip_download_tmp}"
      [[ ${VERBOSE} == yes ]] && printf '.'
    else
      echo "Warning: curl returned HTTP response code ${http_rc} for URL ${blacklist_url}" >&2
      if [[ ${IGNORE_CURL_ERRORS} != yes ]]; then
        exit 1
      fi
    fi
    rm -f "${ip_download_tmp}"
    ip_download_tmp=
  done
fi

if declare -p BLACKLISTS_LOCAL >/dev/null 2>&1; then
  for local_blacklist in "${BLACKLISTS_LOCAL[@]}"; do
    [[ -z ${local_blacklist} ]] && continue
    if [[ ${local_blacklist} != /* ]]; then
      local_blacklist=${IP_BLACKLIST_DIR}/${local_blacklist}
    fi
    if [[ -r ${local_blacklist} ]]; then
      append_ips_from_file "${local_blacklist}"
    fi
  done
fi

sed -E -e '/^(0\.0\.0\.0|10\.|127\.|169\.254\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "${ip_blacklist_tmp}" \
  | sort -n \
  | sort -mu >| "${IP_BLACKLIST}"

if declare -p WHITELISTS_LOCAL >/dev/null 2>&1; then
  whitelist_tmp=$(mktemp)
  for local_whitelist in "${WHITELISTS_LOCAL[@]}"; do
    [[ -z ${local_whitelist} ]] && continue
    if [[ ${local_whitelist} != /* ]]; then
      local_whitelist=${IP_BLACKLIST_DIR}/${local_whitelist}
    fi
    if [[ -r ${local_whitelist} ]]; then
      extract_ips_from_file "${local_whitelist}" >> "${whitelist_tmp}"
    fi
  done
  if [[ -s ${whitelist_tmp} ]]; then
    grep -Fvx -f "${whitelist_tmp}" "${IP_BLACKLIST}" > "${ip_blacklist_tmp}"
    mv "${ip_blacklist_tmp}" "${IP_BLACKLIST}"
    ip_blacklist_tmp=$(mktemp)
  fi
  rm -f "${whitelist_tmp}"
fi

if exists iprange && [[ ${OPTIMIZE_CIDR:-yes} != no ]]; then
  if [[ ${VERBOSE} == yes ]]; then
    printf '\nAddresses before CIDR optimization: %s\n' "$(wc -l < "${IP_BLACKLIST}")"
  fi
  if < "${IP_BLACKLIST}" iprange --optimize - > "${ip_blacklist_tmp}" 2>/dev/null; then
    cp "${ip_blacklist_tmp}" "${IP_BLACKLIST}"
  fi
  if [[ ${VERBOSE} == yes ]]; then
    printf 'Addresses after CIDR optimization:  %s\n' "$(wc -l < "${IP_BLACKLIST}")"
  fi
fi

cat >| "${IP_BLACKLIST_RESTORE}" <<RESTORE_HEADER
create ${IPSET_TMP_BLACKLIST_NAME} -exist hash:net family inet hashsize ${HASHSIZE} maxelem ${MAXELEM}
create ${IPSET_BLACKLIST_NAME} -exist hash:net family inet hashsize ${HASHSIZE} maxelem ${MAXELEM}
flush ${IPSET_TMP_BLACKLIST_NAME}
RESTORE_HEADER

sed -rn -e '/^#|^$/d' -e "s/^([0-9./]+).*/add ${IPSET_TMP_BLACKLIST_NAME} \\1/p" "${IP_BLACKLIST}" >> "${IP_BLACKLIST_RESTORE}"

cat >> "${IP_BLACKLIST_RESTORE}" <<RESTORE_FOOTER
swap ${IPSET_BLACKLIST_NAME} ${IPSET_TMP_BLACKLIST_NAME}
destroy ${IPSET_TMP_BLACKLIST_NAME}
RESTORE_FOOTER

ipset restore -file "${IP_BLACKLIST_RESTORE}" 2>/dev/null || ipset -file "${IP_BLACKLIST_RESTORE}" restore

if [[ -x ${FIREWALL_SCRIPT} ]]; then
  "${FIREWALL_SCRIPT}" "${CONFIG_FILE}"
fi

if [[ ${VERBOSE} == yes ]]; then
  printf '\nBlacklisted addresses found: %s\n' "$(wc -l < "${IP_BLACKLIST}")"
fi
UPDATE_EOF
}

install_systemd_units() {
  write_managed_file "${FIREWALL_SERVICE}" 0644 <<'FIREWALL_SERVICE_EOF'
[Unit]
Description=Prepare persistent ipset blacklist firewall rules
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service
Before=network-pre.target
Wants=network-pre.target
ConditionPathExists=/etc/ipset-blacklist/ipset-blacklist.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ipset-blacklist-firewall.sh /etc/ipset-blacklist/ipset-blacklist.conf

[Install]
WantedBy=multi-user.target
FIREWALL_SERVICE_EOF

  write_managed_file "${UPDATE_SERVICE}" 0644 <<'UPDATE_SERVICE_EOF'
[Unit]
Description=Update ipset blacklist
Wants=network-online.target ipset-blacklist-firewall.service
After=network-online.target ipset-blacklist-firewall.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-blacklist.sh /etc/ipset-blacklist/ipset-blacklist.conf
UPDATE_SERVICE_EOF

  write_managed_file "${UPDATE_TIMER}" 0644 <<'UPDATE_TIMER_EOF'
[Unit]
Description=Run ipset blacklist update daily

[Timer]
OnCalendar=*-*-* 23:33:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UPDATE_TIMER_EOF
}

run_test() {
  local description=$1
  shift

  printf '%s[TEST]%s %s ... ' "${MAGENTA}" "${RESET}" "${description}"
  if "$@" >/tmp/ipset-blacklist-install-test.log 2>&1; then
    printf '%sPASS%s\n' "${GREEN}" "${RESET}"
  else
    printf '%sFAIL%s\n' "${RED}" "${RESET}"
    sed 's/^/  /' /tmp/ipset-blacklist-install-test.log >&2
    exit 1
  fi
}

load_config_for_tests() {
  set +u
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set -u
  IPSET_BLACKLIST_NAME=${IPSET_BLACKLIST_NAME:-blacklist}
  IPTABLES_MANAGED_CHAIN=${IPTABLES_MANAGED_CHAIN:-IPSET-BLACKLIST}
  if ! declare -p PRIVATE_NETWORK_EXCEPTIONS >/dev/null 2>&1; then
    PRIVATE_NETWORK_EXCEPTIONS=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
  fi
}

test_private_exceptions() {
  for private_network in "${PRIVATE_NETWORK_EXCEPTIONS[@]}"; do
    iptables -C "${IPTABLES_MANAGED_CHAIN}" -s "${private_network}" -j RETURN
  done
}

run_install_tests() {
  title "Verification"
  load_config_for_tests

  run_test "update script syntax" bash -n "${UPDATE_SCRIPT}"
  run_test "firewall script syntax" bash -n "${FIREWALL_SCRIPT}"

  if command -v systemd-analyze >/dev/null 2>&1; then
    run_test "systemd unit syntax" systemd-analyze verify "${FIREWALL_SERVICE}" "${UPDATE_SERVICE}" "${UPDATE_TIMER}"
  fi

  systemctl daemon-reload
  run_test "enable firewall persistence service" systemctl enable "$(basename "${FIREWALL_SERVICE}")"
  run_test "start firewall persistence service" systemctl restart "$(basename "${FIREWALL_SERVICE}")"
  run_test "enable daily update timer" systemctl enable --now "$(basename "${UPDATE_TIMER}")"
  run_test "run blacklist update now" systemctl start "$(basename "${UPDATE_SERVICE}")"
  run_test "ipset exists" ipset list "${IPSET_BLACKLIST_NAME}"
  run_test "INPUT jumps to managed chain" iptables -C INPUT -j "${IPTABLES_MANAGED_CHAIN}"
  run_test "private networks return before blacklist drop" test_private_exceptions
  run_test "blacklist drop rule exists" iptables -C "${IPTABLES_MANAGED_CHAIN}" -m set --match-set "${IPSET_BLACKLIST_NAME}" src -j DROP
  run_test "timer is enabled" systemctl is-enabled "$(basename "${UPDATE_TIMER}")"
}

main() {
  title "ipset blacklist installer for Debian 13"
  require_root
  check_debian_13

  title "Packages"
  install_packages

  title "Files"
  install_config
  install_firewall_script
  install_update_script
  install_systemd_units

  run_install_tests

  title "Done"
  ok "Daily blacklist updates are installed and enabled."
  info "Logs: journalctl -u ipset-blacklist-update.service -n 100 --no-pager"
  info "Timer: systemctl list-timers ipset-blacklist-update.timer"
}

main "$@"