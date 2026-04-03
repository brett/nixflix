#!/usr/bin/env bash
# deploy/tests/integration-microvm.sh
#
# Post-deploy integration test for a nixflix Hetzner server with microVM services.
# Can run remotely (SSHing into the server) or locally on the server itself.
#
# USAGE
#   integration-microvm.sh [<server-ip>] [OPTIONS]
#
# OPTIONS
#   -u, --user <user>     SSH user (default: nixflix; falls back to root)
#   -i, --identity <key>  SSH identity file
#   -p, --port <port>     SSH port (default: 22)
#   -t, --timeout <sec>   Per-check timeout in seconds (default: 10)
#   --no-color            Disable colour output
#   -h, --help            Show this help text
#
# EXIT CODES
#   0  All checks passed
#   1  One or more checks failed
#
# EXAMPLE
#   ./deploy/tests/integration-microvm.sh 65.21.100.42
#   ./deploy/tests/integration-microvm.sh 65.21.100.42 --user root -i ~/.ssh/id_ed25519
#   nixflix-check                          # run locally on the server itself

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

SERVER_IP=""
SSH_USER="nixflix"
SSH_IDENTITY=""
SSH_PORT=22
TIMEOUT=10
USE_COLOR=true

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
  sed -n '/^# USAGE/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "$USE_COLOR" == true ]] && [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}✓${RESET} $*"; (( PASS++ )) || true; }
fail() { echo -e "  ${RED}✗${RESET} $*"; (( FAIL++ )) || true; }
info() { echo -e "${BOLD}${YELLOW}▶ $*${RESET}"; }

# ── Argument parsing ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)      SSH_USER="$2";     shift 2 ;;
    -i|--identity)  SSH_IDENTITY="$2"; shift 2 ;;
    -p|--port)      SSH_PORT="$2";     shift 2 ;;
    -t|--timeout)   TIMEOUT="$2";      shift 2 ;;
    --no-color)     USE_COLOR=false;   shift ;;
    -h|--help)      usage 0 ;;
    -*)             die "Unknown option: $1" ;;
    *)
      [[ -z "$SERVER_IP" ]] || die "Unexpected argument: $1"
      SERVER_IP="$1"
      shift
      ;;
  esac
done

# ── SSH helper ────────────────────────────────────────────────────────────────

if [[ -z "$SERVER_IP" ]]; then
  # Local mode: run commands directly (script is executing on the server)
  LOCAL_MODE=true
  ssh_run()   { "$@" 2>/dev/null; }
  ssh_run_sudo() { "$@" 2>/dev/null; }
  # ssh_shell: run a pre-formed shell command string locally via bash -c
  ssh_shell() { bash -c "$1" 2>/dev/null; }
else
  LOCAL_MODE=false
  SSH_OPTS=(
    -o ConnectTimeout="${TIMEOUT}"
    -o StrictHostKeyChecking=no
    -o BatchMode=yes
    -p "${SSH_PORT}"
  )
  [[ -n "$SSH_IDENTITY" ]] && SSH_OPTS+=( -i "$SSH_IDENTITY" )
  ssh_run()   { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "$@" 2>/dev/null; }
  ssh_run_sudo() { ssh_run sudo -- "$@" 2>/dev/null; }
  # ssh_shell: pass a pre-formed shell command string to SSH as a single arg
  ssh_shell() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "$1" 2>/dev/null; }
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}nixflix microVM Integration Tests${RESET}"
if [[ "$LOCAL_MODE" == true ]]; then
  echo -e "  Mode:    local (running on server)"
else
  echo -e "  Server:  ${SERVER_IP}:${SSH_PORT}"
  echo -e "  User:    ${SSH_USER}"
fi
echo ""

if [[ "$LOCAL_MODE" != true ]]; then
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" true 2>/dev/null; then
    if [[ "$SSH_USER" != "root" ]] && \
       ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" true 2>/dev/null; then
      echo -e "${YELLOW}  Note: '${SSH_USER}' not available, falling back to root${RESET}"
      SSH_USER="root"
    else
      die "Cannot SSH to ${SERVER_IP} as '${SSH_USER}' (or root). Check connectivity."
    fi
  fi
fi

# Detect whether postgres microVM is part of this deployment.
# Used to tailor qualityprofile check messaging (postgres vs SQLite mode).
POSTGRES_ACTIVE=$(ssh_run systemctl is-active "microvm@postgres.service" 2>/dev/null || true)

# ── 1. Host systemd services ──────────────────────────────────────────────────

info "1. Host systemd services"

HOST_SERVICES=(
  mullvad-daemon
  mullvad-config
  nginx
)

for svc in "${HOST_SERVICES[@]}"; do
  state=$(ssh_run systemctl is-active "${svc}.service" 2>/dev/null || true)
  if [[ "$state" == "active" ]]; then
    pass "${svc}: active"
  elif [[ "$state" == "activating" ]]; then
    echo -e "  ${YELLOW}⚠${RESET}  ${svc}: activating"
  else
    fail "${svc}: ${state:-unknown} (expected active)"
  fi
done

# ── 2. microVM systemd services ───────────────────────────────────────────────

info "2. microVM services"

MICROVM_SERVICES=(
  sonarr
  sonarr-anime
  radarr
  lidarr
  prowlarr
  qbittorrent
  jellyfin
  seerr
)

for svc in "${MICROVM_SERVICES[@]}"; do
  state=$(ssh_run systemctl is-active "microvm@${svc}.service" 2>/dev/null || true)
  if [[ "$state" == "active" ]]; then
    pass "microvm@${svc}: active"
  elif [[ "$state" == "activating" ]]; then
    echo -e "  ${YELLOW}⚠${RESET}  microvm@${svc}: activating"
  else
    fail "microvm@${svc}: ${state:-unknown} (expected active)"
  fi
done

for svc in "${MICROVM_SERVICES[@]}"; do
  state=$(ssh_run systemctl is-active "microvm@${svc}.service" 2>/dev/null || true)
  if [[ "$state" != "active" ]] && \
     ssh_run systemctl show -p NRestarts --value "microvm@${svc}.service" 2>/dev/null \
       | grep -qxE '[1-9][0-9]*'; then
    fail "microvm@${svc}: has restarts and is not active (possible crash loop)"
  fi
done

# ── 3. Bridge network ─────────────────────────────────────────────────────────

info "3. microVM bridge network"

if ssh_run ip link show nixflix-br0 >/dev/null 2>&1; then
  pass "nixflix-br0: present"
else
  fail "nixflix-br0: bridge interface not found"
fi

# IP forwarding must be enabled for VM egress
if [[ "$(ssh_run cat /proc/sys/net/ipv4/ip_forward)" == "1" ]]; then
  pass "IP forwarding: enabled"
else
  fail "IP forwarding: disabled (VMs cannot reach internet)"
fi

# NAT table must exist with masquerade and forward rules for the bridge subnet
nat_table=$(ssh_run nft list table ip nixflix-microvm-nat 2>/dev/null || true)
if [[ -n "$nat_table" ]]; then
  if echo "$nat_table" | grep -q "masquerade"; then
    pass "NAT masquerade: rule present"
  else
    fail "NAT masquerade: rule missing in nixflix-microvm-nat"
  fi
  if echo "$nat_table" | grep -q "nixflix-br0" && echo "$nat_table" | grep -q "10.100.0.0/24"; then
    pass "NAT forwarding: bridge and subnet rules present"
  else
    fail "NAT forwarding: bridge/subnet rules missing in nixflix-microvm-nat"
  fi
else
  fail "nixflix-microvm-nat: nftables table missing"
fi

# Verify each microVM has an IP on the bridge subnet
declare -A VM_IPS=(
  ["sonarr"]="10.100.0.10"
  ["sonarr-anime"]="10.100.0.11"
  ["radarr"]="10.100.0.12"
  ["lidarr"]="10.100.0.13"
  ["prowlarr"]="10.100.0.14"
  ["qbittorrent"]="10.100.0.21"
  ["jellyfin"]="10.100.0.30"
  ["seerr"]="10.100.0.31"
)

for svc in "${!VM_IPS[@]}"; do
  ip="${VM_IPS[$svc]}"
  if ssh_run ping -c1 -W2 "${ip}" >/dev/null 2>&1; then
    pass "${svc} (${ip}): reachable"
  else
    fail "${svc} (${ip}): unreachable from host"
  fi
done

# Tap interfaces must be attached to the bridge (networkd auto-attaches vm-* interfaces)
for svc in "${!VM_IPS[@]}"; do
  if ssh_run bridge link show 2>/dev/null | grep -q "vm-${svc}"; then
    pass "tap vm-${svc}: attached to bridge"
  else
    fail "tap vm-${svc}: not attached to bridge"
  fi
done

# ── 4. Port connectivity ──────────────────────────────────────────────────────

info "4. Port connectivity (microVM IPs)"

declare -A PORTS=(
  ["Sonarr"]=8989
  ["Sonarr-Anime"]=8990
  ["Radarr"]=7878
  ["Lidarr"]=8686
  ["Prowlarr"]=9696
  ["qBittorrent"]=8282
  ["Jellyfin"]=8096
  ["Jellyseerr"]=5055
  ["nginx HTTP"]=80
  ["nginx HTTPS"]=443
)

declare -A PORT_IPS=(
  ["Sonarr"]="10.100.0.10"
  ["Sonarr-Anime"]="10.100.0.11"
  ["Radarr"]="10.100.0.12"
  ["Lidarr"]="10.100.0.13"
  ["Prowlarr"]="10.100.0.14"
  ["qBittorrent"]="10.100.0.21"
  ["Jellyfin"]="10.100.0.30"
  ["Jellyseerr"]="10.100.0.31"
  ["nginx HTTP"]="127.0.0.1"
  ["nginx HTTPS"]="127.0.0.1"
)

for svc in "${!PORTS[@]}"; do
  port="${PORTS[$svc]}"
  ip="${PORT_IPS[$svc]}"
  if ssh_shell "timeout ${TIMEOUT} bash -c '</dev/tcp/${ip}/${port}' 2>/dev/null"; then
    pass "${svc} (${ip}:${port}): open"
  elif [[ "$svc" == "nginx HTTPS" ]]; then
    echo -e "  ${YELLOW}⚠${RESET}  ${svc} (${ip}:${port}): not listening (ACME cert may not be issued yet)"
  else
    fail "${svc} (${ip}:${port}): not responding"
  fi
done

# ── 5. Arr API health endpoints ───────────────────────────────────────────────

info "5. Arr API /ping endpoints"

declare -A ARR_PINGS=(
  ["Sonarr"]="http://10.100.0.10:8989/ping"
  ["Sonarr-Anime"]="http://10.100.0.11:8990/ping"
  ["Radarr"]="http://10.100.0.12:7878/ping"
  ["Lidarr"]="http://10.100.0.13:8686/ping"
  ["Prowlarr"]="http://10.100.0.14:9696/ping"
)

for svc in "${!ARR_PINGS[@]}"; do
  url="${ARR_PINGS[$svc]}"
  http_code=$(ssh_run curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" "${url}" 2>/dev/null || true)
  if [[ "$http_code" == "200" ]]; then
    pass "${svc} /ping: HTTP 200"
  else
    fail "${svc} /ping: HTTP ${http_code:-no response} (expected 200)"
  fi
done

# ── 6. VPN routing ────────────────────────────────────────────────────────────

info "6. VPN routing"

# nixflix-microvm-vpn-bypass nftables table should exist when microvms + mullvad are active
bypass_table=$(ssh_run nft list table ip nixflix-microvm-vpn-bypass 2>/dev/null || true)
if [[ -n "$bypass_table" ]]; then
  pass "nixflix-microvm-vpn-bypass: nftables table present"
else
  fail "nixflix-microvm-vpn-bypass: nftables table missing"
  bypass_table=""
fi

# Mullvad-specific bypass marks must be present in the prerouting chain
if echo "$bypass_table" | grep -q "0x00000f41"; then
  pass "VPN bypass ct mark (0x00000f41): present"
else
  fail "VPN bypass ct mark (0x00000f41): missing (Mullvad bypass not wired)"
fi
if echo "$bypass_table" | grep -q "0x6d6f6c65"; then
  pass "VPN bypass meta mark (0x6d6f6c65): present"
else
  fail "VPN bypass meta mark (0x6d6f6c65): missing (Mullvad bypass not wired)"
fi
if echo "$bypass_table" | grep -q "prerouting"; then
  pass "VPN bypass prerouting chain: present"
else
  fail "VPN bypass prerouting chain: missing"
fi

# Prerouting chain (VM-originated traffic) must use per-VM IPs, not a blanket subnet.
# The output chain legitimately uses the subnet to mark host-originated traffic to the
# bridge (so nginx can reach VMs), but prerouting must be per-VM to honour vpnBypass = false.
prerouting=$(ssh_run nft list chain ip nixflix-microvm-vpn-bypass prerouting 2>/dev/null || true)
if echo "$prerouting" | grep -q "10.100.0.0/24"; then
  fail "VPN bypass prerouting: subnet-wide rule found — must be per-VM IP"
else
  pass "VPN bypass prerouting: per-VM rules (no subnet-wide bypass)"
fi

# Arr + media service IPs should be in the bypass table (direct internet, not through VPN)
for svc in sonarr sonarr-anime radarr lidarr prowlarr jellyfin seerr; do
  ip="${VM_IPS[$svc]}"
  if echo "$bypass_table" | grep -q "${ip}"; then
    pass "${svc} (${ip}): in VPN bypass table (direct internet)"
  else
    fail "${svc} (${ip}): not in VPN bypass table"
  fi
done

# qbittorrent should NOT be in the bypass table (routes through Mullvad)
qbt_ip="${VM_IPS[qbittorrent]}"
if echo "$bypass_table" | grep -q "${qbt_ip}"; then
  fail "qbittorrent (${qbt_ip}): found in VPN bypass table (should route through Mullvad)"
else
  pass "qbittorrent (${qbt_ip}): not in bypass table (routes through Mullvad)"
fi

# ── 7. Mullvad VPN ────────────────────────────────────────────────────────────

info "7. Mullvad VPN"

mullvad_status=$(ssh_run mullvad status 2>/dev/null || true)

if echo "$mullvad_status" | grep -qi "connected"; then
  pass "Mullvad: connected"
else
  # Check if login failed due to too many devices — common after a fresh deploy
  # where a prior install left an orphaned device on the account.
  if ssh_run journalctl -u mullvad-config.service -b --no-pager -q 2>/dev/null \
       | grep -q "too many devices"; then
    fail "Mullvad: not connected — too many devices on account (revoke one at mullvad.net/account/devices, then: systemctl restart mullvad-config.service)"
  else
    fail "Mullvad: not connected (status: ${mullvad_status:-unavailable})"
  fi
fi

lockdown=$(ssh_run mullvad lockdown-mode get 2>/dev/null || true)
if echo "$lockdown" | grep -qi "on\|enabled"; then
  pass "Mullvad kill switch: enabled"
else
  echo -e "  ${YELLOW}⚠${RESET}  Mullvad kill switch: not enabled (lockdown: ${lockdown:-unavailable})"
fi

if ssh_run ip link show wg0-mullvad >/dev/null 2>&1 || \
   ssh_run ip link show tun0 >/dev/null 2>&1; then
  pass "Mullvad tunnel interface: present"
else
  fail "Mullvad tunnel interface: not found (wg0-mullvad / tun0 missing)"
fi

# Verify traffic actually flows through the tunnel — "Connected" can be stale
# (we hit this in the past: relay showed Connected but couldn't pass traffic).
wg_iface=$(ssh_run ip link show type wireguard 2>/dev/null \
  | awk -F': ' '/^[0-9]/{print $2}' | head -1 || true)
if [[ -n "$wg_iface" ]]; then
  vpn_check=$(ssh_shell \
    "curl -sf --max-time 10 --interface ${wg_iface} https://am.i.mullvad.net/json" || true)
  if echo "$vpn_check" | grep -q '"mullvad_exit_ip":true'; then
    pass "Mullvad tunnel: traffic forwarding confirmed (am.i.mullvad.net)"
  elif [[ -n "$vpn_check" ]]; then
    fail "Mullvad tunnel: response received but not a Mullvad exit IP (routing wrong)"
  else
    fail "Mullvad tunnel: no response — interface present but traffic not flowing"
  fi
else
  echo -e "  ${YELLOW}⚠${RESET}  Mullvad tunnel: no WireGuard interface found for traffic test"
fi

# ── 8. nginx proxying ─────────────────────────────────────────────────────────

info "8. nginx proxying"

http_code=$(ssh_run curl -s -o /dev/null -w "%{http_code}" \
  --max-time "${TIMEOUT}" "http://127.0.0.1/" 2>/dev/null || true)
if [[ "$http_code" =~ ^(200|301|302|303|307|308|404)$ ]]; then
  pass "nginx HTTP: responded with HTTP ${http_code}"
elif [[ "$http_code" == "000" ]]; then
  pass "nginx HTTP: up (default vhost return 444 — connection closed as expected)"
else
  fail "nginx HTTP: unexpected response HTTP ${http_code:-none}"
fi

https_code=$(ssh_run curl -sk -o /dev/null -w "%{http_code}" \
  --max-time "${TIMEOUT}" "https://127.0.0.1/" 2>/dev/null || true)
if [[ -n "$https_code" ]] && [[ "$https_code" != "000" ]]; then
  pass "nginx HTTPS: up (HTTP ${https_code})"
else
  echo -e "  ${YELLOW}⚠${RESET}  nginx HTTPS: port 443 not listening (ACME cert may not be issued yet)"
fi

# ── 9. ZFS pool health ────────────────────────────────────────────────────────

info "9. ZFS pool health"

zpool_output=$(ssh_run_sudo zpool status -x 2>/dev/null || \
               ssh_run zpool status -x 2>/dev/null || true)

if echo "$zpool_output" | grep -qi "all pools are healthy"; then
  pass "ZFS: all pools healthy"
else
  zpool_full=$(ssh_run_sudo zpool status 2>/dev/null || \
               ssh_run zpool status 2>/dev/null || true)
  fail "ZFS: pool not fully healthy"
  echo ""
  echo "${zpool_full}" | sed 's/^/    /'
  echo ""
fi

for state in DEGRADED FAULTED UNAVAIL; do
  if echo "$zpool_output" | grep -qi "$state"; then
    fail "ZFS: pool in $state state"
  fi
done

# ── 10. Arr API deep verification ─────────────────────────────────────────────

info "10. Arr API deep verification"

# Run a curl command on the remote server using a sops secret as the API key.
# Reads the key with a first SSH call, then builds a single-string command for
# the second so SSH doesn't split the "X-Api-Key: <value>" header on the space.
# Usage: arr_api <secret_name> <url>
arr_api() {
  local secret="$1" url="$2" key
  key=$(ssh_run cat "/run/secrets/${secret}") || true
  [[ -z "$key" ]] && { echo ""; return 1; }
  ssh_shell "curl -sf -H 'X-Api-Key: ${key}' '${url}'" || true
}

# service name → "secret|ip:port|api_version|expected_appName|media_dir"
# media_dir is empty for prowlarr (SQLite, no root folder).
declare -A ARR_SERVICES=(
  ["Sonarr"]="sonarr_api_key|10.100.0.10:8989|v3|Sonarr|/data/media/tv"
  ["Sonarr-Anime"]="sonarr_anime_api_key|10.100.0.11:8990|v3|Sonarr|/data/media/tv-anime"
  ["Radarr"]="radarr_api_key|10.100.0.12:7878|v3|Radarr|/data/media/movies"
  ["Lidarr"]="lidarr_api_key|10.100.0.13:8686|v1|Lidarr|/data/media/music"
  ["Prowlarr"]="prowlarr_api_key|10.100.0.14:9696|v1|Prowlarr|"
)

for svc in Sonarr Sonarr-Anime Radarr Lidarr Prowlarr; do
  IFS='|' read -r secret addr api_ver app_name media_dir <<< "${ARR_SERVICES[$svc]}"

  # system/status — verifies API identity and database backend.
  status=$(arr_api "$secret" "http://${addr}/api/${api_ver}/system/status")
  if echo "$status" | grep -q "\"appName\": \"${app_name}\""; then
    pass "${svc} /system/status: appName=${app_name}"
  else
    fail "${svc} /system/status: unexpected response (expected appName=${app_name})"
  fi

  # databaseType — verifies the service is actually using the expected DB backend.
  # Prowlarr uses SQLite regardless of postgres microVM.
  if [[ "$svc" != "Prowlarr" ]]; then
    db_type=$(echo "$status" | grep -o '"databaseType": "[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
    if [[ "$POSTGRES_ACTIVE" == "active" ]]; then
      if [[ "$db_type" == "postgreSQL" ]]; then
        pass "${svc} databaseType: postgreSQL (correct)"
      else
        fail "${svc} databaseType: ${db_type:-unknown} (expected postgreSQL — service may be using SQLite fallback)"
      fi
    else
      pass "${svc} databaseType: ${db_type:-unknown} (SQLite mode)"
    fi
  fi

  # rootfolder — verifies the media directory is registered (skipped for Prowlarr).
  if [[ -n "$media_dir" ]]; then
    folders=$(arr_api "$secret" "http://${addr}/api/${api_ver}/rootfolder")
    if echo "$folders" | grep -q "$media_dir"; then
      pass "${svc} rootfolder: ${media_dir} present"
    else
      fail "${svc} rootfolder: ${media_dir} not found (got: ${folders:0:120})"
    fi
  fi

  # qualityprofile — verifies DB has been seeded (profiles exist in both postgres and SQLite).
  # Prowlarr has no qualityprofile endpoint.
  if [[ "$svc" != "Prowlarr" ]]; then
    profiles=$(arr_api "$secret" "http://${addr}/api/${api_ver}/qualityprofile")
    profile_count=$(echo "$profiles" | grep -o '"id"' | wc -l || true)
    if [[ "${profile_count:-0}" -gt 0 ]]; then
      pass "${svc} qualityprofile: ${profile_count} profile(s)"
    else
      fail "${svc} qualityprofile: no profiles returned (DB may not be seeded)"
    fi
  fi

  # delayprofile — verifies delay profile configuration (torrent protocol configured).
  # Prowlarr does not use delay profiles.
  if [[ "$svc" != "Prowlarr" ]]; then
    delay=$(arr_api "$secret" "http://${addr}/api/${api_ver}/delayprofile")
    delay_count=$(echo "$delay" | grep -o '"id"' | wc -l || true)
    if [[ "${delay_count:-0}" -gt 0 ]]; then
      if echo "$delay" | grep -q '"preferredProtocol"'; then
        pass "${svc} delayprofile: ${delay_count} profile(s) configured"
      else
        fail "${svc} delayprofile: profiles present but preferredProtocol field missing"
      fi
    else
      fail "${svc} delayprofile: no delay profiles returned"
    fi
  fi

  # downloadclient — verifies qBittorrent is registered and enabled.
  # Prowlarr does not use download clients.
  if [[ "$svc" != "Prowlarr" ]]; then
    clients=$(arr_api "$secret" "http://${addr}/api/${api_ver}/downloadclient")
    client_count=$(echo "$clients" | grep -o '"id"' | wc -l || true)
    if [[ "${client_count:-0}" -gt 0 ]]; then
      if echo "$clients" | grep -q '"enable": *true'; then
        pass "${svc} download client: ${client_count} configured (at least one enabled)"
      else
        fail "${svc} download client: ${client_count} configured but none enabled"
      fi
    else
      fail "${svc} download client: none configured (qBittorrent not registered)"
    fi
  fi
done

# Prowlarr application sync — verify arr services are registered as sync targets.
# Both Sonarr and Sonarr-Anime use implementationName "Sonarr"; expect ≥2 instances.
IFS='|' read -r prow_secret prow_addr prow_api_ver _ _ <<< "${ARR_SERVICES[Prowlarr]}"
prowlarr_apps=$(arr_api "$prow_secret" "http://${prow_addr}/api/${prow_api_ver}/applications")
sonarr_app_count=$(echo "$prowlarr_apps" | grep -cF '"implementationName": "Sonarr"' || true)
if [[ "${sonarr_app_count:-0}" -ge 2 ]]; then
  pass "Prowlarr applications: Sonarr + Sonarr-Anime registered (${sonarr_app_count} instances)"
elif [[ "${sonarr_app_count:-0}" -eq 1 ]]; then
  pass "Prowlarr applications: Sonarr registered (1 instance)"
else
  fail "Prowlarr applications: no Sonarr instances registered"
fi
for impl in "Radarr" "Lidarr"; do
  if grep -qF "\"implementationName\": \"${impl}\"" <<< "$prowlarr_apps"; then
    pass "Prowlarr applications: ${impl} registered"
  else
    fail "Prowlarr applications: ${impl} not registered"
  fi
done

# Prowlarr indexers — at least one indexer must be configured for search to work.
prowlarr_indexers=$(arr_api "$prow_secret" "http://${prow_addr}/api/${prow_api_ver}/indexer")
indexer_count=$(echo "$prowlarr_indexers" | grep -o '"id"' | wc -l || true)
if [[ "${indexer_count:-0}" -gt 0 ]]; then
  pass "Prowlarr: ${indexer_count} indexer(s) configured"
else
  fail "Prowlarr: no indexers configured (add indexers in the Prowlarr UI)"
fi

# ── 11. qBittorrent WebUI and categories ──────────────────────────────────────

info "11. qBittorrent WebUI"

qbt_ip="${VM_IPS[qbittorrent]}"
http_code=$(ssh_run curl -s -o /dev/null -w '%{http_code}' \
  "http://${qbt_ip}:8282/" 2>/dev/null || true)
if [[ "${http_code:-000}" == "200" ]]; then
  pass "qBittorrent WebUI (${qbt_ip}:8282): HTTP 200"
else
  fail "qBittorrent WebUI (${qbt_ip}:8282): HTTP ${http_code:-no response} (expected 200)"
fi

# categories.json is written inside the guest VM (virtiofs-mounted state dir).
# Each arr service should have a category with a matching download path.
cats_file="/var/lib/nixflix/qbittorrent/qBittorrent/config/categories.json"
cats_json=$(ssh_run cat "$cats_file" 2>/dev/null || true)
if [[ -n "$cats_json" ]]; then
  pass "qBittorrent categories.json: present"
  for cat in sonarr sonarr-anime radarr lidarr; do
    if echo "$cats_json" | grep -q "\"${cat}\""; then
      pass "qBittorrent category '${cat}': configured"
    else
      fail "qBittorrent category '${cat}': missing from categories.json"
    fi
  done
  # Verify save paths point into the downloads directory (not 127.0.0.1 or empty)
  if echo "$cats_json" | grep -q '"save_path":"/data/downloads'; then
    pass "qBittorrent category save_paths: point to /data/downloads"
  else
    fail "qBittorrent category save_paths: unexpected values (expected /data/downloads/...)"
  fi
else
  fail "qBittorrent categories.json: not found at ${cats_file}"
fi

# ── 12. Bridge DNS resolver ────────────────────────────────────────────────────

info "12. Bridge DNS resolver"

if ssh_run bash -c \
     "ss -lnuH 'src 10.100.0.1:53' 2>/dev/null | grep -q ." 2>/dev/null; then
  pass "DNS resolver: listening on bridge IP 10.100.0.1:53"
else
  fail "DNS resolver: not listening on 10.100.0.1:53 (microVM DNS will be broken)"
fi

# ── 13. Postgres firewall ─────────────────────────────────────────────────────

info "13. Postgres firewall"

# The postgres VM firewall should only allow service VM IPs, not the host bridge
# IP (10.100.0.1). Verify the host cannot connect to postgres port 5432.
# Skip if the postgres microVM is not part of this deployment.
postgres_ip="10.100.0.2"
if [[ "$POSTGRES_ACTIVE" == "active" ]]; then
  pass "postgres VM: running"
  if ssh_run ping -c1 -W2 "${postgres_ip}" >/dev/null 2>&1; then
    pass "postgres (${postgres_ip}): reachable from host bridge"
  else
    fail "postgres (${postgres_ip}): unreachable from host bridge"
  fi
  if ssh_shell "timeout 3 bash -c '</dev/tcp/${postgres_ip}/5432>' 2>/dev/null"; then
    fail "postgres (${postgres_ip}:5432): port OPEN from host bridge — firewall not blocking"
  else
    pass "postgres (${postgres_ip}:5432): blocked from host bridge (firewall correct)"
  fi
else
  echo -e "  ${YELLOW}⚠${RESET}  postgres VM: not deployed in this configuration (skipping firewall check)"
fi

# ── 14. Jellyfin API health ───────────────────────────────────────────────────

info "14. Jellyfin API health"

jellyfin_ip="${VM_IPS[jellyfin]}"
jellyfin_active=$(ssh_run systemctl is-active "microvm@jellyfin.service" 2>/dev/null || true)
if [[ "$jellyfin_active" == "active" ]]; then
  pass "jellyfin VM: running"

  # /System/Info/Public is unauthenticated — verifies Jellyfin is up and responding
  jf_code=$(ssh_run curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "http://${jellyfin_ip}:8096/System/Info/Public" 2>/dev/null || true)
  if [[ "$jf_code" == "200" ]]; then
    pass "Jellyfin /System/Info/Public: HTTP 200"
  else
    fail "Jellyfin /System/Info/Public: HTTP ${jf_code:-no response} (expected 200)"
  fi

  # Verify setup wizard has been completed (StartupWizardCompleted = true)
  jf_info=$(ssh_run curl -s \
    --max-time "${TIMEOUT}" \
    "http://${jellyfin_ip}:8096/System/Info/Public" 2>/dev/null || true)
  if echo "$jf_info" | grep -q '"StartupWizardCompleted":true'; then
    pass "Jellyfin setup wizard: completed"
  else
    echo -e "  ${YELLOW}⚠${RESET}  Jellyfin setup wizard: not yet completed (may still be initialising)"
  fi
else
  echo -e "  ${YELLOW}⚠${RESET}  jellyfin VM: not running (skipping API checks)"
fi

# ── 15. Jellyseerr API health ─────────────────────────────────────────────────

info "15. Jellyseerr API health"

seerr_ip="${VM_IPS[seerr]}"
seerr_active=$(ssh_run systemctl is-active "microvm@seerr.service" 2>/dev/null || true)
if [[ "$seerr_active" == "active" ]]; then
  pass "seerr VM: running"

  # /api/v1/status is unauthenticated — verifies Jellyseerr is up
  js_code=$(ssh_run curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "http://${seerr_ip}:5055/api/v1/status" 2>/dev/null || true)
  if [[ "$js_code" == "200" ]]; then
    pass "Jellyseerr /api/v1/status: HTTP 200"
  else
    fail "Jellyseerr /api/v1/status: HTTP ${js_code:-no response} (expected 200)"
  fi

  # Verify Jellyseerr is initialised (not in setup mode)
  # /api/v1/settings/public returns {"initialized":true} once setup is complete
  js_public=$(ssh_run curl -s \
    --max-time "${TIMEOUT}" \
    "http://${seerr_ip}:5055/api/v1/settings/public" 2>/dev/null || true)
  if echo "$js_public" | grep -q '"initialized":true'; then
    pass "Jellyseerr: initialised"
  else
    echo -e "  ${YELLOW}⚠${RESET}  Jellyseerr: not yet initialised (may still be running setup)"
  fi

  # Verify Jellyfin is configured at the correct microVM IP.
  # settings.json is virtiofs-mounted and readable from the host.
  js_settings=$(ssh_run cat "/var/lib/nixflix/seerr/settings.json" 2>/dev/null || true)
  if [[ -n "$js_settings" ]]; then
    jellyfin_vm_ip="${VM_IPS[jellyfin]}"
    # plex.ip is always empty (""); Jellyfin's ip is the only non-empty one
    jf_ip=$(echo "$js_settings" | grep -o '"ip": *"[^"]*"' | grep -v '""' | head -1 \
      | grep -o '"[^"]*"$' | tr -d '"' || true)
    if [[ "$jf_ip" == "$jellyfin_vm_ip" ]]; then
      pass "Jellyseerr: Jellyfin configured at correct VM IP (${jf_ip})"
    elif [[ -n "$jf_ip" ]]; then
      fail "Jellyseerr: Jellyfin IP is ${jf_ip} (expected VM IP ${jellyfin_vm_ip})"
    else
      fail "Jellyseerr: Jellyfin IP not set in settings.json (Jellyfin not connected)"
    fi
    # Verify library sync has run — libraries entries have enabled:true after setup
    lib_count=$(echo "$js_settings" | grep -o '"enabled": *true' | wc -l || true)
    if [[ "${lib_count:-0}" -gt 0 ]]; then
      pass "Jellyseerr: ${lib_count} Jellyfin library/libraries enabled"
    else
      echo -e "  ${YELLOW}⚠${RESET}  Jellyseerr: no enabled Jellyfin libraries (library sync may not have run)"
    fi
  else
    fail "Jellyseerr: settings.json not readable"
  fi
else
  echo -e "  ${YELLOW}⚠${RESET}  seerr VM: not running (skipping API checks)"
fi

# ── 16. ACME certificate coverage ─────────────────────────────────────────────

info "16. ACME certificate coverage"

# All nginx vhosts with forceSSL should have a cert in /var/lib/acme/.
# qbittorrent/jellyfin/seerr certs were added alongside the initial arr certs.
for svc in sonarr sonarr-anime radarr lidarr prowlarr qbittorrent jellyfin seerr; do
  cert_dir=$(ssh_shell \
    "ls -d /var/lib/acme/${svc}.* 2>/dev/null | head -1" 2>/dev/null || true)
  if [[ -n "$cert_dir" ]]; then
    if ssh_run test -f "${cert_dir}/fullchain.pem" 2>/dev/null; then
      pass "ACME cert: ${cert_dir}/fullchain.pem present"
    else
      fail "ACME cert: ${cert_dir} exists but fullchain.pem missing"
    fi
  else
    echo -e "  ${YELLOW}⚠${RESET}  ACME cert for ${svc}.*: not yet issued (DNS propagation or ACME challenge may be pending)"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
total=$(( PASS + FAIL ))
if [[ "$FAIL" -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All ${total} checks passed.${RESET}"
  echo "════════════════════════════════════════════════════════"
  echo ""
  exit 0
else
  echo -e "  ${RED}${BOLD}${FAIL} of ${total} checks FAILED.${RESET}"
  echo "════════════════════════════════════════════════════════"
  echo ""
  exit 1
fi
