# Auto-Cleanup Administrator Guide

A Kubernetes resource cleanup tool for multi-user DGX clusters. Automatically deletes stale Deployments, Pods, and Services based on configurable age limits.

---

## Table of Contents

1. [Purpose](#purpose)
2. [Key Concepts](#key-concepts)
3. [How It Works](#how-it-works)
4. [Default Time Limits](#default-time-limits)
5. [Running the Script](#running-the-script)
6. [Cron Job Setup](#cron-job-setup)
7. [Configuration](#configuration)
8. [Exclusions](#exclusions)
9. [Logs](#logs)
10. [Protecting Resources with Keep-Alive](#protecting-resources-with-keep-alive)

---

## Purpose

The Auto-Cleanup script automatically removes stale Kubernetes resources (Deployments, Pods, and Services) from DGX cluster namespaces. This prevents resource hoarding and ensures fair access for all users.

**What gets cleaned up:**
- Deployments older than the configured limit (and their managed pods automatically)
- Standalone Pods older than the configured limit
- Services older than the configured limit

**What is NOT touched:**
- Resources in excluded namespaces
- Resources with names in exclusion lists
- Resources protected by the `keep-alive=true` label (within soft limit)

### Pods That Are Never Deleted

During Pod cleanup, the script only processes **standalone pods** (pods without `ownerReferences`). Pods managed by the following controllers are **skipped**:

| Controller Type | Example Workload |
|----------------|------------------|
| **Job** | Batch processing, data migrations |
| **CronJob** | Scheduled backups, periodic reports |
| **StatefulSet** | Databases, message queues |
| **DaemonSet** | Logging agents, node monitors |
| **ReplicationController** | Legacy workloads |
| **Custom Controllers/Operators** | ML frameworks, custom CRDs |

**Note:** Pods managed by Deployments (via ReplicaSets) are not directly deleted during Pod cleanup—instead, when a Deployment is deleted, Kubernetes automatically terminates all its managed pods.

---

## Key Concepts

### User Categories

Users are categorized based on their namespace prefix. Each category has different time limits:

| Namespace Prefix | User Type | Description |
|------------------|-----------|-------------|
| `dgx-s-*` | Student | Student namespaces |
| `dgx-f-*` | Faculty | Faculty namespaces |
| `dgx-i-*` | Industry | Industry partner namespaces |

### Hard Limit vs Soft Limit

| Limit Type | Behavior | Keep-Alive Label |
|------------|----------|------------------|
| **Soft Limit** | Deletes resources that have exceeded the soft limit age | **Respected** - resources with `keep-alive=true` are preserved |
| **Hard Limit** | Deletes resources that have exceeded the hard limit age | **Ignored** - deletion is forced regardless of label |

### Keep-Alive Label

Users can protect their resources from soft-limit deletion by adding the label `keep-alive=true`. However, once the hard limit is reached, the resource will be deleted regardless of this label.

---

## How It Works

```mermaid
flowchart TD
    Start([Script Runs]) --> GetResources[Get all resources in dgx-* namespaces]
    GetResources --> CheckExcluded{Excluded?}
    CheckExcluded -->|Yes| Skip[Skip resource]
    CheckExcluded -->|No| CheckAge{Check resource age}
    
    CheckAge -->|Age >= Hard Limit| HardDelete[DELETE immediately]
    CheckAge -->|Age >= Soft Limit| CheckLabel{keep-alive = true?}
    CheckAge -->|Age < Soft Limit| Preserve[Keep resource]
    
    CheckLabel -->|Yes| Preserve
    CheckLabel -->|No| SoftDelete[DELETE resource]
    
    HardDelete --> NextResource[Process next resource]
    SoftDelete --> NextResource
    Preserve --> NextResource
    Skip --> NextResource
```

**Processing Order:**
1. Deployments are processed first
2. Standalone Pods are processed and queued for batch deletion
3. Services are processed last

---

## Default Time Limits

| User Type | Soft Limit | Hard Limit |
|-----------|------------|------------|
| **Student** (`dgx-s-*`) | 24 hours | 36 hours |
| **Faculty** (`dgx-f-*`) | 36 hours | 84 hours (3.5 days) |
| **Industry** (`dgx-i-*`) | 84 hours (3.5 days) | 168 hours (7 days) |

These limits can be customized in the configuration file.

---

## Running the Script

### Manual Execution

```bash
# Run the cleanup (requires root)
sudo auto-cleanup

# Run in quiet mode (errors only)
sudo auto-cleanup --quiet

# Display help
auto-cleanup --help

# Display version
auto-cleanup --version
```

### Command Location

After installation, the command is available at:
- `/usr/local/bin/auto-cleanup` (symlink)
- `/opt/auto-cleanup/bin/auto-cleanup` (actual script)

---

## Cron Job Setup

To run the cleanup automatically every hour:

```bash
# Create a cron job file
echo '0 * * * * root /usr/local/bin/auto-cleanup' | sudo tee /etc/cron.d/auto-cleanup

# Set proper permissions
sudo chmod 644 /etc/cron.d/auto-cleanup
```

This runs the cleanup at the start of every hour (e.g., 1:00, 2:00, 3:00...).

**Alternative schedules:**

```bash
# Every 30 minutes
*/30 * * * * root /usr/local/bin/auto-cleanup

# Every 6 hours
0 */6 * * * root /usr/local/bin/auto-cleanup

# Once daily at midnight
0 0 * * * root /usr/local/bin/auto-cleanup
```

---

## Configuration

### Configuration File Location

```
/etc/auto-cleanup/auto-cleanup.conf
```

### Key Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `Deployment` | `true` | Enable/disable Deployment cleanup |
| `Pod` | `true` | Enable/disable Pod cleanup |
| `Service` | `true` | Enable/disable Service cleanup |
| `Deployment_HardLimit` | `true` | Enable hard limit for Deployments |
| `Deployment_SoftLimit` | `true` | Enable soft limit for Deployments |
| `Pod_HardLimit` | `true` | Enable hard limit for Pods |
| `Pod_SoftLimit` | `true` | Enable soft limit for Pods |
| `Service_HardLimit` | `true` | Enable hard limit for Services |
| `Service_SoftLimit` | `true` | Enable soft limit for Services |

### Time Limit Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `STUDENT_SOFT` | `24H` | Student soft limit |
| `STUDENT_HARD` | `36H` | Student hard limit |
| `FACULTY_SOFT` | `36H` | Faculty soft limit |
| `FACULTY_HARD` | `84H` | Faculty hard limit |
| `INDUSTRY_SOFT` | `84H` | Industry soft limit |
| `INDUSTRY_HARD` | `168H` | Industry hard limit |

**Time format:** Use `M` for minutes, `H` for hours, `D` for days. Example: `30M`, `2H`, `7D`

### Pod Deletion Configuration

The pod deletion system uses batching and controlled parallelism for efficiency and safety.

| Setting | Default | Description |
|---------|---------|-------------|
| `POD_BATCH_SIZE` | `50` | Number of pods to delete in a single kubectl command |
| `POD_FORCE_DELETE` | `false` | Use `--force --grace-period=0` for immediate termination |
| `POD_BACKGROUND_DELETE` | `true` | Run kubectl delete in background (enables parallelism) |
| `MAX_CONCURRENT_DELETES` | `10` | Maximum parallel kubectl delete processes |
| `KUBECTL_TIMEOUT` | `300` | Timeout for individual kubectl commands (seconds) |
| `WAIT_LOOP_TIMEOUT` | `600` | Maximum wait time for job slots (seconds) |

#### Why Concurrency Controls Are Important

When cleaning up pods across many namespaces, **uncontrolled parallelism can cause serious problems:**

**Without MAX_CONCURRENT_DELETES:**
- 100 namespaces could spawn 100 kubectl processes simultaneously
- Each kubectl process consumes memory and file descriptors
- Kubernetes API server gets overwhelmed with concurrent requests
- System may run out of resources, crash, or become unresponsive

**Without KUBECTL_TIMEOUT:**
- kubectl can hang indefinitely due to network issues, stuck pods, or API problems
- Hung processes block cleanup indefinitely
- Script may never complete, missing subsequent cron runs
- No indication of what went wrong

**Without WAIT_LOOP_TIMEOUT:**
- If kubectl processes hang, the wait loop becomes infinite
- Complete script deadlock - no progress possible
- Requires manual intervention to kill the script

#### Recommended Values by Cluster Size

| Cluster Size | Nodes | MAX_CONCURRENT_DELETES | KUBECTL_TIMEOUT | Notes |
|--------------|-------|------------------------|-----------------|-------|
| **Small** | < 50 | 5 | 300 (5 min) | Conservative limits for smaller API servers |
| **Medium** | 50-200 | 10 | 300 (5 min) | Default configuration (balanced) |
| **Large** | > 200 | 20 | 600 (10 min) | Higher concurrency for large-scale operations |

#### Tuning Guidelines

**Increase MAX_CONCURRENT_DELETES if:**
- You have a large cluster with many namespaces
- Pod deletion takes too long sequentially
- API server has spare capacity (check CPU/memory usage)

**Decrease MAX_CONCURRENT_DELETES if:**
- API server shows high load during cleanup
- You see "too many requests" or rate limiting errors
- System resources (memory, file descriptors) are constrained

**Increase KUBECTL_TIMEOUT if:**
- Pods have complex finalizers that take time
- Network latency to API server is high
- You see legitimate deletions timing out

**Decrease KUBECTL_TIMEOUT if:**
- You want faster detection of hung processes
- Your cluster typically has fast pod terminations
- You're willing to retry on timeout

#### Example Scenarios

**Scenario 1: 200 pods across 50 namespaces (4 pods each)**
```
Batching: 4 pods/namespace = 50 kubectl commands (1 per namespace)
Concurrency: With MAX_CONCURRENT_DELETES=10, runs 10 at a time
Result: 5 waves of 10 parallel deletions = efficient and controlled
```

**Scenario 2: 500 pods in 1 namespace**
```
Batching: 500 pods / 50 batch_size = 10 kubectl commands
Concurrency: All 10 run in parallel (< MAX_CONCURRENT_DELETES)
Result: Fast cleanup without overwhelming the system
```

**Scenario 3: 5000 pods across 100 namespaces**
```
Without limits: 100+ kubectl processes spawn immediately (DANGEROUS!)
With limits: MAX 10 concurrent, others wait → controlled and safe
```

### Editing Configuration

```bash
sudo nano /etc/auto-cleanup/auto-cleanup.conf
```

---

## Exclusions

Exclusion files allow you to protect specific namespaces or resources from cleanup.

### Exclusion File Locations

| File | Purpose |
|------|---------|
| `/etc/auto-cleanup/exclude_namespaces` | Skip entire namespaces |
| `/etc/auto-cleanup/exclude_deployments` | Skip specific deployments by name |
| `/etc/auto-cleanup/exclude_pods` | Skip specific pods by name |
| `/etc/auto-cleanup/exclude_services` | Skip specific services by name |

### File Format

- One name per line
- Lines starting with `#` are comments
- Empty lines are ignored

**Example `/etc/auto-cleanup/exclude_namespaces`:**

```
# Critical namespaces - never delete resources here
dgx-s-admin
dgx-f-shared-resources
```

### Adding Exclusions

```bash
# Exclude a namespace
echo "dgx-s-critical-user" | sudo tee -a /etc/auto-cleanup/exclude_namespaces

# Exclude a specific deployment
echo "important-deployment" | sudo tee -a /etc/auto-cleanup/exclude_deployments
```

---

## Logs

### Log Location

```
/var/log/giindia/auto-cleanup/
```

### Log File Format

Logs are rotated daily with the format:

```
auto-cleanup-YYYY-MM-DD.log
```

Example: `auto-cleanup-2025-12-14.log`

### Viewing Logs

```bash
# List log files
ls -la /var/log/giindia/auto-cleanup/

# View today's log
sudo cat /var/log/giindia/auto-cleanup/auto-cleanup-$(date +%Y-%m-%d).log

# Follow logs in real-time
sudo tail -f /var/log/giindia/auto-cleanup/auto-cleanup-$(date +%Y-%m-%d).log
```

### Log Levels

| Level | Description |
|-------|-------------|
| `DEBUG` | Detailed diagnostic information |
| `INFO` | General operational messages |
| `WARNING` | Non-critical issues |
| `ERROR` | Critical problems |

Default log level is `INFO`. Change it in the configuration file with `LOG_LEVEL=DEBUG`.

### Log Retention

By default, logs older than 30 days are automatically deleted. Adjust with `LOG_RETENTION_DAYS` in the configuration.

---

## Protecting Resources with Keep-Alive

Users can protect their resources from soft-limit deletion by adding the `keep-alive=true` label.

### Adding Keep-Alive to Running Resources

```bash
# Protect a running pod
kubectl label pod <pod-name> -n <namespace> keep-alive=true

# Protect a deployment
kubectl label deployment <deployment-name> -n <namespace> keep-alive=true

# Protect a service
kubectl label service <service-name> -n <namespace> keep-alive=true
```

### Example

```bash
# Protect a pod named "training-job" in namespace "dgx-s-user1"
kubectl label pod training-job -n dgx-s-user1 keep-alive=true
```

### Updating an Existing Label

```bash
kubectl label pod <pod-name> -n <namespace> keep-alive=true --overwrite
```

### Important Notes

- The `keep-alive=true` label only protects against **soft limit** deletion
- Once the **hard limit** is reached, the resource **will be deleted** regardless of the label
- This allows users to extend their resource lifetime within the soft-to-hard limit window

---

## Quick Reference

| Item | Location |
|------|----------|
| Command | `/usr/local/bin/auto-cleanup` |
| Configuration | `/etc/auto-cleanup/auto-cleanup.conf` |
| Exclusion files | `/etc/auto-cleanup/exclude_*` |
| Logs | `/var/log/giindia/auto-cleanup/` |
| Installation directory | `/opt/auto-cleanup/` |

---

## Troubleshooting

### Script won't run

1. Check if another instance is running (lock file: `/var/run/auto-cleanup.lock`)
2. Verify kubectl is configured and accessible
3. Check logs for error messages

### Resources not being deleted

1. Verify the namespace matches `dgx-s-*`, `dgx-f-*`, or `dgx-i-*` pattern
2. Check if the namespace or resource is in an exclusion file
3. Confirm the resource age exceeds the configured limits
4. For pods, ensure they are standalone (not managed by a controller)

### Resources deleted unexpectedly

1. Check if the hard limit was reached (overrides keep-alive)
2. Verify the keep-alive label is correctly set (`keep-alive=true`, not `keep-alive: true`)
3. Review the configuration for the correct user type limits

### kubectl processes appear hung or script never completes

**Symptoms:**
- Script runs for hours without completing
- Lock file exists but cleanup isn't progressing
- High number of kubectl processes visible in process list

**Diagnosis:**

```bash
# Check for running kubectl processes
ps aux | grep kubectl

# Check how long the script has been running
ps aux | grep auto-cleanup

# Check lock file age
ls -la /var/run/auto-cleanup.lock
```

**Solutions:**

1. **Check logs for timeout messages:**
   ```bash
   sudo tail -100 /var/log/giindia/auto-cleanup/auto-cleanup-$(date +%Y-%m-%d).log | grep -i timeout
   ```

2. **Verify timeout settings are reasonable:**
   - KUBECTL_TIMEOUT should be 300-600 seconds (5-10 minutes)
   - WAIT_LOOP_TIMEOUT should be at least 2× KUBECTL_TIMEOUT
   - Edit `/etc/auto-cleanup/auto-cleanup.conf` if needed

3. **Check for stuck pods in Terminating state:**
   ```bash
   kubectl get pods --all-namespaces | grep Terminating
   ```
   Pods with finalizers can cause kubectl to hang. Force delete if necessary:
   ```bash
   kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0
   ```

4. **Reduce concurrency if API server is overloaded:**
   ```bash
   # In /etc/auto-cleanup/auto-cleanup.conf
   MAX_CONCURRENT_DELETES=5  # Reduce from 10 to 5
   ```

5. **Kill hung processes manually (emergency only):**
   ```bash
   # Kill all kubectl delete processes
   pkill -f "kubectl delete"

   # Remove lock file
   sudo rm -f /var/run/auto-cleanup.lock
   ```

### Performance issues or API server errors

**Symptoms:**
- "too many requests" errors in logs
- API server shows high CPU/memory usage during cleanup
- Cluster performance degrades during cleanup runs

**Solutions:**

1. **Reduce MAX_CONCURRENT_DELETES:**
   ```bash
   # In /etc/auto-cleanup/auto-cleanup.conf
   MAX_CONCURRENT_DELETES=5  # Lower value = less API server load
   ```

2. **Disable background deletion (sequential mode):**
   ```bash
   # In /etc/auto-cleanup/auto-cleanup.conf
   POD_BACKGROUND_DELETE=false  # Slower but more predictable load
   ```

3. **Reduce batch size:**
   ```bash
   # In /etc/auto-cleanup/auto-cleanup.conf
   POD_BATCH_SIZE=25  # Smaller batches = less memory per kubectl process
   ```

4. **Run cleanup during off-peak hours:**
   ```bash
   # Update cron schedule to run at night
   echo '0 2 * * * root /usr/local/bin/auto-cleanup' | sudo tee /etc/cron.d/auto-cleanup
   ```

---

**Author:** Anubhav - Global Infoventures  
**Contact:** anubhav.patrick@giindia.com

