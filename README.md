# Linux Server Health Monitor & Auto-Recovery

A Bash-based Linux operations project that checks CPU load per core, memory usage, disk utilization, and an optional systemd service. It writes timestamped logs, invokes an optional local alert command, supports dry-run mode, and can optionally restart one explicitly configured lab service.

> **Safety:** Automatic restart is disabled by default. Test only with a disposable service in a lab. Do not configure production or critical services without change control and a tested recovery plan.

## Features

- CPU load normalized by CPU core count
- Memory utilization from `/proc/meminfo`
- Disk utilization for configured paths
- Optional `systemd` service state check
- Optional service restart, disabled by default
- Timestamped log file and optional `logger` alerts
- Configurable thresholds and exit codes
- Dry-run mode
- Lightweight tests and GitHub Actions ShellCheck workflow

## Requirements

- Bash 4+
- Linux with `/proc/meminfo`, `df`, `awk`, `date`, and `hostname`
- `systemd` and `systemctl` only if checking a service
- Optional: ShellCheck

Ubuntu Server 22.04/24.04 or Rocky Linux 9 are suitable. WSL2 can run the health checks, but service checks and systemd timers require systemd support to be enabled and running. A Linux VM is the most representative environment for service recovery.

## Quick start

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/linux-server-health-monitor.git
cd linux-server-health-monitor
cp config/monitor.conf config/monitor.local.conf
chmod +x scripts/health-check.sh tests/test_health_check.sh
./scripts/health-check.sh --config config/monitor.local.conf
```

The default config is safe: it checks `/` and `/var`, leaves service monitoring disabled, and does not restart services. By default, logs are written to `~/linux-health-monitor.log`.

## Configuration

Edit `config/monitor.conf` or supply a separate config with `--config PATH`.

| Variable | Meaning | Default |
|---|---|---|
| `CPU_LOAD_PER_CORE_THRESHOLD` | Critical when 1-minute load divided by CPU cores is greater than this value | `1.50` |
| `MEMORY_USED_PERCENT_THRESHOLD` | Critical memory utilization percentage | `85` |
| `DISK_USED_PERCENT_THRESHOLD` | Critical disk utilization percentage | `85` |
| `DISK_CHECK_PATHS` | Space-separated paths/mounts to check | `/ /var` |
| `MONITORED_SERVICE` | Optional systemd unit name | empty |
| `AUTO_RESTART_SERVICE` | Restart configured service when inactive | `false` |
| `LOG_FILE` | Log destination | `~/linux-health-monitor.log` |
| `ALERT_COMMAND` | Optional executable receiving a single alert message argument | `/usr/bin/logger` |

The `logger` command sends messages to the local system log; it is not email or a remote paging integration.

## Usage

```bash
# Normal check
./scripts/health-check.sh

# Show what the monitor would do; no alert command or restart is executed
./scripts/health-check.sh --dry-run

# Use an alternate config
./scripts/health-check.sh --config ./config/monitor.conf

# Inspect logs
 tail -n 50 "$HOME/linux-health-monitor.log"
```

Exit codes: `0` means all configured checks passed, `1` means one or more health checks were critical, and `2` means invalid arguments/configuration or a runtime setup error.

## Optional systemd service monitoring

Use a disposable lab service only. For a first test, set:

```bash
MONITORED_SERVICE="cron.service"
AUTO_RESTART_SERVICE=false
```

Run the script and verify whether the service is active. To test auto-recovery, create a disposable systemd unit of your own and set its exact unit name. Enable `AUTO_RESTART_SERVICE=true` only after verifying the unit and testing with `--dry-run`. Do not blindly restart SSH, networking, storage, database, or production application services.

## Schedule with a systemd timer

Copy this repository to `/home/YOUR_USER/linux-server-health-monitor`, replace `USERNAME` and paths in the example unit files, then install them:

```bash
sudo cp systemd/linux-health-monitor.service /etc/systemd/system/
sudo cp systemd/linux-health-monitor.timer /etc/systemd/system/
# Edit both files first and replace USERNAME and repository paths.
sudo systemctl daemon-reload
sudo systemctl enable --now linux-health-monitor.timer
systemctl list-timers --all | grep linux-health-monitor
systemctl status linux-health-monitor.timer
journalctl -u linux-health-monitor.service --since today
```

If the repository/config is under a user's home directory, ensure the service user can read the files and write the configured log. Do not run the monitor as root unless a demonstrated requirement exists.

## Tests

```bash
bash tests/test_health_check.sh
```

Optional lint:

```bash
sudo apt-get update && sudo apt-get install -y shellcheck
shellcheck scripts/health-check.sh tests/test_health_check.sh
```

Tests cover help/argument handling, configurable thresholds, log creation, healthy completion, and invalid threshold rejection. They do not yet test real service restarts or every failure-injection case.

## Safe failure demonstrations

1. **Disk alert logic:** create a temporary config with `DISK_USED_PERCENT_THRESHOLD=0`, run the monitor against `/`, and verify it returns exit code `1` and logs a critical disk message. This intentionally triggers a threshold without filling the disk.
2. **Memory/load thresholds:** use thresholds of `0` in a temporary config to force threshold alerts; do not consume host memory or CPU deliberately.
3. **Service down:** create a disposable systemd unit in a test VM, configure its exact unit name, stop it, and verify the monitor reports it inactive. Keep auto-restart disabled for the first test.
4. **Recovery:** only after validating the disposable unit, enable auto-restart in a lab config, run the monitor, and confirm `systemctl is-active UNIT`.
5. **Invalid config:** change a threshold to non-numeric text and confirm exit code `2`.

Use a separate temporary config and log for failure tests so the normal configuration remains unchanged.

## Architecture

```mermaid
flowchart TD
    A[systemd timer or manual run] --> B[Bash health-check.sh]
    B --> C[Load average and CPU count]
    B --> D[/proc/meminfo]
    B --> E[df disk usage]
    B --> F{Optional systemd service}
    C --> G[Threshold evaluation]
    D --> G
    E --> G
    F --> G
    G --> H[Timestamped log]
    G --> I[Local logger alert]
    G --> J{Configured lab service down?}
    J -->|Yes and auto-restart enabled| K[Restart and verify]
    J -->|No| L[Exit code and summary]
    K --> L
```

## Troubleshooting

- **`systemctl` unavailable:** run on a systemd-based Linux VM, or skip service checks in WSL.
- **Log not writable:** change `LOG_FILE` to a path writable by the user running the script.
- **Threshold never triggers:** compare current metrics with configured thresholds; use a temporary low threshold to validate alert logic.
- **Unexpected exit code 1:** inspect the log for `CRITICAL` messages and confirm the configured thresholds.
- **Timer not firing:** run `systemctl status linux-health-monitor.timer` and `journalctl -u linux-health-monitor.service`.

## Security and limitations

- No credentials or remote access are required.
- The monitor does not install packages, change firewall rules, or alter system configuration.
- Automatic restart is opt-in and only targets the configured unit.
- Load average is a pressure indicator, not a direct CPU utilization percentage.
- The project currently uses local logs and local syslog alerts; no dashboard, email, or remote alert receiver is included.
- Threshold checks are simple and should be tuned to the workload before operational use.

## Evidence to capture for GitHub

- A normal run with `OK` and `SUMMARY` lines
- A forced threshold alert using a temporary config
- Test output from `bash tests/test_health_check.sh`
- Timer status and recent journal entries, if using a systemd VM

## Resume wording (use only after you run and verify it)

- Built a Bash-based Linux health monitoring tool to check load average, memory utilization, disk capacity, and optional systemd service status, with configurable thresholds and timestamped logs.
- Added scheduled execution, exit-code handling, local alert integration, dry-run support, and opt-in recovery for a disposable lab service.
- Validated configuration handling and monitoring behavior with automated shell tests and documented failure-injection procedures.

Add measured outcomes only after recording your own baseline and results; do not claim percentages that you have not measured.

## Suggested GitHub topics

`linux` `bash` `sysadmin` `monitoring` `automation` `systemd` `shell-scripting` `sre`

## License

MIT. See [LICENSE](LICENSE).
