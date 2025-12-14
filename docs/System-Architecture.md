# Auto-Cleanup System Architecture

High-level system architecture diagram showing the main components and their interactions.

## System Architecture

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontSize':'16px', 'primaryTextColor':'#000', 'primaryBorderColor':'#000', 'lineColor':'#000'}}}%%
graph TB
    subgraph "Auto-Cleanup System"
        Main["<b>bin/auto-cleanup</b><br/>Main Script<br/>Orchestrates execution"]
        
        subgraph "Core Modules"
            Common["<b>lib/common.sh</b><br/>Logging, Config, Locking"]
            Exclusions["<b>lib/exclusions.sh</b><br/>Exclusion Management"]
            Kubernetes["<b>lib/kubernetes.sh</b><br/>K8s API Operations"]
            Cleanup["<b>lib/cleanup.sh</b><br/>Cleanup Logic"]
        end
    end
    
    subgraph "Configuration"
        Config["<b>auto-cleanup.conf</b><br/>Main Configuration"]
        ExcludeFiles["<b>Exclusion Files</b><br/>exclude_*"]
    end
    
    subgraph "Kubernetes Cluster"
        K8sAPI["<b>Kubernetes API</b>"]
        Resources["<b>Resources</b><br/>Deployments, Pods, Services<br/>dgx-s-*, dgx-f-*, dgx-i-*"]
    end
    
    subgraph "File System"
        Logs["<b>Log Files</b><br/>/var/log/giindia/auto-cleanup/"]
    end
    
    Main --> Common
    Main --> Exclusions
    Main --> Kubernetes
    Main --> Cleanup
    
    Main --> Config
    Exclusions --> ExcludeFiles
    
    Kubernetes -->|"Query & Delete"| K8sAPI
    K8sAPI <--> Resources
    
    Common --> Logs
    
    %% Styling
    classDef main fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    classDef module fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef config fill:#fff3e0,stroke:#e65100,stroke-width:2px
    classDef k8s fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px
    classDef files fill:#f1f8e9,stroke:#33691e,stroke-width:2px
    
    class Main main
    class Common,Exclusions,Kubernetes,Cleanup module
    class Config,ExcludeFiles config
    class K8sAPI,Resources k8s
    class Logs files
```

## Component Overview

### Auto-Cleanup System
- **bin/auto-cleanup**: Main entry point that orchestrates the cleanup process
- **lib/common.sh**: Provides logging, configuration loading, and lock management
- **lib/exclusions.sh**: Manages exclusion lists for protected resources
- **lib/kubernetes.sh**: Handles all Kubernetes API interactions
- **lib/cleanup.sh**: Implements the core cleanup logic and policy evaluation

### External Systems
- **Configuration Files**: Control system behavior (time limits, policies, exclusions)
- **Kubernetes Cluster**: Target system containing resources to be cleaned
- **Log Files**: System logs stored on the file system

## Execution Flow

1. **Main script** loads configuration and all modules
2. **Cleanup module** queries Kubernetes API for resources
3. **Exclusions module** filters out protected resources
4. **Cleanup module** evaluates resources against policies
5. **Kubernetes module** deletes resources that meet criteria
6. **Common module** logs all operations

## Related Documentation

- [Dependency Graph](Dependency-Graph.md) - Detailed module dependencies
- [Auto-Cleanup Flowcharts](Auto-Cleanup-Flowcharts.md) - Execution flow diagrams
- [Administrator Guide](Administrator-Guide.md) - Installation and configuration
- [User Guide](User-Guide.md) - Usage instructions
