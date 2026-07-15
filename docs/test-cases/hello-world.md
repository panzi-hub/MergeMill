# Test Cases: hello.sh Helper Script

## Feature Description

A simple `scripts/hello.sh` script that prints "Hello from MergeMill!" when executed.
This is a pipeline smoke test — minimal implementation.

## Test Scenarios

| Test ID | Scenario | Expected Result |
|---------|----------|-----------------|
| TC-HELLO-001 | Execute script with `bash scripts/hello.sh` | Outputs exactly "Hello from MergeMill!" and exits 0 |
| TC-HELLO-002 | Script has correct shebang | Contains `#!/bin/bash` as first line |
| TC-HELLO-003 | Script has `set -euo pipefail` | Script includes safety settings |
| TC-HELLO-004 | Script is executable | File has execute permission |
| TC-HELLO-005 | Script output has no extra whitespace | Output is exactly "Hello from MergeMill!" without trailing/leading whitespace |
