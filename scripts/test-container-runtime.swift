#!/usr/bin/env swift
// test-container-runtime.swift
// Standalone verification script for Apple Containerization runtime
//
// NOTE: This script cannot be run directly with `swift` because it depends on
// the Containerization SPM package. Use the companion shell script instead:
//
//   ./scripts/test-container-runtime.sh
//
// That script will:
//   1. Verify system requirements (macOS 26+, arm64)
//   2. Check if the `container` CLI is installed (optional)
//   3. Build and run the XCTest integration test via `swift test`
//   4. Report results
//
// The actual test logic lives in:
//   Tests/LungfishWorkflowTests/AppleContainerRuntimeIntegrationTests.swift
//
// What the integration test verifies:
//   - AppleContainerRuntime actor can be initialized
//   - Bundled kernel (vmlinux) is found via Bundle.module
//   - Bundled initfs (init.rootfs.tar.gz) is loaded into the OCI image store
//   - ContainerManager is created with NAT networking
//   - A minimal Alpine container can be pulled from the registry
//   - A container running `echo "hello from container"` produces expected output
//   - Container lifecycle (create -> start -> wait -> remove) completes cleanly

import Foundation

// This file exists as documentation. The real test is the XCTest target.
// See: Tests/LungfishWorkflowTests/AppleContainerRuntimeIntegrationTests.swift

print("""
This script cannot be run directly. Use the shell driver instead:

    ./scripts/test-container-runtime.sh

Or run the integration test directly:

    swift test --filter AppleContainerRuntimeIntegrationTests

""")

exit(1)
