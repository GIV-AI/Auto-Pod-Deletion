#!/bin/bash

set -u

echo "Auto Cleanup (Deployments, Pods and Services) started..."

# ---------- CONFIG ----------
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/cleanup_config.env"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "Config file $CONFIG_FILE not found!" >&2
  exit 1
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# ---------- Normalise and interpret flags ----------
# Helper: normalize True/False to lower 'true' or 'false', default false if unset
norm_flag() {
  local v="${1:-False}"
  v=$(echo "$v" | tr '[:upper:]' '[:lower:]' | xargs)
  if [[ "$v" == "true" || "$v" == "t" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

DEPLOYMENT_FLAG=$(norm_flag "${Deployment:-False}")
POD_FLAG=$(norm_flag "${Pod:-False}")
SERVICE_FLAG=$(norm_flag "${Service:-False}")

DEPLOY_HARD_FLAG=$(norm_flag "${Deployment_HardLimit:-False}")
DEPLOY_SOFT_FLAG=$(norm_flag "${Deployment_SoftLimit:-False}")

POD_HARD_FLAG=$(norm_flag "${Pod_HardLimit:-False}")
POD_SOFT_FLAG=$(norm_flag "${Pod_SoftLimit:-False}")

SERVICE_HARD_FLAG=$(norm_flag "${Service_HardLimit:-False}")
SERVICE_SOFT_FLAG=$(norm_flag "${Service_SoftLimit:-False}")

# If both hard & soft are false -> treat resource as disabled regardless of main flag

if [[ "$DEPLOY_HARD_FLAG" == "false" && "$DEPLOY_SOFT_FLAG" == "false" ]]; then
  DEPLOYMENT_FLAG="false"
  log "Deployment hard & soft both disabled in config -> Deployment checks disabled."
fi

if [[ "$POD_HARD_FLAG" == "false" && "$POD_SOFT_FLAG" == "false" ]]; then
  POD_FLAG="false"
  log "Pod hard & soft both disabled in config -> Pod checks disabled."
fi

if [[ "$SERVICE_HARD_FLAG" == "false" && "$SERVICE_SOFT_FLAG" == "false" ]]; then
  SERVICE_FLAG="false"
  log "Service hard & soft both disabled in config -> Service checks disabled."
fi

#--------------------------------------------

is_deployment_enabled=false
is_pod_enabled=false
is_service_enabled=false
deploy_hard_enabled=false
deploy_soft_enabled=false
pod_hard_enabled=false
pod_soft_enabled=false
service_hard_enabled=false
service_soft_enabled=false

#--------------------------------------------

[[ "$DEPLOYMENT_FLAG" == "true" ]] && is_deployment_enabled=true
[[ "$POD_FLAG" == "true" ]] && is_pod_enabled=true
[[ "$SERVICE_FLAG" == "true" ]] && is_service_enabled=true

[[ "$DEPLOY_HARD_FLAG" == "true" ]] && deploy_hard_enabled=true
[[ "$DEPLOY_SOFT_FLAG" == "true" ]] && deploy_soft_enabled=true
[[ "$POD_HARD_FLAG" == "true" ]] && pod_hard_enabled=true
[[ "$POD_SOFT_FLAG" == "true" ]] && pod_soft_enabled=true
[[ "$SERVICE_HARD_FLAG" == "true" ]] && service_hard_enabled=true
[[ "$SERVICE_SOFT_FLAG" == "true" ]] && service_soft_enabled=true
if [[ "$DEPLOY_HARD_FLAG" == "false" && "$DEPLOY_SOFT_FLAG" == "false" ]]; then
  DEPLOYMENT_FLAG="false"
  log "Deployment hard & soft both disabled in config -> Deployment checks disabled."
fi

log "Config summary: Deployment Enabled=${is_deployment_enabled}, DeployHard=${deploy_hard_enabled}, DeploySoft=${deploy_soft_enabled}; Pod Enabled=${is_pod_enabled}, PodHard=${pod_hard_enabled}, PodSoft=${pod_soft_enabled}; Service Enabled=${is_service_enabled}, ServiceHard=${service_hard_enabled}, ServiceSoft=${service_soft_enabled}"

# ---------- Generic RESOURCE CLEANUP ----------
# Replace duplicated cleanup_deployment and cleanup_pod with one function.
# resource: "deployment" or "pod"
# age: minutes
# name: resource name
# ns: namespace
# soft/hard: limits in minutes
cleanup_resource() {
  local resource="$1"
  local age="$2"
  local name="$3"
  local ns="$4"
  local soft="$5"
  local hard="$6"

  # Determine which feature flags to consult (resource-specific)
  local hard_flag=false
  local soft_flag=false
  if [[ "$resource" == "deployment" ]]; then
    hard_flag=$deploy_hard_enabled
    soft_flag=$deploy_soft_enabled
  elif [[ "$resource" == "pod" ]]; then
    hard_flag=$pod_hard_enabled
    soft_flag=$pod_soft_enabled
  elif [[ "$resource" == "service" ]]; then
    hard_flag=$service_hard_enabled
    soft_flag=$service_soft_enabled
  fi

  # For human-friendly logging strings
  local ucfirst_resource
  if [[ "$resource" == "deployment" ]]; then
    ucfirst_resource="Deployment"
  elif [[ "$resource" == "pod" ]]; then
    ucfirst_resource="Pod"
  elif [[ "$resource" == "service" ]]; then
    ucfirst_resource="Service"
  fi

  # HARD branch (only if enabled)
  if $hard_flag && (( age >= hard )); then
    log "$ucfirst_resource $name ($ns): age ${age}m >= hard limit ${hard}m -> deleting (hard limit)"
    echo "$ucfirst_resource $name ($ns): HARD delete triggered"
    kubectl delete "$resource" "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete $ucfirst_resource $name ($ns) on hard limit"
    return
  fi

  # SOFT branch (only if enabled)
  if $soft_flag && (( age >= soft )); then
    log "$ucfirst_resource $name ($ns): age ${age}m >= soft limit ${soft}m -> Evaluating keep-alive"
    echo "$ucfirst_resource $name ($ns): Evaluating keep-alive"

    # Fetch keep-alive label regardless of resource type
    keep_alive_label=$(kubectl get "$resource" "$name" -n "$ns" -o jsonpath='{.metadata.labels.keep-alive}' 2>/dev/null || echo "")
    if [[ -z "$keep_alive_label" ]]; then
      log "$ucfirst_resource $name ($ns): keep-alive label NOT present -> deleting (soft path)"
      echo "$ucfirst_resource $name ($ns): keep-alive label NOT present -> deleting (soft path)"
      kubectl delete "$resource" "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete $ucfirst_resource $name ($ns) (no keep-alive)"
      return
    fi

    keep_alive_label_lower=$(echo "$keep_alive_label" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_alive_label_lower" == "false" ]]; then
      log "$ucfirst_resource $name ($ns): keep-alive=false -> deleting (soft path)"
      echo "$ucfirst_resource $name ($ns): keep-alive=false -> deleting (soft path)"
      kubectl delete "$resource" "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete $ucfirst_resource $name ($ns) (keep-alive=false)"
      return
    fi
    keep_alive_label_lower=$(echo "$keep_alive_label" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_alive_label_lower" != "true" ]]; then
      log "$ucfirst_resource $name ($ns): INVALID keep-alive='$keep_alive_label' -> deleting (soft path)"
      echo "$ucfirst_resource $name ($ns): INVALID keep-alive='$keep_alive_label' -> deleting (soft path)"
      kubectl delete "$resource" "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed to delete $ucfirst_resource $name ($ns) (invalid keep-alive)"
      return
    fi
    keep_alive_label_lower=$(echo "$keep_alive_label" | tr '[:upper:]' '[:lower:]')
    if [[ "$keep_alive_label_lower" = "true" ]]; then
      log "$ucfirst_resource $name ($ns): 'Keep Alive' tag present -> keeping $resource"
      echo "$ucfirst_resource $name ($ns): 'Keep Alive' tag present -> keeping $resource"
      return
    fi
  fi

  # If neither hard nor soft triggered
  log "$ucfirst_resource $name ($ns): age ${age}m did not trigger enabled checks -> safe/untouched"
}
# End cleanup_resource

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
    if [[ $age_str =~ ([0-9]+)s ]]; then secs=${BASH_REMATCH[1]}; (( secs>0 )) && age_min=$((age_min)); fi

    if [[ $namespace == dgx-s* ]]; then
      soft_limit=$STUDENT_SOFT; hard_limit=$STUDENT_HARD
    elif [[ $namespace == dgx-f* ]]; then
      soft_limit=$FACULTY_SOFT; hard_limit=$FACULTY_HARD
    elif [[ $namespace == dgx-i* ]]; then
      soft_limit=$INDUSTRY_SOFT; hard_limit=$INDUSTRY_HARD
    else
      continue
    fi

    # Call generic cleanup for deployment
    cleanup_resource "deployment" "$age_min" "$deployname" "$namespace" "$soft_limit" "$hard_limit"
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

      # Convert ISO timestamp → human-readable AGE (same as kubectl)
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
    if [[ $age_str =~ ([0-9]+)s ]]; then secs=${BASH_REMATCH[1]}; (( secs>0 )) && age_min=$((age_min)); fi

    if [[ $namespace == dgx-s* ]]; then
      soft_limit=$STUDENT_SOFT; hard_limit=$STUDENT_HARD
    elif [[ $namespace == dgx-f* ]]; then 
      soft_limit=$FACULTY_SOFT; hard_limit=$FACULTY_HARD
    elif [[ $namespace == dgx-i* ]]; then
      soft_limit=$INDUSTRY_SOFT; hard_limit=$INDUSTRY_HARD
    else
      continue
    fi

    # Call generic cleanup for pod
    cleanup_resource "pod" "$age_min" "$podname" "$namespace" "$soft_limit" "$hard_limit"
  done
else
  log "Pod checks disabled by config -> skipping all pods."
fi

# ---------- Then Services (only if enabled) ----------
if $is_service_enabled; then

  mapfile -t services < <(
  kubectl get services -A --no-headers \
  | awk '/^dgx-/ {print $1, $2}' \
  | while read ns name; do
      # Call kubectl for formatted AGE 
      age_str=$(kubectl get services "$name" -n "$ns" --no-headers | awk '{print $6}')

      # Store final line directly in service array
      echo "$ns $name $age_str"

    done
  )

  for entry in "${services[@]:-}"; do
    namespace=$(echo "$entry" | awk '{print $1}')
    servicename=$(echo "$entry" | awk '{print $2}')
    age_str=$(echo "$entry" | awk '{print $3}')
    age_min=0
    if [[ $age_str =~ ([0-9]+)d ]]; then age_min=$((age_min + ${BASH_REMATCH[1]} * 1440)); fi
    if [[ $age_str =~ ([0-9]+)h ]]; then age_min=$((age_min + ${BASH_REMATCH[1]} * 60)); fi
    if [[ $age_str =~ ([0-9]+)m ]]; then age_min=$((age_min + ${BASH_REMATCH[1]})); fi
    if [[ $age_str =~ ([0-9]+)s ]]; then secs=${BASH_REMATCH[1]}; (( secs>0 )) && age_min=$((age_min)); fi

    if [[ $namespace == dgx-s* ]]; then
      soft_limit=$STUDENT_SOFT; hard_limit=$STUDENT_HARD
    elif [[ $namespace == dgx-f* ]]; then
      soft_limit=$FACULTY_SOFT; hard_limit=$FACULTY_HARD
    elif [[ $namespace == dgx-i* ]]; then
      soft_limit=$INDUSTRY_SOFT; hard_limit=$INDUSTRY_HARD
    else
      continue
    fi

    # Call generic cleanup for service
    cleanup_resource "service" "$age_min" "$servicename" "$namespace" "$soft_limit" "$hard_limit"
  done
else
  log "Service checks disabled by config -> skipping all services"
fi

echo "Auto Cleanup (Deployments, Pods and Services) stop."
