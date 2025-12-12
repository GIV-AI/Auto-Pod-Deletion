# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes auto-cleanup tool for multi-user GPU clusters (DGX, HPC, academic labs). Automatically deletes stale Deployments, Pods, and Services based on configurable age limits with user-type policies.

## Architecture

Modular Bash architecture with separate library modules:

```
auto-cleanup/
├── bin/auto-cleanup        # Main entry point (thin orchestrator)
├── lib/
│   ├── common.sh           # Logging, config, flag normalization, locking
│   ├── exclusions.sh       # Exclusion list loading and checking
│   ├── kubernetes.sh       # kubectl wrappers, age calculation
│   └── cleanup.sh          # cleanup_resource, pod queue, batch deletion
├── conf/
│   ├── auto-cleanup.conf   # Main configuration
│   └── exclude_*.txt       # Exclusion lists
├── install.sh              # Installation script
└── uninstall.sh            # Uninstallation script
```

### Installation Paths (Root-Only Tool)

| Component | Path | Permissions |
|-----------|------|-------------|
| Executable | `/opt/auto-cleanup/bin/auto-cleanup` | 700 |
| Libraries | `/opt/auto-cleanup/lib/*.sh` | 600 |
| Configuration | `/etc/auto-cleanup/` | 640 |
| Logs | `/var/log/giindia/auto-cleanup/` | 750 |
| Symlink | `/usr/local/bin/auto-cleanup` | symlink |

### Key Concepts

1. **User-type routing**: Namespace prefix determines limits (`dgx-s-*` = Student, `dgx-f-*` = Faculty, `dgx-i-*` = Industry)
2. **Hard vs Soft limits**: Hard limit always deletes (ignores `keep-alive` label); Soft limit respects `keep-alive=true`
3. **Standalone pods only**: Script only processes pods without `ownerReferences` (not managed by Deployments/ReplicaSets/Jobs)
4. **Batched pod deletion**: Pods are queued and deleted in batches per namespace (configurable batch size, optional background execution)

### Module Responsibilities

| Module | Functions |
|--------|-----------|
| `common.sh` | `log_*()`, `init_logging()`, `find_config()`, `load_config()`, `norm_flag()`, `acquire_lock()`, `release_lock()` |
| `exclusions.sh` | `load_list()`, `load_all_exclusions()`, `in_list()`, `is_*_excluded()`, `is_resource_excluded()` |
| `kubernetes.sh` | `get_user_type()`, `get_limits_for_namespace()`, `get_age_minutes()`, `get_*()`, `is_standalone_pod()`, `delete_resource()` |
| `cleanup.sh` | `init_limit_flags()`, `cleanup_resource()`, `flush_pod_queue()`, `process_deployments()`, `process_pods()`, `process_services()` |

## Running the Script

```bash
# Installed (production)
sudo auto-cleanup

# Development (from project root)
sudo ./bin/auto-cleanup

# Options
auto-cleanup --help
auto-cleanup --version
auto-cleanup --quiet  # Errors only
```

Script uses flock-based locking (`/var/run/auto-cleanup.lock`) to prevent concurrent runs.

## Configuration

All settings in `/etc/auto-cleanup/auto-cleanup.conf` (or `conf/auto-cleanup.conf` for development):

- `Deployment`, `Pod`, `Service` - enable/disable resource types
- `*_HardLimit`, `*_SoftLimit` - enable/disable limit types per resource
- `STUDENT_SOFT/HARD`, `FACULTY_SOFT/HARD`, `INDUSTRY_SOFT/HARD` - age limits in minutes
- `POD_BATCH_SIZE`, `POD_FORCE_DELETE`, `POD_BACKGROUND_DELETE` - pod deletion behavior
- `LOG_DIR`, `LOG_LEVEL`, `LOG_RETENTION_DAYS` - logging settings

## Shell Coding Standards

Follow `.cursor/rules/shell-coding-best-practices.mdc`:

- Use `[[` for conditionals, quote all variables
- Use `$()` for command substitution, not backticks
- Use `local` for function variables, `readonly` for constants
- Guard modules with `_*_SH_LOADED` variables to prevent double-sourcing
- Add `# shellcheck source=` directives for sourced files
- Explain uncommon commands and non-obvious flags with inline comments

### Module Loading Pattern

```bash
# In main script
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh" || exit 1

# In library modules
[[ -n "$_COMMON_SH_LOADED" ]] && return 0
readonly _COMMON_SH_LOADED=1
```

## Testing

Testing framework not yet implemented. See `tests/README.md` for planned test coverage.

When testing manually:
1. Disable resources in config first
2. Run with `LOG_LEVEL=DEBUG` for verbose output
3. Check logs in `/var/log/giindia/auto-cleanup/`

```bash
# Test config
Deployment=False
Pod=False
Service=False
```

## Common Tasks

### Adding a New User Type

1. Add namespace prefix constant in `lib/kubernetes.sh`
2. Update `get_user_type()` function
3. Update `get_limits_for_namespace()` function
4. Add config variables in `conf/auto-cleanup.conf`

### Adding a New Resource Type

1. Add enable flag and limit variables in config
2. Add exclusion file in `conf/`
3. Update `lib/exclusions.sh` with new exclusion functions
4. Update `lib/cleanup.sh` with new processing function
5. Add kubectl wrapper in `lib/kubernetes.sh`
6. Call from `main()` in `bin/auto-cleanup`
