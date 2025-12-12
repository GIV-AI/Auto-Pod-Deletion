#!/bin/bash
# ============================================================================
# Auto-Cleanup - Common Utilities Module
# ============================================================================
# Shared utilities for logging, configuration loading, and flag normalization.
# This module provides the foundation for all other modules.
#
# Author: Anubhav <anubhav.patrick@giindia.com>
# Organization: Global Infoventures
# Date: 2025-12-12
# ============================================================================

# Guard against double-sourcing
[[ -n "$_COMMON_SH_LOADED" ]] && return 0
readonly _COMMON_SH_LOADED=1

# Module version
readonly COMMON_VERSION="2.0.0"

# ============================================================================
# COLOR CONSTANTS (Terminal Detection)
# ============================================================================
# Detect if running in interactive terminal (safe for cron/pipes)
if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly BLUE=$'\033[0;34m'
    readonly CYAN=$'\033[0;36m'
    readonly NC=$'\033[0m'
    readonly BOLD=$'\033[1m'
else
    # Non-interactive (cron, pipe, redirect) - disable colors
    readonly RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC="" BOLD=""
fi

# ============================================================================
# LOGGING SYSTEM
# ============================================================================
# Log levels with numeric values for comparison
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)

# Default log settings (can be overridden by config)
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_DIR="${LOG_DIR:-/var/log/giindia/auto-cleanup}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"  # 10MB default
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Log file path (set by init_logging)
LOG_FILE=""

# ----------------------------------------------------------------------------
# log_message - Core logging function with level filtering
# Arguments:
#   $1 - Log level (DEBUG, INFO, WARNING, ERROR)
#   $2 - Message to log
# ----------------------------------------------------------------------------
log_message() {
    local level="${1:-INFO}"
    local message="$2"
    local configured_level="${LOG_LEVEL:-INFO}"

    # Skip if level is below configured threshold
    if [[ ${LOG_LEVELS[$level]:-1} -ge ${LOG_LEVELS[$configured_level]:-1} ]]; then
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        local log_entry="[$timestamp] [$level] $message"

        # Write to log file if available and not too large
        if [[ -n "$LOG_FILE" && -w "$(dirname "$LOG_FILE" 2>/dev/null)" ]]; then
            local file_size
            file_size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
            if [[ $file_size -lt ${MAX_LOG_SIZE:-10485760} ]]; then
                echo "$log_entry" >> "$LOG_FILE"
            fi
        fi

        # Also output to terminal based on level
        case "$level" in
            ERROR)   echo -e "${RED}ERROR:${NC} $message" >&2 ;;
            WARNING) echo -e "${YELLOW}WARNING:${NC} $message" >&2 ;;
            INFO)    echo "$message" ;;
            DEBUG)   [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "${CYAN}DEBUG:${NC} $message" ;;
        esac
    fi
}

# Convenience logging functions
log_debug()   { log_message "DEBUG" "$1"; }
log_info()    { log_message "INFO" "$1"; }
log_warning() { log_message "WARNING" "$1"; }
log_error()   { log_message "ERROR" "$1"; }

# ----------------------------------------------------------------------------
# init_logging - Initialize logging system with day-wise rotation
# Arguments:
#   $1 - (optional) Log directory override
# Returns:
#   0 on success, 1 on failure
# ----------------------------------------------------------------------------
init_logging() {
    local log_dir="${1:-$LOG_DIR}"

    [[ -z "$log_dir" ]] && return 1

    # Create log directory if it doesn't exist
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        echo "ERROR: Cannot create log directory: $log_dir" >&2
        return 1
    fi

    # Day-wise log file naming (e.g., auto-cleanup-2025-12-12.log)
    local current_date
    current_date="$(date '+%Y-%m-%d')"
    LOG_FILE="${log_dir}/auto-cleanup-${current_date}.log"

    # Export for subshells/background jobs
    export LOG_FILE LOG_DIR

    # Clean up old logs on startup
    cleanup_old_logs "$log_dir"

    return 0
}

# ----------------------------------------------------------------------------
# cleanup_old_logs - Remove log files older than retention period
# Arguments:
#   $1 - Log directory to clean
# ----------------------------------------------------------------------------
cleanup_old_logs() {
    local log_dir="$1"
    local retention_days="${LOG_RETENTION_DAYS:-30}"

    [[ -z "$log_dir" || ! -d "$log_dir" ]] && return 1

    # Find and remove day-wise logs older than retention period
    # Pattern: auto-cleanup-YYYY-MM-DD.log
    while IFS= read -r -d '' old_file; do
        if [[ -f "$old_file" && ! -L "$old_file" ]]; then
            rm -f -- "$old_file"
        fi
    done < <(find "$log_dir" -maxdepth 1 -type f \
        -name 'auto-cleanup-*.log' \
        -mtime +"$retention_days" -print0 2>/dev/null)
}

# ============================================================================
# CONFIGURATION MANAGEMENT
# ============================================================================

# ----------------------------------------------------------------------------
# find_config - Discover configuration file from standard locations
# Returns:
#   Prints path to config file, returns 0 if found, 1 if not
# ----------------------------------------------------------------------------
find_config() {
    local locations=(
        "/etc/auto-cleanup/auto-cleanup.conf"
        "${SCRIPT_DIR}/../conf/auto-cleanup.conf"
        "${HOME}/.config/auto-cleanup/auto-cleanup.conf"
    )

    for loc in "${locations[@]}"; do
        if [[ -f "$loc" ]]; then
            echo "$loc"
            return 0
        fi
    done

    return 1
}

# ----------------------------------------------------------------------------
# load_config - Load configuration from file
# Arguments:
#   $1 - (optional) Config file path, auto-discovers if not provided
# Returns:
#   0 on success, 1 on failure
# ----------------------------------------------------------------------------
load_config() {
    local config_file="${1:-}"

    # Auto-discover if not provided
    if [[ -z "$config_file" ]]; then
        config_file="$(find_config)"
        if [[ -z "$config_file" ]]; then
            log_error "Configuration file not found in standard locations"
            return 1
        fi
    fi

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    # Source the config file
    # shellcheck disable=SC1090
    if ! source "$config_file"; then
        log_error "Failed to load config file: $config_file"
        return 1
    fi

    log_info "Loaded configuration from: $config_file"
    return 0
}

# ============================================================================
# FLAG NORMALIZATION
# ============================================================================

# ----------------------------------------------------------------------------
# norm_flag - Normalize boolean flag values to "true" or "false"
# Arguments:
#   $1 - Value to normalize (true/false/yes/no/1/0/t/f/y/n)
# Returns:
#   Prints "true" or "false"
# ----------------------------------------------------------------------------
norm_flag() {
    local value="${1:-false}"
    # Convert to lowercase and trim whitespace
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | xargs)"

    case "$value" in
        true|t|yes|y|1) echo "true" ;;
        *)              echo "false" ;;
    esac
}

# ============================================================================
# LOCKING MECHANISM
# ============================================================================
readonly LOCK_FILE="/var/run/auto-cleanup.lock"

# ----------------------------------------------------------------------------
# acquire_lock - Acquire exclusive lock using flock
# Returns:
#   0 on success (lock acquired), exits on failure
# ----------------------------------------------------------------------------
acquire_lock() {
    # Open file descriptor 200 for locking
    exec 200>"$LOCK_FILE"

    if ! flock -n 200; then
        log_error "Another instance is already running. Lock file: $LOCK_FILE"
        exit 1
    fi

    log_debug "Lock acquired: $LOCK_FILE"
}

# ----------------------------------------------------------------------------
# release_lock - Release the lock (called in cleanup trap)
# ----------------------------------------------------------------------------
release_lock() {
    # Close file descriptor to release lock
    exec 200>&- 2>/dev/null
    log_debug "Lock released"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# ----------------------------------------------------------------------------
# command_exists - Check if a command is available
# Arguments:
#   $1 - Command name to check
# Returns:
#   0 if command exists, 1 otherwise
# ----------------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# check_dependencies - Verify required commands are available
# Returns:
#   0 if all dependencies present, 1 otherwise
# ----------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    local deps=(kubectl date awk grep sed)

    for dep in "${deps[@]}"; do
        if ! command_exists "$dep"; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        return 1
    fi

    return 0
}

