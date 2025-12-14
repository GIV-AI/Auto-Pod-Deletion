#!/bin/bash
# ============================================================================
# Auto-Cleanup - Installation Script
# ============================================================================
# Installs the Auto-Cleanup tool to standard system locations.
#
# Installation paths:
#   /opt/auto-cleanup/bin/       - Executable
#   /opt/auto-cleanup/lib/       - Library modules
#   /etc/auto-cleanup/           - Configuration files
#   /var/log/giindia/auto-cleanup/ - Log directory
#   /usr/local/bin/auto-cleanup  - Symlink for easy access
#
# Usage:
#   sudo ./install.sh
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

# ============================================================================
# SCRIPT DIRECTORY
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Safe file copy (rejects symlinks)
safe_copy() {
    local src="$1"
    local dest="$2"

    if [[ -f "$src" && ! -L "$src" ]]; then
        cp -f -- "$src" "$dest"
        return 0
    else
        log_error "Source file not found or is a symlink: $src"
        return 1
    fi
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

# Check for root privileges
if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check for required source files
required_files=(
    "bin/auto-cleanup"
    "lib/common.sh"
    "lib/exclusions.sh"
    "lib/kubernetes.sh"
    "lib/cleanup.sh"
    "conf/auto-cleanup.conf"
)

for file in "${required_files[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${file}" ]]; then
        log_error "Required file not found: ${file}"
        log_error "Please run install.sh from the project root directory"
        exit 1
    fi
done

# ============================================================================
# INSTALLATION
# ============================================================================

log_info "Installing Auto-Cleanup..."

# --- CREATE DIRECTORIES ---
log_info "Creating directories..."

# Save current umask and set restrictive permissions
OLD_UMASK=$(umask)
umask 027

# Create installation directories
mkdir -p "${INSTALL_DIR}/bin"
mkdir -p "${INSTALL_DIR}/lib"
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"

# Restore umask
umask "$OLD_UMASK"

# Set directory permissions
chmod 750 "$INSTALL_DIR"
chmod 750 "${INSTALL_DIR}/bin"
chmod 750 "${INSTALL_DIR}/lib"
chmod 750 "$CONFIG_DIR"
chmod 750 "$LOG_DIR"

# Set ownership
chown root:root "$INSTALL_DIR" "${INSTALL_DIR}/bin" "${INSTALL_DIR}/lib"
chown root:root "$CONFIG_DIR"
chown root:root "$LOG_DIR"

# --- INSTALL EXECUTABLES ---
log_info "Installing executables..."

safe_copy "${SCRIPT_DIR}/bin/auto-cleanup" "${INSTALL_DIR}/bin/auto-cleanup"
chmod 700 "${INSTALL_DIR}/bin/auto-cleanup"
chown root:root "${INSTALL_DIR}/bin/auto-cleanup"

# --- INSTALL LIBRARIES ---
log_info "Installing library modules..."

for lib in common.sh exclusions.sh kubernetes.sh cleanup.sh; do
    safe_copy "${SCRIPT_DIR}/lib/${lib}" "${INSTALL_DIR}/lib/${lib}"
    chmod 600 "${INSTALL_DIR}/lib/${lib}"
    chown root:root "${INSTALL_DIR}/lib/${lib}"
done

# --- INSTALL CONFIGURATION ---
log_info "Installing configuration..."

# Check if config already exists (preserve during upgrades)
if [[ -f "${CONFIG_DIR}/auto-cleanup.conf" ]]; then
    log_warning "Configuration file exists, preserving it"
    safe_copy "${SCRIPT_DIR}/conf/auto-cleanup.conf" "${CONFIG_DIR}/auto-cleanup.conf.new"
    chmod 640 "${CONFIG_DIR}/auto-cleanup.conf.new"
    chown root:root "${CONFIG_DIR}/auto-cleanup.conf.new"
    log_info "New configuration template saved as auto-cleanup.conf.new"
else
    safe_copy "${SCRIPT_DIR}/conf/auto-cleanup.conf" "${CONFIG_DIR}/auto-cleanup.conf"
    chmod 640 "${CONFIG_DIR}/auto-cleanup.conf"
    chown root:root "${CONFIG_DIR}/auto-cleanup.conf"
fi

# Install exclusion files (always copy, they're just templates)
for exclude_file in exclude_namespaces exclude_deployments exclude_pods exclude_services; do
    if [[ -f "${CONFIG_DIR}/${exclude_file}" ]]; then
        log_warning "Exclusion file exists: ${exclude_file} (keeping existing)"
    else
        safe_copy "${SCRIPT_DIR}/conf/${exclude_file}" "${CONFIG_DIR}/${exclude_file}"
        chmod 640 "${CONFIG_DIR}/${exclude_file}"
        chown root:root "${CONFIG_DIR}/${exclude_file}"
    fi
done

# --- CREATE SYMLINK ---
log_info "Creating symlink..."

# Remove existing symlink if present
if [[ -L "$SYMLINK_PATH" ]]; then
    rm -f "$SYMLINK_PATH"
fi

# Create new symlink
ln -sf "${INSTALL_DIR}/bin/auto-cleanup" "$SYMLINK_PATH"

# ============================================================================
# VERIFICATION
# ============================================================================
log_info "Verifying installation..."

if [[ -x "${INSTALL_DIR}/bin/auto-cleanup" ]]; then
    log_info "Executable: OK"
else
    log_error "Executable not found or not executable"
    exit 1
fi

if [[ -L "$SYMLINK_PATH" ]]; then
    log_info "Symlink: OK"
else
    log_error "Symlink not created"
    exit 1
fi

# ============================================================================
# POST-INSTALL INFO
# ============================================================================
echo ""
echo "=============================================="
echo "Auto-Cleanup installed successfully!"
echo "=============================================="
echo ""
echo "Installation locations:"
echo "  Executable:    ${INSTALL_DIR}/bin/auto-cleanup"
echo "  Libraries:     ${INSTALL_DIR}/lib/"
echo "  Configuration: ${CONFIG_DIR}/"
echo "  Logs:          ${LOG_DIR}/"
echo "  Command:       ${SYMLINK_PATH}"
echo ""
echo "Quick start:"
echo "  1. Edit configuration: sudo nano ${CONFIG_DIR}/auto-cleanup.conf"
echo "  2. Add exclusions:     sudo nano ${CONFIG_DIR}/exclude_namespaces"
echo "  3. Run manually:       sudo auto-cleanup"
echo "  4. Check logs:         ls -la ${LOG_DIR}/"
echo ""
echo "Cron setup (hourly cleanup):"
echo "  echo '0 * * * * root /usr/local/bin/auto-cleanup' | sudo tee /etc/cron.d/auto-cleanup"
echo ""

