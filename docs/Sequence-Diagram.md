# Auto-Cleanup Sequence Diagram

Sequence diagrams showing the execution flow broken down into multiple stages for clarity.

---

## Stage 1: Initialization

Setup and configuration loading phase.

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontSize':'14px', 'primaryTextColor':'#000', 'primaryBorderColor':'#000', 'lineColor':'#000'}}}%%
sequenceDiagram
    participant Main as bin/auto-cleanup
    participant Common as lib/common.sh
    participant Exclusions as lib/exclusions.sh
    participant Cleanup as lib/cleanup.sh
    participant Config as Configuration Files
    participant Logs as Log Files

    Main->>Common: Check dependencies
    Common-->>Main: Dependencies OK
    
    Main->>Common: Acquire lock
    Common-->>Main: Lock acquired
    
    Main->>Common: Load configuration
    Common->>Config: Read auto-cleanup.conf
    Config-->>Common: Configuration data
    Common-->>Main: Config loaded
    
    Main->>Common: Initialize logging
    Common->>Logs: Create log file
    Logs-->>Common: Log file ready
    Common-->>Main: Logging initialized
    
    Main->>Exclusions: Load exclusion lists
    Exclusions->>Config: Read exclude_* files
    Config-->>Exclusions: Exclusion data
    Exclusions-->>Main: Exclusions loaded
    
    Main->>Cleanup: Initialize limit flags
    Cleanup-->>Main: Flags initialized
```

---

## Stage 2: Deployment Processing

Processing and cleanup of Kubernetes deployments.

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontSize':'14px', 'primaryTextColor':'#000', 'primaryBorderColor':'#000', 'lineColor':'#000'}}}%%
sequenceDiagram
    participant Main as bin/auto-cleanup
    participant Cleanup as lib/cleanup.sh
    participant Kubernetes as lib/kubernetes.sh
    participant Exclusions as lib/exclusions.sh
    participant K8sAPI as Kubernetes API
    participant Common as lib/common.sh
    participant Logs as Log Files

    Main->>Cleanup: Process deployments
    Cleanup->>Kubernetes: Query deployments
    Kubernetes->>K8sAPI: kubectl get deployments
    K8sAPI-->>Kubernetes: Deployment list
    Kubernetes-->>Cleanup: Deployment data
    
    loop For each deployment
        Cleanup->>Exclusions: Check exclusions
        Exclusions-->>Cleanup: Exclusion status
        
        Cleanup->>Kubernetes: Get age & limits
        Kubernetes->>K8sAPI: kubectl get deployment
        K8sAPI-->>Kubernetes: Resource metadata
        Kubernetes-->>Cleanup: Age & limits
        
        Cleanup->>Kubernetes: Delete deployment (if needed)
        Kubernetes->>K8sAPI: kubectl delete deployment
        K8sAPI-->>Kubernetes: Deletion result
        Kubernetes-->>Cleanup: Deletion complete
        
        Cleanup->>Common: Log operation
        Common->>Logs: Write log entry
    end
    
    Cleanup-->>Main: Deployments processed
```

---

## Stage 3: Pod Processing

Processing standalone pods and queueing them for batch deletion.

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontSize':'14px', 'primaryTextColor':'#000', 'primaryBorderColor':'#000', 'lineColor':'#000'}}}%%
sequenceDiagram
    participant Main as bin/auto-cleanup
    participant Cleanup as lib/cleanup.sh
    participant Kubernetes as lib/kubernetes.sh
    participant Exclusions as lib/exclusions.sh
    participant K8sAPI as Kubernetes API
    participant Common as lib/common.sh
    participant Logs as Log Files

    Main->>Cleanup: Process pods
    Cleanup->>Kubernetes: Query pods
    Kubernetes->>K8sAPI: kubectl get pods
    K8sAPI-->>Kubernetes: Pod list
    Kubernetes-->>Cleanup: Pod data
    
    loop For each pod
        Cleanup->>Exclusions: Check exclusions
        Exclusions-->>Cleanup: Exclusion status
        
        Cleanup->>Kubernetes: Check if standalone
        Kubernetes->>K8sAPI: kubectl get pod
        K8sAPI-->>Kubernetes: Pod metadata
        Kubernetes-->>Cleanup: Standalone status
        
        alt Standalone pod
            Cleanup->>Kubernetes: Get age & limits
            Kubernetes->>K8sAPI: kubectl get pod
            K8sAPI-->>Kubernetes: Resource metadata
            Kubernetes-->>Cleanup: Age & limits
            
            Cleanup->>Cleanup: Queue pod (if needed)
        end
    end
    
    Cleanup->>Common: Log operation
    Common->>Logs: Write log entry
    Cleanup-->>Main: Pods processed
```

---

## Stage 4: Pod Queue Flush

Batch deletion of queued pods.

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontSize':'14px', 'primaryTextColor':'#000', 'primaryBorderColor':'#000', 'lineColor':'#000'}}}%%
sequenceDiagram
    participant Main as bin/auto-cleanup
    participant Cleanup as lib/cleanup.sh
    participant Kubernetes as lib/kubernetes.sh
    participant K8sAPI as Kubernetes API
    participant Common as lib/common.sh
    participant Logs as Log Files

    Main->>Cleanup: Flush pod queue
    Cleanup->>Cleanup: Group pods by namespace
    
    loop For each namespace batch
        Cleanup->>Kubernetes: Batch delete pods
        Kubernetes->>K8sAPI: kubectl delete pods (batched)
        K8sAPI-->>Kubernetes: Deletion results
        Kubernetes-->>Cleanup: Deletions complete
        
        Cleanup->>Common: Log operation
        Common->>Logs: Write log entry
    end
    
    Cleanup-->>Main: Pod queue flushed
```

---

## Stage 5: Service Processing

Processing and cleanup of Kubernetes services.

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontSize':'14px', 'primaryTextColor':'#000', 'primaryBorderColor':'#000', 'lineColor':'#000'}}}%%
sequenceDiagram
    participant Main as bin/auto-cleanup
    participant Cleanup as lib/cleanup.sh
    participant Kubernetes as lib/kubernetes.sh
    participant Exclusions as lib/exclusions.sh
    participant K8sAPI as Kubernetes API
    participant Common as lib/common.sh
    participant Logs as Log Files

    Main->>Cleanup: Process services
    Cleanup->>Kubernetes: Query services
    Kubernetes->>K8sAPI: kubectl get services
    K8sAPI-->>Kubernetes: Service list
    Kubernetes-->>Cleanup: Service data
    
    loop For each service
        Cleanup->>Exclusions: Check exclusions
        Exclusions-->>Cleanup: Exclusion status
        
        Cleanup->>Kubernetes: Get age & limits
        Kubernetes->>K8sAPI: kubectl get service
        K8sAPI-->>Kubernetes: Resource metadata
        Kubernetes-->>Cleanup: Age & limits
        
        Cleanup->>Kubernetes: Delete service (if needed)
        Kubernetes->>K8sAPI: kubectl delete service
        K8sAPI-->>Kubernetes: Deletion result
        Kubernetes-->>Cleanup: Deletion complete
        
        Cleanup->>Common: Log operation
        Common->>Logs: Write log entry
    end
    
    Cleanup-->>Main: Services processed
```

---

## Stage 6: Cleanup

Final cleanup and lock release.

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontSize':'14px', 'primaryTextColor':'#000', 'primaryBorderColor':'#000', 'lineColor':'#000'}}}%%
sequenceDiagram
    participant Main as bin/auto-cleanup
    participant Common as lib/common.sh
    participant Logs as Log Files

    Main->>Common: Release lock
    Common-->>Main: Lock released
    
    Main->>Common: Log completion
    Common->>Logs: Write final log entry
    
    Main->>Main: Exit
```

---

## Stage Summary

1. **Initialization**: Setup, configuration loading, and preparation
2. **Deployment Processing**: Query, evaluate, and delete deployments
3. **Pod Processing**: Query standalone pods and queue for deletion
4. **Pod Queue Flush**: Batch delete queued pods
5. **Service Processing**: Query, evaluate, and delete services
6. **Cleanup**: Release lock and finalize execution

## Key Interactions

- **Main ↔ Common**: Configuration, logging, and locking operations
- **Main ↔ Exclusions**: Loading exclusion lists
- **Main ↔ Cleanup**: Orchestrating resource processing
- **Cleanup ↔ Kubernetes**: Querying and deleting resources
- **Cleanup ↔ Exclusions**: Checking if resources are excluded
- **Kubernetes ↔ K8sAPI**: All Kubernetes API operations
- **Common ↔ Logs**: All logging operations

## Related Documentation

- [System Architecture](System-Architecture.md) - System component overview
- [Dependency Graph](Dependency-Graph.md) - Detailed module dependencies
- [Auto-Cleanup Flowcharts](Auto-Cleanup-Flowcharts.md) - Detailed execution flow diagrams
- [Administrator Guide](Administrator-Guide.md) - Installation and configuration
- [User Guide](User-Guide.md) - Usage instructions

