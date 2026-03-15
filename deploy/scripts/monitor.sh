#!/usr/bin/env bash
# deploy/scripts/monitor.sh
#
# Opens a tmux monitoring session for nixflix microVM services.
# Run this directly on the deployed Hetzner server.
#
# USAGE
#   monitor.sh [OPTIONS]
#
# OPTIONS
#   -s, --session <name>   tmux session name (default: nixflix)
#   -m, --mode <mode>      log source: app (default) or journal
#   -d, --state-dir <dir>  nixflix state directory (default: /var/lib/nixflix)
#   -h, --help             show this help text
#
# MODES
#   app      Tail application log files from the virtiofs-mounted state dir.
#            Log paths: /var/lib/nixflix/<svc>/logs/<svc>.txt
#            These are written by the arr apps themselves — good for tracking
#            searches, grabs, imports, and API activity.
#
#   journal  Follow the host systemd unit logs via journalctl -u microvm@<svc>.
#            These capture the guest serial console (all guest systemd output),
#            useful for debugging boot failures, crashes, and service restarts.
#
# WINDOWS
#   0:  overview   watch systemctl status of all microvm@ services
#   1:  sonarr     sonarr log
#   2:  sonarr-ani sonarr-anime log
#   3:  radarr     radarr log
#   4:  lidarr     lidarr log
#   5:  prowlarr   prowlarr log
#   6:  qbt        qBittorrent log
#   7:  jellyfin   Jellyfin log
#   8:  jseerr     Jellyseerr log
#   9:  postgres   postgres microVM journal
#   10: host       mullvad-daemon + nginx journal
#
# EXAMPLE
#   ./monitor.sh                     # app log mode
#   ./monitor.sh --mode journal      # guest console log mode
#   ./monitor.sh -s myflix           # custom session name

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

SESSION="nixflix"
MODE="app"
STATE_DIR="/var/lib/nixflix"

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
  sed -n '/^# USAGE/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--session)   SESSION="$2";   shift 2 ;;
    -m|--mode)      MODE="$2";      shift 2 ;;
    -d|--state-dir) STATE_DIR="$2"; shift 2 ;;
    -h|--help)      usage 0 ;;
    -*)             die "Unknown option: $1" ;;
    *)              die "Unexpected argument: $1" ;;
  esac
done

[[ "$MODE" == "app" || "$MODE" == "journal" ]] || \
  die "Unknown mode '$MODE'. Use 'app' or 'journal'."

command -v tmux >/dev/null 2>&1 || die "tmux not found. Install: nix-shell -p tmux"

# ── Log source helpers ────────────────────────────────────────────────────────

# Returns the tail command for a service in app mode.
# Log files live on the host because the state dir is virtiofs-mounted from host.
app_log_cmd() {
  local svc="$1"
  local log
  case "$svc" in
    sonarr)       log="${STATE_DIR}/sonarr/logs/sonarr.txt" ;;
    sonarr-anime) log="${STATE_DIR}/sonarr-anime/logs/sonarr.txt" ;;
    radarr)       log="${STATE_DIR}/radarr/logs/radarr.txt" ;;
    lidarr)       log="${STATE_DIR}/lidarr/logs/lidarr.txt" ;;
    prowlarr)     log="${STATE_DIR}/prowlarr/logs/prowlarr.txt" ;;
    qbittorrent)  log="${STATE_DIR}/qbittorrent/qBittorrent/data/logs/qbittorrent.log" ;;
    jellyseerr)   log="${STATE_DIR}/jellyseerr/logs/jellyseerr.log" ;;
  esac
  if [[ "$svc" == "jellyfin" ]]; then
    # Jellyfin rotates logs daily; tail the latest in the log dir.
    local log_dir="${STATE_DIR}/jellyfin/log"
    echo "until ls ${log_dir}/*.log 2>/dev/null | grep -q .; do echo 'waiting for jellyfin logs...'; sleep 2; done; tail -F \$(ls -t ${log_dir}/*.log | head -1)"
    return
  fi
  # Wait for the log file to appear (service may still be starting)
  echo "until [ -f ${log} ]; do echo 'waiting for ${log}...'; sleep 2; done; tail -F ${log}"
}

# Returns the journalctl command for a service in journal mode.
journal_cmd() {
  local svc="$1"
  echo "journalctl -u microvm@${svc} -f --output=short-monotonic"
}

# Dispatch to the right command based on mode.
log_cmd() {
  local svc="$1"
  if [[ "$MODE" == "app" ]]; then
    app_log_cmd "$svc"
  else
    journal_cmd "$svc"
  fi
}

# ── Session setup ─────────────────────────────────────────────────────────────

# Kill existing session if present so we start fresh.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Window 0: overview — live systemctl status for all microvm services
tmux new-session -d -s "$SESSION" -n "overview" \
  "watch -n5 'systemctl status \"microvm@*.service\" --no-pager -l 2>&1 | head -200'"

# Windows 1-8: individual service logs
declare -A WINDOW_NAMES=(
  [sonarr]="sonarr"
  [sonarr-anime]="sonarr-ani"
  [radarr]="radarr"
  [lidarr]="lidarr"
  [prowlarr]="prowlarr"
  [qbittorrent]="qbt"
  [jellyfin]="jellyfin"
  [jellyseerr]="jseerr"
)

for svc in sonarr sonarr-anime radarr lidarr prowlarr qbittorrent jellyfin jellyseerr; do
  tmux new-window -t "$SESSION" -n "${WINDOW_NAMES[$svc]}"
  tmux send-keys -t "$SESSION" "$(log_cmd "$svc")" Enter
done

# Window 9: postgres — always journal (postgres doesn't write app logs to state dir)
tmux new-window -t "$SESSION" -n "postgres" \
  "journalctl -u microvm@postgres -f --output=short-monotonic"

# Window 10: host services — mullvad and nginx together
tmux new-window -t "$SESSION" -n "host" \
  "journalctl -u mullvad-daemon -u mullvad-config -u nginx -f --output=short-monotonic"

# Start on the overview window
tmux select-window -t "${SESSION}:overview"

# ── Attach ────────────────────────────────────────────────────────────────────

echo "Attaching to tmux session '${SESSION}' (mode: ${MODE})"
echo "  Windows: overview | sonarr | sonarr-ani | radarr | lidarr | prowlarr | qbt | jellyfin | jseerr | postgres | host"
echo "  Switch windows: prefix + 0-10  (prefix = Ctrl-b by default)"
echo ""

exec tmux attach-session -t "$SESSION"
