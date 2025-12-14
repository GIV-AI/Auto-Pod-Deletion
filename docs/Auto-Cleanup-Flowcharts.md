# Auto-Cleanup System Flowcharts

This document provides visual flowcharts to understand the logic and execution flow of the Auto-Cleanup system. Due to the complexity of the system, the documentation is organized into 6 sub-flowcharts, each focusing on a specific aspect.

## Table of Contents

1. [Main Execution Flow](#1-main-execution-flow)
2. [Resource Processing Flow](#2-resource-processing-flow)
3. [Limit Evaluation Decision](#3-limit-evaluation-decision-cleanup_resource)
4. [Namespace Type Resolution](#4-namespace-type-resolution)
5. [Pod Batch Deletion Flow](#5-pod-batch-deletion-flow)
6. [Exclusion Checking Flow](#6-exclusion-checking-flow)
7. [Flowchart Legend](#flowchart-legend)

---

## 1. Main Execution Flow

The high-level orchestration flow showing how `bin/auto-cleanup` coordinates the entire cleanup process.

```mermaid
flowchart TD
    Start([Start: auto-cleanup]) --> ParseArgs{Parse Arguments}
    
    ParseArgs -->|--help| ShowHelp[Display Help]
    ParseArgs -->|--version| ShowVersion[Display Version]
    ParseArgs -->|--quiet| SetQuiet[Set LOG_LEVEL=ERROR]
    ParseArgs -->|No args| Continue[Continue Execution]
    
    ShowHelp --> Exit0([Exit 0])
    ShowVersion --> Exit0
    SetQuiet --> Continue
    
    Continue --> CheckDeps{Check Dependencies}
    CheckDeps -->|Missing| DepError[Log Error: Missing deps]
    DepError --> Exit1([Exit 1])
    
    CheckDeps -->|All present| AcquireLock{Acquire Lock}
    AcquireLock -->|Already locked| LockError[Log Error: Another instance running]
    LockError --> Exit1
    
    AcquireLock -->|Success| LoadConfig{Load Configuration}
    LoadConfig -->|Failed| ConfigError[Log Error: Config load failed]
    ConfigError --> Exit1
    
    LoadConfig -->|Success| InitLogging{Initialize Logging}
    InitLogging -->|Failed| LogError[Log Error: Logging init failed]
    LogError --> Exit1
    
    InitLogging -->|Success| InitExclusions[Initialize Exclusion Paths]
    InitExclusions --> LoadExclusions[Load All Exclusions]
    LoadExclusions --> InitLimitFlags[Initialize Limit Flags]
    
    InitLimitFlags --> ProcessDeploy[Process Deployments]
    ProcessDeploy --> ProcessPods[Process Pods]
    ProcessPods --> FlushQueue[Flush Pod Queue]
    FlushQueue --> ProcessSvc[Process Services]
    
    ProcessSvc --> ReleaseLock[Release Lock]
    ReleaseLock --> Complete([Cleanup Complete])
    
    subgraph ResourceProcessing [Resource Processing Order]
        ProcessDeploy
        ProcessPods
        FlushQueue
        ProcessSvc
    end
```

**Key Points:**
- Dependencies checked: `kubectl`, `date`, `awk`, `grep`, `sed`, `flock`
- Lock file prevents concurrent execution: `/var/run/auto-cleanup.lock`
- Trap handler ensures lock release on exit/interrupt
- Resources processed in order: Deployments → Pods → Services

**Source:** [`bin/auto-cleanup`](../bin/auto-cleanup) (main function, lines 217-279)

---

## 2. Resource Processing Flow

Generic flow for processing each resource type (Deployments, Pods, or Services).

```mermaid
flowchart TD
    Start([Start: process_TYPE]) --> CheckEnabled{Is TYPE enabled?}
    
    CheckEnabled -->|No| LogDisabled[Log: TYPE checks disabled]
    LogDisabled --> EndEarly([Return])
    
    CheckEnabled -->|Yes| LogStart[Log: Starting TYPE cleanup]
    LogStart --> GetResources[Get all TYPE resources via kubectl]
    
    GetResources --> LoopStart{More resources?}
    LoopStart -->|No| LogComplete[Log: TYPE cleanup completed]
    LogComplete --> EndComplete([Return])
    
    LoopStart -->|Yes| ReadResource[Read: namespace, name]
    ReadResource --> ValidCheck{Valid ns and name?}
    
    ValidCheck -->|No| LoopStart
    ValidCheck -->|Yes| CheckNsExclude{Namespace excluded?}
    
    CheckNsExclude -->|Yes| LogSkipNs[Log: Skip - namespace excluded]
    LogSkipNs --> LoopStart
    
    CheckNsExclude -->|No| CheckResExclude{Resource name excluded?}
    CheckResExclude -->|Yes| LogSkipRes[Log: Skip - resource excluded]
    LogSkipRes --> LoopStart
    
    CheckResExclude -->|No| IsPod{Is this a Pod?}
    
    IsPod -->|Yes| CheckStandalone{Is standalone pod?}
    CheckStandalone -->|No| LoopStart
    CheckStandalone -->|Yes| GetAge[Get resource age in minutes]
    
    IsPod -->|No| GetAge
    
    GetAge --> GetLimits[Get limits for namespace]
    GetLimits --> LimitsCheck{Limits available?}
    
    LimitsCheck -->|No| LoopStart
    LimitsCheck -->|Yes| CallCleanup[Call cleanup_resource]
    
    CallCleanup --> LoopStart
    
    subgraph ExclusionChecks [Exclusion Checks]
        CheckNsExclude
        CheckResExclude
    end
```

**Key Points:**
- Each resource type has its own `process_*` function but follows the same pattern
- Pods have an extra check: only **standalone pods** (no ownerReferences) are processed
- Managed pods (created by Deployments, Jobs, etc.) are skipped - their controllers handle them
- Namespace pattern filter: only `dgx-*` namespaces are processed

**Source:** [`lib/cleanup.sh`](../lib/cleanup.sh)
- `process_deployments()` (lines 347-378)
- `process_pods()` (lines 386-431)
- `process_services()` (lines 439-465)

---

## 3. Limit Evaluation Decision (cleanup_resource)

The core decision logic that determines whether a resource should be deleted.

```mermaid
flowchart TD
    Start([Start: cleanup_resource]) --> SelectFlags[Select hard/soft flags for resource kind]
    
    SelectFlags --> CheckExcluded{Resource excluded?}
    CheckExcluded -->|Yes| LogSkip[Log: Skipping - excluded]
    LogSkip --> ReturnSkip([Return])
    
    CheckExcluded -->|No| CheckHardFlag{Hard limit enabled?}
    
    CheckHardFlag -->|Yes| CheckHardAge{age >= hard_limit?}
    CheckHardAge -->|Yes| HardDelete[HARD LIMIT TRIGGERED]
    
    HardDelete --> IsPodHard{Is Pod?}
    IsPodHard -->|Yes| QueueHard[Queue pod for batch deletion]
    IsPodHard -->|No| DeleteHard[Delete resource immediately]
    
    QueueHard --> LogHard[Log: HARD delete queued/executed]
    DeleteHard --> LogHard
    LogHard --> ReturnHard([Return])
    
    CheckHardFlag -->|No| CheckSoftFlag
    CheckHardAge -->|No| CheckSoftFlag{Soft limit enabled?}
    
    CheckSoftFlag -->|Yes| CheckSoftAge{age >= soft_limit?}
    CheckSoftAge -->|No| WithinLimits[Resource within limits]
    WithinLimits --> LogWithin[Log: age within limits]
    LogWithin --> ReturnOK([Return])
    
    CheckSoftFlag -->|No| WithinLimits
    
    CheckSoftAge -->|Yes| SoftReached[SOFT LIMIT REACHED]
    SoftReached --> GetKeepAlive[Get keep-alive label value]
    
    GetKeepAlive --> CheckKeepAlive{keep-alive = true?}
    
    CheckKeepAlive -->|Yes| KeepResource[Keep resource alive]
    KeepResource --> LogKeep[Log: keep-alive=true, keeping]
    LogKeep --> ReturnKeep([Return])
    
    CheckKeepAlive -->|No| SoftDelete[SOFT DELETE]
    
    SoftDelete --> IsPodSoft{Is Pod?}
    IsPodSoft -->|Yes| QueueSoft[Queue pod for batch deletion]
    IsPodSoft -->|No| DeleteSoft[Delete resource immediately]
    
    QueueSoft --> LogSoft[Log: SOFT delete queued/executed]
    DeleteSoft --> LogSoft
    LogSoft --> ReturnSoft([Return])
    
    subgraph HardLimitPath [Hard Limit Path - Ignores keep-alive]
        CheckHardAge
        HardDelete
        IsPodHard
        QueueHard
        DeleteHard
    end
    
    subgraph SoftLimitPath [Soft Limit Path - Respects keep-alive]
        CheckSoftAge
        SoftReached
        GetKeepAlive
        CheckKeepAlive
        SoftDelete
        IsPodSoft
        QueueSoft
        DeleteSoft
    end
```

**Key Points:**
- **Hard Limit**: Always deletes when age exceeds limit, **ignores** `keep-alive` label
- **Soft Limit**: Respects `keep-alive=true` label; only deletes if not set or `false`
- Pods are queued for batch deletion; Deployments and Services are deleted immediately
- Exclusions are checked first before any limit evaluation
- If the hard limit is not set and the user starts a pod/service/deployment with the `keep-alive` label, then the resource will not be auto-deleted.

**Source:** [`lib/cleanup.sh`](../lib/cleanup.sh) - `cleanup_resource()` (lines 139-226)

---

## 4. Namespace Type Resolution

How time limits are determined based on namespace naming convention.

```mermaid
flowchart TD
    Start([Start: get_limits_for_namespace]) --> GetUserType[Determine user type from namespace]
    
    GetUserType --> CheckPrefix{Check namespace prefix}
    
    CheckPrefix -->|dgx-s-*| Student[User Type: Student]
    CheckPrefix -->|dgx-f-*| Faculty[User Type: Faculty]
    CheckPrefix -->|dgx-i-*| Industry[User Type: Industry]
    CheckPrefix -->|Other| NoMatch[No matching pattern]
    
    NoMatch --> ReturnEmpty1([Return empty - skip resource])
    
    Student --> CheckStudentConfig{STUDENT_SOFT and STUDENT_HARD configured?}
    CheckStudentConfig -->|No| LogWarnStudent[Log Warning: Missing config]
    LogWarnStudent --> ReturnEmpty2([Return empty])
    CheckStudentConfig -->|Yes| ParseStudent[Parse time values to minutes]
    ParseStudent --> ReturnStudent([Return: STUDENT_SOFT STUDENT_HARD])
    
    Faculty --> CheckFacultyConfig{FACULTY_SOFT and FACULTY_HARD configured?}
    CheckFacultyConfig -->|No| LogWarnFaculty[Log Warning: Missing config]
    LogWarnFaculty --> ReturnEmpty3([Return empty])
    CheckFacultyConfig -->|Yes| ParseFaculty[Parse time values to minutes]
    ParseFaculty --> ReturnFaculty([Return: FACULTY_SOFT FACULTY_HARD])
    
    Industry --> CheckIndustryConfig{INDUSTRY_SOFT and INDUSTRY_HARD configured?}
    CheckIndustryConfig -->|No| LogWarnIndustry[Log Warning: Missing config]
    LogWarnIndustry --> ReturnEmpty4([Return empty])
    CheckIndustryConfig -->|Yes| ParseIndustry[Parse time values to minutes]
    ParseIndustry --> ReturnIndustry([Return: INDUSTRY_SOFT INDUSTRY_HARD])
    
    subgraph TimeFormat [Time Format Parsing]
        direction LR
        T1["30 or 30M = 30 minutes"]
        T2["2H = 120 minutes"]
        T3["7D = 10080 minutes"]
    end
```

**Default Configuration Values:**

| User Type | Namespace Prefix | Soft Limit | Hard Limit |
|-----------|------------------|------------|------------|
| Student   | `dgx-s-*`        | 24 hours   | 36 hours   |
| Faculty   | `dgx-f-*`        | 36 hours   | 84 hours   |
| Industry  | `dgx-i-*`        | 84 hours   | 168 hours  |

**Source:** [`lib/kubernetes.sh`](../lib/kubernetes.sh)
- `get_user_type()` (lines 42-56)
- `get_limits_for_namespace()` (lines 80-152)

---

## 5. Pod Batch Deletion Flow

The `flush_pod_queue()` logic for efficient batch deletion of queued pods.

```mermaid
flowchart TD
    Start([Start: flush_pod_queue]) --> GetQueueSize[Get queue size]
    
    GetQueueSize --> CheckEmpty{Queue empty?}
    CheckEmpty -->|Yes| LogEmpty[Log: No pods queued]
    LogEmpty --> ReturnEmpty([Return])
    
    CheckEmpty -->|No| LogFlush[Log: Flushing queue with N pods]
    LogFlush --> GroupByNs[Group pods by namespace]
    
    GroupByNs --> NsLoop{More namespaces?}
    NsLoop -->|No| ClearQueue[Clear POD_DELETE_QUEUE]
    ClearQueue --> LogDone[Log: Pod queue flushed]
    LogDone --> ReturnDone([Return])
    
    NsLoop -->|Yes| GetNsPods[Get pods for current namespace]
    GetNsPods --> InitBatch[Initialize batch index = 0]
    
    InitBatch --> BatchLoop{More pods in namespace?}
    BatchLoop -->|No| NsLoop
    
    BatchLoop -->|Yes| BuildBatch[Build batch up to POD_BATCH_SIZE]
    BuildBatch --> BuildCmd[Build kubectl delete command]
    
    BuildCmd --> CheckForce{POD_FORCE_DELETE?}
    CheckForce -->|Yes| AddForce[Add --grace-period=0 --force]
    CheckForce -->|No| SkipForce[No force flags]
    
    AddForce --> CheckBg{POD_BACKGROUND_DELETE?}
    SkipForce --> CheckBg
    
    CheckBg -->|Yes| RunBg[Run with nohup in background]
    CheckBg -->|No| RunFg[Run synchronously]
    
    RunBg --> LogBatch[Log: Batch deletion executed]
    RunFg --> LogBatch
    
    LogBatch --> BatchLoop
    
    subgraph BatchProcessing [Batch Processing]
        BuildBatch
        BuildCmd
        CheckForce
        AddForce
        SkipForce
    end
    
    subgraph ExecutionMode [Execution Mode]
        CheckBg
        RunBg
        RunFg
    end
```

**Configuration Options:**

| Setting | Default | Description |
|---------|---------|-------------|
| `POD_BATCH_SIZE` | 50 | Number of pods per kubectl delete command |
| `POD_FORCE_DELETE` | false | Use `--grace-period=0 --force` |
| `POD_BACKGROUND_DELETE` | true | Run kubectl in background (non-blocking) |

**Dual Optimization Strategy:**

The pod deletion combines TWO optimizations:

| Optimization | Mechanism | Effect |
|--------------|-----------|--------|
| **Intra-namespace batching** | Pods in the same namespace are combined into a single `kubectl delete pod p1 p2 ... -n ns` command | Reduces kubectl API calls |
| **Inter-namespace parallelism** | When `POD_BACKGROUND_DELETE=true`, each namespace's kubectl command runs in background (`nohup ... &`) | Namespaces are deleted simultaneously, not sequentially |

**Combined Effect Example:**

| Scenario | Pods | Namespaces | kubectl Commands | Execution |
|----------|------|------------|------------------|-----------|
| Best case | 100 | 1 | 2 (batches of 50) | Sequential |
| Typical | 100 | 5 (20 each) | 5 | Parallel |
| Worst case | 100 | 100 (1 each) | 100 | Parallel |

Even in the worst case (1 pod per namespace), background execution ensures all 100 deletions run **in parallel**, completing in roughly the time of a single deletion.

**Source:** [`lib/cleanup.sh`](../lib/cleanup.sh) - `flush_pod_queue()` (lines 238-335)

---

## 6. Exclusion Checking Flow

How exclusion lists are loaded and evaluated for resources.

```mermaid
flowchart TD
    subgraph Loading [Loading Exclusions at Startup]
        LoadStart([init_exclusion_paths]) --> SetPaths[Set paths to exclusion files]
        SetPaths --> LoadAll([load_all_exclusions])
        LoadAll --> LoadNs[Load exclude_namespaces]
        LoadAll --> LoadDeploy[Load exclude_deployments]
        LoadAll --> LoadPod[Load exclude_pods]
        LoadAll --> LoadSvc[Load exclude_services]
        
        LoadNs --> EX_NS[(EX_NS Array)]
        LoadDeploy --> EX_DEPLOY[(EX_DEPLOY Array)]
        LoadPod --> EX_POD[(EX_POD Array)]
        LoadSvc --> EX_SVC[(EX_SVC Array)]
    end
    
    subgraph FileFormat [Exclusion File Format]
        FF1["# Comments are stripped"]
        FF2["resource-name-1"]
        FF3["resource-name-2  # inline comment"]
        FF4["# Empty lines are skipped"]
    end
    
    subgraph Checking [Runtime Exclusion Check]
        CheckStart([is_resource_excluded]) --> CheckNs{Namespace in EX_NS?}
        
        CheckNs -->|Yes| ExcludedNs[EXCLUDED: Namespace level]
        ExcludedNs --> ReturnTrue([Return 0 - Excluded])
        
        CheckNs -->|No| CheckKind{Resource kind?}
        
        CheckKind -->|deployment| CheckDeploy{Name in EX_DEPLOY?}
        CheckKind -->|pod| CheckPodEx{Name in EX_POD?}
        CheckKind -->|service| CheckSvcEx{Name in EX_SVC?}
        
        CheckDeploy -->|Yes| ExcludedDeploy[EXCLUDED: Deployment name]
        CheckDeploy -->|No| NotExcluded
        
        CheckPodEx -->|Yes| ExcludedPod[EXCLUDED: Pod name]
        CheckPodEx -->|No| NotExcluded
        
        CheckSvcEx -->|Yes| ExcludedSvc[EXCLUDED: Service name]
        CheckSvcEx -->|No| NotExcluded[NOT EXCLUDED]
        
        ExcludedDeploy --> ReturnTrue
        ExcludedPod --> ReturnTrue
        ExcludedSvc --> ReturnTrue
        
        NotExcluded --> ReturnFalse([Return 1 - Not Excluded])
    end
```

**Exclusion File Locations:**

| File | Purpose |
|------|---------|
| `/etc/auto-cleanup/exclude_namespaces` | Namespace-level exclusions (skips ALL resources) |
| `/etc/auto-cleanup/exclude_deployments` | Specific deployment names to skip |
| `/etc/auto-cleanup/exclude_pods` | Specific pod names to skip |
| `/etc/auto-cleanup/exclude_services` | Specific service names to skip |

**Exclusion Hierarchy:**
1. **Namespace exclusion** is checked first (most powerful - skips all resources in that namespace)
2. **Resource-specific exclusion** is checked second (exact name match)

**Source:** [`lib/exclusions.sh`](../lib/exclusions.sh)
- `load_all_exclusions()` (lines 164-178)
- `is_resource_excluded()` (lines 282-321)

---

## Flowchart Legend

| Symbol | Meaning |
|--------|---------|
| `([Text])` | Terminal (Start/End) |
| `[Text]` | Process/Action |
| `{Text}` | Decision |
| `[(Text)]` | Database/Storage |
| `subgraph` | Logical grouping |
| Solid arrow | Normal flow |

## Cross-Reference Matrix

| Flowchart | Calls/Uses |
|-----------|-----------|
| 1. Main Execution | → 2. Resource Processing (for each type) |
| 2. Resource Processing | → 3. Limit Evaluation, → 4. Namespace Resolution, → 6. Exclusion Checking |
| 3. Limit Evaluation | → 6. Exclusion Checking (at start) |
| 5. Pod Batch Deletion | Called after 2. Resource Processing (pods) |

## Summary Diagram

A simplified overview of how all components interact:

```mermaid
flowchart LR
    subgraph Startup [Startup Phase]
        Config[Load Config]
        Exclusions[Load Exclusions]
        Flags[Init Limit Flags]
    end
    
    subgraph Processing [Processing Phase]
        Deploy[Process Deployments]
        Pods[Process Pods]
        Services[Process Services]
    end
    
    subgraph Evaluation [For Each Resource]
        NsType[Resolve Namespace Type]
        Exclude[Check Exclusions]
        Limits[Evaluate Limits]
    end
    
    subgraph Deletion [Deletion Phase]
        Immediate[Immediate Delete]
        Queue[Pod Queue]
        Batch[Batch Delete]
    end
    
    Config --> Processing
    Exclusions --> Exclude
    Flags --> Limits
    
    Deploy --> Evaluation
    Pods --> Evaluation
    Services --> Evaluation
    
    Evaluation -->|Hard/Soft triggered| Deletion
    
    Queue --> Batch
```

---

## Related Documentation

- [Administrator Guide](Administrator-Guide.md) - Installation and configuration
- [README](../README.md) - Quick start and overview
- [Configuration File](../conf/auto-cleanup.conf) - All configurable options

