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
readonly KUBERNETES_VERSION="1.0.0"

# ============================================================================
# NAMESPACE PATTERN MATCHING
# ============================================================================
# Namespace prefixes for user-type routing.
# Multi-tenant DGX clusters use naming conventions:
#   dgx-s-<username> = Student namespace
#   dgx-f-<username> = Faculty namespace
#   dgx-i-<company>  = Industry/partner namespace
readonly NS_STUDENT_PREFIX="dgx-s"
readonly NS_FACULTY_PREFIX="dgx-f"
readonly NS_INDUSTRY_PREFIX="dgx-i"

# ----------------------------------------------------------------------------
# get_user_type - Determine user type from namespace prefix
# Arguments:
#   $1 - Namespace name
# Returns:
#   Prints user type (student, faculty, industry) or empty if no match
# Description:
#   Routes cleanup policies based on namespace naming convention.
#   Different user types may have different soft/hard time limits.
# ----------------------------------------------------------------------------
get_user_type() {
    local ns="$1"

    # Pattern matching: ${VAR}* means "VAR followed by anything".
    # [[ "$ns" == prefix* ]] is Bash glob matching (not regex).
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
#   Prints "soft hard" values (in minutes) or empty if namespace doesn't match
# Description:
#   Returns the appropriate time limits (in minutes) based on the namespace
#   prefix. Uses global config variables STUDENT_SOFT/HARD, etc.
#   Config values support suffixes: M (minutes), H (hours). No suffix = minutes.
#   Examples: "30" = 30 min, "30M" = 30 min, "2H" = 120 min
# ----------------------------------------------------------------------------
get_limits_for_namespace() {
    local ns="$1"
    local user_type soft_val hard_val
    user_type="$(get_user_type "$ns")"

    case "$user_type" in
        student)
            if ! soft_val="$(parse_time_to_minutes "${STUDENT_SOFT:-60}")"; then
                log_error "Invalid STUDENT_SOFT configuration: ${STUDENT_SOFT}"
                exit 1
            fi
            if ! hard_val="$(parse_time_to_minutes "${STUDENT_HARD:-1440}")"; then
                log_error "Invalid STUDENT_HARD configuration: ${STUDENT_HARD}"
                exit 1
            fi
            echo "$soft_val $hard_val"
            ;;
        faculty)
            if ! soft_val="$(parse_time_to_minutes "${FACULTY_SOFT:-120}")"; then
                log_error "Invalid FACULTY_SOFT configuration: ${FACULTY_SOFT}"
                exit 1
            fi
            if ! hard_val="$(parse_time_to_minutes "${FACULTY_HARD:-2880}")"; then
                log_error "Invalid FACULTY_HARD configuration: ${FACULTY_HARD}"
                exit 1
            fi
            echo "$soft_val $hard_val"
            ;;
        industry)
            if ! soft_val="$(parse_time_to_minutes "${INDUSTRY_SOFT:-60}")"; then
                log_error "Invalid INDUSTRY_SOFT configuration: ${INDUSTRY_SOFT}"
                exit 1
            fi
            if ! hard_val="$(parse_time_to_minutes "${INDUSTRY_HARD:-1440}")"; then
                log_error "Invalid INDUSTRY_HARD configuration: ${INDUSTRY_HARD}"
                exit 1
            fi
            echo "$soft_val $hard_val"
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
# Description:
#   Queries all deployments across namespaces and filters by namespace pattern.
# ----------------------------------------------------------------------------
get_deployments() {
    local ns_pattern="${1:-^dgx-}"

    # kubectl options explained:
    #   get deploy    = List deployment resources
    #   -A            = All namespaces (--all-namespaces short form)
    #   --no-headers  = Omit column headers (cleaner for parsing)
    #   2>/dev/null   = Suppress stderr (e.g., cluster connection errors)
    #
    # awk options explained:
    #   -v pattern="$ns_pattern"  = Pass shell variable to awk
    #   $1 ~ pattern              = Field 1 (namespace) matches regex pattern
    #   {print $1, $2, $6}        = Output: namespace, name, age
    kubectl get deploy -A --no-headers 2>/dev/null | \
        awk -v pattern="$ns_pattern" '$1 ~ pattern {print $1, $2, $6}'
}

# ----------------------------------------------------------------------------
# get_pods - List pods matching namespace pattern
# Arguments:
#   $1 - (optional) Namespace pattern regex (default: ^dgx-)
# Returns:
#   Prints "namespace name age" for each matching pod
# Description:
#   Queries all pods across namespaces and filters by namespace pattern.
#   Note: Pod age is in column 5 (vs column 6 for deployments).
# ----------------------------------------------------------------------------
get_pods() {
    local ns_pattern="${1:-^dgx-}"

    # kubectl get pods output columns: NAMESPACE NAME READY STATUS RESTARTS AGE
    # $5 = AGE column (differs from deployments due to extra columns)
    kubectl get pods -A --no-headers 2>/dev/null | \
        awk -v pattern="$ns_pattern" '$1 ~ pattern {print $1, $2, $5}'
}

# ----------------------------------------------------------------------------
# get_services - List services matching namespace pattern
# Arguments:
#   $1 - (optional) Namespace pattern regex (default: ^dgx-)
# Returns:
#   Prints "namespace name age" for each matching service
# Description:
#   Queries all services across namespaces and filters by namespace pattern.
# ----------------------------------------------------------------------------
get_services() {
    local ns_pattern="${1:-^dgx-}"

    # kubectl get svc output columns: NAMESPACE NAME TYPE CLUSTER-IP ... AGE
    # $5 = AGE column
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
#   DaemonSets, etc. These are typically manually created pods via `kubectl run`.
#   We only clean up standalone pods because managed pods are handled by their
#   controllers (deleting a Deployment automatically deletes its pods).
# ----------------------------------------------------------------------------
is_standalone_pod() {
    local name="$1"
    local ns="$2"
    local owner

    # -o jsonpath extracts specific fields from the JSON response.
    # .metadata.ownerReferences is an array of owner resources.
    # Empty array [] or missing field = standalone pod.
    owner="$(kubectl get pod "$name" -n "$ns" \
        -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null || echo "")"

    # [[ -z "$owner" ]] returns 0 (true) if owner is empty string.
    # Empty owner references means standalone pod (created directly, not by controller).
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
#   $1 - Resource kind (deployment, pod, service)
#   $2 - Resource name
#   $3 - Namespace
#   $@ - (optional) Additional kubectl flags after shift 3
# Returns:
#   0 on success, 1 on failure
# Side effects:
#   - Appends kubectl output to LOG_FILE
#   - Logs success/failure messages
# ----------------------------------------------------------------------------
delete_resource() {
    local kind="$1"
    local name="$2"
    local ns="$3"
    # `shift 3` removes the first 3 positional parameters ($1, $2, $3).
    # After shift, $@ contains any remaining arguments (extra flags).
    shift 3
    local extra_flags=("$@")

    log_info "Deleting $kind $name in namespace $ns"

    # >> appends stdout to LOG_FILE, 2>&1 redirects stderr to stdout.
    # This captures kubectl output and errors in the log file.
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
#   $@ - Pod names (remaining arguments after shift 2)
# Returns:
#   0 on success, 1 on failure
# Description:
#   Efficiently deletes multiple pods with a single kubectl command.
#   Supports force deletion for pods stuck in Terminating state.
# ----------------------------------------------------------------------------
delete_pods_batch() {
    local ns="$1"
    local force="$2"
    shift 2
    # `local -a` declares a local indexed array.
    # $@ after shift contains all remaining arguments (pod names).
    local -a pods=("$@")

    # Build command as an array to safely handle spaces in names.
    # Arrays preserve word boundaries without quoting issues.
    local -a cmd=(kubectl delete pod)
    cmd+=("${pods[@]}")
    cmd+=(-n "$ns")

    if [[ "$force" == "true" ]]; then
        # --grace-period=0 = Skip graceful shutdown, terminate immediately.
        # --force = Required with grace-period=0 for immediate deletion.
        # Use case: Stuck pods in Terminating state that won't respond to SIGTERM.
        cmd+=(--grace-period=0 --force)
    fi

    log_info "Batch deleting ${#pods[@]} pods in namespace $ns (force=$force)"

    # "${cmd[@]}" expands array elements as separate words (safe execution).
    if "${cmd[@]}" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        log_error "Batch delete failed for pods in namespace $ns"
        return 1
    fi
}

