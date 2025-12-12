# Auto-Cleanup Test Suite

This directory contains test cases for the Auto-Cleanup tool.

## Status

**Not yet implemented.** Test framework selection pending.

## Planned Testing Framework

Consider using one of the following:

- **[bats-core](https://github.com/bats-core/bats-core)** - Bash Automated Testing System
- **[shunit2](https://github.com/kward/shunit2)** - xUnit-based unit testing for shell scripts

## Test Coverage Plan

### Unit Tests (lib/*.sh)

| Module | Functions to Test |
|--------|-------------------|
| `common.sh` | `norm_flag()`, `log_message()`, `find_config()` |
| `exclusions.sh` | `load_list()`, `in_list()`, `is_resource_excluded()` |
| `kubernetes.sh` | `get_user_type()`, `get_limits_for_namespace()`, `get_age_minutes()` |
| `cleanup.sh` | `cleanup_resource()`, `flush_pod_queue()` |

### Integration Tests

- Configuration loading from multiple paths
- Exclusion list processing
- Mock kubectl responses

### End-to-End Tests

- Full cleanup cycle with test namespace
- Dry-run mode validation (when implemented)

## Running Tests

```bash
# When implemented:
./tests/run_tests.sh
```

## Contributing Tests

1. Create test files with `.bats` extension (for bats) or `test_*.sh` (for shunit2)
2. Follow existing test patterns
3. Mock external commands (kubectl) to avoid cluster dependencies
4. Ensure tests are idempotent

