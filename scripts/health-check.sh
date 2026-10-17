#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-"${SCRIPT_DIR}/../config/monitor.conf"}"
DRY_RUN=false

usage() {
  cat <<'USAGE'
Usage: health-check.sh [--config PATH] [--dry-run] [--help]

Checks CPU load, memory usage, disk usage, and an optional systemd service.
Exit codes: 0=healthy, 1=one or more health checks failed, 2=configuration/runtime error.
--dry-run prints actions but does not restart a service or invoke the alert command.
USAGE
}

while (($#)); do
  case "$1" in
    --config) [[ $# -ge 2 ]] || { echo "ERROR: --config requires a path" >&2; exit 2; }; CONFIG_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -r "$CONFIG_FILE" ]] || { echo "ERROR: config not readable: $CONFIG_FILE" >&2; exit 2; }
# shellcheck source=../config/monitor.conf
source "$CONFIG_FILE"

: "${CPU_LOAD_PER_CORE_THRESHOLD:=1.50}"
: "${MEMORY_USED_PERCENT_THRESHOLD:=85}"
: "${DISK_USED_PERCENT_THRESHOLD:=85}"
: "${DISK_CHECK_PATHS:=/}"
: "${MONITORED_SERVICE:=}"
: "${AUTO_RESTART_SERVICE:=false}"
: "${LOG_FILE:=${HOME}/linux-health-monitor.log}"
: "${ALERT_COMMAND:=}"

is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
for pair in \
  "CPU_LOAD_PER_CORE_THRESHOLD:$CPU_LOAD_PER_CORE_THRESHOLD" \
  "MEMORY_USED_PERCENT_THRESHOLD:$MEMORY_USED_PERCENT_THRESHOLD" \
  "DISK_USED_PERCENT_THRESHOLD:$DISK_USED_PERCENT_THRESHOLD"; do
  key=${pair%%:*}; val=${pair#*:}
  is_number "$val" || { echo "ERROR: $key must be numeric" >&2; exit 2; }
done

log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$level] $*"
  if [[ -n "$LOG_FILE" ]] && { mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || true; } && touch "$LOG_FILE" 2>/dev/null; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  else
    printf '%s\n' "$line" >&2
  fi
  printf '%s\n' "$line"
}

alert() {
  local message="$1"
  if [[ -n "$ALERT_COMMAND" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log INFO "DRY-RUN: would invoke alert command: $ALERT_COMMAND"
    elif [[ -x "$ALERT_COMMAND" ]]; then
      "$ALERT_COMMAND" "LinuxHealthMonitor: $message" >/dev/null 2>&1 || log WARN "Alert command failed"
    else
      log WARN "Alert command is not executable: $ALERT_COMMAND"
    fi
  fi
}

failures=0
log INFO "Health check started (host=$(hostname), dry_run=$DRY_RUN)"

# Load average normalized by CPU core count gives a comparable per-core signal.
if command -v uptime >/dev/null 2>&1 && command -v nproc >/dev/null 2>&1; then
  load_1m="$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)"
  cores="$(nproc)"
  if is_number "$load_1m" && [[ "$cores" =~ ^[1-9][0-9]*$ ]]; then
    load_per_core="$(awk -v l="$load_1m" -v c="$cores" 'BEGIN { printf "%.2f", l/c }')"
    if awk -v a="$load_per_core" -v b="$CPU_LOAD_PER_CORE_THRESHOLD" 'BEGIN {exit !(a>b)}'; then
      log CRITICAL "CPU load per core high: $load_per_core (threshold=$CPU_LOAD_PER_CORE_THRESHOLD; load1=$load_1m; cores=$cores)"
      alert "CPU load per core high: $load_per_core"
      ((failures+=1))
    else
      log OK "CPU load per core: $load_per_core (threshold=$CPU_LOAD_PER_CORE_THRESHOLD)"
    fi
  else
    log WARN "Could not read CPU load metrics"
  fi
else
  log WARN "uptime/nproc unavailable; skipping CPU load check"
fi

# Memory usage is calculated from MemTotal and MemAvailable (Linux /proc/meminfo).
if [[ -r /proc/meminfo ]]; then
  read -r mem_total mem_available < <(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print t, a}' /proc/meminfo)
  if [[ "${mem_total:-}" =~ ^[1-9][0-9]*$ && "${mem_available:-}" =~ ^[0-9]+$ ]]; then
    mem_used_pct="$(awk -v t="$mem_total" -v a="$mem_available" 'BEGIN {printf "%.1f", ((t-a)/t)*100}')"
    if awk -v a="$mem_used_pct" -v b="$MEMORY_USED_PERCENT_THRESHOLD" 'BEGIN {exit !(a>b)}'; then
      log CRITICAL "Memory usage high: ${mem_used_pct}% (threshold=${MEMORY_USED_PERCENT_THRESHOLD}%)"
      alert "Memory usage high: ${mem_used_pct}%"
      ((failures+=1))
    else
      log OK "Memory usage: ${mem_used_pct}% (threshold=${MEMORY_USED_PERCENT_THRESHOLD}%)"
    fi
  else
    log WARN "Could not parse memory metrics"
  fi
else
  log WARN "/proc/meminfo unavailable; skipping memory check"
fi

# Check each configured mount/path. df output uses POSIX formatting to keep parsing predictable.
for path in $DISK_CHECK_PATHS; do
  if [[ ! -e "$path" ]]; then
    log WARN "Disk check path does not exist: $path"
    continue
  fi
  disk_line="$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $5, $6}')"
  read -r disk_pct mount_point <<< "$disk_line"
  disk_pct="${disk_pct%%%}"
  if [[ "${disk_pct:-}" =~ ^[0-9]+$ ]]; then
    if (( disk_pct > DISK_USED_PERCENT_THRESHOLD )); then
      log CRITICAL "Disk usage high: ${disk_pct}% on $mount_point (threshold=${DISK_USED_PERCENT_THRESHOLD}%)"
      alert "Disk usage high: ${disk_pct}% on $mount_point"
      ((failures+=1))
    else
      log OK "Disk usage: ${disk_pct}% on $mount_point (threshold=${DISK_USED_PERCENT_THRESHOLD}%)"
    fi
  else
    log WARN "Could not parse df output for path: $path"
  fi
done

# Only monitor/restart a service explicitly named by the operator.
if [[ -n "$MONITORED_SERVICE" ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    log WARN "systemctl unavailable; skipping service check for $MONITORED_SERVICE"
  elif systemctl is-active --quiet "$MONITORED_SERVICE"; then
    log OK "Service active: $MONITORED_SERVICE"
  else
    log CRITICAL "Service is not active: $MONITORED_SERVICE"
    alert "Service is not active: $MONITORED_SERVICE"
    ((failures+=1))
    if [[ "$AUTO_RESTART_SERVICE" == true ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        log INFO "DRY-RUN: would restart allowlisted configured service: $MONITORED_SERVICE"
      elif systemctl restart "$MONITORED_SERVICE"; then
        sleep 2
        if systemctl is-active --quiet "$MONITORED_SERVICE"; then
          log RECOVERY "Service restarted successfully: $MONITORED_SERVICE"
        else
          log CRITICAL "Service still inactive after restart: $MONITORED_SERVICE"
        fi
      else
        log CRITICAL "Restart command failed for service: $MONITORED_SERVICE"
      fi
    fi
  fi
else
  log INFO "Service check skipped (MONITORED_SERVICE is empty)"
fi

if (( failures > 0 )); then
  log SUMMARY "Health check completed with $failures failure(s)"
  exit 1
fi
log SUMMARY "Health check completed: all configured checks passed"
exit 0
