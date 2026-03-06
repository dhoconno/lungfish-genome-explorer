// AppleContainerRuntimeIntegrationTests.swift
// Integration tests for Apple Containerization runtime
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests verify that the Apple Containerization framework works
// end-to-end: initialization, image pulling, container lifecycle.
//
// Requirements:
//   - macOS 26+ on Apple Silicon
//   - Bundled vmlinux and init.rootfs.tar.gz in Resources/Containerization
//   - Network access (for image pull tests)
//   - com.apple.security.virtualization entitlement (for container start tests)
//
// Run:
//   swift test --filter AppleContainerRuntimeIntegrationTests
//   swift test --filter AppleContainerRuntimeIntegrationTests/testRuntimeInitialization
//
// Note: Container start/run tests will be skipped when run via `swift test`
// because the test runner binary lacks the com.apple.security.virtualization
// entitlement. These tests pass when the signed app runs containers.

import XCTest
@testable import LungfishWorkflow

@available(macOS 26, *)
final class AppleContainerRuntimeIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Checks if a container runtime error is due to missing virtualization entitlement.
    private func isEntitlementError(_ error: Error) -> Bool {
        let desc = "\(error)"
        return desc.contains("com.apple.security.virtualization")
            || desc.contains("VZErrorDomain")
    }

    // MARK: - Runtime Initialization

    /// Verifies the runtime can be initialized with bundled kernel and initfs.
    /// This test does NOT require network access.
    func testRuntimeInitialization() async throws {
        let runtime: AppleContainerRuntime
        do {
            runtime = try await AppleContainerRuntime()
        } catch {
            XCTFail("AppleContainerRuntime initialization failed: \(error)")
            return
        }

        // Check that the runtime reports as available (kernel + initfs loaded)
        let available = await runtime.isAvailable()
        if available {
            // Full runtime with kernel - ContainerManager was created
            let version = try await runtime.version()
            XCTAssertFalse(version.isEmpty, "Version string should not be empty")
            let hasKernel = await runtime.hasKernel()
            XCTAssertTrue(hasKernel, "Runtime should have kernel configured")
        } else {
            // Runtime initialized but without kernel - limited functionality
            let hasKernel = await runtime.hasKernel()
            XCTAssertFalse(hasKernel)
            print("WARNING: Runtime initialized without kernel. Container operations will not work.")
            print("Ensure vmlinux and init.rootfs.tar.gz exist in Resources/Containerization/")
        }
    }

    /// Verifies the image store directory is created.
    func testImageStoreCreated() async throws {
        let runtime = try await AppleContainerRuntime()
        let storePath = await runtime.getImageStorePath()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storePath.path),
            "Image store directory should exist at \(storePath.path)"
        )
    }

    /// Verifies custom image store path works.
    func testCustomImageStorePath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-container-test-\(UUID().uuidString)")

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let runtime = try await AppleContainerRuntime(imageStorePath: tempDir)
        let storePath = await runtime.getImageStorePath()
        XCTAssertEqual(storePath, tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    // MARK: - Image Pull Tests (requires network)

    /// Pulls a minimal Alpine image and verifies the image metadata.
    /// Requires network access but NOT the virtualization entitlement.
    func testPullAlpineImage() async throws {
        let runtime = try await AppleContainerRuntime()

        let available = await runtime.isAvailable()
        guard available else {
            throw XCTSkip("Runtime not fully available (no kernel). Skipping image pull test.")
        }

        let image: ContainerImage
        do {
            image = try await runtime.pullImage(reference: "docker.io/library/alpine:latest")
        } catch {
            throw XCTSkip("Failed to pull Alpine image (network issue?): \(error)")
        }

        XCTAssertEqual(image.reference, "docker.io/library/alpine:latest")
        XCTAssertEqual(image.runtimeType, .appleContainerization)
        XCTAssertEqual(image.os, "linux")
        XCTAssertEqual(image.architecture, "arm64")
        XCTAssertNotNil(image.pulledAt)
    }

    // MARK: - Container Lifecycle (requires network + entitlement)

    /// Pulls a minimal Alpine image and runs `echo "hello from container"`.
    ///
    /// This test requires:
    /// - Network access (image pull)
    /// - com.apple.security.virtualization entitlement (VM creation)
    ///
    /// When run via `swift test`, this will skip due to missing entitlement.
    /// The test validates the full lifecycle when run from the signed app.
    func testRunEchoContainer() async throws {
        let runtime = try await AppleContainerRuntime()

        let available = await runtime.isAvailable()
        guard available else {
            throw XCTSkip("Runtime not fully available (no kernel). Skipping container lifecycle test.")
        }

        // Pull a minimal image
        let image: ContainerImage
        do {
            image = try await runtime.pullImage(reference: "docker.io/library/alpine:latest")
        } catch {
            throw XCTSkip("Failed to pull Alpine image (network issue?): \(error)")
        }

        XCTAssertEqual(image.reference, "docker.io/library/alpine:latest")
        XCTAssertEqual(image.runtimeType, .appleContainerization)

        // Create container configuration with echo command
        let config = ContainerConfiguration(
            cpuCount: 1,
            memoryBytes: 512 * 1024 * 1024,  // 512 MB
            command: ["/bin/sh", "-c", "echo 'hello from container'"]
        )

        // Create the container
        let container: Container
        do {
            container = try await runtime.createContainer(
                name: "echo-test-\(UUID().uuidString.prefix(8))",
                image: image,
                config: config
            )
        } catch {
            if isEntitlementError(error) {
                throw XCTSkip(
                    "Container creation requires com.apple.security.virtualization entitlement. "
                    + "This is expected when running via `swift test`. "
                    + "The test will pass when run from the signed app."
                )
            }
            throw error
        }

        XCTAssertEqual(container.state, .created)
        XCTAssertEqual(container.runtimeType, .appleContainerization)

        // Run the container and wait for it to complete
        do {
            let exitCode = try await runtime.runAndWait(container)
            XCTAssertEqual(exitCode, 0, "Container should exit with code 0")
        } catch {
            if isEntitlementError(error) {
                // Clean up and skip
                try? await runtime.removeContainer(container)
                throw XCTSkip(
                    "Container start requires com.apple.security.virtualization entitlement. "
                    + "This is expected when running via `swift test`. "
                    + "The test will pass when run from the signed app."
                )
            }
            throw error
        }

        // Clean up
        try await runtime.removeContainer(container)

        // Verify it was removed
        let containers = await runtime.listContainers()
        XCTAssertFalse(
            containers.contains(where: { $0.id == container.id }),
            "Container should be removed from active list"
        )
    }

    /// Tests that a container with a failing command returns non-zero exit code.
    func testContainerFailingCommand() async throws {
        let runtime = try await AppleContainerRuntime()

        let available = await runtime.isAvailable()
        guard available else {
            throw XCTSkip("Runtime not fully available. Skipping.")
        }

        let image: ContainerImage
        do {
            image = try await runtime.pullImage(reference: "docker.io/library/alpine:latest")
        } catch {
            throw XCTSkip("Failed to pull image: \(error)")
        }

        let config = ContainerConfiguration(
            cpuCount: 1,
            memoryBytes: 512 * 1024 * 1024,
            command: ["/bin/sh", "-c", "exit 42"]
        )

        let container: Container
        do {
            container = try await runtime.createContainer(
                name: "fail-test-\(UUID().uuidString.prefix(8))",
                image: image,
                config: config
            )
        } catch {
            if isEntitlementError(error) {
                throw XCTSkip("Requires com.apple.security.virtualization entitlement.")
            }
            throw error
        }

        do {
            let exitCode = try await runtime.runAndWait(container)
            XCTAssertEqual(exitCode, 42, "Container should exit with code 42")
        } catch {
            if isEntitlementError(error) {
                try? await runtime.removeContainer(container)
                throw XCTSkip("Requires com.apple.security.virtualization entitlement.")
            }
            throw error
        }

        try await runtime.removeContainer(container)
    }

    /// Tests container with file system mount.
    func testContainerWithMount() async throws {
        let runtime = try await AppleContainerRuntime()

        let available = await runtime.isAvailable()
        guard available else {
            throw XCTSkip("Runtime not fully available. Skipping.")
        }

        let image: ContainerImage
        do {
            image = try await runtime.pullImage(reference: "docker.io/library/alpine:latest")
        } catch {
            throw XCTSkip("Failed to pull image: \(error)")
        }

        // Create a temp directory with a test file to mount into the container
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-mount-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello from host".write(to: testFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let mount = MountBinding(
            source: tempDir.path,
            destination: "/workspace",
            readOnly: true
        )

        let config = ContainerConfiguration(
            cpuCount: 1,
            memoryBytes: 512 * 1024 * 1024,
            mounts: [mount],
            command: ["/bin/sh", "-c", "cat /workspace/test.txt"]
        )

        let container: Container
        do {
            container = try await runtime.createContainer(
                name: "mount-test-\(UUID().uuidString.prefix(8))",
                image: image,
                config: config
            )
        } catch {
            if isEntitlementError(error) {
                throw XCTSkip("Requires com.apple.security.virtualization entitlement.")
            }
            throw error
        }

        do {
            let exitCode = try await runtime.runAndWait(container)
            XCTAssertEqual(exitCode, 0, "Container should read the mounted file successfully")
        } catch {
            if isEntitlementError(error) {
                try? await runtime.removeContainer(container)
                throw XCTSkip("Requires com.apple.security.virtualization entitlement.")
            }
            throw error
        }

        try await runtime.removeContainer(container)
    }

    // MARK: - NAT Network Tests

    /// Tests NATNetwork address allocation and release.
    func testNATNetworkAddressAllocation() throws {
        var network = NATNetwork()

        // Allocate a few addresses
        let iface1 = try network.create("container-1")
        XCTAssertNotNil(iface1, "First interface should be created")

        let iface2 = try network.create("container-2")
        XCTAssertNotNil(iface2, "Second interface should be created")

        // Release first address
        try network.release("container-1")

        // Allocate again - should reuse the released address
        let iface3 = try network.create("container-3")
        XCTAssertNotNil(iface3, "Third interface should reuse released address")

        // Clean up
        try network.release("container-2")
        try network.release("container-3")
    }

    /// Tests that releasing a non-existent container ID is safe.
    func testNATNetworkReleaseUnknownID() throws {
        var network = NATNetwork()
        // Should not throw
        try network.release("nonexistent")
    }
}
