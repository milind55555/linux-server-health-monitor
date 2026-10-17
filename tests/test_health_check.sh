#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/health-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Help should exit successfully.
"$SCRIPT" --help >/dev/null || fail 'help command'
pass 'help command'

# Invalid option should return configuration/usage error (exit 2).
set +e
"$SCRIPT" --not-a-real-option >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail 'invalid option returns exit 2'
pass 'invalid option validation'

# A controlled configuration should run and write to a temporary log.
cat > "$TMP/test.conf" <<CFG
CPU_LOAD_PER_CORE_THRESHOLD=999
MEMORY_USED_PERCENT_THRESHOLD=999
DISK_USED_PERCENT_THRESHOLD=999
DISK_CHECK_PATHS="/"
MONITORED_SERVICE=""
AUTO_RESTART_SERVICE=false
LOG_FILE="$TMP/monitor.log"
ALERT_COMMAND=""
CFG
"$SCRIPT" --config "$TMP/test.conf" >/dev/null || fail 'healthy thresholds run'
grep -q 'Health check started' "$TMP/monitor.log" || fail 'log created'
grep -q 'Health check completed: all configured checks passed' "$TMP/monitor.log" || fail 'summary logged'
pass 'config, checks, and logging'

# Invalid threshold should be rejected with exit 2.
cat > "$TMP/bad.conf" <<CFG
CPU_LOAD_PER_CORE_THRESHOLD=not-a-number
MEMORY_USED_PERCENT_THRESHOLD=85
DISK_USED_PERCENT_THRESHOLD=85
DISK_CHECK_PATHS="/"
MONITORED_SERVICE=""
AUTO_RESTART_SERVICE=false
LOG_FILE="$TMP/bad.log"
ALERT_COMMAND=""
CFG
set +e
"$SCRIPT" --config "$TMP/bad.conf" >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail 'invalid threshold returns exit 2'
pass 'invalid configuration validation'

printf '\nAll tests passed.\n'
