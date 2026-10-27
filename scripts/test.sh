#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -parse-as-library CommandRunner.swift Tests/CommandRunnerTests.swift -o build/tests/command-runner-tests
build/tests/command-runner-tests
swiftc -parse-as-library CommandRunner.swift DiskIdentity.swift DiskEvents.swift RamDiskManager.swift Tests/DiskManagerTests.swift -o build/tests/disk-manager-tests
build/tests/disk-manager-tests
if [[ "${JRAMDISK_RUN_DISK_TESTS:-0}" == "1" ]]; then
  swiftc -parse-as-library CommandRunner.swift DiskIdentity.swift DiskEvents.swift RamDiskManager.swift Tests/RuntimeSmoke.swift -o build/tests/runtime-smoke
  build/tests/runtime-smoke
fi
