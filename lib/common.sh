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
# -n is a test to check if the variable is not empty
[[ -n "$_COMMON_SH_LOADED" ]] && return 0
readonly _COMMON_SH_LOADED=1

# Module version (used by show_version() in main script)
# shellcheck disable=SC2034
readonly COMMON_VERSION="1.0.0"

# ============================================================================
# COLOR CONSTANTS (Terminal Detection)
# ============================================================================
# [[ -t 1 ]] tests if file descriptor 1 (stdout) is connected to a terminal.
# Returns true for interactive shells, false for cron jobs, pipes, or redirects.
# This prevents ANSI escape codes from polluting log files or non-terminal output.
#
# $'\033[...' is Bash ANSI-C quoting for escape sequences.
# \033 = ESC character, [...m = SGR (Select Graphic Rendition) codes.
if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'      # Red text
    readonly GREEN=$'\033[0;32m'    # Green text
    readonly YELLOW=$'\033[1;33m'   # Bold yellow text
    readonly BLUE=$'\033[0;34m'     # Blue text
    readonly CYAN=$'\033[0;36m'     # Cyan text
    readonly NC=$'\033[0m'          # No Color (reset)
    readonly BOLD=$'\033[1m'        # Bold text
else
    # Non-interactive (cron, pipe, redirect) - disable colors
    # shellcheck disable=SC2034  # Color variables defined for consistency
    readonly RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC="" BOLD=""
fi

# ============================================================================
# LOGGING SYSTEM
# ============================================================================
# Log levels with numeric values for comparison.
# `declare -A` creates an associative array (hash/dictionary).
# Keys are log level names, values are numeric priorities for filtering.
# Higher numbers = more severe = always shown; lower numbers = verbose.
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

    # Skip if level is below configured threshold.
    # ${LOG_LEVELS[$level]:-1} = Get numeric value for level, default to 1 if not found.
    # Messages are logged only if their level >= configured threshold.
    if [[ ${LOG_LEVELS[$level]:-1} -ge ${LOG_LEVELS[$configured_level]:-1} ]]; then
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        local log_entry="[$timestamp] [$level] $message"

        # Write to log file if available and not too large.
        # -w = Check if directory is writable (for log rotation safety).
        if [[ -n "$LOG_FILE" && -w "$(dirname "$LOG_FILE" 2>/dev/null)" ]]; then
            local file_size
            # `stat -c %s` outputs only the file size in bytes (-c = format, %s = size).
            # 2>/dev/null suppresses "file not found" errors for new log files.
            file_size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
            if [[ $file_size -lt ${MAX_LOG_SIZE:-10485760} ]]; then
                echo "$log_entry" >> "$LOG_FILE"
            else
                # Write a "log full" message only once to avoid repeated writes.
                # Only check the last line (O(1)) instead of searching entire file (O(n)).
                local log_full_msg="LOG FILE FULL - Maximum size reached, no further logs will be written"
                if [[ "$(tail -1 "$LOG_FILE" 2>/dev/null)" != *"$log_full_msg"* ]]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $log_full_msg" >> "$LOG_FILE"
                fi
            fi
        fi

        # Also output to terminal based on level (primarily for interactive use).
        # In cron: output goes to mail (if configured) or is silently discarded.
        # Primary logging is via $LOG_FILE above; this is supplementary feedback.
        # >&2 redirects to stderr (separates errors from normal output in pipelines).
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
# Uses $LOG_DIR from configuration (no parameter override for security).
# Returns:
#   0 on success, 1 on failure
# ----------------------------------------------------------------------------
init_logging() {
    [[ -z "$LOG_DIR" ]] && {
        echo "ERROR: LOG_DIR not set in configuration" >&2
        return 1
    }

    local log_dir="$LOG_DIR"

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
# Description:
#   Safely removes day-wise log files older than LOG_RETENTION_DAYS.
#   Uses null-separated output to handle filenames with spaces/special chars.
# ----------------------------------------------------------------------------
cleanup_old_logs() {
    local log_dir="$1"
    local retention_days="${LOG_RETENTION_DAYS:-30}"

    [[ -z "$log_dir" || ! -d "$log_dir" ]] && return 1

    # Find and remove day-wise logs older than retention period.
    # Pattern: auto-cleanup-YYYY-MM-DD.log
    #
    # `find` options explained:
    #   -maxdepth 1   = Don't recurse into subdirectories
    #   -type f       = Only regular files (not directories or symlinks)
    #   -name '...'   = Match filename pattern (glob, not regex)
    #   -mtime +N     = Modified more than N days ago (+ means "greater than")
    #   -print0       = Output null-separated paths (see note below)
    #
    # `read` options explained:
    #   IFS=          = Don't split on whitespace (preserve full path)
    #   -r            = Don't interpret backslashes as escapes
    #   -d ''         = Use null byte as delimiter (see note below)
    #
    # < <(cmd) is process substitution: treats command output as a file.
    # This avoids subshell issues with `cmd | while read` (variables lost).
    #
    # NULL DELIMITER PAIRING (-print0 + read -d ''):
    #   The find command's -print0 outputs filenames separated by null bytes (\0)
    #   instead of newlines. The read command's -d '' reads until a null byte.
    #   These MUST be used together. Why null bytes?
    #   - Null is the ONLY character that cannot appear in Unix filenames
    #   - Newlines, spaces, tabs, quotes CAN appear in filenames
    #   - Without this pairing, a file named "log 2024.log" would be split
    #     into two separate reads ("log" and "2024.log"), causing errors
    while IFS= read -r -d '' old_file; do
        # -f = Is regular file, ! -L = Is not a symlink (extra safety)
        # -- after rm prevents filenames starting with - being parsed as options
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
# Description:
#   Searches for config file in order of precedence:
#   1. /etc/auto-cleanup/ (system-wide, for production installs)
#   2. ../conf/ relative to script (for development/testing)
# ----------------------------------------------------------------------------
find_config() {
    local locations=(
        "/etc/auto-cleanup/auto-cleanup.conf"
        "${SCRIPT_DIR}/../conf/auto-cleanup.conf"
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
    local config_file="${1:-}" # May be empty, will be auto-discovered

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
# Description:
#   Handles various boolean representations from config files or user input.
#   Case-insensitive: "True", "TRUE", "true" all normalize to "true".
# ----------------------------------------------------------------------------
norm_flag() {
    local value="${1:-false}"
    # `tr '[:upper:]' '[:lower:]'` converts all uppercase chars to lowercase.
    # `xargs` with no arguments trims leading/trailing whitespace.
    # `printf '%s'` is used instead of echo to avoid issues with special chars
    # (echo interprets -n, -e flags and backslashes inconsistently).
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | xargs)"

    case "$value" in
        true|t|yes|y|1) echo "true" ;;
        *)              echo "false" ;;
    esac
}

# ============================================================================
# LOCKING MECHANISM
# ============================================================================
# Prevents concurrent execution using flock(1) file locking.
# This is critical for cron jobs that may overlap if a previous run is slow.
readonly LOCK_FILE="/var/run/auto-cleanup.lock"

# ----------------------------------------------------------------------------
# acquire_lock - Acquire exclusive lock using flock
# Returns:
#   0 on success (lock acquired), exits with 1 on failure
# Description:
#   Uses a file descriptor-based lock that persists for the script's lifetime
#   and auto-releases on process exit (even crashes), preventing stale locks.
# ----------------------------------------------------------------------------
acquire_lock() {
    # `exec N>file` opens file on file descriptor N for writing.
    # FD 200 is chosen as a high number to avoid conflicts with:
    #   0 = stdin, 1 = stdout, 2 = stderr, 3-9 often used by shells.
    # Using exec (not a subshell) keeps the FD open for the script's lifetime.
    exec 200>"$LOCK_FILE"

    # `flock` is a file locking utility from util-linux.
    #   -n = Non-blocking: fail immediately if lock is held by another process.
    #   200 = File descriptor number to lock (must match exec above).
    # Without -n, flock would block (wait) until the lock is available.
    if ! flock -n 200; then
        log_error "Another instance is already running. Lock file: $LOCK_FILE"
        exit 1
    fi

    log_debug "Lock acquired: $LOCK_FILE"
}

# ----------------------------------------------------------------------------
# release_lock - Release the lock (called in cleanup trap)
# Description:
#   Closes the file descriptor, which automatically releases the flock.
#   Safe to call multiple times (2>/dev/null suppresses "bad FD" errors).
# ----------------------------------------------------------------------------
release_lock() {
    # `exec N>&-` closes file descriptor N.
    # Closing the FD automatically releases the flock advisory lock.
    # 2>/dev/null suppresses errors if FD is already closed.
    exec 200>&- 2>/dev/null
    log_debug "Lock released"
}

# ============================================================================
# TIME PARSING
# ============================================================================

# ----------------------------------------------------------------------------
# parse_time_to_minutes - Convert time value with suffix to minutes
# Arguments:
#   $1 - Time value with optional suffix (e.g., "30", "30M", "2H", "7D")
# Returns:
#   Prints time value in minutes; returns 1 on invalid input
# Description:
#   Parses time values that may include a suffix:
#     - No suffix or M/m = Minutes (e.g., "30" or "30M" = 30 minutes)
#     - H/h = Hours (e.g., "2H" = 120 minutes)
#     - D/d = Days (e.g., "7D" = 10080 minutes)
#   Case-insensitive. Invalid values (no numeric part) cause error exit.
# ----------------------------------------------------------------------------
parse_time_to_minutes() {
    local input="${1:-0}"
    local value suffix
    
    # Remove leading/trailing whitespace
    # xargs utility is used to trim whitespace and ensure consistent input.
    input="$(printf '%s' "$input" | xargs)"
    
    # If empty or just whitespace, fail with error
    if [[ -z "$input" ]]; then
        log_error "Invalid time value: empty or whitespace-only input"
        return 1
    fi
    
    # Extract numeric value and suffix using parameter expansion.
    # ${input//[^0-9]/} removes all non-digit characters (keeps only digits).
    # ${input//[0-9]/} removes all digits (keeps only suffix).
    value="${input//[^0-9]/}"
    suffix="${input//[0-9]/}"
    
    # Convert suffix to uppercase for case-insensitive comparison
    suffix="$(printf '%s' "$suffix" | tr '[:lower:]' '[:upper:]')"
    
    # If no numeric value found, fail with error
    if [[ -z "$value" ]]; then
        log_error "Invalid time value '$input': no numeric value found"
        return 1
    fi
    
    # Convert based on suffix
    case "$suffix" in
        D)
            # Days to minutes
            echo $((value * 1440))
            ;;
        H)
            # Hours to minutes
            echo $((value * 60))
            ;;
        M|"")
            # Minutes (explicit M or no suffix)
            echo "$value"
            ;;
        *)
            # Unknown suffix - treat as minutes, log warning
            log_warning "Unknown time suffix '$suffix' in '$input', treating as minutes"
            echo "$value"
            ;;
    esac
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
    # -v flag checks if command exists in PATH.
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# check_dependencies - Verify required commands are available
# Returns:
#   0 if all dependencies present, 1 otherwise
# ----------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    local deps=(kubectl date awk grep sed flock timeout)

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

