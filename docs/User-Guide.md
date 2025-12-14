# Auto-Cleanup System - User Guide

## What is Auto-Cleanup?

The cluster runs an automatic garbage collection system that deletes idle Deployments, Pods, and Services to free up GPU and compute resources for other users. Resources are deleted based on their age and your user type.

## Usage Limits

Your resources are subject to two types of limits based on your namespace prefix. The exact time limits are configured by your cluster administrator.

| User Type | Namespace Prefix |
|-----------|------------------|
| **Student** | `dgx-s-*` |
| **Faculty** | `dgx-f-*` |
| **Industry** | `dgx-i-*` |

**Contact your cluster administrator to learn the specific soft and hard limits configured for your user type.**

### What are Soft and Hard Limits?

- **Soft Limit**: Your resource will be deleted when it reaches this age, **UNLESS** you add a `keep-alive` label (see below)
- **Hard Limit**: Your resource will be **AUTOMATICALLY DELETED** when it reaches this age, **NO EXCEPTIONS**

---

## CRITICAL: Data Persistence Warning

### YOU ARE RESPONSIBLE FOR SAVING YOUR DATA TO PERSISTENT STORAGE

- Pods and their data can be **AUTOMATICALLY DELETED** at any time when they reach usage limits
- Any data stored **inside the pod** (code, models, checkpoints, results) will be **PERMANENTLY LOST**
- The garbage collector runs automatically and will delete resources **without confirmation**
- There is **NO DATA RECOVERY** after deletion

### How to Protect Your Data

**ALWAYS** save your work to:
- Persistent Volumes (PVs)
- Network storage (NFS, shared drives)
- External repositories (Git, cloud storage)
- Database servers

**NEVER** rely on pod-local storage for important data

---

## Extending Soft Limits (Keep-Alive Label)

You can temporarily protect your resources from **soft limit** deletion by adding a `keep-alive` label. This label can be added when you create a resource or added later to already running resources.

### Adding the Keep-Alive Label When Creating Resources

You can include the `keep-alive` label directly in your YAML manifest when creating a new resource:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-training-job
  namespace: dgx-s-username
  labels:
    keep-alive: "true"
spec:
  containers:
  - name: pytorch
    image: pytorch/pytorch:latest
    command: ["python", "train.py"]
    resources:
      limits:
        nvidia.com/gpu: 1
```

**Note:** The same pattern applies to Deployments and Services. Simply add `keep-alive: "true"` under the `metadata.labels` section of your YAML manifest.

### Adding the Keep-Alive Label to Existing Resources

You can add the `keep-alive` label to resources that are already running:

```bash
# Protect an existing pod
kubectl label pod <pod-name> -n <your-namespace> keep-alive=true

# Protect an existing deployment
kubectl label deployment <deployment-name> -n <your-namespace> keep-alive=true

# Protect an existing service
kubectl label service <service-name> -n <your-namespace> keep-alive=true
```

### Updating an Existing Label

If the label already exists and you want to change its value:

```bash
kubectl label pod <pod-name> -n <your-namespace> keep-alive=true --overwrite
```

### Important Restrictions

- **Keep-alive only works until the HARD limit** - Your resource will still be deleted at the hard limit
- **Use sparingly** - This feature should only be used in rare scenarios when you need a few extra hours
- **Not a permanent solution** - Resources with `keep-alive=true` still count toward cluster capacity
- **Soft limit only** - Once hard limit is reached, your resource will be deleted regardless of the label

---

## How Auto-Cleanup Works (User Perspective)

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Pod/Deployment/Service is Running                         │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
          ┌──────────────────────┐
          │  Age < Soft Limit?   │
          └──────┬───────────────┘
                 │
        ┌────────┴────────┐
        │ YES             │ NO
        ▼                 ▼
  ┌─────────┐    ┌─────────────────────┐
  │ Keep    │    │ Has keep-alive=true │
  │ Running │    │ label?              │
  └─────────┘    └──────┬──────────────┘
                        │
                 ┌──────┴───────┐
                 │ YES          │ NO
                 ▼              ▼
          ┌─────────────┐  ┌──────────────┐
          │ Age < Hard  │  │   DELETED    │
          │ Limit?      │  └──────────────┘
          └──────┬──────┘
                 │
          ┌──────┴───────┐
          │ YES          │ NO
          ▼              ▼
    ┌─────────┐    ┌──────────────┐
    │ Keep    │    │   DELETED    │
    │ Running │    │ (Hard Limit) │
    └─────────┘    └──────────────┘
```

---

## Best Practices

### DO

- **Save all important data to persistent storage immediately**
- Monitor your resource age using `kubectl get pods -n <namespace> --show-labels`
- Delete resources manually when you're done to free up cluster capacity
- Plan your work to complete within the soft limit timeframe
- Use `keep-alive` only when absolutely necessary and you're actively working

### DON'T

- Rely on pod-local storage for anything important
- Assume your pod will run indefinitely
- Use `keep-alive` as a default practice
- Leave idle resources running "just in case"
- Store code, models, or results only inside the pod

---

## Checking Your Resource Age

```bash
# List all pods in your namespace with creation timestamp
kubectl get pods -n <your-namespace> -o wide

# Check labels on a specific pod
kubectl get pod <pod-name> -n <your-namespace> --show-labels

# See when your pod was created
kubectl describe pod <pod-name> -n <your-namespace> | grep "Created"
```

---

## Frequently Asked Questions

**Q: Can I recover my data after my pod is deleted?**
A: No. Once deleted, all data stored inside the pod is permanently lost.

**Q: How often does the garbage collector run?**
A: The garbage collector runs automatically on a schedule. Assume your resources will be deleted as soon as they reach the limit.

**Q: What if I need more time than the hard limit?**
A: Hard limits cannot be extended. Plan your work accordingly or contact your cluster administrator if you have exceptional requirements.

**Q: Will I be notified before deletion?**
A: No. The system deletes resources automatically without notification. It is your responsibility to monitor resource age.

**Q: Can I disable auto-cleanup for my namespace?**
A: Contact your cluster administrator if you believe you need an exemption. Exemptions are granted rarely and only for specific use cases.

**Q: Does the `keep-alive` label cost me anything?**
A: There is no direct cost, but your resource continues to occupy cluster capacity (GPU, memory, CPU) that other users might need. Use it responsibly.

---

## Support

For questions or issues with the auto-cleanup system, contact your cluster administrator.

**Remember: Always save your data to persistent storage. The auto-cleanup system is designed to optimize cluster utilization and will delete resources automatically.**
