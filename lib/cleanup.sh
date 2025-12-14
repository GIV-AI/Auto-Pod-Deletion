#!/bin/bash
# ============================================================================
# Auto-Cleanup - Cleanup Logic Module
# ============================================================================
# Core cleanup logic for evaluating resource age limits, managing pod deletion
# queue, and executing batch deletions. Handles hard/soft limit policies and
# keep-alive label checking.
#
# Author: Anubhav <anubhav.patrick@giindia.com>
# Organization: Global Infoventures
# Date: 2025-12-12
# ============================================================================

# Guard against double-sourcing
[[ -n "$_CLEANUP_SH_LOADED" ]] && return 0
readonly _CLEANUP_SH_LOADED=1

# Module version
readonly CLEANUP_VERSION="1.0.0"

# ============================================================================
# LIMIT FLAG STATE
# ============================================================================
# These flags are initialized from config via init_limit_flags().
# Not readonly because they're set dynamically after config is loaded.
#
# Hard limit: Always deletes when age exceeds limit (ignores keep-alive label).
# Soft limit: Respects keep-alive=true label; deletes only if not set/false.
DEPLOY_HARD_FLAG="false"
DEPLOY_SOFT_FLAG="false"
POD_HARD_FLAG="false"
POD_SOFT_FLAG="false"
SERVICE_HARD_FLAG="false"
SERVICE_SOFT_FLAG="false"

# Resource enable flags (derived from config + limit combinations)
is_deployment_enabled="false"
is_pod_enabled="false"
is_service_enabled="false"

# ============================================================================
# POD DELETION QUEUE
# ============================================================================
# `declare -a` creates an indexed array (0, 1, 2...).
# Pods are queued during processing and deleted in batches for efficiency.
# Format: "namespace/podname" (e.g., "dgx-s-user1/training-pod")
declare -a POD_DELETE_QUEUE=()

# Pod deletion behavior settings (with defaults).
# ${VAR:-default} syntax: Use VAR if set and non-empty, otherwise use default.
# These can be overridden by the config file.
POD_FORCE_DELETE="${POD_FORCE_DELETE:-false}"      # Use --grace-period=0 --force
POD_BACKGROUND_DELETE="${POD_BACKGROUND_DELETE:-true}"  # Run kubectl in background
POD_BATCH_SIZE="${POD_BATCH_SIZE:-50}"             # Pods per kubectl command

# ============================================================================
# INITIALIZATION
# ============================================================================

# ----------------------------------------------------------------------------
# init_limit_flags - Initialize limit flags from config values
# Description:
#   Normalizes boolean flags from config and determines which resource types
#   are enabled based on their hard/soft limit settings.
# ----------------------------------------------------------------------------
init_limit_flags() {
    # Normalize resource enable flags from config.
    # ${Deployment:-False} uses the Deployment config variable or "False" if unset.
    # norm_flag() converts various boolean representations to "true"/"false".
    local deployment_flag pod_flag service_flag
    deployment_flag="$(norm_flag "${Deployment:-False}")"
    pod_flag="$(norm_flag "${Pod:-False}")"
    service_flag="$(norm_flag "${Service:-False}")"

    # Normalize limit flags per resource type
    DEPLOY_HARD_FLAG="$(norm_flag "${Deployment_HardLimit:-False}")"
    DEPLOY_SOFT_FLAG="$(norm_flag "${Deployment_SoftLimit:-False}")"

    POD_HARD_FLAG="$(norm_flag "${Pod_HardLimit:-False}")"
    POD_SOFT_FLAG="$(norm_flag "${Pod_SoftLimit:-False}")"

    SERVICE_HARD_FLAG="$(norm_flag "${Service_HardLimit:-False}")"
    SERVICE_SOFT_FLAG="$(norm_flag "${Service_SoftLimit:-False}")"

    # If both hard & soft are disabled, disable the resource entirely.
    # This prevents unnecessary kubectl queries for resources with no active limits.
    if [[ "$DEPLOY_HARD_FLAG" == "false" && "$DEPLOY_SOFT_FLAG" == "false" ]]; then
        deployment_flag="false"
        log_info "Deployment hard & soft both disabled -> Deployment checks disabled"
    fi

    if [[ "$POD_HARD_FLAG" == "false" && "$POD_SOFT_FLAG" == "false" ]]; then
        pod_flag="false"
        log_info "Pod hard & soft both disabled -> Pod checks disabled"
    fi

    if [[ "$SERVICE_HARD_FLAG" == "false" && "$SERVICE_SOFT_FLAG" == "false" ]]; then
        service_flag="false"
        log_info "Service hard & soft both disabled -> Service checks disabled"
    fi

    # Set final enable state
    is_deployment_enabled="$deployment_flag"
    is_pod_enabled="$pod_flag"
    is_service_enabled="$service_flag"

    # Validate pod batch size is a positive integer.
    # grep -E = Extended regex, -q = Quiet mode (no output, just exit status).
    # ^[0-9]+$ = String containing only digits (positive integer).
    if ! printf '%s' "$POD_BATCH_SIZE" | grep -Eq '^[0-9]+$'; then
        POD_BATCH_SIZE=50
    fi
    # -le = Less than or equal (arithmetic comparison)
    if [[ "$POD_BATCH_SIZE" -le 0 ]]; then
        POD_BATCH_SIZE=50
    fi

    log_debug "Limit flags initialized: deploy=$is_deployment_enabled, pod=$is_pod_enabled, service=$is_service_enabled"
}

# ============================================================================
# CORE CLEANUP LOGIC
# ============================================================================

# ----------------------------------------------------------------------------
# cleanup_resource - Evaluate and clean up a single resource
# Arguments:
#   $1 - Resource kind (deployment, pod, service)
#   $2 - Resource age in minutes
#   $3 - Resource name
#   $4 - Namespace
#   $5 - Soft limit (minutes)
#   $6 - Hard limit (minutes)
# Description:
#   Evaluates a resource against hard and soft limits. For pods, queues them
#   for batch deletion. For other resources, deletes immediately.
#   Respects keep-alive=true label for soft limit violations.
# ----------------------------------------------------------------------------
cleanup_resource() {
    local kind="$1"
    local age="$2"
    local name="$3"
    local ns="$4"
    local soft="$5"
    local hard="$6"
    local hard_flag="false"
    local soft_flag="false"

    # Select flags for the resource kind
    case "$kind" in
        deployment)
            hard_flag="$DEPLOY_HARD_FLAG"
            soft_flag="$DEPLOY_SOFT_FLAG"
            ;;
        pod)
            hard_flag="$POD_HARD_FLAG"
            soft_flag="$POD_SOFT_FLAG"
            ;;
        service)
            hard_flag="$SERVICE_HARD_FLAG"
            soft_flag="$SERVICE_SOFT_FLAG"
            ;;
        *)
            return 0
            ;;
    esac

    # Check exclusions using is_resource_excluded from exclusions.sh
    if is_resource_excluded "$kind" "$name" "$ns"; then
        log_info "Skipping $kind $name ($ns) -> excluded"
        return 0
    fi

    # --- HARD LIMIT CHECK ---
    # Hard limit always deletes, ignoring keep-alive label
    if [[ "$hard_flag" == "true" && "$age" -ge "$hard" ]]; then
        if [[ "$kind" == "pod" ]]; then
            # Queue pod for batched deletion
            POD_DELETE_QUEUE+=("$ns/$name")
            log_info "Pod $name ($ns) queued for HARD deletion (age=${age}m >= ${hard}m)"
            echo "Pod $name ($ns): HARD delete queued"
        else
            log_info "Hard limit: deleting $kind $name ($ns) (age=${age}m >= ${hard}m)"
            echo "Deleting $kind $name ($ns) via HARD limit"
            delete_resource "$kind" "$name" "$ns"
        fi
        return 0
    fi

    # --- SOFT LIMIT CHECK ---
    # Soft limit respects keep-alive=true label
    if [[ "$soft_flag" == "true" && "$age" -ge "$soft" ]]; then
        log_info "Soft limit reached for $kind $name ($ns) (age=${age}m >= ${soft}m) -> Checking keep-alive"
        echo "$kind $name ($ns): soft limit reached, evaluating keep-alive"

        # Get keep-alive label value from Kubernetes resource metadata.
        # tr '[:upper:]' '[:lower:]' converts to lowercase for case-insensitive compare.
        local keep_alive keep_lc
        keep_alive="$(get_keep_alive_label "$kind" "$name" "$ns")"
        keep_lc="$(printf '%s' "$keep_alive" | tr '[:upper:]' '[:lower:]')"

        # Delete if keep-alive is not explicitly "true".
        # Conditions checked: empty, "false", or anything other than "true".
        # This means missing label = delete, "false" = delete, "TRUE" = keep.
        if [[ -z "$keep_lc" || "$keep_lc" == "false" || "$keep_lc" != "true" ]]; then
            if [[ "$kind" == "pod" ]]; then
                POD_DELETE_QUEUE+=("$ns/$name")
                log_info "Pod $name ($ns) queued for SOFT deletion (keep-alive='$keep_alive')"
                echo "Pod $name ($ns): SOFT delete queued (keep-alive='$keep_alive')"
            else
                log_info "Soft limit: deleting $kind $name ($ns) (keep-alive='$keep_alive')"
                echo "Deleting $kind $name ($ns) via SOFT path"
                delete_resource "$kind" "$name" "$ns"
            fi
        else
            # keep-alive=true - skip deletion
            log_info "keep-alive=true for $kind $name ($ns) -> skipping deletion"
            echo "$kind $name ($ns): keep-alive=true -> keeping"
        fi
        return 0
    fi

    # No deletion needed - resource is within limits
    log_debug "$kind $name ($ns): age=${age}m within limits (soft=${soft}m, hard=${hard}m)"
    return 0
}

# ============================================================================
# POD QUEUE MANAGEMENT
# ============================================================================

# ----------------------------------------------------------------------------
# flush_pod_queue - Process and delete all queued pods in batches
# Description:
#   Groups queued pods by namespace and deletes them in configurable batch
#   sizes. Supports force delete and background execution modes.
# ----------------------------------------------------------------------------
flush_pod_queue() {
    # ${#array[@]} returns the number of elements in the array.
    local queue_size="${#POD_DELETE_QUEUE[@]}"
    log_info "Flushing Pod deletion queue ($queue_size pods)..."

    if [[ $queue_size -eq 0 ]]; then
        log_info "No pods queued for deletion"
        return 0
    fi

    # Group pods by namespace using associative array (hash/dictionary).
    # `declare -A` creates an associative array with string keys.
    # This allows efficient grouping: PODS_BY_NS["dgx-s-user1"]="pod1 pod2"
    declare -A PODS_BY_NS=()

    for item in "${POD_DELETE_QUEUE[@]:-}"; do
        # Skip empty entries (:-} provides empty default if array is unset)
        [[ -z "$item" ]] && continue

        # Parse "namespace/podname" format using parameter expansion.
        # ${item%%/*} = Remove longest match of /* from end (keeps namespace).
        # ${item##*/} = Remove longest match of */ from start (keeps podname).
        # Example: "dgx-s-user1/train-pod" → ns="dgx-s-user1", pod="train-pod"
        local ns="${item%%/*}"
        local pod="${item##*/}"

        # Skip malformed entries (e.g., missing / separator)
        [[ -z "$ns" || -z "$pod" ]] && continue

        # Append pod to namespace group (space-separated list).
        # ${PODS_BY_NS[$ns]:-} returns empty string if key doesn't exist.
        if [[ -z "${PODS_BY_NS[$ns]:-}" ]]; then
            PODS_BY_NS["$ns"]="$pod"
        else
            PODS_BY_NS["$ns"]="${PODS_BY_NS[$ns]} $pod"
        fi
    done

    # Process each namespace.
    # ${!array[@]} returns all keys of an associative array.
    for ns in "${!PODS_BY_NS[@]}"; do
        # Convert space-separated list to array.
        # `read -r -a array` reads words into array elements.
        #   -r = Don't interpret backslashes as escapes.
        #   -a = Read into indexed array.
        # <<< "string" is a here-string (feeds string as stdin to command).
        local -a pods_in_ns
        read -r -a pods_in_ns <<< "${PODS_BY_NS[$ns]}"
        local total="${#pods_in_ns[@]}"
        local idx=0

        # Process pods in batches of POD_BATCH_SIZE.
        # -lt = Less than (arithmetic comparison).
        while [[ "$idx" -lt "$total" ]]; do
            # Build a batch up to POD_BATCH_SIZE pods
            local -a batch=()
            local count=0

            while [[ "$idx" -lt "$total" && "$count" -lt "$POD_BATCH_SIZE" ]]; do
                batch+=("${pods_in_ns[$idx]}")
                # $(( )) is arithmetic expansion for integer math.
                idx=$((idx + 1))
                count=$((count + 1))
            done

            # Build kubectl command as array (safe for special characters).
            local -a cmd=(kubectl delete pod)
            cmd+=("${batch[@]}")
            cmd+=(-n "$ns")

            if [[ "$POD_FORCE_DELETE" == "true" ]]; then
                # --grace-period=0 --force = Immediate termination without graceful shutdown.
                cmd+=(--grace-period=0 --force)
            fi

            # ${batch[*]} expands array elements as single string (space-separated).
            log_info "Deleting pods in batch (namespace=$ns): ${batch[*]} (force=$POD_FORCE_DELETE background=$POD_BACKGROUND_DELETE)"

            # Execute deletion
            if [[ "$POD_BACKGROUND_DELETE" == "true" ]]; then
                # `nohup` runs command immune to hangup signals (SIGHUP).
                # Prevents kubectl from terminating if parent shell exits.
                # & at end runs command in background (non-blocking).
                # Output redirected to LOG_FILE to capture any errors.
                nohup "${cmd[@]}" >> "$LOG_FILE" 2>&1 &
            else
                # Run synchronously (blocking) - wait for kubectl to complete.
                # || is OR - runs log_error only if kubectl returns non-zero.
                "${cmd[@]}" >> "$LOG_FILE" 2>&1 || \
                    log_error "kubectl delete returned non-zero for pods (${batch[*]}) in ns=$ns"
            fi
        done
    done

    # Clear the queue
    POD_DELETE_QUEUE=()
    log_info "Pod deletion queue flushed"
}

# ============================================================================
# RESOURCE PROCESSING FUNCTIONS
# ============================================================================

# ----------------------------------------------------------------------------
# process_deployments - Scan and clean up deployments
# Description:
#   Iterates through all deployments in dgx-* namespaces and evaluates them
#   against configured limits.
# ----------------------------------------------------------------------------
process_deployments() {
    if [[ "$is_deployment_enabled" != "true" ]]; then
        log_info "Deployment checks disabled by config"
        return 0
    fi

    log_info "Starting Deployment cleanup..."

    # Read output from get_deployments line by line.
    # `read -r ns name _` reads whitespace-separated fields into variables.
    #   -r = Don't interpret backslashes as escapes.
    #   _ = Discard remaining fields (age column, unused here).
    # < <(cmd) is process substitution (avoids subshell variable scope issues).
    while read -r ns name _; do
        # Skip empty lines or malformed input
        [[ -z "$ns" || -z "$name" ]] && continue

        local age_min limits soft hard
        age_min="$(get_age_minutes deployment "$name" "$ns")"
        limits="$(get_limits_for_namespace "$ns")"

        # Skip if limits unavailable (namespace doesn't match dgx-s/f/i OR config missing)
        [[ -z "$limits" ]] && continue

        # <<< is a here-string: "soft hard" becomes stdin for read.
        read -r soft hard <<< "$limits"
        cleanup_resource "deployment" "$age_min" "$name" "$ns" "$soft" "$hard"

    done < <(get_deployments)

    log_info "Deployment cleanup completed"
}

# ----------------------------------------------------------------------------
# process_pods - Scan and queue standalone pods for cleanup
# Description:
#   Iterates through all pods in dgx-* namespaces, filtering to only
#   standalone pods (no owner references), and evaluates them against limits.
# ----------------------------------------------------------------------------
process_pods() {
    if [[ "$is_pod_enabled" != "true" ]]; then
        log_info "Pod checks disabled by config"
        return 0
    fi

    log_info "Starting Pod scan & queueing..."

    # Process pods line by line from get_pods output.
    # Pods are queued (not deleted immediately) for batch processing.
    while read -r ns name _; do
        [[ -z "$ns" || -z "$name" ]] && continue

        # Apply exclusion filters early to avoid unnecessary kubectl calls.
        # Check order: namespace first (cheaper), then specific pod name.
        if is_namespace_excluded "$ns"; then
            log_debug "Skipping pod $name ($ns) -> namespace excluded"
            continue
        fi

        if is_pod_excluded "$name"; then
            log_debug "Skipping pod $name ($ns) -> explicitly excluded"
            continue
        fi

        # Only process standalone pods (no owner references).
        # Managed pods (from Deployments, Jobs, etc.) are handled by their controllers.
        # `!` negates the return value: continue if pod IS managed.
        if ! is_standalone_pod "$name" "$ns"; then
            continue
        fi

        local age_min limits soft hard
        age_min="$(get_age_minutes pod "$name" "$ns")"
        limits="$(get_limits_for_namespace "$ns")"

        # Skip if limits unavailable (namespace doesn't match dgx-s/f/i OR config missing)
        [[ -z "$limits" ]] && continue

        read -r soft hard <<< "$limits"
        cleanup_resource "pod" "$age_min" "$name" "$ns" "$soft" "$hard"

    done < <(get_pods)

    log_info "Pod scan completed"
}

# ----------------------------------------------------------------------------
# process_services - Scan and clean up services
# Description:
#   Iterates through all services in dgx-* namespaces and evaluates them
#   against configured limits.
# ----------------------------------------------------------------------------
process_services() {
    if [[ "$is_service_enabled" != "true" ]]; then
        log_info "Service checks disabled by config"
        return 0
    fi

    log_info "Starting Service cleanup..."

    # Services are deleted immediately (not batched like pods).
    # Services are independent of pods/deployments and can be cleaned up anytime.
    while read -r ns name _; do
        [[ -z "$ns" || -z "$name" ]] && continue

        local age_min limits soft hard
        age_min="$(get_age_minutes service "$name" "$ns")"
        limits="$(get_limits_for_namespace "$ns")"

        # Skip if limits unavailable (namespace doesn't match dgx-s/f/i OR config missing)
        [[ -z "$limits" ]] && continue

        read -r soft hard <<< "$limits"
        cleanup_resource "service" "$age_min" "$name" "$ns" "$soft" "$hard"

    done < <(get_services)

    log_info "Service cleanup completed"
}

