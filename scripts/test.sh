#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -parse-as-library CommandRunner.swift Tests/CommandRunnerTests.swift -o build/tests/command-runner-tests
build/tests/command-runner-tests
