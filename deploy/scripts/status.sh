#!/usr/bin/env bash
# deploy/scripts/status.sh
#
# Quick one-shot status check for all nixflix services.
# Run directly on the server or via nix run .#status -- <host-ip>
#
# USAGE
#   On server:  status.sh [OPTIONS]
#   Remote:     nix run .#status -- <host-ip> [OPTIONS]
#
# OPTIONS
#   -h, --help    Show this help text
#
# OUTPUT
#   One line per service: VM state, HTTP/TCP health, any failed systemd units
#
# EXAMPLE
#   nix run .#status -- <host-ip>

set -euo pipefail

# ── Argument parsing ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      sed -n '/^# USAGE/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
      exit 0
      ;;
    -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *)  echo "ERROR: Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

# ── Colors ─────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BOLD=''; DIM=''; NC=''
fi

# ── Helpers ────────────────────────────────────────────────────────────────────

check_http() {
  local url="$1"
  # curl always writes %{http_code} (e.g. "000" on failure); don't add || echo
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 --connect-timeout 2 "$url" 2>/dev/null
}

check_tcp() {
  local host="$1" port="$2"
  if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
    echo "ok"
  else
    echo "fail"
  fi
}

fmt_vm() {
  case "$1" in
    active)      echo -e "${GREEN}●${NC}" ;;
    activating)  echo -e "${YELLOW}◌${NC}" ;;
    *)           echo -e "${RED}✗${NC}" ;;
  esac
}

fmt_http() {
  local code="$1"
  case "$code" in
    2*|401)  echo -e "${GREEN}HTTP $code${NC}" ;;
    000)     echo -e "${RED}NO RESP ${NC}" ;;
    *)       echo -e "${YELLOW}HTTP $code${NC}" ;;
  esac
}

# ── Service definitions ────────────────────────────────────────────────────────

# Format: "name addr port http_path"
# Empty addr/port = VM-state-only (no API check); empty path = TCP-only check
SERVICES=(
  "postgres             "
  "sonarr      10.100.0.10  8989  /api/v3/system/status"
  "sonarr-ani  10.100.0.11  8990  /api/v3/system/status"
  "radarr      10.100.0.12  7878  /api/v3/system/status"
  "lidarr      10.100.0.13  8686  /api/v1/system/status"
  "prowlarr    10.100.0.14  9696  /api/v1/system/status"
  "qbittorrent 10.100.0.21  8282  /api/v2/app/version"
  "jellyfin    10.100.0.30  8096  /health"
  "jellyseerr  10.100.0.31  5055  /api/v1/status"
)

# Map short name → microvm unit name
declare -A UNIT_NAME=(
  [sonarr-ani]="sonarr-anime"
)

# ── Main ───────────────────────────────────────────────────────────────────────

echo -e "${BOLD}nixflix status — $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo "────────────────────────────────────────────────────────"
printf "${BOLD}%-12s  %-3s  %-12s  %s${NC}\n" "SERVICE" "VM" "API" "FAILED UNITS"
echo "────────────────────────────────────────────────────────"

for entry in "${SERVICES[@]}"; do
  read -r name addr port path <<< "$entry"

  unit="${UNIT_NAME[$name]:-$name}"
  vm_state=$(systemctl is-active "microvm@${unit}.service" 2>/dev/null || echo "inactive")
  vm_bullet=$(fmt_vm "$vm_state")

  if [[ -n "$path" ]]; then
    http_code=$(check_http "http://${addr}:${port}${path}")
    api_disp=$(fmt_http "$http_code")
  elif [[ -n "$addr" && -n "$port" ]]; then
    tcp_result=$(check_tcp "$addr" "$port")
    if [[ "$tcp_result" == "ok" ]]; then
      api_disp=$(echo -e "${GREEN}TCP OK  ${NC}")
    else
      api_disp=$(echo -e "${RED}TCP FAIL${NC}")
    fi
  else
    # VM-state-only service (e.g. postgres: internal, not reachable from host)
    api_disp=$(echo -e "${DIM}internal${NC}")
  fi

  # Failed host-side units for this service
  failed=$(systemctl list-units --state=failed --no-legend 2>/dev/null \
    | grep -i "$unit" | awk '{print $1}' | head -3 | tr '\n' ' ' || true)

  printf "%b %-12s  %b  %s\n" \
    "$vm_bullet" "$name" "$api_disp" "${failed:-}"
done

echo "────────────────────────────────────────────────────────"

# Host services
echo ""
printf "${BOLD}%-20s  %s${NC}\n" "HOST SERVICE" "STATE"
for svc in mullvad-daemon nginx; do
  state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
  bullet=$(fmt_vm "$state")
  printf "%b %-18s  %s\n" "$bullet" "$svc" "$state"
done

# Mullvad connection
mullvad_line=$(mullvad status 2>/dev/null | head -1 || echo "unknown")
echo ""
echo -e "  Mullvad: $mullvad_line"

# Any globally failed units (non-microvm)
failed_global=$(systemctl list-units --state=failed --no-legend 2>/dev/null \
  | grep -v "microvm@" | awk '{print $1}' | head -5 | tr '\n' ' ' || true)
if [[ -n "$failed_global" ]]; then
  echo -e "\n${RED}Failed host units: ${failed_global}${NC}"
fi
