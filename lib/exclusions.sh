#!/bin/bash
# ============================================================================
# Auto-Cleanup - Exclusions Module
# ============================================================================
# Handles loading and checking exclusion lists for namespaces, deployments,
# pods, and services. Supports comments and whitespace in exclusion files.
#
# Author: Anubhav <anubhav.patrick@giindia.com>
# Organization: Global Infoventures
# Date: 2025-12-12
# ============================================================================

# Guard against double-sourcing
[[ -n "$_EXCLUSIONS_SH_LOADED" ]] && return 0
readonly _EXCLUSIONS_SH_LOADED=1

# Module version
readonly EXCLUSIONS_VERSION="2.0.0"

# ============================================================================
# EXCLUSION LIST STORAGE
# ============================================================================
# Global arrays to store exclusion lists
declare -a EX_NS=()
declare -a EX_DEPLOY=()
declare -a EX_POD=()
declare -a EX_SVC=()

# ============================================================================
# EXCLUSION FILE PATHS
# ============================================================================
# These are set after config is loaded, defaulting to conf directory

# ----------------------------------------------------------------------------
# init_exclusion_paths - Initialize paths to exclusion files
# Arguments:
#   $1 - Base directory containing exclusion files
# ----------------------------------------------------------------------------
init_exclusion_paths() {
    local base_dir="${1:-}"

    if [[ -z "$base_dir" ]]; then
        # Try standard locations
        if [[ -d "/etc/auto-cleanup" ]]; then
            base_dir="/etc/auto-cleanup"
        elif [[ -n "$SCRIPT_DIR" && -d "${SCRIPT_DIR}/../conf" ]]; then
            base_dir="${SCRIPT_DIR}/../conf"
        fi
    fi

    EX_NS_FILE="${base_dir}/exclude_namespaces.txt"
    EX_DEPLOY_FILE="${base_dir}/exclude_deployments.txt"
    EX_POD_FILE="${base_dir}/exclude_pods.txt"
    EX_SVC_FILE="${base_dir}/exclude_services.txt"
}

# ============================================================================
# LIST LOADING FUNCTIONS
# ============================================================================

# ----------------------------------------------------------------------------
# load_list - Load exclusion list from file into array
# Arguments:
#   $1 - File path to read from
#   $2 - Name of output array variable
# Description:
#   Reads a file line by line, stripping comments (# ...) and whitespace.
#   Empty lines are skipped. Results are stored in the named array.
# ----------------------------------------------------------------------------
load_list() {
    local file="$1"
    local out_var="$2"
    local line
    local -a arr=()

    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Strip comments (everything after #)
            line="${line%%#*}"
            # Trim leading and trailing whitespace
            line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            # Skip empty lines
            [[ -z "$line" ]] && continue
            arr+=("$line")
        done < "$file"
    fi

    # Use eval to assign array to named variable
    # shellcheck disable=SC2086
    eval "$out_var=(\"\${arr[@]}\")"
}

# ----------------------------------------------------------------------------
# load_all_exclusions - Load all exclusion lists from configured paths
# Returns:
#   Logs count of loaded exclusions
# ----------------------------------------------------------------------------
load_all_exclusions() {
    # Reset arrays
    EX_NS=()
    EX_DEPLOY=()
    EX_POD=()
    EX_SVC=()

    # Load each exclusion file
    load_list "$EX_NS_FILE" EX_NS
    load_list "$EX_DEPLOY_FILE" EX_DEPLOY
    load_list "$EX_POD_FILE" EX_POD
    load_list "$EX_SVC_FILE" EX_SVC

    log_info "Loaded exclusions: namespaces=${#EX_NS[@]}, deployments=${#EX_DEPLOY[@]}, pods=${#EX_POD[@]}, services=${#EX_SVC[@]}"
}

# ============================================================================
# LIST CHECKING FUNCTIONS
# ============================================================================

# ----------------------------------------------------------------------------
# in_list - Check if a value exists in a list
# Arguments:
#   $1 - Value to search for
#   $@ - List elements to search in (remaining arguments)
# Returns:
#   0 if value is found in list, 1 otherwise
# Example:
#   if in_list "my-ns" "${EX_NS[@]}"; then echo "excluded"; fi
# ----------------------------------------------------------------------------
in_list() {
    local value="$1"
    shift
    local item

    for item in "$@"; do
        if [[ "$item" == "$value" ]]; then
            return 0
        fi
    done

    return 1
}

# ----------------------------------------------------------------------------
# is_namespace_excluded - Check if namespace is in exclusion list
# Arguments:
#   $1 - Namespace name to check
# Returns:
#   0 if excluded, 1 otherwise
# ----------------------------------------------------------------------------
is_namespace_excluded() {
    local ns="$1"
    in_list "$ns" "${EX_NS[@]:-}"
}

# ----------------------------------------------------------------------------
# is_deployment_excluded - Check if deployment is in exclusion list
# Arguments:
#   $1 - Deployment name to check
# Returns:
#   0 if excluded, 1 otherwise
# ----------------------------------------------------------------------------
is_deployment_excluded() {
    local name="$1"
    in_list "$name" "${EX_DEPLOY[@]:-}"
}

# ----------------------------------------------------------------------------
# is_pod_excluded - Check if pod is in exclusion list
# Arguments:
#   $1 - Pod name to check
# Returns:
#   0 if excluded, 1 otherwise
# ----------------------------------------------------------------------------
is_pod_excluded() {
    local name="$1"
    in_list "$name" "${EX_POD[@]:-}"
}

# ----------------------------------------------------------------------------
# is_service_excluded - Check if service is in exclusion list
# Arguments:
#   $1 - Service name to check
# Returns:
#   0 if excluded, 1 otherwise
# ----------------------------------------------------------------------------
is_service_excluded() {
    local name="$1"
    in_list "$name" "${EX_SVC[@]:-}"
}

# ----------------------------------------------------------------------------
# is_resource_excluded - Generic exclusion check for any resource type
# Arguments:
#   $1 - Resource kind (deployment, pod, service)
#   $2 - Resource name
#   $3 - Namespace
# Returns:
#   0 if excluded (by namespace or name), 1 otherwise
# ----------------------------------------------------------------------------
is_resource_excluded() {
    local kind="$1"
    local name="$2"
    local ns="$3"

    # Check namespace exclusion first
    if is_namespace_excluded "$ns"; then
        log_debug "Skipping $kind $name in namespace $ns -> namespace excluded"
        return 0
    fi

    # Check resource-specific exclusion
    case "$kind" in
        deployment)
            if is_deployment_excluded "$name"; then
                log_debug "Skipping deployment $name ($ns) -> explicitly excluded"
                return 0
            fi
            ;;
        pod)
            if is_pod_excluded "$name"; then
                log_debug "Skipping pod $name ($ns) -> explicitly excluded"
                return 0
            fi
            ;;
        service)
            if is_service_excluded "$name"; then
                log_debug "Skipping service $name ($ns) -> explicitly excluded"
                return 0
            fi
            ;;
    esac

    return 1
}

