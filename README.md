# ✅ Kubernetes Auto Resource Cleanup Tool (Deployments, Pods & Services)

This tool is a **policy-driven Kubernetes auto-cleanup system** designed for **multi-user GPU clusters** (DGX, HPC, academic labs, shared infra). It automatically deletes **stale Deployments, Pods, and Services** based on **hard & soft age limits**, while supporting:

- ✅ User-type based limits (Student / Faculty / Industry)
- ✅ Namespace-level exclusions
- ✅ Resource-specific exclusions
- ✅ `keep-alive=true` label protection
- ✅ Batched background pod deletion (non-blocking)
- ✅ Cron-safe execution (no deadlocks)
- ✅ Full audit logging

---

## 🧠 Execution Order (Guaranteed)

The script **always runs in this strict order**:

1. **Deployments Cleanup**
2. **Pods Cleanup (Batch-Queued Deletion)**
3. **Services Cleanup**
4. **Exit & Unlock**

➡ No step blocks the next.

---

## 🔐 Script Locking (Cron-Safe)

Only **one instance** of the script can run at a time.

If another run starts while one is executing:
- The new run exits immediately.
- This prevents **overlapping cron deadlocks**.

---

## 🗑️ Deletion Logic (Unified for All Resources)

Each resource (Deployment / Pod / Service) follows:

### 1️⃣ Hard Limit (Forced Delete)
If:

AGE ≥ HARD LIMIT

Then:

➡ `keep-alive` label is **ignored**

➡ Resource is **deleted immediately**  

---

### 2️⃣ Soft Limit (Conditional Delete)
If:

AGE ≥ SOFT LIMIT

Then:

| keep-alive Label | Action |
|------------------|--------|
| Not present      | DELETE |
| FALSE/False/false| DELETE |
| TRUE/True/true   | SKIP   |

---

### 3️⃣ Below Soft Limit

AGE < SOFT LIMIT

➡ Resource is always **preserved**

---

## ⚡ High-Performance Pod Deletion (Non-Blocking)

Pods are **NOT deleted one-by-one**.

Instead:

1. All eligible **standalone pods** (pods without ownerReferences) are:
   - Evaluated
   - Queued into a memory array

2. The script issues batched deletions:

   kubectl delete pod pod1 pod2 pod3 ... -n <namespace>
   
3. Pods enter **Terminating state**

4. Script **immediately proceeds to services**

5. Script **does NOT wait for completion** (when background delete is enabled)

✅ Eliminates **50+ minute deletion delays**

✅ Safe for **hourly cron schedules**

> **Note:** Only standalone pods (not managed by Deployments, ReplicaSets, Jobs, etc.) are processed. Pods with `ownerReferences` are automatically skipped.

---

## 👥 User Categories & Policy Routing

Namespace prefix determines which limits apply:

| Namespace Pattern | User Type  | Limits Used |
|------------------|------------|-------------|
| `dgx-s-*`        | Student    | `STUDENT_*` |
| `dgx-f-*`        | Faculty    | `FACULTY_*` |
| `dgx-i-*`        | Industry   | `INDUSTRY_*` |

---

## 🧾 Label-Based Protection

To protect any resource:

metadata:

 labels:
 
   keep-alive: "true"

➡ This protects it from **only under soft-limit conditions**.  

➡ **Hard limit always overrides.**

---

## ⛔ Exclusion System (Full Control)

These files should be placed in the same directory as the script (optional - missing files are ignored):

| File | Purpose |
| --- | --- |
| `exclude_namespaces.txt` | Skip entire namespaces |
| `exclude_deployments.txt` | Skip specific deployments |
| `exclude_pods.txt` | Skip specific pods |
| `exclude_services.txt` | Skip specific services |

### File Format

resource-name

resource-name-2

➡ Comments are allowed

---

## ⚙️ Configuration (`cleanup_config.env`)

### ✅ Enable / Disable Resource Types

Deployment=True

Pod=True

Service=True

---

### ✅ Enable / Disable Hard / Soft Logic Per Resource

Deployment_HardLimit=True

Deployment_SoftLimit=True


Pod_HardLimit=True

Pod_SoftLimit=True


Service_HardLimit=True

Service_SoftLimit=True

---

### ✅ Time Limits (Minutes)

# Students
STUDENT_SOFT=2

STUDENT_HARD=30


# Faculty
FACULTY_SOFT=2

FACULTY_HARD=30


# Industry
INDUSTRY_SOFT=2

INDUSTRY_HARD=10

---

### ✅ Pod Batch Deletion Settings

POD_FORCE_DELETE=false    # If true, uses --grace-period=0 --force

POD_BACKGROUND_DELETE=true   # If true, runs deletion in background (non-blocking)

POD_BATCH_SIZE=50   # Number of pods to delete per kubectl command

---

### ✅ Logging Output

LOG_FILE="/var/log/giindia/auto_cleanup_logs/auto_cleanup.log"

---

## 📝 Logging Behavior

Every action is:

-   ✅ Logged to file
    
-   ✅ Echoed to terminal
    
-   ✅ Timestamped
    

Examples:

Pod user-pod-1 (dgx-s-1): keep-alive=false -> deleting (soft path)

Deployment train-job (dgx-f-2): HARD delete triggered

Service api-svc (dgx-i-1): safe/untouched

---

## 🔁 Cron Job Example

Run every hour:

0 * * * * /bin/bash /path/to/auto-pod-deletion.sh

---

## ✅ Safety Guarantees

-   No duplicate executions
            
-   No skipped namespace touched
    
-   No excluded resource touched
    
-   No cluster freeze during mass deletions

---

## 📌 Recommended Best Practices

-   Always test with:
    
    Service=False

    Pod=False

    Deployment=False
    
-   Then enable resources gradually.
    
-   Always maintain exclusion files.
    
-   Always keep logs mounted to persistent storage.
