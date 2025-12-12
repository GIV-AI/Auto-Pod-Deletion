#!/bin/bash
# ============================================================================
# Auto-Cleanup - Uninstallation Script
# ============================================================================
# Removes the Auto-Cleanup tool from the system.
#
# Usage:
#   sudo ./uninstall.sh [OPTIONS]
#
# Options:
#   --keep-config   Keep configuration files in /etc/auto-cleanup/
#   --keep-logs     Keep log files in /var/log/giindia/auto-cleanup/
#   --purge         Remove everything including config and logs (default)
#   -y, --yes       Non-interactive mode (assume yes to all prompts)
#
# Author: Anubhav <anubhav.patrick@giindia.com>
# Organization: Global Infoventures
# Date: 2025-12-12
# ============================================================================

set -e

# ============================================================================
# INSTALLATION PATHS
# ============================================================================
readonly INSTALL_DIR="/opt/auto-cleanup"
readonly CONFIG_DIR="/etc/auto-cleanup"
readonly LOG_DIR="/var/log/giindia/auto-cleanup"
readonly SYMLINK_PATH="/usr/local/bin/auto-cleanup"
readonly LOCK_FILE="/var/run/auto-cleanup.lock"
readonly CRON_FILE="/etc/cron.d/auto-cleanup"

# ============================================================================
# OPTIONS
# ============================================================================
KEEP_CONFIG=false
KEEP_LOGS=false
NON_INTERACTIVE=false

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
log_info() {
    echo "[INFO] $1"
}

log_warning() {
    echo "[WARNING] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

# Safe directory removal (rejects symlinks)
safe_remove_dir() {
    local target="$1"

    if [[ ! -e "$target" ]]; then
        log_info "Directory does not exist: $target"
        return 0
    fi

    if [[ -L "$target" ]]; then
        log_error "Refusing to remove symlink: $target"
        return 1
    fi

    if [[ ! -d "$target" ]]; then
        log_error "Not a directory: $target"
        return 1
    fi

    rm -rf -- "$target"
    log_info "Removed: $target"
}

# Prompt for confirmation (respects non-interactive mode)
prompt_yes_no() {
    local prompt="$1"
    local default="${2:-no}"
    local response

    # Non-interactive mode: return default
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ "$default" == "yes" ]] && return 0 || return 1
    fi

    # Check if running in terminal
    if [[ ! -t 0 ]]; then
        [[ "$default" == "yes" ]] && return 0 || return 1
    fi

    while true; do
        read -r -p "$prompt [y/N]: " response
        case "${response,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-config)
            KEEP_CONFIG=true
            shift
            ;;
        --keep-logs)
            KEEP_LOGS=true
            shift
            ;;
        --purge)
            KEEP_CONFIG=false
            KEEP_LOGS=false
            shift
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep-config   Keep configuration files"
            echo "  --keep-logs     Keep log files"
            echo "  --purge         Remove everything (default)"
            echo "  -y, --yes       Non-interactive mode"
            echo "  -h, --help      Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

# Check for root privileges
if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if anything is installed
if [[ ! -d "$INSTALL_DIR" && ! -d "$CONFIG_DIR" && ! -L "$SYMLINK_PATH" ]]; then
    log_info "Auto-Cleanup does not appear to be installed"
    exit 0
fi

# ============================================================================
# CONFIRMATION
# ============================================================================
echo ""
echo "This will remove Auto-Cleanup from your system."
echo ""
echo "Components to remove:"
echo "  - Application: $INSTALL_DIR"
[[ "$KEEP_CONFIG" == "false" ]] && echo "  - Configuration: $CONFIG_DIR"
[[ "$KEEP_LOGS" == "false" ]] && echo "  - Logs: $LOG_DIR"
echo "  - Symlink: $SYMLINK_PATH"
echo "  - Cron job: $CRON_FILE (if exists)"
echo ""

if ! prompt_yes_no "Continue with uninstallation?"; then
    log_info "Uninstallation cancelled"
    exit 0
fi

# ============================================================================
# UNINSTALLATION
# ============================================================================

log_info "Uninstalling Auto-Cleanup..."

# --- REMOVE CRON JOB ---
if [[ -f "$CRON_FILE" ]]; then
    log_info "Removing cron job..."
    rm -f -- "$CRON_FILE"
fi

# --- REMOVE SYMLINK ---
if [[ -L "$SYMLINK_PATH" ]]; then
    log_info "Removing symlink..."
    rm -f -- "$SYMLINK_PATH"
fi

# --- REMOVE LOCK FILE ---
if [[ -f "$LOCK_FILE" ]]; then
    log_info "Removing lock file..."
    rm -f -- "$LOCK_FILE"
fi

# --- REMOVE APPLICATION ---
if [[ -d "$INSTALL_DIR" ]]; then
    log_info "Removing application directory..."
    safe_remove_dir "$INSTALL_DIR"
fi

# --- REMOVE CONFIGURATION (if not keeping) ---
if [[ "$KEEP_CONFIG" == "false" ]]; then
    if [[ -d "$CONFIG_DIR" ]]; then
        if prompt_yes_no "Remove configuration directory ($CONFIG_DIR)?"; then
            safe_remove_dir "$CONFIG_DIR"
        else
            log_info "Keeping configuration directory"
        fi
    fi
else
    log_info "Keeping configuration directory (--keep-config)"
fi

# --- REMOVE LOGS (if not keeping) ---
if [[ "$KEEP_LOGS" == "false" ]]; then
    if [[ -d "$LOG_DIR" ]]; then
        if prompt_yes_no "Remove log directory ($LOG_DIR)?"; then
            safe_remove_dir "$LOG_DIR"
        else
            log_info "Keeping log directory"
        fi
    fi
else
    log_info "Keeping log directory (--keep-logs)"
fi

# ============================================================================
# POST-UNINSTALL INFO
# ============================================================================
echo ""
echo "=============================================="
echo "Auto-Cleanup uninstalled successfully!"
echo "=============================================="
echo ""

if [[ "$KEEP_CONFIG" == "true" || "$KEEP_LOGS" == "true" ]]; then
    echo "Preserved directories:"
    [[ "$KEEP_CONFIG" == "true" && -d "$CONFIG_DIR" ]] && echo "  - Configuration: $CONFIG_DIR"
    [[ "$KEEP_LOGS" == "true" && -d "$LOG_DIR" ]] && echo "  - Logs: $LOG_DIR"
    echo ""
fi

log_info "Uninstallation complete"

