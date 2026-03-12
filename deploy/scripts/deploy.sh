#!/usr/bin/env bash
# deploy/scripts/deploy.sh
#
# Deploys the nixflix NixOS configuration to a Hetzner Cloud server via nixos-anywhere.
#
# USAGE
#   deploy.sh <server-ip> [OPTIONS]
#
# OPTIONS
#   -c, --config <name>     NixOS config to deploy (default: hetzner-bare)
#   -k, --age-key <path>    Path to age secret key for sops (default: ~/.config/sops/age/keys.txt)
#   -f, --flake <path>      Path to flake root (default: repo root)
#   --no-age                Skip copying age key (if sops is not in use)
#   --hcloud-token <token>  Hetzner Cloud API token (or set HETZNER_CLOUD_TOKEN)
#                           Used to disable rescue mode before rebooting.
#   -h, --help              Show this help text
#
# REQUIREMENTS
#   - nixos-anywhere: available via nix run github:nix-community/nixos-anywhere
#     or nix run .#deploy (from this flake)
#   - SSH access to the target server (root, rescue mode)
#   - An age secret key if deploying with sops-nix secrets
#   - curl (for Hetzner Cloud API rescue disable)
#
# EXAMPLE
#   ./deploy.sh 65.21.100.42
#   HETZNER_CLOUD_TOKEN=... ./deploy.sh 65.21.100.42
#   nix run .#deploy -- 65.21.100.42

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

CONFIG="hetzner-bare"
AGE_KEY_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
FLAKE_ROOT=""
SERVER_IP=""
SKIP_AGE=false
HCLOUD_TOKEN="${HETZNER_CLOUD_TOKEN:-}"

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
  sed -n '/^# USAGE/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || \
    die "'$1' not found. Install: nix-shell -p $1  OR  nix run github:nix-community/nixos-anywhere"
}

hcloud_api() {
  local method="$1" path="$2"
  curl -sf -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    -H "Content-Type: application/json" \
    -X "$method" \
    "https://api.hetzner.cloud/v1${path}"
}

disable_rescue() {
  echo "Disabling Hetzner Cloud rescue mode via API..."
  local server_id
  server_id="$(hcloud_api GET "/servers" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
ip = '${SERVER_IP}'
for s in data.get('servers', []):
    if s.get('public_net', {}).get('ipv4', {}).get('ip') == ip:
        print(s['id'])
        break
")" 2>/dev/null || true

  if [[ -z "$server_id" ]]; then
    echo "Warning: could not find server ID for $SERVER_IP — skipping rescue disable."
    return
  fi

  if hcloud_api POST "/servers/${server_id}/actions/disable_rescue" > /dev/null 2>&1; then
    echo "Rescue mode disabled (server id: $server_id)."
  else
    echo "Warning: could not disable rescue mode (may already be inactive)."
  fi
}

# ── Argument parsing ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)      CONFIG="$2";      shift 2 ;;
    -k|--age-key)     AGE_KEY_PATH="$2"; shift 2 ;;
    -f|--flake)       FLAKE_ROOT="$2";  shift 2 ;;
    --no-age)         SKIP_AGE=true;    shift ;;
    --hcloud-token)   HCLOUD_TOKEN="$2"; shift 2 ;;
    -h|--help)        usage 0 ;;
    -*)               die "Unknown option: $1" ;;
    *)
      [[ -z "$SERVER_IP" ]] || die "Unexpected argument: $1"
      SERVER_IP="$1"
      shift
      ;;
  esac
done

[[ -n "$SERVER_IP" ]] || { echo "Error: server IP required."; usage 1; }

# ── Resolve flake root ────────────────────────────────────────────────────────

if [[ -z "$FLAKE_ROOT" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FLAKE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

[[ -f "$FLAKE_ROOT/flake.nix" ]] || \
  die "Could not find flake.nix in '$FLAKE_ROOT'. Use --flake to set the path."

# ── Pre-flight ────────────────────────────────────────────────────────────────

require_cmd nixos-anywhere
require_cmd ssh
require_cmd curl

HAVE_HCLOUD=false
[[ -n "$HCLOUD_TOKEN" ]] && HAVE_HCLOUD=true

echo "Deploying nixflix to $SERVER_IP"
echo "  Config:    .#$CONFIG"
echo "  Flake:     $FLAKE_ROOT"
if [[ "$SKIP_AGE" == false ]]; then
  echo "  Age key:   ${AGE_KEY_PATH}"
fi
if [[ "$HAVE_HCLOUD" == true ]]; then
  echo "  hcloud:    enabled (will disable rescue before reboot)"
else
  echo "  hcloud:    disabled (pass --hcloud-token or set HETZNER_CLOUD_TOKEN to auto-disable rescue)"
fi
echo ""

# Verify SSH connectivity before doing any work
echo "Checking SSH connectivity..."
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "root@$SERVER_IP" true \
  || die "Cannot connect to root@$SERVER_IP. Is the server in rescue mode?"
echo "SSH OK"
echo ""

# ── Deploy ────────────────────────────────────────────────────────────────────

echo "Running nixos-anywhere..."

EXTRA_FILES_ARGS=()
if [[ "$SKIP_AGE" == false ]]; then
  [[ -f "$AGE_KEY_PATH" ]] || \
    die "Age key not found at '$AGE_KEY_PATH'. Use --age-key or --no-age."

  EXTRA_FILES_DIR="$(mktemp -d)"
  trap 'rm -rf "$EXTRA_FILES_DIR"' EXIT
  install -D -m 600 "$AGE_KEY_PATH" "$EXTRA_FILES_DIR/var/lib/sops-nix/key.txt"
  EXTRA_FILES_ARGS=(--extra-files "$EXTRA_FILES_DIR")
fi

# --no-reboot: disable rescue mode via API before reboot, or server boots back into rescue.
REBOOT_ARGS=()
if [[ "$HAVE_HCLOUD" == true ]]; then
  REBOOT_ARGS=(--no-reboot)
fi

nixos-anywhere \
  --flake "${FLAKE_ROOT}#${CONFIG}" \
  "${EXTRA_FILES_ARGS[@]}" \
  "${REBOOT_ARGS[@]}" \
  "root@${SERVER_IP}"

# ── Disable rescue and reboot ─────────────────────────────────────────────────

if [[ "$HAVE_HCLOUD" == true ]]; then
  echo ""
  disable_rescue
  echo "Rebooting server..."
  ssh -o StrictHostKeyChecking=no "root@$SERVER_IP" reboot || true
fi

# ── Wait for reboot and reload nginx after ACME ───────────────────────────────

echo ""
echo "Waiting for server to come back online..."
for i in $(seq 1 60); do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
       "root@$SERVER_IP" true 2>/dev/null; then
    echo "Server is up."
    break
  fi
  sleep 5
done

echo "Waiting for ACME certificates and reloading nginx..."
ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes \
  "root@$SERVER_IP" bash <<'REMOTE'
# Wait up to 5 minutes for all acme-order-renew services to finish
for i in $(seq 1 60); do
  pending=0
  for svc in $(systemctl list-units 'acme-order-renew-*.service' --no-legend --plain 2>/dev/null | awk '{print $1}'); do
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "activating" ]]; then
      pending=1
    fi
  done
  [[ $pending -eq 0 ]] && break
  sleep 5
done
systemctl reload nginx
echo "nginx reloaded."
REMOTE

# ── Next steps ────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Deployment complete!"
echo ""
echo "  Server IP: $SERVER_IP"
echo "  Config:    .#$CONFIG"
echo ""
echo "  Next steps:"
echo "    1. SSH in: ssh root@$SERVER_IP"
echo "    2. Check services: systemctl status"
echo "    3. Run integration tests: ./deploy/tests/integration.sh $SERVER_IP"
echo "════════════════════════════════════════════════════════"
