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

No step blocks the next.

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
```

AGE ≥ HARD\_LIMIT

```yaml
➡ Resource is **deleted immediately**  
➡ `keep-alive` label is **ignored**

---

### 2️⃣ Soft Limit (Conditional Delete)
If:
```

AGE ≥ SOFT\_LIMIT

```yaml
Then:

| keep-alive Label | Action |
|------------------|--------|
| Not present      | DELETE |
| false            | DELETE |
| true             | SKIP   |

---

### 3️⃣ Below Soft Limit
```

AGE < SOFT\_LIMIT

```yaml
➡ Resource is always **preserved**

---

## ⚡ High-Performance Pod Deletion (Non-Blocking)

Pods are **NOT deleted one-by-one**.

Instead:

1. All eligible pods are:
   - Evaluated
   - Queued into a memory array
2. The script issues:
```

kubectl delete pod pod1 pod2 pod3 ...

```yaml
3. Pods enter **Terminating state**
4. Script **immediately proceeds to services**
5. Script **does NOT wait for completion**

✅ Eliminates **50+ minute deletion delays**
✅ Safe for **hourly cron schedules**

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

```yaml
metadata:
labels:
 keep-alive: "true"
```

This protects it **only under soft-limit conditions**.  
**Hard limit always overrides.**

---

## ⛔ Exclusion System (Full Control)

These files must exist in the same directory as the script:

| File | Purpose |
| --- | --- |
| `exclude_namespaces.txt` | Skip entire namespaces |
| `exclude_deployments.txt` | Skip specific deployments |
| `exclude_pods.txt` | Skip specific pods |
| `exclude_services.txt` | Skip specific services |

### File Format

```pgsql
resource-name
resource-name-2
# comments are allowed
```

---

## ⚙️ Configuration (`cleanup_config.env`)

### ✅ Enable / Disable Resource Types

```env
Deployment=True
Pod=True
Service=True
```

---

### ✅ Enable / Disable Hard / Soft Logic Per Resource

```env
Deployment_HardLimit=True
Deployment_SoftLimit=True

Pod_HardLimit=True
Pod_SoftLimit=True

Service_HardLimit=True
Service_SoftLimit=True
```

---

### ✅ Time Limits (Minutes)

```env
# Students
STUDENT_SOFT=2
STUDENT_HARD=40

# Faculty
FACULTY_SOFT=2
FACULTY_HARD=40

# Industry
INDUSTRY_SOFT=2
INDUSTRY_HARD=25
```

---

### ✅ Logging Output

```env
LOG_FILE="/var/log/giindia/auto_cleanup_logs/auto_cleanup.logs"
```

---

## 📝 Logging Behavior

Every action is:

-   ✅ Logged to file
    
-   ✅ Echoed to terminal
    
-   ✅ Timestamped
    

Examples:

```pgsql
Pod user-pod-1 (dgx-s-1): keep-alive=false -> deleting (soft path)
Deployment train-job (dgx-f-2): HARD delete triggered
Service api-svc (dgx-i-1): safe/untouched
```

---

## 🔁 Cron Job Example

Run every hour:

```bash
0 * * * * /bin/bash /root/auto-pod-delete/auto-pod-deletion-final.sh
```

---

## ✅ Safety Guarantees

-   No duplicate executions
    
-   No service deleted before pods
    
-   No pod blocking service cleanup
    
-   No student resource deleted using faculty policy
    
-   No skipped namespace touched
    
-   No excluded resource touched
    
-   No cluster freeze during mass deletions
    

---

## ✅ Production Ready Status

This script is now **fully suitable for**:

-   NVIDIA DGX Kubernetes Clusters
    
-   University GPU Labs
    
-   Multi-tenant AI infra
    
-   Research clusters
    
-   Slurm-to-Kubernetes hybrid environments
    

---

## 📌 Recommended Best Practices

-   Always test with:
    
    ```ini
    Service=False
    Pod=False
    Deployment=False
    ```
    
-   Then enable resources gradually.
    
-   Always maintain exclusion files.
    
-   Always keep logs mounted to persistent storage.
