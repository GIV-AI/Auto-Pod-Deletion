#!/bin/bash
# ============================================================================
# Auto-Cleanup - Kubernetes Module
# ============================================================================
# Provides kubectl wrappers and Kubernetes-specific utility functions for
# resource age calculation and namespace pattern matching.
#
# Author: Anubhav <anubhav.patrick@giindia.com>
# Organization: Global Infoventures
# Date: 2025-12-12
# ============================================================================

# Guard against double-sourcing
[[ -n "$_KUBERNETES_SH_LOADED" ]] && return 0
readonly _KUBERNETES_SH_LOADED=1

# Module version
readonly KUBERNETES_VERSION="2.0.0"

# ============================================================================
# NAMESPACE PATTERN MATCHING
# ============================================================================
# Namespace prefixes for user-type routing
readonly NS_STUDENT_PREFIX="dgx-s"
readonly NS_FACULTY_PREFIX="dgx-f"
readonly NS_INDUSTRY_PREFIX="dgx-i"

# ----------------------------------------------------------------------------
# get_user_type - Determine user type from namespace prefix
# Arguments:
#   $1 - Namespace name
# Returns:
#   Prints user type (student, faculty, industry) or empty if no match
# ----------------------------------------------------------------------------
get_user_type() {
    local ns="$1"

    if [[ "$ns" == ${NS_STUDENT_PREFIX}* ]]; then
        echo "student"
    elif [[ "$ns" == ${NS_FACULTY_PREFIX}* ]]; then
        echo "faculty"
    elif [[ "$ns" == ${NS_INDUSTRY_PREFIX}* ]]; then
        echo "industry"
    else
        echo ""
    fi
}

# ----------------------------------------------------------------------------
# get_limits_for_namespace - Get soft/hard limits based on namespace
# Arguments:
#   $1 - Namespace name
# Returns:
#   Prints "soft hard" values or empty if namespace doesn't match patterns
# Description:
#   Returns the appropriate time limits (in minutes) based on the namespace
#   prefix. Uses global config variables STUDENT_SOFT/HARD, etc.
# ----------------------------------------------------------------------------
get_limits_for_namespace() {
    local ns="$1"
    local user_type
    user_type="$(get_user_type "$ns")"

    case "$user_type" in
        student)
            echo "${STUDENT_SOFT:-60} ${STUDENT_HARD:-1440}"
            ;;
        faculty)
            echo "${FACULTY_SOFT:-120} ${FACULTY_HARD:-2880}"
            ;;
        industry)
            echo "${INDUSTRY_SOFT:-60} ${INDUSTRY_HARD:-1440}"
            ;;
        *)
            # Namespace doesn't match any pattern
            echo ""
            ;;
    esac
}

# ============================================================================
# AGE CALCULATION
# ============================================================================

# ----------------------------------------------------------------------------
# get_age_minutes - Calculate resource age in minutes
# Arguments:
#   $1 - Resource kind (deployment, pod, service)
#   $2 - Resource name
#   $3 - Namespace
# Returns:
#   Prints age in minutes (0 if unable to calculate)
# ----------------------------------------------------------------------------
get_age_minutes() {
    local kind="$1"
    local name="$2"
    local ns="$3"
    local creation_ts created_epoch now_epoch diff

    # Get creation timestamp from Kubernetes
    creation_ts="$(kubectl get "$kind" "$name" -n "$ns" \
        -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")"

    if [[ -z "$creation_ts" ]]; then
        echo 0
        return 0
    fi

    # Convert ISO timestamp to epoch seconds
    created_epoch="$(date -d "$creation_ts" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"

    if [[ "$created_epoch" -le 0 ]]; then
        echo 0
        return 0
    fi

    # Calculate difference in minutes
    diff=$(( (now_epoch - created_epoch) / 60 ))
    echo "$diff"
}

# ============================================================================
# KUBECTL WRAPPERS
# ============================================================================

# ----------------------------------------------------------------------------
# get_deployments - List deployments matching namespace pattern
# Arguments:
#   $1 - (optional) Namespace pattern regex (default: ^dgx-)
# Returns:
#   Prints "namespace name age" for each matching deployment
# ----------------------------------------------------------------------------
get_deployments() {
    local ns_pattern="${1:-^dgx-}"

    kubectl get deploy -A --no-headers 2>/dev/null | \
        awk -v pattern="$ns_pattern" '$1 ~ pattern {print $1, $2, $6}'
}

# ----------------------------------------------------------------------------
# get_pods - List pods matching namespace pattern
# Arguments:
#   $1 - (optional) Namespace pattern regex (default: ^dgx-)
# Returns:
#   Prints "namespace name age" for each matching pod
# ----------------------------------------------------------------------------
get_pods() {
    local ns_pattern="${1:-^dgx-}"

    kubectl get pods -A --no-headers 2>/dev/null | \
        awk -v pattern="$ns_pattern" '$1 ~ pattern {print $1, $2, $5}'
}

# ----------------------------------------------------------------------------
# get_services - List services matching namespace pattern
# Arguments:
#   $1 - (optional) Namespace pattern regex (default: ^dgx-)
# Returns:
#   Prints "namespace name age" for each matching service
# ----------------------------------------------------------------------------
get_services() {
    local ns_pattern="${1:-^dgx-}"

    kubectl get svc -A --no-headers 2>/dev/null | \
        awk -v pattern="$ns_pattern" '$1 ~ pattern {print $1, $2, $5}'
}

# ----------------------------------------------------------------------------
# is_standalone_pod - Check if pod has no owner references (standalone)
# Arguments:
#   $1 - Pod name
#   $2 - Namespace
# Returns:
#   0 if standalone (no owner), 1 if managed by controller
# Description:
#   Standalone pods are those not managed by Deployments, ReplicaSets, Jobs,
#   DaemonSets, etc. These are typically manually created pods.
# ----------------------------------------------------------------------------
is_standalone_pod() {
    local name="$1"
    local ns="$2"
    local owner

    owner="$(kubectl get pod "$name" -n "$ns" \
        -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null || echo "")"

    # Empty owner references means standalone pod
    [[ -z "$owner" ]]
}

# ----------------------------------------------------------------------------
# get_keep_alive_label - Get keep-alive label value from resource
# Arguments:
#   $1 - Resource kind
#   $2 - Resource name
#   $3 - Namespace
# Returns:
#   Prints label value (empty if not set)
# ----------------------------------------------------------------------------
get_keep_alive_label() {
    local kind="$1"
    local name="$2"
    local ns="$3"

    kubectl get "$kind" "$name" -n "$ns" \
        -o jsonpath='{.metadata.labels.keep-alive}' 2>/dev/null || echo ""
}

# ----------------------------------------------------------------------------
# delete_resource - Delete a Kubernetes resource
# Arguments:
#   $1 - Resource kind
#   $2 - Resource name
#   $3 - Namespace
#   $4 - (optional) Additional kubectl flags
# Returns:
#   0 on success, 1 on failure
# ----------------------------------------------------------------------------
delete_resource() {
    local kind="$1"
    local name="$2"
    local ns="$3"
    shift 3
    local extra_flags=("$@")

    log_info "Deleting $kind $name in namespace $ns"

    if kubectl delete "$kind" "$name" -n "$ns" "${extra_flags[@]}" >> "$LOG_FILE" 2>&1; then
        log_info "Successfully deleted $kind $name ($ns)"
        return 0
    else
        log_error "Failed to delete $kind $name ($ns)"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# delete_pods_batch - Delete multiple pods in a single namespace
# Arguments:
#   $1 - Namespace
#   $2 - Force delete flag (true/false)
#   $@ - Pod names (remaining arguments)
# Returns:
#   0 on success, 1 on failure
# ----------------------------------------------------------------------------
delete_pods_batch() {
    local ns="$1"
    local force="$2"
    shift 2
    local -a pods=("$@")

    local -a cmd=(kubectl delete pod)
    cmd+=("${pods[@]}")
    cmd+=(-n "$ns")

    if [[ "$force" == "true" ]]; then
        cmd+=(--grace-period=0 --force)
    fi

    log_info "Batch deleting ${#pods[@]} pods in namespace $ns (force=$force)"

    if "${cmd[@]}" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        log_error "Batch delete failed for pods in namespace $ns"
        return 1
    fi
}

