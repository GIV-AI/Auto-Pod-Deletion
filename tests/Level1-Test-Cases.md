# Level 1 Functional Test Cases

## Overview

This document defines **20 critical functional test cases** for the Auto-Cleanup system. These Level 1 test cases focus on the most important scenarios that **should work** and **should not work**, covering core functionality including resource deletion logic, user-type policies, exclusion mechanisms, pod-specific behavior, resource enable/disable, and configuration validation.

**Scope:** Functional correctness only. Edge cases, security issues, and performance testing are deferred to later levels.

## Test Case Format

Each test case includes:
- **Test Case ID**: Unique identifier (TC-01 to TC-20)
- **Title**: Brief descriptive name
- **Category**: Functional area being tested
- **Description**: What is being tested
- **Expected Behavior**: Whether this SHOULD work or SHOULD NOT work
- **Prerequisites**: Required setup before testing
- **Test Steps**: Step-by-step actions to execute
- **Expected Results**: What should happen

---

## Test Cases

### TC-01: Hard Limit Deletion - Resource Exceeds Hard Limit
**Category:** Resource Deletion Logic  
**Expected Behavior:** SHOULD work

**Description:**  
A resource (Deployment, Pod, or Service) that has exceeded its hard limit should be deleted immediately, regardless of any keep-alive label.

**Prerequisites:**
- Resource exists in a dgx-* namespace (e.g., `dgx-s-user1`)
- Resource age > hard limit configured for the namespace
- Hard limit is enabled in configuration (`Deployment_HardLimit=true`, `Pod_HardLimit=true`, or `Service_HardLimit=true`)

**Test Steps:**
1. Create a Deployment/Pod/Service in namespace `dgx-s-user1`
2. Set resource creation time to be older than `STUDENT_HARD` limit (e.g., 40 hours if hard limit is 36H)
3. Optionally add `keep-alive=true` label to the resource
4. Run `auto-cleanup`
5. Verify resource is deleted

**Expected Results:**
- Resource is deleted immediately
- Log shows: "Hard limit: deleting [resource-type] [name] ([namespace]) (age=Xm >= Ym)"
- Keep-alive label is ignored (resource deleted even if present)

---

### TC-02: Soft Limit Deletion - Resource Exceeds Soft Limit Without Keep-Alive
**Category:** Resource Deletion Logic  
**Expected Behavior:** SHOULD work

**Description:**  
A resource that has exceeded its soft limit should be deleted if it does not have a `keep-alive=true` label.

**Prerequisites:**
- Resource exists in a dgx-* namespace
- Resource age > soft limit but < hard limit
- Soft limit is enabled in configuration
- Resource does NOT have `keep-alive=true` label

**Test Steps:**
1. Create a Deployment/Pod/Service in namespace `dgx-s-user1`
2. Set resource creation time to be older than `STUDENT_SOFT` limit but younger than `STUDENT_HARD` (e.g., 30 hours if soft=24H, hard=36H)
3. Ensure resource does NOT have `keep-alive` label (or has `keep-alive=false`)
4. Run `auto-cleanup`
5. Verify resource is deleted

**Expected Results:**
- Resource is deleted
- Log shows: "Soft limit: deleting [resource-type] [name] ([namespace]) (keep-alive='')" or similar
- For pods, log shows: "Pod [name] ([namespace]): SOFT delete queued"

---

### TC-03: Soft Limit Protection - Resource Exceeds Soft Limit With Keep-Alive=True
**Category:** Resource Deletion Logic  
**Expected Behavior:** SHOULD NOT work (resource should be preserved)

**Description:**  
A resource that has exceeded its soft limit but has `keep-alive=true` label should NOT be deleted.

**Prerequisites:**
- Resource exists in a dgx-* namespace
- Resource age > soft limit but < hard limit
- Soft limit is enabled
- Resource has `keep-alive=true` label

**Test Steps:**
1. Create a Deployment/Pod/Service in namespace `dgx-s-user1`
2. Set resource creation time to be older than `STUDENT_SOFT` limit but younger than `STUDENT_HARD`
3. Add `keep-alive=true` label to the resource
4. Run `auto-cleanup`
5. Verify resource still exists

**Expected Results:**
- Resource is NOT deleted
- Log shows: "keep-alive=true for [resource-type] [name] ([namespace]) -> skipping deletion"
- Resource remains in the cluster

---

### TC-04: Resource Below Soft Limit - No Deletion
**Category:** Resource Deletion Logic  
**Expected Behavior:** SHOULD NOT work (resource should be preserved)

**Description:**  
A resource that is younger than the soft limit should never be deleted, regardless of labels.

**Prerequisites:**
- Resource exists in a dgx-* namespace
- Resource age < soft limit
- Both soft and hard limits are configured

**Test Steps:**
1. Create a Deployment/Pod/Service in namespace `dgx-s-user1`
2. Set resource creation time to be younger than `STUDENT_SOFT` limit (e.g., 10 hours if soft=24H)
3. Run `auto-cleanup`
4. Verify resource still exists

**Expected Results:**
- Resource is NOT deleted
- No deletion log entry for this resource
- Resource remains in the cluster

---

### TC-05: Hard Limit Overrides Keep-Alive Label
**Category:** Resource Deletion Logic  
**Expected Behavior:** SHOULD work (resource should be deleted)

**Description:**  
A resource that has exceeded its hard limit should be deleted even if it has `keep-alive=true` label. Hard limit always takes precedence.

**Prerequisites:**
- Resource exists in a dgx-* namespace
- Resource age > hard limit
- Hard limit is enabled
- Resource has `keep-alive=true` label

**Test Steps:**
1. Create a Deployment/Pod/Service in namespace `dgx-s-user1`
2. Set resource creation time to be older than `STUDENT_HARD` limit (e.g., 40 hours if hard=36H)
3. Add `keep-alive=true` label to the resource
4. Run `auto-cleanup`
5. Verify resource is deleted

**Expected Results:**
- Resource is deleted despite `keep-alive=true` label
- Log shows hard limit deletion message
- Hard limit enforcement takes precedence over keep-alive protection

---

### TC-06: Student Namespace Uses STUDENT_* Limits
**Category:** User-Type Policy Enforcement  
**Expected Behavior:** SHOULD work

**Description:**  
Resources in namespaces with prefix `dgx-s-*` should use `STUDENT_SOFT` and `STUDENT_HARD` time limits.

**Prerequisites:**
- `STUDENT_SOFT` and `STUDENT_HARD` are configured in `auto-cleanup.conf`
- Test namespace `dgx-s-testuser` exists

**Test Steps:**
1. Create a Deployment in namespace `dgx-s-testuser`
2. Set resource age to be between `STUDENT_SOFT` and `STUDENT_HARD` (e.g., 30H if soft=24H, hard=36H)
3. Ensure resource does not have `keep-alive=true`
4. Run `auto-cleanup`
5. Verify resource is deleted using student limits

**Expected Results:**
- Resource is evaluated against `STUDENT_SOFT` and `STUDENT_HARD` limits
- Resource is deleted (age exceeds student soft limit)
- Log confirms student namespace processing

---

### TC-07: Faculty Namespace Uses FACULTY_* Limits
**Category:** User-Type Policy Enforcement  
**Expected Behavior:** SHOULD work

**Description:**  
Resources in namespaces with prefix `dgx-f-*` should use `FACULTY_SOFT` and `FACULTY_HARD` time limits.

**Prerequisites:**
- `FACULTY_SOFT` and `FACULTY_HARD` are configured
- Test namespace `dgx-f-testuser` exists

**Test Steps:**
1. Create a Deployment in namespace `dgx-f-testuser`
2. Set resource age to be between `FACULTY_SOFT` and `FACULTY_HARD` (e.g., 60H if soft=36H, hard=84H)
3. Ensure resource does not have `keep-alive=true`
4. Run `auto-cleanup`
5. Verify resource is deleted using faculty limits

**Expected Results:**
- Resource is evaluated against `FACULTY_SOFT` and `FACULTY_HARD` limits
- Resource is deleted (age exceeds faculty soft limit)
- Log confirms faculty namespace processing

---

### TC-08: Industry Namespace Uses INDUSTRY_* Limits
**Category:** User-Type Policy Enforcement  
**Expected Behavior:** SHOULD work

**Description:**  
Resources in namespaces with prefix `dgx-i-*` should use `INDUSTRY_SOFT` and `INDUSTRY_HARD` time limits.

**Prerequisites:**
- `INDUSTRY_SOFT` and `INDUSTRY_HARD` are configured
- Test namespace `dgx-i-testcompany` exists

**Test Steps:**
1. Create a Deployment in namespace `dgx-i-testcompany`
2. Set resource age to be between `INDUSTRY_SOFT` and `INDUSTRY_HARD` (e.g., 100H if soft=84H, hard=168H)
3. Ensure resource does not have `keep-alive=true`
4. Run `auto-cleanup`
5. Verify resource is deleted using industry limits

**Expected Results:**
- Resource is evaluated against `INDUSTRY_SOFT` and `INDUSTRY_HARD` limits
- Resource is deleted (age exceeds industry soft limit)
- Log confirms industry namespace processing

---

### TC-09: Non-DGX Namespace Skipped
**Category:** User-Type Policy Enforcement  
**Expected Behavior:** SHOULD NOT work (namespace should be skipped)

**Description:**  
Resources in namespaces that do not match `dgx-s-*`, `dgx-f-*`, or `dgx-i-*` patterns should be skipped entirely.

**Prerequisites:**
- Test namespace `default` or `kube-system` exists (non-dgx namespace)
- Resource exists in the non-dgx namespace

**Test Steps:**
1. Create a Deployment in namespace `default` (or any non-dgx namespace)
2. Set resource age to be very old (e.g., 1000 hours)
3. Run `auto-cleanup`
4. Verify resource is NOT processed

**Expected Results:**
- Resource is NOT deleted
- Log shows: "No limits configured for namespace '[namespace]' -> skipping [resource-type] [name]"
- Namespace is skipped entirely (no processing)

---

### TC-10: Namespace Exclusion Prevents All Resource Deletion
**Category:** Exclusion Mechanisms  
**Expected Behavior:** SHOULD NOT work (resources should be preserved)

**Description:**  
All resources in an excluded namespace should be skipped, regardless of age or labels.

**Prerequisites:**
- Namespace `dgx-s-protected` is listed in `/etc/auto-cleanup/exclude_namespaces`
- Resources exist in the excluded namespace

**Test Steps:**
1. Add `dgx-s-protected` to `exclude_namespaces` file
2. Create a Deployment/Pod/Service in namespace `dgx-s-protected`
3. Set resource age to exceed hard limit (e.g., 100 hours)
4. Run `auto-cleanup`
5. Verify all resources in the namespace are preserved

**Expected Results:**
- No resources in `dgx-s-protected` are deleted
- Log shows: "Skipping [resource-type] [name] ([namespace]) -> namespace excluded"
- All resources remain in the cluster

---

### TC-11: Deployment Exclusion Prevents Specific Deployment Deletion
**Category:** Exclusion Mechanisms  
**Expected Behavior:** SHOULD NOT work (deployment should be preserved)

**Description:**  
A deployment listed in `exclude_deployments` should not be deleted, even if it exceeds limits.

**Prerequisites:**
- Deployment name `critical-app` is listed in `/etc/auto-cleanup/exclude_deployments`
- Deployment exists in a dgx-* namespace

**Test Steps:**
1. Add `critical-app` to `exclude_deployments` file
2. Create deployment `critical-app` in namespace `dgx-s-user1`
3. Set deployment age to exceed hard limit (e.g., 100 hours)
4. Run `auto-cleanup`
5. Verify deployment is preserved

**Expected Results:**
- Deployment `critical-app` is NOT deleted
- Log shows: "Skipping deployment critical-app (dgx-s-user1) -> excluded"
- Deployment remains in the cluster

---

### TC-12: Pod Exclusion Prevents Specific Pod Deletion
**Category:** Exclusion Mechanisms  
**Expected Behavior:** SHOULD NOT work (pod should be preserved)

**Description:**  
A pod listed in `exclude_pods` should not be deleted, even if it exceeds limits.

**Prerequisites:**
- Pod name `debug-pod` is listed in `/etc/auto-cleanup/exclude_pods`
- Standalone pod exists in a dgx-* namespace

**Test Steps:**
1. Add `debug-pod` to `exclude_pods` file
2. Create standalone pod `debug-pod` in namespace `dgx-s-user1`
3. Set pod age to exceed hard limit (e.g., 100 hours)
4. Run `auto-cleanup`
5. Verify pod is preserved

**Expected Results:**
- Pod `debug-pod` is NOT deleted
- Log shows: "Skipping pod debug-pod (dgx-s-user1) -> excluded"
- Pod remains in the cluster

---

### TC-13: Service Exclusion Prevents Specific Service Deletion
**Category:** Exclusion Mechanisms  
**Expected Behavior:** SHOULD NOT work (service should be preserved)

**Description:**  
A service listed in `exclude_services` should not be deleted, even if it exceeds limits.

**Prerequisites:**
- Service name `api-service` is listed in `/etc/auto-cleanup/exclude_services`
- Service exists in a dgx-* namespace

**Test Steps:**
1. Add `api-service` to `exclude_services` file
2. Create service `api-service` in namespace `dgx-s-user1`
3. Set service age to exceed hard limit (e.g., 100 hours)
4. Run `auto-cleanup`
5. Verify service is preserved

**Expected Results:**
- Service `api-service` is NOT deleted
- Log shows: "Skipping service api-service (dgx-s-user1) -> excluded"
- Service remains in the cluster

---

### TC-14: Standalone Pods Are Processed for Deletion
**Category:** Pod-Specific Behavior  
**Expected Behavior:** SHOULD work

**Description:**  
Standalone pods (pods without `ownerReferences`) should be processed and deleted if they exceed limits.

**Prerequisites:**
- Standalone pod exists in a dgx-* namespace
- Pod has no ownerReferences (not managed by Deployment, Job, etc.)
- Pod age exceeds soft limit

**Test Steps:**
1. Create a standalone pod (not created by Deployment/Job/etc.) in namespace `dgx-s-user1`
2. Set pod age to exceed `STUDENT_SOFT` limit
3. Ensure pod does not have `keep-alive=true`
4. Run `auto-cleanup`
5. Verify pod is queued and deleted

**Expected Results:**
- Pod is processed and queued for deletion
- Log shows: "Pod [name] ([namespace]): SOFT delete queued" or "HARD delete queued"
- Pod is deleted in batch operation

---

### TC-15: Managed Pods Are Skipped (Job/CronJob/StatefulSet/DaemonSet)
**Category:** Pod-Specific Behavior  
**Expected Behavior:** SHOULD NOT work (pods should be preserved)

**Description:**  
Pods managed by controllers (Job, CronJob, StatefulSet, DaemonSet, ReplicationController) should be skipped during pod cleanup.

**Prerequisites:**
- Pod managed by Job/CronJob/StatefulSet/DaemonSet exists in a dgx-* namespace
- Pod age exceeds limits

**Test Steps:**
1. Create a Job in namespace `dgx-s-user1` (which creates a managed pod)
2. Set pod age to exceed hard limit (e.g., 100 hours)
3. Run `auto-cleanup`
4. Verify managed pod is NOT deleted

**Expected Results:**
- Managed pod is NOT deleted
- Log shows: "Skipping pod [name] ([namespace]) -> managed by [ControllerType] controller (not cleaned by this script)"
- Pod remains in the cluster (controller manages its lifecycle)

---

### TC-16: Pod Batching Groups by Namespace Correctly
**Category:** Pod-Specific Behavior  
**Expected Behavior:** SHOULD work

**Description:**  
Pods queued for deletion should be grouped by namespace and deleted in batches, with each namespace's pods deleted together.

**Prerequisites:**
- Multiple standalone pods exist across different namespaces
- Pods exceed limits and are queued for deletion
- `POD_BATCH_SIZE` is configured (e.g., 50)

**Test Steps:**
1. Create 4 standalone pods in namespace `dgx-s-user1` (all exceed soft limit)
2. Create 5 standalone pods in namespace `dgx-s-user2` (all exceed soft limit)
3. Run `auto-cleanup`
4. Verify pods are batched by namespace

**Expected Results:**
- Pods from `dgx-s-user1` are grouped together and deleted in one or more batches
- Pods from `dgx-s-user2` are grouped together and deleted separately
- Log shows: "Deleting pods in batch (namespace=[ns]): [pod-list]"
- Each namespace's pods are processed together (intra-namespace batching)

---

### TC-17: Disabled Resource Type Skips Processing
**Category:** Resource Type Enable/Disable  
**Expected Behavior:** SHOULD NOT work (resource type should be skipped)

**Description:**  
If a resource type is disabled in configuration (`Deployment=false`, `Pod=false`, or `Service=false`), that resource type should not be processed at all.

**Prerequisites:**
- Configuration has `Deployment=false` (or `Pod=false`, or `Service=false`)
- Resources of that type exist in dgx-* namespaces

**Test Steps:**
1. Set `Deployment=false` in `auto-cleanup.conf`
2. Create a Deployment in namespace `dgx-s-user1` with age exceeding hard limit
3. Run `auto-cleanup`
4. Verify Deployment is NOT processed

**Expected Results:**
- Deployment cleanup is skipped entirely
- Log shows: "Deployment checks disabled by config"
- No deployments are queried or processed

---

### TC-18: Enabled Resource Type Processes Correctly
**Category:** Resource Type Enable/Disable  
**Expected Behavior:** SHOULD work

**Description:**  
If a resource type is enabled in configuration, it should be processed according to limits and exclusions.

**Prerequisites:**
- Configuration has `Deployment=true`, `Pod=true`, and `Service=true`
- Resources exist that should be deleted

**Test Steps:**
1. Ensure all resource types are enabled (`Deployment=true`, `Pod=true`, `Service=true`)
2. Create resources (Deployment, Pod, Service) that exceed soft limits
3. Run `auto-cleanup`
4. Verify all enabled resource types are processed

**Expected Results:**
- All enabled resource types are processed
- Log shows: "Starting Deployment cleanup...", "Starting Pod scan & queueing...", "Starting Service cleanup..."
- Resources are evaluated and deleted according to limits

---

### TC-19: Missing Limit Configuration Skips Namespace
**Category:** Configuration and Limits  
**Expected Behavior:** SHOULD NOT work (namespace should be skipped)

**Description:**  
If `STUDENT_SOFT`, `STUDENT_HARD`, `FACULTY_SOFT`, `FACULTY_HARD`, `INDUSTRY_SOFT`, or `INDUSTRY_HARD` is missing from configuration, resources in that namespace type should be skipped.

**Prerequisites:**
- `STUDENT_SOFT` or `STUDENT_HARD` is missing/empty in configuration
- Resources exist in `dgx-s-*` namespace

**Test Steps:**
1. Remove or comment out `STUDENT_SOFT` from `auto-cleanup.conf`
2. Create a Deployment in namespace `dgx-s-user1` with age exceeding any limit
3. Run `auto-cleanup`
4. Verify namespace is skipped

**Expected Results:**
- Resources in student namespaces are NOT processed
- Log shows: "Missing STUDENT_SOFT or STUDENT_HARD configuration for namespace: [namespace]"
- Log shows: "No limits configured for namespace '[namespace]' -> skipping [resource-type] [name]"

---

### TC-20: Both Hard and Soft Disabled Disables Resource Type
**Category:** Configuration and Limits  
**Expected Behavior:** SHOULD NOT work (resource type should be disabled)

**Description:**  
If both `[Resource]_HardLimit=false` and `[Resource]_SoftLimit=false` for a resource type, that resource type should be completely disabled, even if `[Resource]=true`.

**Prerequisites:**
- Configuration has `Deployment_HardLimit=false` and `Deployment_SoftLimit=false`
- `Deployment=true` is set

**Test Steps:**
1. Set `Deployment_HardLimit=false` and `Deployment_SoftLimit=false` in configuration
2. Set `Deployment=true`
3. Create a Deployment that exceeds any limit
4. Run `auto-cleanup`
5. Verify Deployment processing is disabled

**Expected Results:**
- Deployment cleanup is disabled
- Log shows: "Deployment hard & soft both disabled -> Deployment checks disabled"
- No deployments are queried or processed

---

## Summary Table

| ID | Title | Category | Expected Behavior |
|----|-------|----------|-------------------|
| TC-01 | Hard Limit Deletion - Resource Exceeds Hard Limit | Resource Deletion Logic | SHOULD work |
| TC-02 | Soft Limit Deletion - Resource Exceeds Soft Limit Without Keep-Alive | Resource Deletion Logic | SHOULD work |
| TC-03 | Soft Limit Protection - Resource Exceeds Soft Limit With Keep-Alive=True | Resource Deletion Logic | SHOULD NOT work |
| TC-04 | Resource Below Soft Limit - No Deletion | Resource Deletion Logic | SHOULD NOT work |
| TC-05 | Hard Limit Overrides Keep-Alive Label | Resource Deletion Logic | SHOULD work |
| TC-06 | Student Namespace Uses STUDENT_* Limits | User-Type Policy Enforcement | SHOULD work |
| TC-07 | Faculty Namespace Uses FACULTY_* Limits | User-Type Policy Enforcement | SHOULD work |
| TC-08 | Industry Namespace Uses INDUSTRY_* Limits | User-Type Policy Enforcement | SHOULD work |
| TC-09 | Non-DGX Namespace Skipped | User-Type Policy Enforcement | SHOULD NOT work |
| TC-10 | Namespace Exclusion Prevents All Resource Deletion | Exclusion Mechanisms | SHOULD NOT work |
| TC-11 | Deployment Exclusion Prevents Specific Deployment Deletion | Exclusion Mechanisms | SHOULD NOT work |
| TC-12 | Pod Exclusion Prevents Specific Pod Deletion | Exclusion Mechanisms | SHOULD NOT work |
| TC-13 | Service Exclusion Prevents Specific Service Deletion | Exclusion Mechanisms | SHOULD NOT work |
| TC-14 | Standalone Pods Are Processed for Deletion | Pod-Specific Behavior | SHOULD work |
| TC-15 | Managed Pods Are Skipped (Job/CronJob/StatefulSet/DaemonSet) | Pod-Specific Behavior | SHOULD NOT work |
| TC-16 | Pod Batching Groups by Namespace Correctly | Pod-Specific Behavior | SHOULD work |
| TC-17 | Disabled Resource Type Skips Processing | Resource Type Enable/Disable | SHOULD NOT work |
| TC-18 | Enabled Resource Type Processes Correctly | Resource Type Enable/Disable | SHOULD work |
| TC-19 | Missing Limit Configuration Skips Namespace | Configuration and Limits | SHOULD NOT work |
| TC-20 | Both Hard and Soft Disabled Disables Resource Type | Configuration and Limits | SHOULD NOT work |

---

## Notes

- **Test Execution:** These test cases are designed to be implemented using a testing framework (e.g., bats-core or shunit2) with mocked kubectl commands to avoid requiring a real Kubernetes cluster.

- **Prerequisites:** All test cases assume proper configuration files exist and kubectl is available (or mocked). Test setup should create necessary namespaces and resources as needed.

- **Log Verification:** Expected log messages are based on the current implementation. Log format may vary slightly, but the core information should be present.

- **Time Format:** All time values in test cases use the format supported by the system (e.g., `24H`, `36H`, `84H` for hours, or `30M` for minutes).

