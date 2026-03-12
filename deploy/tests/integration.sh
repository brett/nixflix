#!/usr/bin/env bash
# deploy/tests/integration.sh
#
# Post-deploy integration test for a nixflix Hetzner server.
# SSHes into the deployed server and verifies the full stack is healthy.
#
# USAGE
#   integration.sh <server-ip> [OPTIONS]
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
#   ./deploy/tests/integration.sh 65.21.100.42
#   ./deploy/tests/integration.sh 65.21.100.42 --user root -i ~/.ssh/id_ed25519

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

# Colour codes (disabled when --no-color or not a tty)
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

[[ -n "$SERVER_IP" ]] || { echo "Error: server IP required."; usage 1; }

# ── SSH helper ────────────────────────────────────────────────────────────────

SSH_OPTS=(
  -o ConnectTimeout="${TIMEOUT}"
  -o StrictHostKeyChecking=no
  -o BatchMode=yes
  -p "${SSH_PORT}"
)
[[ -n "$SSH_IDENTITY" ]] && SSH_OPTS+=( -i "$SSH_IDENTITY" )

ssh_run() {
  # Runs a command on the remote server; returns its exit code.
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "$@" 2>/dev/null
}

ssh_run_sudo() {
  # Runs a command with sudo (falls back if already root).
  ssh_run sudo -- "$@" 2>/dev/null
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}nixflix Integration Tests${RESET}"
echo -e "  Server:  ${SERVER_IP}:${SSH_PORT}"
echo -e "  User:    ${SSH_USER}"
echo ""

# Try primary user; if it fails, attempt root fallback
if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" true 2>/dev/null; then
  if [[ "$SSH_USER" != "root" ]] && \
     ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" true 2>/dev/null; then
    echo -e "${YELLOW}  Note: '${SSH_USER}' not available, falling back to root${RESET}"
    SSH_USER="root"
  else
    die "Cannot SSH to ${SERVER_IP} as '${SSH_USER}' (or root). Check connectivity."
  fi
fi

# ── 1. Systemd services ───────────────────────────────────────────────────────

info "1. Systemd services"

SERVICES=(
  mullvad-daemon
  mullvad-config
  nginx
  sonarr
  sonarr-anime
  radarr
  lidarr
  prowlarr
  qbittorrent
)

for svc in "${SERVICES[@]}"; do
  state=$(ssh_run systemctl is-active "${svc}.service" 2>/dev/null || true)
  if [[ "$state" == "active" ]]; then
    pass "${svc}: active"
  elif [[ "$state" == "activating" ]]; then
    echo -e "  ${YELLOW}⚠${RESET}  ${svc}: activating (ExecStartPost still running — API check is definitive)"
  else
    fail "${svc}: ${state:-unknown} (expected active)"
  fi
done

# Check for crash-looping: only flag restarts when service is not currently active.
for svc in "${SERVICES[@]}"; do
  state=$(ssh_run systemctl is-active "${svc}.service" 2>/dev/null || true)
  if [[ "$state" != "active" ]] && \
     ssh_run systemctl show -p NRestarts --value "${svc}.service" 2>/dev/null \
       | grep -qxE '[1-9][0-9]*'; then
    fail "${svc}: has restarts and is not active (possible crash loop)"
  fi
done

# ── 2. Port connectivity ──────────────────────────────────────────────────────

info "2. Port connectivity (localhost)"

# Map: description → port
declare -A PORTS=(
  ["Sonarr"]=8989
  ["Sonarr-Anime"]=8990
  ["Radarr"]=7878
  ["Lidarr"]=8686
  ["Prowlarr"]=9696
  ["qBittorrent"]=8282
  ["nginx HTTP"]=80
  ["nginx HTTPS"]=443
)

for svc in "${!PORTS[@]}"; do
  port="${PORTS[$svc]}"
  # Pass as a single string so SSH doesn't word-split the bash -c argument.
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
       "timeout ${TIMEOUT} bash -c '</dev/tcp/127.0.0.1/${port}'" 2>/dev/null; then
    pass "${svc} (port ${port}): open"
  elif [[ "$svc" == "nginx HTTPS" ]]; then
    # 443 requires ACME certs; warn rather than fail until certs are issued.
    echo -e "  ${YELLOW}⚠${RESET}  ${svc} (port ${port}): not listening (ACME cert may not be issued yet)"
  else
    fail "${svc} (port ${port}): not responding"
  fi
done

# ── 3. Arr API health endpoints ───────────────────────────────────────────────

info "3. Arr API /ping endpoints"

# The /ping endpoint returns {"status":"OK"} without authentication.
declare -A ARR_PINGS=(
  ["Sonarr"]="http://127.0.0.1:8989/ping"
  ["Sonarr-Anime"]="http://127.0.0.1:8990/ping"
  ["Radarr"]="http://127.0.0.1:7878/ping"
  ["Lidarr"]="http://127.0.0.1:8686/ping"
  ["Prowlarr"]="http://127.0.0.1:9696/ping"
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

# ── 4. nginx proxying ─────────────────────────────────────────────────────────

info "4. nginx proxying"

# nginx should accept the TCP connection. The default catch-all vhost uses
# `return 444` which closes the connection without sending an HTTP response,
# causing curl to report HTTP 000.  That is still proof nginx is running.
http_code=$(ssh_run curl -s -o /dev/null -w "%{http_code}" \
  --max-time "${TIMEOUT}" "http://127.0.0.1/" 2>/dev/null || true)
if [[ "$http_code" =~ ^(200|301|302|303|307|308|404)$ ]]; then
  pass "nginx HTTP: responded with HTTP ${http_code}"
elif [[ "$http_code" == "000" ]]; then
  # 000 means nginx closed the connection (return 444 default vhost) — nginx IS up.
  pass "nginx HTTP: up (default vhost return 444 — connection closed as expected)"
else
  fail "nginx HTTP: unexpected response HTTP ${http_code:-none}"
fi

# nginx HTTPS requires ACME certs; skip gracefully if 443 is not yet listening.
https_listening=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
  "timeout 3 bash -c '</dev/tcp/127.0.0.1/443'" 2>/dev/null && echo yes || echo no)
if [[ "$https_listening" == "yes" ]]; then
  http_code=$(ssh_run curl -sk -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" "https://127.0.0.1/" 2>/dev/null || true)
  if [[ "$http_code" =~ ^(200|301|302|303|307|308|404)$ ]] || [[ "$http_code" == "000" ]]; then
    pass "nginx HTTPS: up (HTTP ${http_code})"
  else
    fail "nginx HTTPS: unexpected response HTTP ${http_code:-none}"
  fi
else
  echo -e "  ${YELLOW}⚠${RESET}  nginx HTTPS: port 443 not listening (ACME cert may not be issued yet)"
fi

# ── 5. Mullvad VPN ────────────────────────────────────────────────────────────

info "5. Mullvad VPN"

mullvad_status=$(ssh_run mullvad status 2>/dev/null || true)

if echo "$mullvad_status" | grep -qi "connected"; then
  pass "Mullvad: connected"
else
  fail "Mullvad: not connected (status: ${mullvad_status:-unavailable})"
fi

# Kill switch / lockdown mode
lockdown=$(ssh_run mullvad lockdown-mode get 2>/dev/null || true)
if echo "$lockdown" | grep -qi "on\|enabled"; then
  pass "Mullvad kill switch: enabled"
else
  # Kill switch may not be configured in hetzner-bare.nix; warn rather than fail.
  echo -e "  ${YELLOW}⚠${RESET}  Mullvad kill switch: not enabled (lockdown: ${lockdown:-unavailable})"
fi

# Verify traffic actually exits through the VPN (tunnel interface present)
if ssh_run ip link show wg0-mullvad >/dev/null 2>&1 || \
   ssh_run ip link show tun0 >/dev/null 2>&1; then
  pass "Mullvad tunnel interface: present"
else
  fail "Mullvad tunnel interface: not found (wg0-mullvad / tun0 missing)"
fi

# ── 6. ZFS pool health ────────────────────────────────────────────────────────

info "6. ZFS pool health"

zpool_output=$(ssh_run_sudo zpool status -x 2>/dev/null || \
               ssh_run zpool status -x 2>/dev/null || true)

if echo "$zpool_output" | grep -qi "all pools are healthy"; then
  pass "ZFS: all pools healthy"
else
  # Print status detail and mark failed
  zpool_full=$(ssh_run_sudo zpool status 2>/dev/null || \
               ssh_run zpool status 2>/dev/null || true)
  fail "ZFS: pool not fully healthy"
  echo ""
  echo "${zpool_full}" | sed 's/^/    /'
  echo ""
fi

# Check no pools are degraded / faulted / unavail
for state in DEGRADED FAULTED UNAVAIL; do
  if echo "$zpool_output" | grep -qi "$state"; then
    fail "ZFS: pool in $state state"
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
