#!/bin/sh
set -eu
cd "$(dirname "$0")"

mkdir -p build/ModuleCache
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path build/ModuleCache \
    Sources/SleepCoordinator.swift Tests/CoordinatorTests.swift \
    -o build/CoordinatorTests
build/CoordinatorTests

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path build/ModuleCache \
    Sources/ChimeOutput.swift Sources/UnmountSound.swift Tests/SoundTests.swift \
    -o build/SoundTests
build/SoundTests
