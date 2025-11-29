#!/bin/bash
# cleanup_merged_configurable.sh - Merged cleanup for Deployments then Pods (with Service deletion)
# New: behavior controlled via cleanup_config.env flags:
#   Deployment=Yes|No, Pod=Yes|No
#   Deployment_HardLimit=Yes|No, Deployment_SoftLimit=Yes|No
#   Pod_HardLimit=Yes|No, Pod_SoftLimit=Yes|No

set -u

echo "Auto Cleanup (Deployments -> Pods) started..."

# ---------- CONFIG ----------
CONFIG_FILE="./cleanup_config.env"
if [[ -f "$CONFIG_FILE" ]]; then

# shellcheck disable=SC1090

  source "$CONFIG_FILE"
else
  echo "Config file $CONFIG_FILE not found!" >&2
  exit 1
fi

LOG_FILE="${LOG_FILE:-/var/log/giindia/auto_cleanup_logs/auto_cleanup.log}"
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# ---------- Normalise and interpret flags ----------
# Helper: normalize Yes/No to lower 'yes' or 'no', default no if unset
norm_flag() {
  local v="${1:-No}"
  v=$(echo "$v" | tr '[:upper:]' '[:lower:]' | xargs)
  if [[ "$v" == "yes" || "$v" == "y" ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

DEPLOYMENT_FLAG=$(norm_flag "${Deployment:-No}")
POD_FLAG=$(norm_flag "${Pod:-No}")

DEPLOY_HARD_FLAG=$(norm_flag "${Deployment_HardLimit:-No}")
DEPLOY_SOFT_FLAG=$(norm_flag "${Deployment_SoftLimit:-No}")

POD_HARD_FLAG=$(norm_flag "${Pod_HardLimit:-No}")
POD_SOFT_FLAG=$(norm_flag "${Pod_SoftLimit:-No}")

# If both hard & soft are no -> treat resource as disabled regardless of main flag
if [[ "$DEPLOY_HARD_FLAG" == "no" && "$DEPLOY_SOFT_FLAG" == "no" ]]; then
  DEPLOYMENT_FLAG="no"
  log "Deployment hard & soft both disabled in config -> Deployment checks disabled."
fi

if [[ "$POD_HARD_FLAG" == "no" && "$POD_SOFT_FLAG" == "no" ]]; then
  POD_FLAG="no"
  log "Pod hard & soft both disabled in config -> Pod checks disabled."
fi

# Convert 'yes'/'no' flags to bash booleans for easier checks
is_deployment_enabled=false
is_pod_enabled=false
deploy_hard_enabled=false
deploy_soft_enabled=false
pod_hard_enabled=false
pod_soft_enabled=false

[[ "$DEPLOYMENT_FLAG" == "yes" ]] && is_deployment_enabled=true
[[ "$POD_FLAG" == "yes" ]] && is_pod_enabled=true
[[ "$DEPLOY_HARD_FLAG" == "yes" ]] && deploy_hard_enabled=true
[[ "$DEPLOY_SOFT_FLAG" == "yes" ]] && deploy_soft_enabled=true
[[ "$POD_HARD_FLAG" == "yes" ]] && pod_hard_enabled=true
[[ "$POD_SOFT_FLAG" == "yes" ]] && pod_soft_enabled=true

log "Config summary: Deployment enabled=${is_deployment_enabled}, DeployHard=${deploy_hard_enabled}, DeploySoft=${deploy_soft_enabled}; Pod enabled=${is_pod_enabled}, PodHard=${pod_hard_enabled}, PodSoft=${pod_soft_enabled}"


# ---------- DEPLOYMENT CLEANUP ----------
cleanup_deployment() {
  local age=$1; local name=$2; local ns=$3; local soft=$4; local hard=$5

  # HARD branch (only if enabled)
  if $deploy_hard_enabled && (( age > hard )); then
    log "Deployment $name ($ns): age ${age}m >= hard limit ${hard}m -> deleting (hard limit)"
    echo "Deployment $name ($ns): HARD delete triggered"
    kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) on hard limit"
    return
  fi

  # SOFT branch (only if enabled)
  if $deploy_soft_enabled && (( age > soft )); then
    log "Deployment $name ($ns): age ${age}m >= soft limit ${soft}m -> Evaluating keep-alive"
    echo "Deployment $name ($ns): Evaluating keep-alive"

    keep_alive_label=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.metadata.labels.keep-alive}' 2>/dev/null || echo "")
    if [[ -z "$keep_alive_label" ]]; then
      log "Deployment $name ($ns): keep-alive label NOT present -> deleting (soft path)"
      echo "Deployment $name ($ns): keep-alive label NOT present -> deleting (soft path)"
      kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) (no keep-alive)"
      return
    fi

    keep_alive_label_lower=$(echo "$keep_alive_label" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_alive_label_lower" == "false" ]]; then
      log "Deployment $name ($ns): keep-alive=false -> deleting (soft path)"
      echo "Deployment $name ($ns): keep-alive=false -> deleting (soft path)"
      kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) (keep-alive=false)"
      return
    fi

    if [[ "$keep_alive_label_lower" != "true" ]]; then
      log "Deployment $name ($ns): INVALID keep-alive='$keep_alive_label' -> deleting (soft path)"
      echo "Deployment $name ($ns): INVALID keep-alive='$keep_alive_label' -> deleting (soft path)"
      kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) (invalid keep-alive)"
      return
     fi

     if [[ "$keep_alive_label_lower" = "true" ]]; then
      log "Deployment $name ($ns): 'Keep Alive' tag present -> keeping deployment"
      echo "Deployment $name ($ns): 'Keep Alive' tag present -> keeping deployment"
      return
     fi
  fi

  # If neither hard nor soft path triggered or they were disabled:
  log "Deployment $name ($ns): age ${age}m did not trigger enabled checks -> safe/untouched"
}

# ---------- POD CLEANUP ----------
cleanup_pod() {
  local age=$1; local name=$2; local ns=$3; local soft=$4; local hard=$5

  if $pod_hard_enabled && (( age > hard )); then
    log "Pod $name ($ns): age ${age}m >= hard limit ${hard}m -> deleting (hard limit)"
    echo "Pod $name ($ns): HARD delete triggered"
    kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) on hard limit"
    return
  fi

  if $pod_soft_enabled && (( age > soft )); then
    log "Pod $name ($ns): age ${age}m >= soft limit ${soft}m -> evaluating keep-alive label"
    echo "Pod $name ($ns): Evaluating keep-alive label"

    keep_alive_label=$(kubectl get pod "$name" -n "$ns" -o jsonpath='{.metadata.labels.keep-alive}' 2>/dev/null || echo "")
    if [[ -z "$keep_alive_label" ]]; then
      log "Pod $name ($ns): keep-alive label NOT present -> deleting (soft path)"
      kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) (no keep-alive)"
      return
    fi

    keep_alive_label_lower=$(echo "$keep_alive_label" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_alive_label_lower" == "false" ]]; then
      log "Pod $name ($ns): keep-alive=false -> deleting (soft path)"
      kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) (keep-alive=false)"
      return
    fi

    if [[ "$keep_alive_label_lower" != "true" ]]; then
      log "Pod $name ($ns): keep-alive label value='$keep_alive_label' is not 'true' -> deleting (soft path)"
      kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) (invalid keep-alive)"
      return
    fi

    if [[ "$keep_alive_label_lower" = "true" ]]; then
      log "Pod $name ($ns): 'Keep Alive' tag present -> keeping pod"
      echo "Pod $name ($ns): 'Keep Alive' tag present -> keeping pod"
      return
    fi
    return
  fi

  log "Pod $name ($ns): age ${age}m did not trigger enabled checks -> safe/untouched"
}

# ---------- MAIN: Deployments first (only if enabled) ----------
if $is_deployment_enabled; then
  mapfile -t deployments < <(kubectl get deploy -A --no-headers 2>/dev/null | awk '/^dgx-/ {print $1, $2, $6}')
  for entry in "${deployments[@]:-}"; do
    namespace=$(echo "$entry" | awk '{print $1}')
    deployname=$(echo "$entry" | awk '{print $2}')
    age_str=$(echo "$entry" | awk '{print $3}')
    age_min=0
    if [[ $age_str =~ ([0-9]+)d ]]; then age_min=$((age_min + ${BASH_REMATCH[1]} * 1440)); fi
    if [[ $age_str =~ ([0-9]+)h ]]; then age_min=$((age_min + ${BASH_REMATCH[1]} * 60)); fi
    if [[ $age_str =~ ([0-9]+)m ]]; then age_min=$((age_min + ${BASH_REMATCH[1]})); fi
    if [[ $age_str =~ ([0-9]+)s ]]; then secs=${BASH_REMATCH[1]}; (( secs>0 )) && age_min=$((age_min+1)); fi

    if [[ $namespace == dgx-s* ]]; then
      soft_limit=$STUDENT_SOFT; hard_limit=$STUDENT_HARD
    elif [[ $namespace == dgx-f* ]] || [[ $namespace == dgx-i* ]]; then
      soft_limit=$FACULTY_SOFT; hard_limit=$FACULTY_HARD
    else
      continue
    fi

    cleanup_deployment "$age_min" "$deployname" "$namespace" "$soft_limit" "$hard_limit"
  done
else
  log "Deployment checks disabled by config -> skipping all deployments."
fi

# ---------- Then Pods (only if enabled) ----------
if $is_pod_enabled; then

  mapfile -t pods < <(
  kubectl get pods -A --no-headers \
  | awk '/^dgx-/ {print $1, $2}' \
  | while read ns name; do

      # Check if pod has an owner
      owner=$(kubectl get pod "$name" -n "$ns" -o jsonpath='{.metadata.ownerReferences}')

      # Skip non-standalone pods
      if [[ -n "$owner" ]]; then
        continue
      fi

      # Extract status and age using jsonpath
      status=$(kubectl get pod "$name" -n "$ns" -o jsonpath='{.status.phase}')
      age=$(kubectl get pod "$name" -n "$ns" -o jsonpath='{.metadata.creationTimestamp}')

      # Convert ISO timestamp → human-readable AGE (same as kubectl)
      # Call kubectl again for formatted AGE (fast, reliable)
      age_str=$(kubectl get pod "$name" -n "$ns" --no-headers | awk '{print $5}')

      # Store final line directly in pods array
      echo "$ns $name $status $age_str"

    done
  )

  for entry in "${pods[@]:-}"; do
    namespace=$(echo "$entry" | awk '{print $1}')
    podname=$(echo "$entry" | awk '{print $2}')
    state=$(echo "$entry" | awk '{print $3}')
    age_str=$(echo "$entry" | awk '{print $4}')
    age_min=0
    if [[ $age_str =~ ([0-9]+)d ]]; then age_min=$((age_min + ${BASH_REMATCH[1]} * 1440)); fi
    if [[ $age_str =~ ([0-9]+)h ]]; then age_min=$((age_min + ${BASH_REMATCH[1]} * 60)); fi
    if [[ $age_str =~ ([0-9]+)m ]]; then age_min=$((age_min + ${BASH_REMATCH[1]})); fi
    if [[ $age_str =~ ([0-9]+)s ]]; then secs=${BASH_REMATCH[1]}; (( secs>0 )) && age_min=$((age_min+1)); fi

    if [[ $namespace == dgx-s* ]]; then
      soft_limit=$STUDENT_SOFT; hard_limit=$STUDENT_HARD
    elif [[ $namespace == dgx-f* ]] || [[ $namespace == dgx-i* ]]; then
      soft_limit=$FACULTY_SOFT; hard_limit=$FACULTY_HARD
    else
      continue
    fi

    cleanup_pod "$age_min" "$podname" "$namespace" "$soft_limit" "$hard_limit"
  done
else
  log "Pod checks disabled by config -> skipping all pods."
fi

# ---------- FINAL STEP: ORPHAN SERVICE SWEEP (with soft/hard age checks) ----------
log "Starting orphan-service sweep with soft/hard age checks."

# ---------- Helper: age calculation using creationTimestamp ----------
get_age_minutes() {
  local resource=$1; local name=$2; local ns=$3
  creation_ts=$(kubectl get "$resource" "$name" -n "$ns" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
  if [[ -z "$creation_ts" ]]; then
    echo "-1"
    return
  fi
  created_epoch=$(date -d "$creation_ts" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  if [[ "$created_epoch" -le 0 ]]; then
    echo "-1"
    return
  fi
  echo $(( (now_epoch - created_epoch) / 60 ))
}


# Get namespaces that start with dgx-
mapfile -t target_namespaces < <(
  kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/^dgx-/'
)

for ns in "${target_namespaces[@]:-}"; do
  log "Scanning services in namespace $ns"

  # Fetch services and endpoints for namespace (single-shot)
  svc_json=$(kubectl get svc -n "$ns" -o json 2>/dev/null)
  endpoints_json=$(kubectl get endpoints -n "$ns" -o json 2>/dev/null)

  if [[ -z "$svc_json" ]]; then
    log "No services found or failed to fetch services in $ns"
    continue
  fi

  # Get list of service names
  mapfile -t svc_names < <(echo "$svc_json" | jq -r '.items[] | .metadata.name' 2>/dev/null || echo "")

  for svc in "${svc_names[@]:-}"; do
    # Skip headless services (clusterIP == "None")
    cluster_ip=$(echo "$svc_json" | jq -r --arg s "$svc" '.items[] | select(.metadata.name==$s) | .spec.clusterIP // empty' 2>/dev/null || echo "")
    if [[ "$cluster_ip" == "None" ]]; then
      log "Service $svc ($ns) is headless (clusterIP=None) -> skipping"
      continue
    fi

    # Compute service age (minutes) using existing helper
    age_min=$(get_age_minutes "service" "$svc" "$ns")
    if [[ "$age_min" == "-1" ]]; then
      log "No Service found inside the namespcae: ($ns): Nothing to delete"
         # If we cannot get age, be conservative and skip deletion
      continue
    fi

    # Determine policy limits based on namespace prefix
    if [[ $ns == dgx-s* ]]; then
      soft_limit="$STUDENT_SOFT"
      hard_limit="$STUDENT_HARD"
    elif [[ $ns == dgx-f* ]] || [[ $ns == dgx-i* ]]; then
      soft_limit="$FACULTY_SOFT"
      hard_limit="$FACULTY_HARD"
    else
      # Not a target namespace (shouldn't happen because we filtered), skip
      continue
    fi

    log "Service $svc ($ns): age=${age_min}m soft=${soft_limit}m hard=${hard_limit}m"

    # If hard limit breached -> delete immediately (regardless of endpoints)
    if (( age_min >= hard_limit )); then
      log "Service $svc ($ns): age ${age_min}m >= hard limit ${hard_limit}m -> deleting (hard limit)"
      kubectl delete svc "$svc" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete service $svc ($ns) on hard limit"
      continue
    fi

    # If soft limit not breached -> keep (give user time)
    if (( age_min < soft_limit )); then
      log "Service $svc ($ns): age ${age_min}m < soft limit ${soft_limit}m -> keeping"
      continue
    fi

    # At this point: soft <= age < hard -> check endpoints
    svc_ips=$(echo "$endpoints_json" | jq -r --arg s "$svc" '
      .items[] | select(.metadata.name==$s) | ( ([.subsets[]?.addresses[]?.ip] // []) | join(",") )
    ' 2>/dev/null || echo "")

    if [[ -z "$svc_ips" ]]; then
      log "Service $svc ($ns): age ${age_min}m >= soft ${soft_limit}m AND NO endpoints -> deleting (soft path)"
      kubectl delete svc "$svc" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete service $svc ($ns) on soft-no-endpoints"
    else
      log "Service $svc ($ns): age ${age_min}m >= soft ${soft_limit}m BUT endpoints present (${svc_ips}) -> keeping"
    fi
  done
done

log "Orphan-service sweep (with age checks) completed."


echo "Auto Cleanup completed."
