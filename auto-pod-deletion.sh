#!/usr/bin/env bash

set -euo pipefail

echo "Auto Cleanup (Deployments, Pods and Services) started..."

########################################
# 1. LOCKING TO AVOID CRON OVERLAP
########################################
LOCK_DIR="/var/lock/auto_cleanup.lock"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another cleanup process already running. Exiting."
  exit 0
fi

cleanup_lock() {
  rm -rf "$LOCK_DIR"
}
trap cleanup_lock EXIT

########################################
# 2. CONFIG & LOGGING
########################################
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/cleanup_config.env"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file $CONFIG_FILE not found!" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR"

log() {
  local msg="$1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts - $msg" | tee -a "$LOG_FILE"
}

########################################
# 3. EXCLUSION LISTS (NAMESPACE/RESOURCES)
########################################
EX_NS_FILE="$SCRIPT_DIR/exclude_namespaces.txt"
EX_DEPLOY_FILE="$SCRIPT_DIR/exclude_deployments.txt"
EX_POD_FILE="$SCRIPT_DIR/exclude_pods.txt"
EX_SVC_FILE="$SCRIPT_DIR/exclude_services.txt"

load_list() {
  local file="$1"
  local out_var="$2"
  local line trimmed
  local arr=()

  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # strip comments
      line="${line%%#*}"
      # trim whitespace
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -z "$line" ] && continue
      arr+=("$line")
    done < "$file"
  fi

  eval "$out_var=(\"\${arr[@]}\")"
}

in_list() {
  local value="$1"; shift
  local item
  for item in "$@"; do
    if [ "$item" = "$value" ]; then
      return 0
    fi
  done
  return 1
}

# Load all exclusion arrays
EX_NS=()
EX_DEPLOY=()
EX_POD=()
EX_SVC=()

load_list "$EX_NS_FILE" EX_NS
load_list "$EX_DEPLOY_FILE" EX_DEPLOY
load_list "$EX_POD_FILE" EX_POD
load_list "$EX_SVC_FILE" EX_SVC

log "Loaded excludes: namespaces=${#EX_NS[@]}, deployments=${#EX_DEPLOY[@]}, pods=${#EX_POD[@]}, services=${#EX_SVC[@]}"

########################################
# 4. NORMALISE ENABLE FLAGS
########################################
norm_flag() {
  local v="${1:-False}"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$v" in
    true|t|yes|y|1) echo "true" ;;
    *)              echo "false" ;;
  esac
}

DEPLOYMENT_FLAG="$(norm_flag "${Deployment:-False}")"
POD_FLAG="$(norm_flag "${Pod:-False}")"
SERVICE_FLAG="$(norm_flag "${Service:-False}")"

DEPLOY_HARD_FLAG="$(norm_flag "${Deployment_HardLimit:-False}")"
DEPLOY_SOFT_FLAG="$(norm_flag "${Deployment_SoftLimit:-False}")"

POD_HARD_FLAG="$(norm_flag "${Pod_HardLimit:-False}")"
POD_SOFT_FLAG="$(norm_flag "${Pod_SoftLimit:-False}")"

SERVICE_HARD_FLAG="$(norm_flag "${Service_HardLimit:-False}")"
SERVICE_SOFT_FLAG="$(norm_flag "${Service_SoftLimit:-False}")"

# If both hard & soft are false, disable that resource
if [ "$DEPLOY_HARD_FLAG" = "false" ] && [ "$DEPLOY_SOFT_FLAG" = "false" ]; then
  DEPLOYMENT_FLAG="false"
  log "Deployment hard & soft both disabled in config -> Deployment checks disabled."
fi

if [ "$POD_HARD_FLAG" = "false" ] && [ "$POD_SOFT_FLAG" = "false" ]; then
  POD_FLAG="false"
  log "Pod hard & soft both disabled in config -> Pod checks disabled."
fi

if [ "$SERVICE_HARD_FLAG" = "false" ] && [ "$SERVICE_SOFT_FLAG" = "false" ]; then
  SERVICE_FLAG="false"
  log "Service hard & soft both disabled in config -> Service checks disabled."
fi

is_deployment_enabled="$DEPLOYMENT_FLAG"
is_pod_enabled="$POD_FLAG"
is_service_enabled="$SERVICE_FLAG"

########################################
# 5. POD BATCH BEHAVIOUR CONFIG
########################################
POD_FORCE_DELETE="${POD_FORCE_DELETE:-false}"
POD_BACKGROUND_DELETE="${POD_BACKGROUND_DELETE:-true}"
POD_BATCH_SIZE="${POD_BATCH_SIZE:-50}"

if ! printf '%s' "$POD_BATCH_SIZE" | grep -Eq '^[0-9]+$'; then
  POD_BATCH_SIZE=50
fi
if [ "$POD_BATCH_SIZE" -le 0 ]; then
  POD_BATCH_SIZE=50
fi

declare -a POD_DELETE_QUEUE=()

########################################
# 6. AGE CALCULATION (minutes)
########################################
get_age_minutes() {
  local kind="$1"
  local name="$2"
  local ns="$3"
  local creation_ts created_epoch now_epoch diff

  creation_ts="$(kubectl get "$kind" "$name" -n "$ns" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")"
  if [ -z "$creation_ts" ]; then
    echo 0
    return 0
  fi

  created_epoch="$(date -d "$creation_ts" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"

  if [ "$created_epoch" -le 0 ]; then
    echo 0
    return 0
  fi

  diff=$(( (now_epoch - created_epoch) / 60 ))
  echo "$diff"
}

########################################
# 7. GENERIC CLEANUP (DEPLOYMENTS/SERVICES + POD LOGIC)
########################################
cleanup_resource() {
  # usage: cleanup_resource <kind> <age> <name> <namespace> <soft> <hard>
  local kind="$1"
  local age="$2"
  local name="$3"
  local ns="$4"
  local soft="$5"
  local hard="$6"
  local keep_alive keep_lc
  local hard_flag="false"
  local soft_flag="false"

  # select flags for the kind
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

  # Exclusion checks
  if in_list "$ns" "${EX_NS[@]}"; then
    log "Skipping $kind $name in namespace $ns -> namespace excluded"
    return 0
  fi

  if [ "$kind" = "deployment" ] && in_list "$name" "${EX_DEPLOY[@]}"; then
    log "Skipping deployment $name ($ns) -> explicitly excluded"
    return 0
  fi

  if [ "$kind" = "pod" ] && in_list "$name" "${EX_POD[@]}"; then
    log "Skipping pod $name ($ns) -> explicitly excluded"
    return 0
  fi

  if [ "$kind" = "service" ] && in_list "$name" "${EX_SVC[@]}"; then
    log "Skipping service $name ($ns) -> explicitly excluded"
    return 0
  fi

  # HARD limit
  if [ "$hard_flag" = "true" ] && [ "$age" -ge "$hard" ]; then
    if [ "$kind" = "pod" ]; then
      # queue pod for batched deletion
      POD_DELETE_QUEUE+=( "$ns/$name" )
      log "Pod $name ($ns) queued for HARD deletion (age=${age}m >= ${hard}m)"
      echo "Pod $name ($ns): HARD delete queued"
    else
      log "Hard limit: deleting $kind $name ($ns) (age=${age}m >= ${hard}m)"
      echo "Deleting $kind $name ($ns) via HARD limit"
      kubectl delete "$kind" "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed deleting $kind $name ($ns) on hard limit"
    fi
    return 0
  fi

  # SOFT limit
  if [ "$soft_flag" = "true" ] && [ "$age" -ge "$soft" ]; then
    log "Soft limit reached for $kind $name ($ns) (age=${age}m >= ${soft}m) -> Checking keep-alive"
    echo "$kind $name ($ns): soft limit reached, evaluating keep-alive"

    keep_alive="$(kubectl get "$kind" "$name" -n "$ns" -o jsonpath='{.metadata.labels.keep-alive}' 2>/dev/null || echo "")"
    keep_lc="$(printf '%s' "$keep_alive" | tr '[:upper:]' '[:lower:]')"

    if [ -z "$keep_lc" ] || [ "$keep_lc" = "false" ] || [ "$keep_lc" != "true" ]; then
      # no label, false, or invalid -> delete
      if [ "$kind" = "pod" ]; then
        POD_DELETE_QUEUE+=( "$ns/$name" )
        log "Pod $name ($ns) queued for SOFT deletion (keep-alive='$keep_alive')"
        echo "Pod $name ($ns): SOFT delete queued (keep-alive='$keep_alive')"
      else
        log "Soft limit: deleting $kind $name ($ns) (keep-alive='$keep_alive')"
        echo "Deleting $kind $name ($ns) via SOFT path"
        kubectl delete "$kind" "$name" -n "$ns" >> "$LOG_FILE" 2>&1 || log "Failed deleting $kind $name ($ns) on soft path"
      fi
    else
      # keep-alive=true
      log "keep-alive=true for $kind $name ($ns) -> skipping deletion"
      echo "$kind $name ($ns): keep-alive=true -> keeping"
    fi

    return 0
  fi

  # no deletion
  log "$kind $name ($ns): age=${age}m did not cross active limits -> safe/untouched"
  return 0
}

########################################
# 8. DEPLOYMENT CLEANUP
########################################
if [ "$is_deployment_enabled" = "true" ]; then
  log "Starting Deployment cleanup..."
  # namespace, name from dgx-* namespaces
  while read -r ns name _; do
    age_min="$(get_age_minutes deployment "$name" "$ns")"

    # thresholds by namespace type
    if printf '%s' "$ns" | grep -q '^dgx-s'; then
      soft="$STUDENT_SOFT"; hard="$STUDENT_HARD"
    elif printf '%s' "$ns" | grep -q '^dgx-f'; then
      soft="$FACULTY_SOFT"; hard="$FACULTY_HARD"
    elif printf '%s' "$ns" | grep -q '^dgx-i'; then
      soft="$INDUSTRY_SOFT"; hard="$INDUSTRY_HARD"
    else
      continue
    fi

    cleanup_resource "deployment" "$age_min" "$name" "$ns" "$soft" "$hard"
  done < <(kubectl get deploy -A --no-headers 2>/dev/null | awk '/^dgx-/ {print $1, $2, $6}')
else
  log "Deployment checks disabled by config."
fi

########################################
# 9. POD DISCOVERY & QUEUEING
########################################
if [ "$is_pod_enabled" = "true" ]; then
  log "Starting Pod scan & queueing..."
  while read -r ns name _; do
    # skip namespaced or pod-specific exclusions early
    if in_list "$ns" "${EX_NS[@]}"; then
      log "Skipping pod $name ($ns) -> namespace excluded"
      continue
    fi
    if in_list "$name" "${EX_POD[@]}"; then
      log "Skipping pod $name ($ns) -> explicitly excluded"
      continue
    fi

    # only standalone pods (no ownerReferences)
    owner="$(kubectl get pod "$name" -n "$ns" -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null || echo "")"
    if [ -n "$owner" ]; then
      continue
    fi

    age_min="$(get_age_minutes pod "$name" "$ns")"

    if printf '%s' "$ns" | grep -q '^dgx-s'; then
      soft="$STUDENT_SOFT"; hard="$STUDENT_HARD"
    elif printf '%s' "$ns" | grep -q '^dgx-f'; then
      soft="$FACULTY_SOFT"; hard="$FACULTY_HARD"
    elif printf '%s' "$ns" | grep -q '^dgx-i'; then
      soft="$INDUSTRY_SOFT"; hard="$INDUSTRY_HARD"
    else
      continue
    fi

    cleanup_resource "pod" "$age_min" "$name" "$ns" "$soft" "$hard"

  done < <(kubectl get pods -A --no-headers 2>/dev/null | awk '/^dgx-/ {print $1, $2, $5}')
else
  log "Pod checks disabled by config."
fi

########################################
# 10. BATCH DELETE QUEUED PODS
########################################
log "Flushing Pod deletion queue (${#POD_DELETE_QUEUE[@]} pods)..."

# safe grouping by namespace into associative array (works with set -u)
  # ---------- SAFE GROUPING OF POD DELETE QUEUE ----------
  declare -A PODS_BY_NS=()
  for item in "${POD_DELETE_QUEUE[@]:-}"; do
          # SAFETY: Skip empty entries
          [[ -z "$item" ]] && continue
          # Ensure correct ns/pod format
          ns="${item%%/*}"
          pod="${item##*/}"
          # SAFETY: Skip if malformed
          [[ -z "$ns" || -z "$pod" ]] && continue
          # Append pod safely without triggering set -u issues
          if [[ -z "${PODS_BY_NS[$ns]:-}" ]]; then
                  PODS_BY_NS["$ns"]="$pod"
          else
                  PODS_BY_NS["$ns"]="${PODS_BY_NS[$ns]} $pod"
          fi
  done



  for ns in "${!PODS_BY_NS[@]}"; do
    # convert to array
    read -r -a pods_in_ns <<< "${PODS_BY_NS[$ns]}"
    total="${#pods_in_ns[@]}"
    idx=0

    while [ "$idx" -lt "$total" ]; do
      # build a batch
      batch=()
      count=0
      while [ "$idx" -lt "$total" ] && [ "$count" -lt "$POD_BATCH_SIZE" ]; do
        batch+=( "${pods_in_ns[$idx]}" )
        idx=$((idx + 1))
        count=$((count + 1))
      done

      # build the kubectl command
      cmd=(kubectl delete pod)
      for p in "${batch[@]}"; do
        cmd+=( "$p" )
      done
      cmd+=( -n "$ns" )

      if [ "$POD_FORCE_DELETE" = "true" ]; then
        cmd+=( --grace-period=0 --force )
      fi

      log "Deleting pods in batch (namespace=$ns): ${batch[*]} (force=$POD_FORCE_DELETE background=$POD_BACKGROUND_DELETE)"

      if [ "$POD_BACKGROUND_DELETE" = "true" ]; then
        # do not wait; leave pods in Terminating while script moves on
        nohup "${cmd[@]}" >> "$LOG_FILE" 2>&1 &
      else
        "${cmd[@]}" >> "$LOG_FILE" 2>&1 || log "kubectl delete returned non-zero for pods (${batch[*]}) in ns=$ns"
      fi
    done
  done

  log "No Pods queued for deletion."


########################################
# 11. SERVICE CLEANUP (SAME PATTERN AS DEPLOYMENT)
########################################
if [ "$is_service_enabled" = "true" ]; then
  log "Starting Service cleanup..."
  while read -r ns name _; do
    age_min="$(get_age_minutes service "$name" "$ns")"

    if printf '%s' "$ns" | grep -q '^dgx-s'; then
      soft="$STUDENT_SOFT"; hard="$STUDENT_HARD"
    elif printf '%s' "$ns" | grep -q '^dgx-f'; then
      soft="$FACULTY_SOFT"; hard="$FACULTY_HARD"
    elif printf '%s' "$ns" | grep -q '^dgx-i'; then
      soft="$INDUSTRY_SOFT"; hard="$INDUSTRY_HARD"
    else
      continue
    fi

    cleanup_resource "service" "$age_min" "$name" "$ns" "$soft" "$hard"

  done < <(kubectl get svc -A --no-headers 2>/dev/null | awk '/^dgx-/ {print $1, $2, $5}')
else
  log "Service checks disabled by config."
fi

########################################
# 12. EXIT
########################################
log "Auto Cleanup (Deployments, Pods and Services) completed. Releasing lock."
echo "Auto Cleanup (Deployments, Pods and Services) completed."
