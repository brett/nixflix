#!/usr/bin/env bash
# deploy/scripts/provision.sh
#
# Provisions a Hetzner CPX21 server for nixflix deployment using the hcloud CLI.
#
# USAGE
#   provision.sh [OPTIONS] <server-name>
#   provision.sh teardown <server-name>
#
# SUBCOMMANDS
#   (default)   Create and boot server into rescue mode, then print the IP.
#   teardown    Delete the named server.
#
# OPTIONS
#   -k, --ssh-key <name>        SSH key name registered in Hetzner (required)
#   -l, --location <location>   Hetzner datacenter location (default: nbg1)
#   -t, --server-type <type>    Server type (default: cpx21)
#   -h, --help                  Show this help text
#
# SETUP
#   1. Install the hcloud CLI:
#        # NixOS: nix-shell -p hcloud
#        # Homebrew: brew install hcloud
#        # Direct: https://github.com/hetznercloud/cli/releases
#
#   2. Set your Hetzner Cloud API token:
#        export HCLOUD_TOKEN=your_token_here
#      Or create a context:
#        hcloud context create nixflix
#      (Paste token when prompted; hcloud stores it in ~/.config/hcloud/cli.toml)
#
# EXAMPLE
#   export HCLOUD_TOKEN=abc123...
#   ./provision.sh --ssh-key my-key --location nbg1 nixflix-test
#   # → Prints server IP once in rescue mode
#
#   ./provision.sh teardown nixflix-test
#   # → Deletes the server

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

SSH_KEY=""
LOCATION="nbg1"
SERVER_TYPE="cpx21"
OS_IMAGE="debian-12"       # hcloud needs an OS image even for rescue-mode boots
RESCUE_TYPE="linux64"
SUBCOMMAND=""
SERVER_NAME=""

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
  sed -n '/^# USAGE/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }

require_token() {
  [[ -n "${HCLOUD_TOKEN:-}" ]] || \
    die "HCLOUD_TOKEN is not set. See the SETUP section in this script."
}

require_hcloud() {
  command -v hcloud >/dev/null 2>&1 || \
    die "hcloud not found. Install it: nix-shell -p hcloud  OR  brew install hcloud"
}

wait_for_status() {
  local server="$1" target_status="$2" timeout="${3:-300}" interval=5
  local elapsed=0
  echo "Waiting for server '$server' to reach status '$target_status' (timeout: ${timeout}s)..."
  while true; do
    local status
    status=$(hcloud server describe "$server" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    if [[ "$status" == "$target_status" ]]; then
      echo "Server status: $status"
      return 0
    fi
    if (( elapsed >= timeout )); then
      die "Timeout waiting for status '$target_status' (current: $status)"
    fi
    printf "  [%3ds] status=%s ...\r" "$elapsed" "$status"
    sleep "$interval"
    (( elapsed += interval ))
  done
}

# ── Argument parsing ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "teardown" ]]; then
  SUBCOMMAND="teardown"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--ssh-key)      SSH_KEY="$2";      shift 2 ;;
    -l|--location)     LOCATION="$2";     shift 2 ;;
    -t|--server-type)  SERVER_TYPE="$2";  shift 2 ;;
    -h|--help)         usage 0 ;;
    -*)                die "Unknown option: $1" ;;
    *)
      [[ -z "$SERVER_NAME" ]] || die "Unexpected argument: $1"
      SERVER_NAME="$1"
      shift
      ;;
  esac
done

[[ -n "$SERVER_NAME" ]] || { echo "Error: server name required."; usage 1; }

require_hcloud
require_token

# ── Teardown ──────────────────────────────────────────────────────────────────

if [[ "$SUBCOMMAND" == "teardown" ]]; then
  echo "Deleting server '$SERVER_NAME'..."
  hcloud server delete "$SERVER_NAME"
  echo "Done. Server '$SERVER_NAME' deleted."
  exit 0
fi

# ── Provision ─────────────────────────────────────────────────────────────────

[[ -n "$SSH_KEY" ]] || die "SSH key name required. Use --ssh-key <name>."

echo "Provisioning Hetzner server:"
echo "  Name:     $SERVER_NAME"
echo "  Type:     $SERVER_TYPE  (CPX21: 3 vCPU, 4 GB RAM)"
echo "  Location: $LOCATION"
echo "  SSH key:  $SSH_KEY"
echo ""

# Create server
echo "Creating server..."
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --image "$OS_IMAGE" \
  --location "$LOCATION" \
  --ssh-key "$SSH_KEY"

# Wait until running before enabling rescue mode
wait_for_status "$SERVER_NAME" "running" 120

# Enable rescue mode
echo "Enabling rescue mode ($RESCUE_TYPE)..."
hcloud server enable-rescue \
  --type "$RESCUE_TYPE" \
  --ssh-key "$SSH_KEY" \
  "$SERVER_NAME"

# Reboot into rescue
echo "Rebooting into rescue mode..."
hcloud server reboot "$SERVER_NAME"

# Wait for rescue boot (server goes off then running again)
sleep 5
wait_for_status "$SERVER_NAME" "running" 180

# Retrieve IP
SERVER_IP=$(hcloud server describe "$SERVER_NAME" -o json \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['public_net']['ipv4']['ip'])")

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Server is ready in rescue mode!"
echo "  IP: $SERVER_IP"
echo ""
echo "  Connect:  ssh root@$SERVER_IP"
echo "  Deploy:   ./deploy.sh $SERVER_IP"
echo "  Teardown: $0 teardown $SERVER_NAME"
echo "════════════════════════════════════════════════════════"
