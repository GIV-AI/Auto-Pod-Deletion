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

LOG_FILE="${LOG_FILE:-/var/log/auto_cleanup.log}"
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

# ---------- COMMON SERVICE-DELETION HELPER ----------
# -------------------------------
# NEW FUNCTION: Delete Services linked to a Deployment
# -------------------------------
delete_services_for_deployment() {
  local name=$1
  local ns=$2

  log "Searching for services linked to deployment $name ($ns)"

  selector_json=$(kubectl get deploy "$name" -n "$ns" -o json 2>/dev/null)
  if [[ -z "$selector_json" ]]; then
    log "Cannot fetch selector for deployment $name ($ns)"
    return
  fi

  # Extract all labels into KEY=VAL array
  mapfile -t label_array < <(
    echo "$selector_json" | jq -r '
      .spec.template.metadata.labels
      | to_entries
      | .[] 
      | "\(.key)=\(.value)"
    '
  )

  if (( ${#label_array[@]} == 0 )); then
    log "No labels found for deployment -> no services evaluated"
    return
  fi

  log "Labels to check individually: ${label_array[*]}"

  # Create an associative array to avoid duplicates
  declare -A svc_map

  # Check each label independently
  for lbl in "${label_array[@]}"; do
    log "Checking services whose selector matches deployment label: $lbl"

    # Split KEY=VALUE from "app=ml"
    key="${lbl%%=*}"
    val="${lbl#*=}"

    # Find services whose selector contains this key/value
    mapfile -t found_svcs < <(
      kubectl get svc -n "$ns" -o json \
      | jq -r --arg k "$key" --arg v "$val" '
          .items[]
          | select(.spec.selector[$k] == $v)
          | .metadata.name
        ' 2>/dev/null
    )

    # Add matched services to svc_map (unique list)
    for svc in "${found_svcs[@]}"; do
      svc_map["$svc"]=1
    done
  done


  # -------------------------------------------------------------------

  same_name_svc=$(kubectl get svc "$name" -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')

  if [[ -n "$same_name_svc" ]]; then
    log "Found service with same name as deployment: $same_name_svc"
    svc_map["$same_name_svc"]=1
  fi

  # -------------------------------------------------------------------

  # Put union result in array
  svc_list=("${!svc_map[@]}")

  if (( ${#svc_list[@]} == 0 )); then
    log "No services found for ANY label of deployment"
    return
  fi

  log "Services found for deletion: ${svc_list[*]}"

  for svc in "${svc_list[@]}"; do
    log "Deleting service $svc ($ns)"
    kubectl delete svc "$svc" -n "$ns" >> "$LOG_FILE" 2>&1 || \
      log "Failed to delete service $svc ($ns)"
  done
}


delete_services_for_pod() {
  local pod="$1"
  local ns="$2"

  log "Searching for services linked to pod $pod ($ns)"

  # Get pod JSON
  pod_json=$(kubectl get pod "$pod" -n "$ns" -o json 2>/dev/null)
  if [[ -z "$pod_json" ]]; then
    log "Failed to fetch pod $pod ($ns)"
    return
  fi

  # Extract ALL labels as KEY=VAL pairs
  mapfile -t label_array < <(
    echo "$pod_json" | jq -r '
      .metadata.labels
      | to_entries
      | .[]
      | "\(.key)=\(.value)"
    '
  )

  if (( ${#label_array[@]} == 0 )); then
    log "Pod $pod ($ns): No labels found on pod → no label-based service lookup"
  else
    log "Pod $pod ($ns): Labels to check individually: ${label_array[*]}"
  fi

  # Hashmap for dedupe
  declare -A svc_map

  # -------------------------------------------------------------
  # Check EACH label independently (same logic as deployment version)
  # -------------------------------------------------------------
  for lbl in "${label_array[@]}"; do
    log "Checking services whose selector contains: $lbl"

    # Split KEY=VALUE into key and value
    key="${lbl%%=*}"
    val="${lbl#*=}"

    # Query all services in the namespace and filter by selector
    mapfile -t found_svcs < <(
      kubectl get svc -n "$ns" -o json \
      | jq -r --arg k "$key" --arg v "$val" '
          .items[]
          | select(.spec.selector[$k] == $v)
          | .metadata.name
        ' 2>/dev/null
    )

    if (( ${#found_svcs[@]} == 0 )); then
      log "No services found whose selector matches '$lbl'"
      continue
    fi

    log "Services matched for selector '$lbl': ${found_svcs[*]}"

    # Add to map
    for svc in "${found_svcs[@]}"; do
      svc_map["$svc"]=1
    done
  done


  # -------------------------------------------------------------
  # Check if any service has the same NAME as the pod
  # -------------------------------------------------------------
  same_name_svc=$(kubectl get svc "$pod" -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')

  if [[ -n "$same_name_svc" ]]; then
    log "Found service with same name as pod: $same_name_svc"
    svc_map["$same_name_svc"]=1
  fi

  # -------------------------------------------------------------
  # Final service list
  # -------------------------------------------------------------
  svc_list=("${!svc_map[@]}")

  if (( ${#svc_list[@]} == 0 )); then
    log "Pod $pod ($ns): No matched services found → nothing to delete"
    return
  fi

  log "Services selected for deletion: ${svc_list[*]}"

  # -------------------------------------------------------------
  # Delete all unique services
  # -------------------------------------------------------------
  for svc in "${svc_list[@]}"; do
    log "Deleting service '$svc' ($ns)"
    kubectl delete svc "$svc" -n "$ns" >> "$LOG_FILE" 2>&1 || \
      log "Failed to delete service '$svc' ($ns)"
  done
}


# ---------- DEPLOYMENT CLEANUP ----------
cleanup_deployment() {
  local age=$1; local name=$2; local ns=$3; local soft=$4; local hard=$5; local cpu_thr=$6

  # HARD branch (only if enabled)
  if $deploy_hard_enabled && (( age >= hard )); then
    log "Deployment $name ($ns): age ${age}m >= hard limit ${hard}m -> deleting (hard limit)"
    echo "Deployment $name ($ns): HARD delete triggered"
    delete_services_for_deployment "$name" "$ns"
    kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) on hard limit"
    return
  fi

  # SOFT branch (only if enabled)
  if $deploy_soft_enabled && (( age >= soft )); then
    log "Deployment $name ($ns): age ${age}m >= soft limit ${soft}m -> Evaluating keep-alive + CPU"
    echo "Deployment $name ($ns): SOFT-evaluation triggered"

    keep_alive_label=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.metadata.labels.keep-alive}' 2>/dev/null || echo "")
    if [[ -z "$keep_alive_label" ]]; then
      log "Deployment $name ($ns): keep-alive label NOT present -> deleting (soft path)"
      delete_services_for_deployment "$name" "$ns"
      kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) (no keep-alive)"
      return
    fi

    keep_alive_label_lower=$(echo "$keep_alive_label" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_alive_label_lower" == "false" ]]; then
      log "Deployment $name ($ns): keep-alive=false -> deleting (soft path)"
      delete_services_for_deployment "$name" "$ns"
      kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) (keep-alive=false)"
      return
    fi

    if [[ "$keep_alive_label_lower" != "true" ]]; then
      log "Deployment $name ($ns): INVALID keep-alive='$keep_alive_label' -> deleting (soft path)"
      delete_services_for_deployment "$name" "$ns"
      kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) (invalid keep-alive)"
      return
    fi

    # build selector (preferring matchLabels)
    selector=$(kubectl get deployment "$name" -n "$ns" -o json | \
               jq -r ' .metadata.labels | to_entries | map("\(.key)=\(.value)") | join(",")')
    echo "$selector"

    if [[ -z "$selector" ]]; then
      log "Deployment $name ($ns): No selector found -> keeping deployment"
      return
    fi

    log "Checking CPU for Pods with selector: $selector"

    mapfile -t cpu_list < <(kubectl top pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | awk '{print $2}')
    if (( ${#cpu_list[@]} == 0 )); then
      log "Deployment $name ($ns): No CPU data returned -> keeping deployment"
      return
    fi

    all_below_threshold=true
    for cpu_raw in "${cpu_list[@]}"; do
      if [[ $cpu_raw == *m ]]; then
        cpu_val=${cpu_raw%m}
      elif [[ $cpu_raw =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        cpu_val=$(awk -v v="$cpu_raw" 'BEGIN{ printf("%d", v * 1000) }')
      else
        cpu_val=0
      fi
      log "Deployment $name ($ns): Pod CPU=${cpu_val}m threshold=${cpu_thr}m"
      if (( cpu_val >= cpu_thr )); then
        all_below_threshold=false
      fi
    done

    if $all_below_threshold; then
      log "Deployment $name ($ns): ALL pods CPU < threshold -> deleting (soft/CPU path)"
      delete_services_for_deployment "$name" "$ns"
      kubectl delete deployment "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete deployment $name ($ns) after CPU check"
    else
      log "Deployment $name ($ns): At least one pod CPU >= threshold -> keeping deployment"
    fi
    return
  fi

  # If neither hard nor soft path triggered or they were disabled:
  log "Deployment $name ($ns): age ${age}m did not trigger enabled checks -> safe/untouched"
}

# ---------- POD CLEANUP ----------
cleanup_pod() {
  local age=$1; local name=$2; local ns=$3; local soft=$4; local hard=$5; local cpu_thr=$6

  if $pod_hard_enabled && (( age >= hard )); then
    log "Pod $name ($ns): age ${age}m >= hard limit ${hard}m -> deleting (hard limit)"
    echo "Pod $name ($ns): HARD delete triggered"
    delete_services_for_pod "$name" "$ns"
    kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) on hard limit"
    return
  fi

  if $pod_soft_enabled && (( age >= soft )); then
    log "Pod $name ($ns): age ${age}m >= soft limit ${soft}m -> evaluating keep-alive label and CPU"
    echo "Pod $name ($ns): SOFT-evaluation triggered"

    keep_alive_label=$(kubectl get pod "$name" -n "$ns" -o jsonpath='{.metadata.labels.keep-alive}' 2>/dev/null || echo "")
    if [[ -z "$keep_alive_label" ]]; then
      log "Pod $name ($ns): keep-alive label NOT present -> deleting (soft path)"
      delete_services_for_pod "$name" "$ns"
      kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) (no keep-alive)"
      return
    fi

    keep_alive_label_lower=$(echo "$keep_alive_label" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_alive_label_lower" == "false" ]]; then
      log "Pod $name ($ns): keep-alive=false -> deleting (soft path)"
      delete_services_for_pod "$name" "$ns"
      kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) (keep-alive=false)"
      return
    fi

    if [[ "$keep_alive_label_lower" != "true" ]]; then
      log "Pod $name ($ns): keep-alive label value='$keep_alive_label' is not 'true' -> deleting (soft path)"
      delete_services_for_pod "$name" "$ns"
      kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) (invalid keep-alive)"
      return
    fi

    log "Pod $name ($ns): keep-alive=true -> checking CPU usage"
    cpu_raw=$(kubectl top pod "$name" -n "$ns" --no-headers 2>/dev/null | awk '{print $2}' || echo "")
    if [[ -z "$cpu_raw" ]]; then
      log "Pod $name ($ns): kubectl top returned no CPU value -> cannot evaluate CPU; keeping pod"
      return
    fi

    if [[ $cpu_raw == *m ]]; then
      cpu=${cpu_raw%m}
    elif [[ $cpu_raw =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      cpu=$(awk -v v="$cpu_raw" 'BEGIN{ printf("%d", v * 1000) }')
    else
      cpu=0
    fi

    log "Pod $name ($ns): CPU usage ${cpu}m; threshold ${cpu_thr}m"
    if (( cpu > cpu_thr )); then
      log "Pod $name ($ns): CPU ${cpu}m > threshold ${cpu_thr}m -> keeping pod"
    else
      log "Pod $name ($ns): CPU ${cpu}m <= threshold ${cpu_thr}m -> deleting pod (soft/CPU path)"
      delete_services_for_pod "$name" "$ns"
      kubectl delete pod "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete Pod $name ($ns) after CPU check"
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

    cleanup_deployment "$age_min" "$deployname" "$namespace" "$soft_limit" "$hard_limit" "$CPU_THRESHOLD"
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

    cleanup_pod "$age_min" "$podname" "$namespace" "$soft_limit" "$hard_limit" "$CPU_THRESHOLD"
  done
else
  log "Pod checks disabled by config -> skipping all pods."
fi

echo "Auto Cleanup completed."

