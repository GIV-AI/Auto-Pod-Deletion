# 🧹 **Auto Cleanup System for Kubernetes Deployments, Pods & Services**
### *A simple, automated tool to keep your DGX Kubernetes namespaces clean and healthy*

## 📌 **Overview**
This tool automatically **monitors** and **cleans up** user-created Kubernetes resources inside the DGX namespaces:

- **Deployments**
- **Pods**
- **Services** (connected to pods or deployments)

The goal is to make sure:
- Old & unused resources are removed,
- Cluster GPU & CPU capacity is freed,
- Users don’t accidentally leave long-running workloads,
- Everything stays clean without manual monitoring.

This system runs **automatically at Your Desired Interval**.

---

## 🔧 **How It Works (Simple Explanation)**

### ✔ 1. **Reads settings from a config file**
All cleanup behavior is controlled by:

```
cleanup_config.env
```

Users ONLY edit this config file, not the script.

---

### ✔ 2. **Cleans up Deployments first**
Checks age, soft limits, hard limits, CPU, and keep-alive labels.

Deletes any linked Services using:
- Label matching  
- Name matching  
- Selector-subset matching  

---

### ✔ 3. **Cleans up Pods next**
Similar logic to Deployments.

Pod Services are deleted using:
- Direct label selectors  
- Service name == pod name  
- Selector-subset matching (accurate and safe)

---

### ✔ 4. **Logging**
All actions are logged to:

```
/var/log/auto_cleanup.log
```

---

## 📁 **Files**
```
auto-pod-deletion.sh
cleanup_config.env
README.md
```

---

## ⚙️ **Configuration Guide**

### Enable/Disable Resource Cleanup by switching between `Yes`and `No`
```
Deployment=Yes
Pod=Yes
```

### Enable/Disable Hard + Soft Limits
Deployment:
```
Deployment_Hard=Yes
Deployment_Soft=Yes
```
Pods:
```
Pod_Hard=Yes
Pod_Soft=Yes
```

### Time Limits (minutes)
```
STUDENT_SOFT=720
STUDENT_HARD=2160

FACULTY_SOFT=4320
FACULTY_HARD=20160
```

### CPU Threshold
```
CPU_THRESHOLD=100
```

### Logging
```
LOG_FILE="/var/log/auto_cleanup.log"
```

---

## 🕒 **Cron Job (Runs at Your Desired Interval)**

Add the following entry to sudo crontab -e, and replace each * with your desired schedule values in the order:
Minute / Hour / Day-of-Month / Month / Day-of-Week
```
* * * * * /bin/bash /path/to/auto-pod-deletion.sh >> /var/log/auto_cleanup_cron.log 2>&1
```

---

## 🚀 **Setup Steps**

```
chmod +x auto-pod-deletion.sh
nano cleanup_config.env
sudo crontab -e
```

---

## 🛡 **Safety Features**
- Selector-based service deletion  
- Namespace filtering  
- CPU-based protection  
- User-friendly config  

---

## 📝 **Summary (For Non-Technical Users)**

| Feature | Description |
|---------|-------------|
| Auto Cleanup | Frees resources every 2 hours |
| Deployment Cleanup | Removes old/idle deployments |
| Pod Cleanup | Removes old/idle pods |
| Intelligent Service Cleanup | Deletes linked services only |
| Config-driven | No script editing required |
| Safe | Active workloads stay untouched |

---

This system ensures the DGX Kubernetes environment remains **clean, stable, and efficient** with minimal human intervention.
