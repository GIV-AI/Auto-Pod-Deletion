# Auto-Cleanup

Kubernetes auto-cleanup tool for multi-user GPU clusters (DGX, HPC, academic labs). Automatically deletes stale **Deployments**, **Pods**, and **Services** based on configurable age limits with user-type policies.

## Features

- **User-type based limits** (Student / Faculty / Industry via namespace prefix)
- **Namespace-level exclusions**
- **Resource-specific exclusions**
- **`keep-alive=true` label protection** (respects soft limits)
- **Batched background pod deletion** (non-blocking)
- **Cron-safe execution** (lock-based, no deadlocks)
- **Day-wise log rotation** with configurable retention
- **Modular architecture** for maintainability

## Project Structure

```
auto-cleanup/
├── bin/
│   └── auto-cleanup              # Main entry point
├── lib/
│   ├── common.sh                 # Logging, config, utilities
│   ├── exclusions.sh             # Exclusion list handling
│   ├── kubernetes.sh             # kubectl wrappers
│   └── cleanup.sh                # Cleanup logic
├── conf/
│   ├── auto-cleanup.conf         # Main configuration
│   ├── exclude_namespaces.txt    # Namespace exclusions
│   ├── exclude_deployments.txt   # Deployment exclusions
│   ├── exclude_pods.txt          # Pod exclusions
│   └── exclude_services.txt      # Service exclusions
├── docs/                         # Documentation
├── tests/                        # Test suite (planned)
├── install.sh                    # Installation script
├── uninstall.sh                  # Uninstallation script
└── README.md
```

## Installation

### Quick Install

```bash
# Clone the repository
git clone <repository-url> auto-cleanup
cd auto-cleanup

# Install (requires root)
sudo ./install.sh
```

### Installation Paths

| Component | Path |
|-----------|------|
| Executable | `/opt/auto-cleanup/bin/auto-cleanup` |
| Libraries | `/opt/auto-cleanup/lib/` |
| Configuration | `/etc/auto-cleanup/` |
| Logs | `/var/log/giindia/auto-cleanup/` |
| Command | `/usr/local/bin/auto-cleanup` (symlink) |

### Uninstallation

```bash
# Remove everything
sudo ./uninstall.sh

# Keep configuration
sudo ./uninstall.sh --keep-config

# Keep logs
sudo ./uninstall.sh --keep-logs
```

## Configuration

Edit `/etc/auto-cleanup/auto-cleanup.conf`:

### Enable/Disable Resource Types

```bash
Deployment=true
Pod=true
Service=true
```

### Enable/Disable Limit Types

```bash
Deployment_HardLimit=true
Deployment_SoftLimit=true

Pod_HardLimit=true
Pod_SoftLimit=true

Service_HardLimit=true
Service_SoftLimit=true
```

### Time Limits

Time values support suffixes: `M` for minutes, `H` for hours. No suffix defaults to minutes.

```bash
# Student namespaces (dgx-s-*)
STUDENT_SOFT=24H
STUDENT_HARD=36H

# Faculty namespaces (dgx-f-*)
FACULTY_SOFT=36H
FACULTY_HARD=84H

# Industry namespaces (dgx-i-*)
INDUSTRY_SOFT=84H
INDUSTRY_HARD=168H
```

Examples: `30M` = 30 minutes, `2H` = 2 hours (120 minutes), `30` = 30 minutes

### Pod Batch Deletion

```bash
POD_BATCH_SIZE=50           # Pods per kubectl command
POD_FORCE_DELETE=false      # Use --force --grace-period=0
POD_BACKGROUND_DELETE=true  # Don't wait for completion
```

## Deletion Logic

### Execution Order

1. **Deployments Cleanup**
2. **Pods Cleanup** (queued, then batch deleted)
3. **Services Cleanup**
4. **Exit & Release Lock**

### Hard Limit (Forced Delete)

When `AGE >= HARD_LIMIT`:
- Resource is **deleted immediately**
- `keep-alive` label is **ignored**

### Soft Limit (Conditional Delete)

When `AGE >= SOFT_LIMIT`:

| keep-alive Label | Action |
|------------------|--------|
| Not present | DELETE |
| `false` | DELETE |
| `true` | SKIP |

### Below Soft Limit

When `AGE < SOFT_LIMIT`:
- Resource is **preserved**

## User Categories

Namespace prefix determines which limits apply:

| Namespace Pattern | User Type | Limits Used |
|-------------------|-----------|-------------|
| `dgx-s-*` | Student | `STUDENT_*` |
| `dgx-f-*` | Faculty | `FACULTY_*` |
| `dgx-i-*` | Industry | `INDUSTRY_*` |

## Label Protection

Add this label to protect resources from soft-limit deletion:

```yaml
metadata:
  labels:
    keep-alive: "true"
```

**Note:** Hard limit always overrides the label.

## Exclusion Files

Edit files in `/etc/auto-cleanup/`:

| File | Purpose |
|------|---------|
| `exclude_namespaces.txt` | Skip entire namespaces |
| `exclude_deployments.txt` | Skip specific deployments |
| `exclude_pods.txt` | Skip specific pods |
| `exclude_services.txt` | Skip specific services |

Format: One name per line, comments start with `#`

## Usage

### Manual Execution

```bash
# Run with default settings
sudo auto-cleanup

# Quiet mode (errors only)
sudo auto-cleanup --quiet

# Show version
auto-cleanup --version

# Show help
auto-cleanup --help
```

### Cron Setup

```bash
# Run hourly
echo '0 * * * * root /usr/local/bin/auto-cleanup' | sudo tee /etc/cron.d/auto-cleanup
```

## Development

For development, run directly from the project directory:

```bash
# Make executable
chmod +x bin/auto-cleanup

# Run (config loaded from conf/)
sudo ./bin/auto-cleanup
```

## Logging

- **Location:** `/var/log/giindia/auto-cleanup/`
- **Format:** `auto-cleanup-YYYY-MM-DD.log` (day-wise)
- **Retention:** Configurable (default 30 days)

Example log entries:

```
[2025-12-12 10:30:00] [INFO] Starting Deployment cleanup...
[2025-12-12 10:30:01] [INFO] Hard limit: deleting deployment train-job (dgx-s-user1) (age=1500m >= 1440m)
[2025-12-12 10:30:02] [INFO] Pod debug-pod (dgx-f-admin) queued for SOFT deletion (keep-alive='')
```

## Safety Guarantees

- **Lock-based execution:** Only one instance runs at a time
- **Namespace exclusions:** Protected namespaces are never touched
- **Resource exclusions:** Protected resources are never touched
- **Non-blocking deletions:** Cluster doesn't freeze during mass deletions
- **Standalone pods only:** Pods managed by controllers are skipped

## Best Practices

1. **Test first:** Disable all resources, then enable gradually
2. **Maintain exclusions:** Keep critical resources in exclusion files
3. **Persistent logs:** Mount log directory to persistent storage
4. **Monitor:** Check logs regularly for unexpected behavior

## License

[Your License Here]

## Author

**Anubhav** - Global Infoventures  
Email: anubhav.patrick@giindia.com
