// WorkflowRegressionTests.swift - Regression tests for LungfishWorkflow public API
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests lock in the current public API surface of key LungfishWorkflow types
// to provide regression protection during upcoming code simplification.

import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore

// MARK: - Container Model Tests

final class ContainerStateRegressionTests: XCTestCase {

    // MARK: - ContainerState

    func testContainerStateAllCases() {
        let allCases = ContainerState.allCases
        XCTAssertEqual(allCases.count, 7)
        XCTAssertTrue(allCases.contains(.created))
        XCTAssertTrue(allCases.contains(.running))
        XCTAssertTrue(allCases.contains(.paused))
        XCTAssertTrue(allCases.contains(.stopping))
        XCTAssertTrue(allCases.contains(.stopped))
        XCTAssertTrue(allCases.contains(.removed))
        XCTAssertTrue(allCases.contains(.error))
    }

    func testContainerStateRawValues() {
        XCTAssertEqual(ContainerState.created.rawValue, "created")
        XCTAssertEqual(ContainerState.running.rawValue, "running")
        XCTAssertEqual(ContainerState.paused.rawValue, "paused")
        XCTAssertEqual(ContainerState.stopping.rawValue, "stopping")
        XCTAssertEqual(ContainerState.stopped.rawValue, "stopped")
        XCTAssertEqual(ContainerState.removed.rawValue, "removed")
        XCTAssertEqual(ContainerState.error.rawValue, "error")
    }

    func testContainerStateDisplayName() {
        XCTAssertEqual(ContainerState.created.displayName, "Created")
        XCTAssertEqual(ContainerState.running.displayName, "Running")
        XCTAssertEqual(ContainerState.error.displayName, "Error")
    }

    func testContainerStateAllowsExecution() {
        XCTAssertTrue(ContainerState.running.allowsExecution)
        XCTAssertFalse(ContainerState.created.allowsExecution)
        XCTAssertFalse(ContainerState.paused.allowsExecution)
        XCTAssertFalse(ContainerState.stopped.allowsExecution)
        XCTAssertFalse(ContainerState.removed.allowsExecution)
        XCTAssertFalse(ContainerState.error.allowsExecution)
    }

    func testContainerStateIconNames() {
        XCTAssertEqual(ContainerState.created.iconName, "plus.circle")
        XCTAssertEqual(ContainerState.running.iconName, "play.circle.fill")
        XCTAssertEqual(ContainerState.paused.iconName, "pause.circle.fill")
        XCTAssertEqual(ContainerState.stopped.iconName, "stop.circle.fill")
        XCTAssertEqual(ContainerState.removed.iconName, "trash.circle")
        XCTAssertEqual(ContainerState.error.iconName, "exclamationmark.circle.fill")
    }

    func testContainerStateValidTransitions() {
        // From created
        XCTAssertTrue(ContainerState.created.canTransition(to: .running))
        XCTAssertTrue(ContainerState.created.canTransition(to: .removed))
        XCTAssertTrue(ContainerState.created.canTransition(to: .error))
        XCTAssertFalse(ContainerState.created.canTransition(to: .paused))
        XCTAssertFalse(ContainerState.created.canTransition(to: .stopped))

        // From running
        XCTAssertTrue(ContainerState.running.canTransition(to: .paused))
        XCTAssertTrue(ContainerState.running.canTransition(to: .stopping))
        XCTAssertTrue(ContainerState.running.canTransition(to: .stopped))
        XCTAssertTrue(ContainerState.running.canTransition(to: .error))
        XCTAssertFalse(ContainerState.running.canTransition(to: .created))
        XCTAssertFalse(ContainerState.running.canTransition(to: .removed))

        // From paused
        XCTAssertTrue(ContainerState.paused.canTransition(to: .running))
        XCTAssertTrue(ContainerState.paused.canTransition(to: .stopping))
        XCTAssertTrue(ContainerState.paused.canTransition(to: .stopped))

        // From stopping
        XCTAssertTrue(ContainerState.stopping.canTransition(to: .stopped))
        XCTAssertTrue(ContainerState.stopping.canTransition(to: .error))
        XCTAssertFalse(ContainerState.stopping.canTransition(to: .running))

        // From stopped
        XCTAssertTrue(ContainerState.stopped.canTransition(to: .removed))
        XCTAssertTrue(ContainerState.stopped.canTransition(to: .running))

        // From error
        XCTAssertTrue(ContainerState.error.canTransition(to: .removed))
        XCTAssertFalse(ContainerState.error.canTransition(to: .running))

        // Same-state always valid
        for state in ContainerState.allCases {
            XCTAssertTrue(state.canTransition(to: state), "\(state) should allow self-transition")
        }
    }

    func testContainerStateCodableRoundTrip() throws {
        for state in ContainerState.allCases {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(ContainerState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
    }
}

// MARK: - Container Tests

final class ContainerRegressionTests: XCTestCase {

    private func makeTestImage() -> ContainerImage {
        ContainerImage(
            id: "img-001",
            reference: "docker.io/library/ubuntu:22.04",
            runtimeType: .docker
        )
    }

    private func makeTestContainer() -> Container {
        Container(
            id: "abc123def456",
            name: "test-container",
            runtimeType: .docker,
            state: .created,
            image: makeTestImage(),
            configuration: ContainerConfiguration(),
            nativeContainer: AnySendable("docker-handle")
        )
    }

    func testContainerConstruction() {
        let container = makeTestContainer()
        XCTAssertEqual(container.id, "abc123def456")
        XCTAssertEqual(container.name, "test-container")
        XCTAssertEqual(container.runtimeType, .docker)
        XCTAssertEqual(container.state, .created)
        XCTAssertNil(container.startedAt)
        XCTAssertNil(container.stoppedAt)
        XCTAssertNil(container.exitCode)
        XCTAssertNil(container.ipAddress)
    }

    func testContainerHostnameDefaultsToName() {
        let container = makeTestContainer()
        XCTAssertEqual(container.hostname, "test-container")
    }

    func testContainerHostnameExplicit() {
        let container = Container(
            id: "id",
            name: "name",
            runtimeType: .docker,
            image: makeTestImage(),
            configuration: ContainerConfiguration(),
            hostname: "custom-host",
            nativeContainer: AnySendable()
        )
        XCTAssertEqual(container.hostname, "custom-host")
    }

    func testContainerComputedProperties() {
        var container = makeTestContainer()
        XCTAssertTrue(container.canStart)
        XCTAssertFalse(container.isRunning)
        XCTAssertFalse(container.canStop)
        XCTAssertTrue(container.canRemove)

        try! container.updateState(.running)
        XCTAssertTrue(container.isRunning)
        XCTAssertFalse(container.canStart)
        XCTAssertTrue(container.canStop)
        XCTAssertFalse(container.canRemove)
        XCTAssertNotNil(container.startedAt)
    }

    func testContainerShortID() {
        let container = makeTestContainer()
        XCTAssertEqual(container.shortID, "abc123def456")

        let longID = Container(
            id: "abc123def456789abcdef",
            name: "c",
            runtimeType: .docker,
            image: makeTestImage(),
            configuration: ContainerConfiguration(),
            nativeContainer: AnySendable()
        )
        XCTAssertEqual(longID.shortID, "abc123def456")
    }

    func testContainerStateUpdateSetsTimestamps() throws {
        var container = makeTestContainer()

        try container.updateState(.running)
        XCTAssertNotNil(container.startedAt)
        XCTAssertNil(container.stoppedAt)

        try container.updateState(.stopped)
        XCTAssertNotNil(container.stoppedAt)
    }

    func testContainerInvalidStateTransitionThrows() {
        var container = makeTestContainer()
        XCTAssertThrowsError(try container.updateState(.paused))
    }

    func testContainerRunDuration() throws {
        var container = makeTestContainer()
        XCTAssertNil(container.runDuration)

        try container.updateState(.running)
        let duration = container.runDuration
        XCTAssertNotNil(duration)
        XCTAssertGreaterThanOrEqual(duration!, 0)
    }

    func testContainerEquatableByIDAndRuntime() {
        let c1 = Container(
            id: "same-id",
            name: "a",
            runtimeType: .docker,
            image: makeTestImage(),
            configuration: ContainerConfiguration(),
            nativeContainer: AnySendable()
        )
        let c2 = Container(
            id: "same-id",
            name: "different-name",
            runtimeType: .docker,
            image: makeTestImage(),
            configuration: ContainerConfiguration(),
            nativeContainer: AnySendable()
        )
        let c3 = Container(
            id: "same-id",
            name: "a",
            runtimeType: .appleContainerization,
            image: ContainerImage(reference: "x", runtimeType: .appleContainerization),
            configuration: ContainerConfiguration(),
            nativeContainer: AnySendable()
        )

        XCTAssertEqual(c1, c2, "Same ID and runtime should be equal")
        XCTAssertNotEqual(c1, c3, "Same ID but different runtime should not be equal")
    }

    func testContainerHashable() {
        let c1 = makeTestContainer()
        let c2 = makeTestContainer()
        let set: Set<Container> = [c1, c2]
        XCTAssertEqual(set.count, 1, "Same ID+runtime containers should hash to one entry")
    }

    func testContainerDescription() {
        let container = makeTestContainer()
        let desc = container.description
        XCTAssertTrue(desc.contains("test-container"))
        XCTAssertTrue(desc.contains("abc123def456"))
        XCTAssertTrue(desc.contains("created"))
    }

    func testContainerSetIPAddress() {
        var container = makeTestContainer()
        XCTAssertNil(container.ipAddress)
        container.setIPAddress("10.0.0.5")
        XCTAssertEqual(container.ipAddress, "10.0.0.5")
    }

    func testContainerSetExitCode() {
        var container = makeTestContainer()
        XCTAssertNil(container.exitCode)
        container.setExitCode(0)
        XCTAssertEqual(container.exitCode, 0)
        container.setExitCode(137)
        XCTAssertEqual(container.exitCode, 137)
    }

    func testAnySendableAccess() {
        let container = makeTestContainer()
        let handle: String? = container.nativeContainerAs(String.self)
        XCTAssertEqual(handle, "docker-handle")
        let wrong: Int? = container.nativeContainerAs(Int.self)
        XCTAssertNil(wrong)
    }

    func testAnySendableEmpty() {
        let empty = AnySendable()
        XCTAssertTrue(empty.value is Void)
    }
}

// MARK: - ContainerStats Tests

final class ContainerStatsRegressionTests: XCTestCase {

    func testContainerStatsConstruction() {
        let stats = ContainerStats(
            cpuUsagePercent: 42.5,
            memoryUsageBytes: 4_294_967_296,
            memoryLimitBytes: 8_589_934_592
        )
        XCTAssertEqual(stats.cpuUsagePercent, 42.5)
        XCTAssertEqual(stats.memoryUsageBytes, 4_294_967_296)
        XCTAssertEqual(stats.memoryLimitBytes, 8_589_934_592)
        XCTAssertEqual(stats.networkRxBytes, 0)
        XCTAssertEqual(stats.networkTxBytes, 0)
        XCTAssertEqual(stats.blockReadBytes, 0)
        XCTAssertEqual(stats.blockWriteBytes, 0)
    }

    func testContainerStatsMemoryFraction() {
        let stats = ContainerStats(
            cpuUsagePercent: 0,
            memoryUsageBytes: 4_294_967_296,
            memoryLimitBytes: 8_589_934_592
        )
        XCTAssertEqual(stats.memoryUsageFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(stats.memoryUsagePercent, 50.0, accuracy: 0.1)
    }

    func testContainerStatsZeroLimit() {
        let stats = ContainerStats(
            cpuUsagePercent: 0,
            memoryUsageBytes: 100,
            memoryLimitBytes: 0
        )
        XCTAssertEqual(stats.memoryUsageFraction, 0.0)
        XCTAssertEqual(stats.memoryUsagePercent, 0.0)
    }
}

// MARK: - ContainerConfiguration Tests

final class ContainerConfigurationRegressionTests: XCTestCase {

    func testDefaultConstruction() {
        let config = ContainerConfiguration()
        XCTAssertNil(config.cpuCount)
        XCTAssertNil(config.memoryBytes)
        XCTAssertTrue(config.mounts.isEmpty)
        XCTAssertNil(config.hostname)
        XCTAssertNil(config.workingDirectory)
        XCTAssertTrue(config.environment.isEmpty)
        XCTAssertEqual(config.networkMode, .bridge)
        XCTAssertTrue(config.portMappings.isEmpty)
        XCTAssertNil(config.command)
        XCTAssertTrue(config.dockerOptions.isEmpty)
        XCTAssertNil(config.userID)
        XCTAssertNil(config.groupID)
    }

    func testFullConstruction() {
        let config = ContainerConfiguration(
            cpuCount: 4,
            memoryBytes: 8.gib(),
            mounts: [MountBinding(source: "/host", destination: "/container")],
            hostname: "test",
            workingDirectory: "/workspace",
            environment: ["PATH": "/usr/bin"],
            networkMode: .host,
            portMappings: [PortMapping(hostPort: 8080, containerPort: 80)],
            command: ["echo", "hello"],
            dockerOptions: ["--rm"],
            userID: 1000,
            groupID: 1000
        )
        XCTAssertEqual(config.cpuCount, 4)
        XCTAssertEqual(config.memoryBytes, 8_589_934_592)
        XCTAssertEqual(config.mounts.count, 1)
        XCTAssertEqual(config.hostname, "test")
        XCTAssertEqual(config.workingDirectory, "/workspace")
        XCTAssertEqual(config.environment["PATH"], "/usr/bin")
        XCTAssertEqual(config.networkMode, .host)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.command, ["echo", "hello"])
        XCTAssertEqual(config.dockerOptions, ["--rm"])
        XCTAssertEqual(config.userID, 1000)
        XCTAssertEqual(config.groupID, 1000)
    }

    func testMinimalFactory() {
        let config = ContainerConfiguration.minimal()
        XCTAssertEqual(config.cpuCount, 1)
        XCTAssertEqual(config.memoryBytes, 1.gib())
    }

    func testBioinformaticsDefaultFactory() {
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        let config = ContainerConfiguration.bioinformaticsDefault(workspacePath: workspace)
        XCTAssertEqual(config.cpuCount, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertEqual(config.memoryBytes, 8.gib())
        XCTAssertEqual(config.mounts.count, 1)
        XCTAssertEqual(config.mounts.first?.destination, "/workspace")
        XCTAssertEqual(config.workingDirectory, "/workspace")
        XCTAssertEqual(config.environment["LC_ALL"], "C.UTF-8")
        XCTAssertEqual(config.networkMode, .bridge)
    }

    func testCodableRoundTrip() throws {
        let original = ContainerConfiguration(
            cpuCount: 2,
            memoryBytes: 4.gib(),
            mounts: [MountBinding(source: "/a", destination: "/b", readOnly: true)],
            hostname: "myhost",
            environment: ["FOO": "bar"],
            networkMode: .none
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEquatable() {
        let a = ContainerConfiguration(cpuCount: 4)
        let b = ContainerConfiguration(cpuCount: 4)
        let c = ContainerConfiguration(cpuCount: 8)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - MountBinding Tests

final class MountBindingRegressionTests: XCTestCase {

    func testConstruction() {
        let mount = MountBinding(source: "/host/data", destination: "/container/data")
        XCTAssertEqual(mount.source, "/host/data")
        XCTAssertEqual(mount.destination, "/container/data")
        XCTAssertFalse(mount.readOnly)
        XCTAssertEqual(mount.propagation, .private)
    }

    func testReadOnlyMount() {
        let mount = MountBinding(source: "/host", destination: "/container", readOnly: true)
        XCTAssertTrue(mount.readOnly)
    }

    func testURLConstruction() {
        let mount = MountBinding(
            source: URL(fileURLWithPath: "/host/path"),
            destination: "/container/path",
            readOnly: true
        )
        XCTAssertEqual(mount.source, "/host/path")
        XCTAssertTrue(mount.readOnly)
    }

    func testDockerMountSpec() {
        let rw = MountBinding(source: "/data", destination: "/mnt/data")
        XCTAssertEqual(rw.dockerMountSpec, "/data:/mnt/data")

        let ro = MountBinding(source: "/data", destination: "/mnt/data", readOnly: true)
        XCTAssertEqual(ro.dockerMountSpec, "/data:/mnt/data:ro")
    }

    func testIdentifiable() {
        let mount = MountBinding(source: "/src", destination: "/dst")
        XCTAssertEqual(mount.id, "/src:/dst")
    }

    func testCodableRoundTrip() throws {
        let original = MountBinding(
            source: "/a",
            destination: "/b",
            readOnly: true,
            propagation: .shared
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MountBinding.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - NetworkMode Tests

final class NetworkModeRegressionTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(NetworkMode.bridge.rawValue, "bridge")
        XCTAssertEqual(NetworkMode.host.rawValue, "host")
        XCTAssertEqual(NetworkMode.none.rawValue, "none")
        XCTAssertEqual(NetworkMode.vmnetShared.rawValue, "vmnet_shared")
        XCTAssertEqual(NetworkMode.vmnetBridged.rawValue, "vmnet_bridged")
    }

    func testDockerNetworkFlag() {
        XCTAssertEqual(NetworkMode.bridge.dockerNetworkFlag, "bridge")
        XCTAssertEqual(NetworkMode.host.dockerNetworkFlag, "host")
        XCTAssertEqual(NetworkMode.none.dockerNetworkFlag, "none")
        // vmnet modes fall back to bridge for Docker
        XCTAssertEqual(NetworkMode.vmnetShared.dockerNetworkFlag, "bridge")
        XCTAssertEqual(NetworkMode.vmnetBridged.dockerNetworkFlag, "bridge")
    }
}

// MARK: - PortMapping Tests

final class PortMappingRegressionTests: XCTestCase {

    func testConstruction() {
        let mapping = PortMapping(hostPort: 8080, containerPort: 80)
        XCTAssertEqual(mapping.hostPort, 8080)
        XCTAssertEqual(mapping.containerPort, 80)
        XCTAssertEqual(mapping.protocol, .tcp)
        XCTAssertNil(mapping.hostIP)
    }

    func testSamePortFactory() {
        let mapping = PortMapping.same(3000)
        XCTAssertEqual(mapping.hostPort, 3000)
        XCTAssertEqual(mapping.containerPort, 3000)
    }

    func testDockerFlag() {
        let basic = PortMapping(hostPort: 8080, containerPort: 80)
        XCTAssertEqual(basic.dockerFlag, "8080:80")

        let withIP = PortMapping(hostPort: 8080, containerPort: 80, hostIP: "127.0.0.1")
        XCTAssertEqual(withIP.dockerFlag, "127.0.0.1:8080:80")

        let udp = PortMapping(hostPort: 5353, containerPort: 53, protocol: .udp)
        XCTAssertEqual(udp.dockerFlag, "5353:53/udp")
    }

    func testIdentifiable() {
        let mapping = PortMapping(hostPort: 443, containerPort: 8443)
        XCTAssertEqual(mapping.id, "443:8443")
    }
}

// MARK: - Memory Size Extensions Tests

final class MemorySizeExtensionRegressionTests: XCTestCase {

    func testGiB() {
        XCTAssertEqual(1.gib(), 1_073_741_824)
        XCTAssertEqual(8.gib(), 8_589_934_592)
    }

    func testMiB() {
        XCTAssertEqual(1.mib(), 1_048_576)
        XCTAssertEqual(512.mib(), 536_870_912)
    }

    func testFormattedBytes() {
        XCTAssertEqual(8.gib().formattedBytes, "8.0 GiB")
        XCTAssertEqual(512.mib().formattedBytes, "512 MiB")
        XCTAssertEqual(UInt64(1024).formattedBytes, "1 KiB")
    }
}

// MARK: - ContainerImage Tests

final class ContainerImageRegressionTests: XCTestCase {

    func testConstruction() {
        let image = ContainerImage(
            id: "test-id",
            reference: "docker.io/library/ubuntu:22.04",
            digest: "sha256:abc123",
            sizeBytes: 100_000_000,
            runtimeType: .docker
        )
        XCTAssertEqual(image.id, "test-id")
        XCTAssertEqual(image.reference, "docker.io/library/ubuntu:22.04")
        XCTAssertEqual(image.digest, "sha256:abc123")
        XCTAssertEqual(image.sizeBytes, 100_000_000)
        XCTAssertEqual(image.runtimeType, .docker)
    }

    func testNameParsing() {
        let image = ContainerImage(reference: "docker.io/library/ubuntu:22.04", runtimeType: .docker)
        XCTAssertEqual(image.name, "ubuntu")

        let biocontainer = ContainerImage(reference: "quay.io/biocontainers/bwa:0.7.17", runtimeType: .docker)
        XCTAssertEqual(biocontainer.name, "bwa")

        let plain = ContainerImage(reference: "nginx", runtimeType: .docker)
        XCTAssertEqual(plain.name, "nginx")
    }

    func testTagParsing() {
        let tagged = ContainerImage(reference: "ubuntu:22.04", runtimeType: .docker)
        XCTAssertEqual(tagged.tag, "22.04")

        let noTag = ContainerImage(reference: "ubuntu", runtimeType: .docker)
        XCTAssertNil(noTag.tag)
    }

    func testRegistryParsing() {
        let dockerHub = ContainerImage(reference: "ubuntu:22.04", runtimeType: .docker)
        XCTAssertEqual(dockerHub.registry, "docker.io")

        let quay = ContainerImage(reference: "quay.io/biocontainers/bwa:0.7.17", runtimeType: .docker)
        XCTAssertEqual(quay.registry, "quay.io")

        let ghcr = ContainerImage(reference: "ghcr.io/nextflow-io/nextflow:24.04.0", runtimeType: .docker)
        XCTAssertEqual(ghcr.registry, "ghcr.io")
    }

    func testRepositoryParsing() {
        let simple = ContainerImage(reference: "ubuntu:22.04", runtimeType: .docker)
        // "ubuntu:22.04" contains ":" so repository parser treats it as registry
        // and strips it, leaving empty repository. This is known current behavior.
        XCTAssertEqual(simple.repository, "")

        let namespaced = ContainerImage(reference: "biocontainers/bwa:0.7.17", runtimeType: .docker)
        XCTAssertEqual(namespaced.repository, "biocontainers/bwa")
    }

    func testDisplayName() {
        let tagged = ContainerImage(reference: "ubuntu:22.04", runtimeType: .docker)
        XCTAssertEqual(tagged.displayName, "ubuntu:22.04")

        let untagged = ContainerImage(reference: "ubuntu", runtimeType: .docker)
        XCTAssertEqual(untagged.displayName, "ubuntu")
    }

    func testIsPulled() {
        let docker = ContainerImage(reference: "ubuntu", runtimeType: .docker)
        XCTAssertTrue(docker.isPulled, "Docker images are always considered pulled")

        let appleNoRootfs = ContainerImage(reference: "ubuntu", runtimeType: .appleContainerization)
        XCTAssertFalse(appleNoRootfs.isPulled)

        let appleWithRootfs = ContainerImage(
            reference: "ubuntu",
            rootfsPath: URL(fileURLWithPath: "/tmp/rootfs"),
            runtimeType: .appleContainerization
        )
        XCTAssertTrue(appleWithRootfs.isPulled)
    }

    func testNormalizeReference() {
        let normalized = ContainerImage.normalizeReference("ubuntu")
        XCTAssertEqual(normalized, "docker.io/library/ubuntu:latest")

        let tagged = ContainerImage.normalizeReference("ubuntu:22.04")
        // "ubuntu:22.04" has known parsing quirk: colon causes repository to be empty
        XCTAssertEqual(tagged, "docker.io/:22.04")
    }

    func testCodableRoundTrip() throws {
        let original = ContainerImage(
            id: "test",
            reference: "quay.io/biocontainers/samtools:1.18",
            digest: "sha256:abcdef",
            sizeBytes: 500_000_000,
            labels: ["maintainer": "test"],
            architecture: "arm64",
            os: "linux",
            runtimeType: .docker
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContainerImage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testHashable() {
        let img1 = ContainerImage(id: "same", reference: "a", runtimeType: .docker)
        let img2 = ContainerImage(id: "same", reference: "b", runtimeType: .docker)
        let set: Set<ContainerImage> = [img1, img2]
        // Equatable compares all properties (Codable synthesis), so different references
        // make them unequal even though hash (id-only) collides.
        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - ImagePullProgress Tests

final class ImagePullProgressRegressionTests: XCTestCase {

    func testFractionCompleted() {
        let progress = ImagePullProgress(currentBytes: 50, totalBytes: 100)
        XCTAssertEqual(progress.fractionCompleted, 0.5, accuracy: 0.001)
        XCTAssertEqual(progress.percentComplete, 50)
    }

    func testZeroTotalBytes() {
        let progress = ImagePullProgress(currentBytes: 0, totalBytes: 0)
        XCTAssertEqual(progress.fractionCompleted, 0.0)
        XCTAssertEqual(progress.percentComplete, 0)
    }

    func testCompletedFactory() {
        let progress = ImagePullProgress.completed(totalBytes: 1000)
        XCTAssertEqual(progress.currentBytes, 1000)
        XCTAssertEqual(progress.totalBytes, 1000)
        XCTAssertEqual(progress.fractionCompleted, 1.0)
    }

    func testDisplayString() {
        let withLayer = ImagePullProgress(layer: "layer1", currentBytes: 512.mib(), totalBytes: 1.gib())
        XCTAssertTrue(withLayer.displayString.contains("layer1"))

        let noLayer = ImagePullProgress(currentBytes: 100, totalBytes: 200)
        XCTAssertFalse(noLayer.displayString.contains("layer"))
    }
}

// MARK: - ContainerImageSpec Tests

final class ContainerImageSpecRegressionTests: XCTestCase {

    func testConstruction() {
        let spec = ContainerImageSpec(
            id: "samtools",
            name: "SAMtools",
            description: "Tools for SAM/BAM",
            reference: "docker.io/condaforge/miniforge3:latest",
            category: .core,
            purpose: .indexing,
            version: "1.18",
            supportedExtensions: ["bam", "sam"]
        )
        XCTAssertEqual(spec.id, "samtools")
        XCTAssertEqual(spec.name, "SAMtools")
        XCTAssertEqual(spec.category, .core)
        XCTAssertEqual(spec.purpose, .indexing)
        XCTAssertEqual(spec.version, "1.18")
        XCTAssertEqual(spec.supportedExtensions, ["bam", "sam"])
        XCTAssertFalse(spec.requiresEntitlements)
    }

    func testCodableRoundTrip() throws {
        let spec = ContainerImageSpec(
            id: "bwa",
            name: "BWA",
            description: "Aligner",
            reference: "docker.io/condaforge/miniforge3:latest",
            category: .optional,
            purpose: .alignment,
            version: "0.7.17"
        )
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(ContainerImageSpec.self, from: data)
        XCTAssertEqual(decoded, spec)
    }
}

// MARK: - ImageCategory & ImagePurpose Tests

final class ImageCategoryPurposeRegressionTests: XCTestCase {

    func testImageCategoryAllCases() {
        XCTAssertEqual(ImageCategory.allCases.count, 3)
        XCTAssertEqual(ImageCategory.core.displayName, "Core")
        XCTAssertEqual(ImageCategory.optional.displayName, "Optional")
        XCTAssertEqual(ImageCategory.custom.displayName, "Custom")
    }

    func testImagePurposeAllCases() {
        XCTAssertEqual(ImagePurpose.allCases.count, 10)
        XCTAssertEqual(ImagePurpose.indexing.displayName, "Indexing")
        XCTAssertEqual(ImagePurpose.alignment.displayName, "Alignment")
        XCTAssertEqual(ImagePurpose.assembly.displayName, "Assembly")
    }

    func testImageCategoryCodableRoundTrip() throws {
        for category in ImageCategory.allCases {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(ImageCategory.self, from: data)
            XCTAssertEqual(decoded, category)
        }
    }

    func testImagePurposeCodableRoundTrip() throws {
        for purpose in ImagePurpose.allCases {
            let data = try JSONEncoder().encode(purpose)
            let decoded = try JSONDecoder().decode(ImagePurpose.self, from: data)
            XCTAssertEqual(decoded, purpose)
        }
    }
}

// MARK: - DefaultContainerImages Tests

final class DefaultContainerImagesRegressionTests: XCTestCase {

    func testCoreImageCount() {
        XCTAssertEqual(DefaultContainerImages.coreImages.count, 5)
    }

    func testOptionalImageCount() {
        XCTAssertEqual(DefaultContainerImages.optionalImages.count, 5)
    }

    func testAllImagesIsSupersetOfCoreAndOptional() {
        let all = DefaultContainerImages.all
        let core = DefaultContainerImages.coreImages
        let optional = DefaultContainerImages.optionalImages
        XCTAssertEqual(all.count, core.count + optional.count)
    }

    func testCoreImageIDs() {
        let ids = DefaultContainerImages.coreImages.map(\.id)
        XCTAssertTrue(ids.contains("samtools"))
        XCTAssertTrue(ids.contains("bcftools"))
        XCTAssertTrue(ids.contains("htslib"))
        XCTAssertTrue(ids.contains("ucsc-bedtobigbed"))
        XCTAssertTrue(ids.contains("ucsc-bedgraphtobigwig"))
    }

    func testImageLookupByID() {
        let samtools = DefaultContainerImages.image(id: "samtools")
        XCTAssertNotNil(samtools)
        XCTAssertEqual(samtools?.name, "SAMtools")

        let missing = DefaultContainerImages.image(id: "nonexistent")
        XCTAssertNil(missing)
    }

    func testImagesByPurpose() {
        let aligners = DefaultContainerImages.images(for: .alignment)
        XCTAssertGreaterThan(aligners.count, 0)
        for aligner in aligners {
            XCTAssertEqual(aligner.purpose, .alignment)
        }
    }

    func testImagesByCategory() {
        let core = DefaultContainerImages.images(for: .core)
        XCTAssertEqual(core.count, 5)
        for image in core {
            XCTAssertEqual(image.category, .core)
        }
    }

    func testImagesByExtension() {
        let bamImages = DefaultContainerImages.images(forExtension: "bam")
        XCTAssertGreaterThan(bamImages.count, 0)
    }

    func testEstimatedSizes() {
        XCTAssertGreaterThan(DefaultContainerImages.estimatedCoreSizeBytes, 0)
        XCTAssertGreaterThan(DefaultContainerImages.estimatedOptionalSizeBytes, 0)
    }

    func testBaseImage() {
        XCTAssertEqual(DefaultContainerImages.baseImage, "docker.io/condaforge/miniforge3:latest")
    }

    func testSPAdesSpec() {
        let spades = DefaultContainerImages.spades
        XCTAssertEqual(spades.id, "spades")
        XCTAssertEqual(spades.category, .optional)
        XCTAssertEqual(spades.purpose, .assembly)
        XCTAssertNil(spades.setupCommands, "SPAdes uses pre-built image, no setup needed")
    }
}

// MARK: - ContainerRuntimeType Tests

final class ContainerRuntimeTypeRegressionTests: XCTestCase {

    func testAllCases() {
        let cases = ContainerRuntimeType.allCases
        XCTAssertEqual(cases.count, 2)
        XCTAssertTrue(cases.contains(.appleContainerization))
        XCTAssertTrue(cases.contains(.docker))
    }

    func testRawValues() {
        XCTAssertEqual(ContainerRuntimeType.appleContainerization.rawValue, "apple")
        XCTAssertEqual(ContainerRuntimeType.docker.rawValue, "docker")
    }

    func testDisplayNames() {
        XCTAssertEqual(ContainerRuntimeType.appleContainerization.displayName, "Apple Containerization")
        XCTAssertEqual(ContainerRuntimeType.docker.displayName, "Docker")
    }

    func testRequiresDaemon() {
        XCTAssertFalse(ContainerRuntimeType.appleContainerization.requiresDaemon)
        XCTAssertTrue(ContainerRuntimeType.docker.requiresDaemon)
    }

    func testCodableRoundTrip() throws {
        for runtime in ContainerRuntimeType.allCases {
            let data = try JSONEncoder().encode(runtime)
            let decoded = try JSONDecoder().decode(ContainerRuntimeType.self, from: data)
            XCTAssertEqual(decoded, runtime)
        }
    }
}

// MARK: - Unified Workflow Schema Tests

final class UnifiedWorkflowSchemaRegressionTests: XCTestCase {

    private func makeTestSchema() -> UnifiedWorkflowSchema {
        let params = [
            UnifiedWorkflowParameter(
                name: "input",
                title: "Input Files",
                description: "FASTQ input",
                type: .file,
                isRequired: true
            ),
            UnifiedWorkflowParameter(
                name: "threads",
                title: "Threads",
                type: .integer,
                defaultValue: .integer(4),
                isRequired: false
            ),
            UnifiedWorkflowParameter(
                name: "mode",
                type: .enumeration(["fast", "sensitive", "balanced"]),
                defaultValue: .string("balanced")
            ),
        ]
        let group = UnifiedParameterGroup(
            id: "main",
            title: "Main Options",
            description: "Primary parameters",
            parameters: params
        )
        return UnifiedWorkflowSchema(
            version: "1.0",
            title: "Test Workflow",
            description: "A test workflow",
            groups: [group]
        )
    }

    func testSchemaConstruction() {
        let schema = makeTestSchema()
        XCTAssertEqual(schema.version, "1.0")
        XCTAssertEqual(schema.title, "Test Workflow")
        XCTAssertEqual(schema.description, "A test workflow")
        XCTAssertEqual(schema.groups.count, 1)
    }

    func testAllParameters() {
        let schema = makeTestSchema()
        XCTAssertEqual(schema.allParameters.count, 3)
    }

    func testRequiredParameters() {
        let schema = makeTestSchema()
        let required = schema.requiredParameters
        XCTAssertEqual(required.count, 1)
        XCTAssertEqual(required.first?.name, "input")
    }

    func testParameterLookupByName() {
        let schema = makeTestSchema()
        let threads = schema.parameter(named: "threads")
        XCTAssertNotNil(threads)
        XCTAssertEqual(threads?.type, .integer)

        let missing = schema.parameter(named: "nonexistent")
        XCTAssertNil(missing)
    }

    func testValidationMissingRequired() {
        let schema = makeTestSchema()
        let errors = schema.validate([:])
        XCTAssertTrue(errors.contains(where: {
            if case .missingRequired(let name) = $0 { return name == "input" }
            return false
        }))
    }

    func testValidationUnknownParameter() {
        let schema = makeTestSchema()
        let errors = schema.validate(["input": "/path", "bogus": "value"])
        XCTAssertTrue(errors.contains(where: {
            if case .unknownParameter(let name) = $0 { return name == "bogus" }
            return false
        }))
    }

    func testCodableRoundTrip() throws {
        let original = makeTestSchema()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UnifiedWorkflowSchema.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - UnifiedParameterGroup Tests

final class UnifiedParameterGroupRegressionTests: XCTestCase {

    func testConstruction() {
        let group = UnifiedParameterGroup(
            id: "advanced",
            title: "Advanced Options",
            description: "For power users",
            iconName: "gearshape",
            isCollapsedByDefault: true,
            isHidden: false,
            parameters: []
        )
        XCTAssertEqual(group.id, "advanced")
        XCTAssertEqual(group.title, "Advanced Options")
        XCTAssertEqual(group.description, "For power users")
        XCTAssertEqual(group.iconName, "gearshape")
        XCTAssertTrue(group.isCollapsedByDefault)
        XCTAssertFalse(group.isHidden)
        XCTAssertTrue(group.parameters.isEmpty)
    }

    func testDefaults() {
        let group = UnifiedParameterGroup(id: "g", title: "G", parameters: [])
        XCTAssertFalse(group.isCollapsedByDefault)
        XCTAssertFalse(group.isHidden)
        XCTAssertNil(group.iconName)
        XCTAssertNil(group.description)
    }
}

// MARK: - UnifiedWorkflowParameter Tests

final class UnifiedWorkflowParameterRegressionTests: XCTestCase {

    func testConstructionDefaults() {
        let param = UnifiedWorkflowParameter(name: "my_param", type: .string)
        XCTAssertEqual(param.id, "my_param")
        XCTAssertEqual(param.name, "my_param")
        XCTAssertEqual(param.title, "My Param")  // auto-generated from name
        XCTAssertFalse(param.isRequired)
        XCTAssertFalse(param.isHidden)
        XCTAssertNil(param.defaultValue)
        XCTAssertNil(param.validation)
        XCTAssertNil(param.iconName)
        XCTAssertNil(param.helpURL)
    }

    func testCustomIDAndTitle() {
        let param = UnifiedWorkflowParameter(
            id: "custom-id",
            name: "param_name",
            title: "Custom Title",
            type: .boolean
        )
        XCTAssertEqual(param.id, "custom-id")
        XCTAssertEqual(param.title, "Custom Title")
    }

    func testValidateStringType() {
        let param = UnifiedWorkflowParameter(name: "s", type: .string)
        XCTAssertNil(param.validate("hello"))
        XCTAssertNotNil(param.validate(42))
    }

    func testValidateIntegerType() {
        let param = UnifiedWorkflowParameter(name: "i", type: .integer)
        XCTAssertNil(param.validate(42))
        XCTAssertNotNil(param.validate("not an int"))
    }

    func testValidateBooleanType() {
        let param = UnifiedWorkflowParameter(name: "b", type: .boolean)
        XCTAssertNil(param.validate(true))
        XCTAssertNotNil(param.validate("yes"))
    }

    func testValidateEnumeration() {
        let param = UnifiedWorkflowParameter(name: "e", type: .enumeration(["a", "b", "c"]))
        XCTAssertNil(param.validate("a"))
        let errors = param.validate("x")
        XCTAssertNotNil(errors)
        XCTAssertTrue(errors!.contains(where: {
            if case .invalidEnumValue = $0 { return true }
            return false
        }))
    }
}

// MARK: - UnifiedParameterType Tests

final class UnifiedParameterTypeRegressionTests: XCTestCase {

    func testDisplayNames() {
        XCTAssertEqual(UnifiedParameterType.string.displayName, "Text")
        XCTAssertEqual(UnifiedParameterType.integer.displayName, "Integer")
        XCTAssertEqual(UnifiedParameterType.number.displayName, "Number")
        XCTAssertEqual(UnifiedParameterType.boolean.displayName, "Boolean")
        XCTAssertEqual(UnifiedParameterType.file.displayName, "File")
        XCTAssertEqual(UnifiedParameterType.directory.displayName, "Directory")
        XCTAssertEqual(UnifiedParameterType.enumeration(["a"]).displayName, "Selection")
        XCTAssertEqual(UnifiedParameterType.array(.string).displayName, "Array")
    }

    func testJSONSchemaTypes() {
        XCTAssertEqual(UnifiedParameterType.string.jsonSchemaType, "string")
        XCTAssertEqual(UnifiedParameterType.integer.jsonSchemaType, "integer")
        XCTAssertEqual(UnifiedParameterType.number.jsonSchemaType, "number")
        XCTAssertEqual(UnifiedParameterType.boolean.jsonSchemaType, "boolean")
        XCTAssertEqual(UnifiedParameterType.file.jsonSchemaType, "string")
        XCTAssertEqual(UnifiedParameterType.array(.integer).jsonSchemaType, "array")
    }

    func testCodableRoundTrip() throws {
        let types: [UnifiedParameterType] = [
            .string, .integer, .number, .boolean, .file, .directory,
            .enumeration(["x", "y"]),
            .array(.string),
        ]
        for type in types {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(UnifiedParameterType.self, from: data)
            XCTAssertEqual(decoded, type, "Round-trip failed for \(type.displayName)")
        }
    }
}

// MARK: - UnifiedParameterValue Tests

final class UnifiedParameterValueRegressionTests: XCTestCase {

    func testStringValue() {
        let v = UnifiedParameterValue.string("hello")
        XCTAssertEqual(v.stringValue, "hello")
        XCTAssertNil(v.integerValue)
        XCTAssertFalse(v.isNull)
    }

    func testIntegerValue() {
        let v = UnifiedParameterValue.integer(42)
        XCTAssertEqual(v.integerValue, 42)
        XCTAssertNil(v.stringValue)
    }

    func testNumberValue() {
        let v = UnifiedParameterValue.number(3.14)
        XCTAssertEqual(v.numberValue, 3.14)
    }

    func testBooleanValue() {
        let v = UnifiedParameterValue.boolean(true)
        XCTAssertEqual(v.booleanValue, true)
    }

    func testArrayValue() {
        let v = UnifiedParameterValue.array([.integer(1), .integer(2)])
        XCTAssertEqual(v.arrayValue?.count, 2)
    }

    func testNullValue() {
        let v = UnifiedParameterValue.null
        XCTAssertTrue(v.isNull)
        XCTAssertNil(v.stringValue)
    }

    func testCodableRoundTrip() throws {
        let values: [UnifiedParameterValue] = [
            .string("test"),
            .integer(99),
            .number(2.718),
            .boolean(false),
            .array([.string("a"), .integer(1)]),
            .null,
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(UnifiedParameterValue.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func testAnyValueConversion() {
        XCTAssertEqual(UnifiedParameterValue.string("x").anyValue as? String, "x")
        XCTAssertEqual(UnifiedParameterValue.integer(5).anyValue as? Int, 5)
        XCTAssertEqual(UnifiedParameterValue.boolean(true).anyValue as? Bool, true)
    }
}

// MARK: - UnifiedParameterValidation Tests

final class UnifiedParameterValidationRegressionTests: XCTestCase {

    func testDefaultConstruction() {
        let v = UnifiedParameterValidation()
        XCTAssertNil(v.pattern)
        XCTAssertNil(v.minimum)
        XCTAssertNil(v.maximum)
        XCTAssertNil(v.minLength)
        XCTAssertNil(v.maxLength)
        XCTAssertFalse(v.mustExist)
        XCTAssertNil(v.mimeTypes)
        XCTAssertNil(v.fileExtensions)
    }

    func testCodableRoundTrip() throws {
        let v = UnifiedParameterValidation(
            pattern: "^[A-Z]+$",
            minimum: 0.0,
            maximum: 100.0,
            minLength: 1,
            maxLength: 255,
            mustExist: true,
            mimeTypes: ["text/plain"],
            fileExtensions: ["txt", "csv"]
        )
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(UnifiedParameterValidation.self, from: data)
        XCTAssertEqual(decoded, v)
    }
}

// MARK: - SchemaValidationError Tests

final class SchemaValidationErrorRegressionTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(SchemaValidationError.missingRequired(parameterName: "x").errorDescription)
        XCTAssertNotNil(SchemaValidationError.unknownParameter(name: "y").errorDescription)
        XCTAssertNotNil(SchemaValidationError.typeMismatch(parameterName: "z", expected: "string").errorDescription)
        XCTAssertNotNil(SchemaValidationError.invalidEnumValue(parameterName: "e", value: "bad", options: ["a"]).errorDescription)
        XCTAssertNotNil(SchemaValidationError.valueTooSmall(parameterName: "n", minimum: 0).errorDescription)
        XCTAssertNotNil(SchemaValidationError.valueTooLarge(parameterName: "n", maximum: 100).errorDescription)
    }

    func testEquatable() {
        let a = SchemaValidationError.missingRequired(parameterName: "input")
        let b = SchemaValidationError.missingRequired(parameterName: "input")
        let c = SchemaValidationError.missingRequired(parameterName: "output")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - ToolVersionsManifest Tests

final class ToolVersionsManifestRegressionTests: XCTestCase {

    func testDecodableFromJSON() throws {
        let json = """
        {
            "formatVersion": "1.0",
            "lastUpdated": "2025-01-15",
            "buildArchitecture": "arm64",
            "tools": [
                {
                    "name": "micromamba",
                    "displayName": "micromamba",
                    "version": "2.0.5-0",
                    "license": "BSD-3-Clause",
                    "licenseId": "BSD-3-Clause",
                    "sourceUrl": "https://github.com/mamba-org/mamba",
                    "releaseUrl": "https://github.com/mamba-org/micromamba-releases/releases",
                    "licenseUrl": "https://github.com/mamba-org/mamba/blob/main/LICENSE",
                    "copyright": "Copyright (c) QuantStack and mamba contributors",
                    "executables": ["micromamba"],
                    "dependencies": [],
                    "provisioningMethod": "downloadBinary",
                    "notes": null
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ToolVersionsManifest.self, from: data)
        XCTAssertEqual(manifest.formatVersion, "1.0")
        XCTAssertEqual(manifest.buildArchitecture, "arm64")
        XCTAssertEqual(manifest.tools.count, 1)

        let tool = manifest.tools[0]
        XCTAssertEqual(tool.name, "micromamba")
        XCTAssertEqual(tool.displayName, "micromamba")
        XCTAssertEqual(tool.version, "2.0.5-0")
        XCTAssertEqual(tool.id, "micromamba")
        XCTAssertEqual(tool.executables, ["micromamba"])
        XCTAssertTrue(tool.dependencies.isEmpty)
        XCTAssertNil(tool.notes)
    }
}

// MARK: - ToolManifest Tests

final class ToolManifestRegressionTests: XCTestCase {

    func testConstruction() {
        let manifest = ToolManifest(
            formatVersion: "1.0",
            tools: []
        )
        XCTAssertEqual(manifest.formatVersion, "1.0")
        XCTAssertTrue(manifest.tools.isEmpty)
    }

    func testSaveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = ToolManifest(
            formatVersion: "1.0",
            tools: [.micromamba()]
        )

        let fileURL = tempDir.appendingPathComponent("manifest.json")
        try original.save(to: fileURL)
        let loaded = try ToolManifest.load(from: fileURL)

        XCTAssertEqual(loaded.formatVersion, original.formatVersion)
        XCTAssertEqual(loaded.tools.count, original.tools.count)
        XCTAssertEqual(loaded.tools[0].name, "micromamba")
    }

    func testDefaultBundledManifestUsesPackagedResource() throws {
        let packagedManifest = try XCTUnwrap(ToolVersionsManifest.loadFromBundle())
        let resourceManifest = ToolManifest(
            formatVersion: packagedManifest.formatVersion,
            lastUpdated: Date(timeIntervalSince1970: 0),
            tools: packagedManifest.tools.compactMap { BundledToolSpec(packagedEntry: $0) }
        )
        let defaultManifest = ToolManifest.defaultBundledManifest

        XCTAssertEqual(defaultManifest.formatVersion, resourceManifest.formatVersion)
        XCTAssertEqual(defaultManifest.tools.map(\.name), resourceManifest.tools.map(\.name))
        XCTAssertEqual(defaultManifest.tools.map(\.version), resourceManifest.tools.map(\.version))
        XCTAssertEqual(defaultManifest.tools.map(\.displayName), resourceManifest.tools.map(\.displayName))
    }
}

// MARK: - BundledToolSpec Tests

final class BundledToolSpecRegressionTests: XCTestCase {

    func testHtslibFactory() {
        let spec = BundledToolSpec.htslib()
        XCTAssertEqual(spec.name, "htslib")
        XCTAssertEqual(spec.displayName, "HTSlib")
        XCTAssertEqual(spec.version, "1.21")
        XCTAssertEqual(spec.executables, ["bgzip", "tabix"])
        XCTAssertTrue(spec.dependencies.isEmpty)
        XCTAssertEqual(spec.id, "htslib")
    }

    func testMicromambaFactory() {
        let spec = BundledToolSpec.micromamba()
        XCTAssertEqual(spec.name, "micromamba")
        XCTAssertEqual(spec.displayName, "micromamba")
        XCTAssertEqual(spec.version, "2.0.5-0")
        XCTAssertEqual(spec.executables, ["micromamba"])
        XCTAssertTrue(spec.dependencies.isEmpty)
        XCTAssertEqual(spec.license.spdxId, "BSD-3-Clause")
        XCTAssertEqual(spec.id, "micromamba")
    }

    func testSamtoolsFactory() {
        let spec = BundledToolSpec.samtools()
        XCTAssertEqual(spec.name, "samtools")
        XCTAssertEqual(spec.executables, ["samtools"])
        XCTAssertEqual(spec.dependencies, ["htslib"])
    }

    func testBcftoolsFactory() {
        let spec = BundledToolSpec.bcftools()
        XCTAssertEqual(spec.name, "bcftools")
        XCTAssertEqual(spec.executables, ["bcftools"])
        XCTAssertEqual(spec.dependencies, ["htslib"])
    }

    func testUCSCToolsFactory() {
        let spec = BundledToolSpec.ucscTools()
        XCTAssertEqual(spec.name, "ucsc-tools")
        XCTAssertEqual(spec.executables, ["bedToBigBed", "bedGraphToBigWig"])
        XCTAssertEqual(spec.supportedArchitectures, [.x86_64])
        XCTAssertNotNil(spec.notes)
    }

    func testDefaultTools() {
        let defaults = BundledToolSpec.defaultTools
        XCTAssertEqual(defaults.map(\.name), ToolManifest.defaultBundledManifest.tools.map(\.name))
        XCTAssertEqual(defaults.map(\.version), ToolManifest.defaultBundledManifest.tools.map(\.version))
    }
}

// MARK: - ToolProvisioningOrchestrator Tests

final class ToolProvisioningOrchestratorRegressionTests: XCTestCase {

    func testCreateVersionInfoWritesMicromambaOnlySummary() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let orchestrator = ToolProvisioningOrchestrator(outputDirectory: tempDir)
        let result = ToolProvisioningOrchestrator.Result(
            successful: ["micromamba": [tempDir.appendingPathComponent("micromamba")]],
            failed: [:],
            skipped: [],
            duration: 1.2
        )

        try await orchestrator.createVersionInfo(for: result)

        let versions = try String(
            contentsOf: tempDir.appendingPathComponent("VERSIONS.txt"),
            encoding: .utf8
        )

        XCTAssertTrue(versions.contains("Lungfish Bundled Bootstrap Tools"))
        XCTAssertTrue(versions.contains("- micromamba: 2.0.5-0 (BSD-3-Clause license)"))
        XCTAssertTrue(versions.contains("managed separately."))
        XCTAssertFalse(versions.contains("already installed"))
        XCTAssertFalse(versions.contains("failed"))
        XCTAssertFalse(versions.contains("Build duration"))
        XCTAssertFalse(versions.contains("micromamba (arm64):"))
        XCTAssertFalse(versions.contains("micromamba (x86_64):"))
    }

    func testCreateVersionInfoUsesProvisionedArchitecture() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let orchestrator = ToolProvisioningOrchestrator(outputDirectory: tempDir)
        let result = try await orchestrator.provisionAll(
            manifest: ToolManifest(tools: []),
            architecture: .x86_64,
            forceRebuild: false
        ) { _ in }

        try await orchestrator.createVersionInfo(for: result)

        let versions = try String(
            contentsOf: tempDir.appendingPathComponent("VERSIONS.txt"),
            encoding: .utf8
        )

        XCTAssertTrue(versions.contains("Build architecture: x86_64"))
        XCTAssertFalse(versions.contains("- micromamba:"))
    }

    func testPreferredSourceURLUsesProvisionedArchitectureForBinaryDownloads() async throws {
        let orchestrator = ToolProvisioningOrchestrator()
        _ = try await orchestrator.provisionAll(
            manifest: ToolManifest(tools: []),
            architecture: .x86_64,
            forceRebuild: false
        ) { _ in }

        let tool = BundledToolSpec(
            name: "test-tool",
            displayName: "Test Tool",
            version: "1.0.0",
            license: LicenseInfo(spdxId: "MIT"),
            provisioningMethod: .downloadBinary(BinaryDownload(
                urls: [
                    .arm64: URL(string: "https://example.com/test-tool-arm64")!,
                    .x86_64: URL(string: "https://example.com/test-tool-x86_64")!
                ],
                isArchive: false
            )),
            executables: ["test-tool"]
        )

        let url = await orchestrator.preferredSourceURL(forVersionInfo: tool)
        XCTAssertEqual(url?.absoluteString, "https://example.com/test-tool-x86_64")
    }

    func testCreateVersionInfoUsesExplicitBuildTimestampWhenProvided() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let priorTimestamp = ProcessInfo.processInfo.environment["LUNGFISH_BUILD_TIMESTAMP"]
        setenv("LUNGFISH_BUILD_TIMESTAMP", "2024-01-02T03:04:05Z", 1)
        defer {
            if let priorTimestamp {
                setenv("LUNGFISH_BUILD_TIMESTAMP", priorTimestamp, 1)
            } else {
                unsetenv("LUNGFISH_BUILD_TIMESTAMP")
            }
        }

        let orchestrator = ToolProvisioningOrchestrator(outputDirectory: tempDir)
        let result = ToolProvisioningOrchestrator.Result(
            successful: ["micromamba": [tempDir.appendingPathComponent("micromamba")]],
            failed: [:],
            skipped: [],
            duration: 0.1
        )

        try await orchestrator.createVersionInfo(for: result)

        let versions = try String(
            contentsOf: tempDir.appendingPathComponent("VERSIONS.txt"),
            encoding: .utf8
        )

        XCTAssertTrue(versions.contains("Build date: 2024-01-02 03:04:05 UTC"))
    }
}

final class NativeBundleBuilderRegressionTests: XCTestCase {

    func testMissingToolsDescriptionReferencesManagedBootstrapModel() {
        let info = NativeBundleBuilder.MissingToolsInfo(missingTools: [.samtools, .bgzip])

        XCTAssertFalse(info.description.contains("Missing bundled tools"))
        XCTAssertTrue(info.description.contains("managed tools are unavailable"))
        XCTAssertTrue(info.description.contains("micromamba bootstrap"))
    }
}

// MARK: - Architecture Tests

final class ArchitectureRegressionTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(Architecture.allCases.count, 2)
        XCTAssertTrue(Architecture.allCases.contains(.arm64))
        XCTAssertTrue(Architecture.allCases.contains(.x86_64))
    }

    func testRawValues() {
        XCTAssertEqual(Architecture.arm64.rawValue, "arm64")
        XCTAssertEqual(Architecture.x86_64.rawValue, "x86_64")
    }

    func testClangFlag() {
        XCTAssertEqual(Architecture.arm64.clangFlag, "-arch arm64")
        XCTAssertEqual(Architecture.x86_64.clangFlag, "-arch x86_64")
    }

    func testCurrentArchitecture() {
        let current = Architecture.current
        #if arch(arm64)
        XCTAssertEqual(current, .arm64)
        #else
        XCTAssertEqual(current, .x86_64)
        #endif
    }
}

// MARK: - ArchiveFormat Tests

final class ArchiveFormatRegressionTests: XCTestCase {

    func testTarFlags() {
        XCTAssertEqual(ArchiveFormat.tarGz.tarFlag, "-z")
        XCTAssertEqual(ArchiveFormat.tarBz2.tarFlag, "-j")
        XCTAssertEqual(ArchiveFormat.tarXz.tarFlag, "-J")
        XCTAssertNil(ArchiveFormat.zip.tarFlag)
    }
}

// MARK: - LicenseInfo Tests

final class LicenseInfoRegressionTests: XCTestCase {

    func testMITPreset() {
        let mit = LicenseInfo.mit
        XCTAssertEqual(mit.spdxId, "MIT")
        XCTAssertNotNil(mit.summary)
    }

    func testMITExpatPreset() {
        let mitExpat = LicenseInfo.mitExpat
        XCTAssertEqual(mitExpat.spdxId, "MIT")
        XCTAssertNotNil(mitExpat.url)
    }

    func testCodableRoundTrip() throws {
        let info = LicenseInfo(
            spdxId: "Apache-2.0",
            url: URL(string: "https://example.com/LICENSE"),
            summary: "Apache license"
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(LicenseInfo.self, from: data)
        XCTAssertEqual(decoded.spdxId, info.spdxId)
        XCTAssertEqual(decoded.url, info.url)
        XCTAssertEqual(decoded.summary, info.summary)
    }
}

// MARK: - ClassificationConfig Tests

final class ClassificationConfigRegressionTests: XCTestCase {

    private let tempDir = URL(fileURLWithPath: "/tmp/test-classification")
    private let dbPath = URL(fileURLWithPath: "/tmp/test-db")
    private let inputFile = URL(fileURLWithPath: "/tmp/test.fastq")

    func testConstruction() {
        let config = ClassificationConfig(
            goal: .classify,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Standard-8",
            databaseVersion: "20240904",
            databasePath: dbPath,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: tempDir
        )
        XCTAssertEqual(config.goal, .classify)
        XCTAssertEqual(config.inputFiles.count, 1)
        XCTAssertFalse(config.isPairedEnd)
        XCTAssertEqual(config.databaseName, "Standard-8")
        XCTAssertEqual(config.databaseVersion, "20240904")
        XCTAssertEqual(config.confidence, 0.2)
        XCTAssertEqual(config.minimumHitGroups, 2)
        XCTAssertEqual(config.threads, 4)
        XCTAssertFalse(config.memoryMapping)
        XCTAssertFalse(config.quickMode)
    }

    func testGoalAllCases() {
        let goals = ClassificationConfig.Goal.allCases
        XCTAssertEqual(goals.count, 3)
        XCTAssertTrue(goals.contains(.classify))
        XCTAssertTrue(goals.contains(.profile))
        XCTAssertTrue(goals.contains(.extract))
    }

    func testPresetAllCases() {
        let presets = ClassificationConfig.Preset.allCases
        XCTAssertEqual(presets.count, 3)
        XCTAssertTrue(presets.contains(.sensitive))
        XCTAssertTrue(presets.contains(.balanced))
        XCTAssertTrue(presets.contains(.precise))
    }

    func testPresetParameters() {
        let sensitive = ClassificationConfig.Preset.sensitive.parameters
        XCTAssertEqual(sensitive.confidence, 0.0)
        XCTAssertEqual(sensitive.minimumHitGroups, 1)

        let balanced = ClassificationConfig.Preset.balanced.parameters
        XCTAssertEqual(balanced.confidence, 0.2)
        XCTAssertEqual(balanced.minimumHitGroups, 2)

        let precise = ClassificationConfig.Preset.precise.parameters
        XCTAssertEqual(precise.confidence, 0.5)
        XCTAssertEqual(precise.minimumHitGroups, 3)
    }

    func testFromPreset() {
        let config = ClassificationConfig.fromPreset(
            .precise,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: dbPath,
            outputDirectory: tempDir
        )
        XCTAssertEqual(config.confidence, 0.5)
        XCTAssertEqual(config.minimumHitGroups, 3)
    }

    func testOutputURLs() {
        let config = ClassificationConfig(
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "db",
            databasePath: dbPath,
            outputDirectory: tempDir
        )
        XCTAssertTrue(config.reportURL.path.hasSuffix("classification.kreport"))
        XCTAssertTrue(config.outputURL.path.hasSuffix("classification.kraken"))
        XCTAssertTrue(config.brackenURL.path.hasSuffix("classification.bracken"))
    }

    func testKraken2Arguments() {
        let config = ClassificationConfig(
            goal: .classify,
            inputFiles: [URL(fileURLWithPath: "/data/reads.fastq")],
            isPairedEnd: false,
            databaseName: "std",
            databasePath: URL(fileURLWithPath: "/db/kraken2"),
            confidence: 0.3,
            minimumHitGroups: 3,
            threads: 8,
            memoryMapping: true,
            quickMode: true,
            outputDirectory: URL(fileURLWithPath: "/out")
        )
        let args = config.kraken2Arguments()
        XCTAssertTrue(args.contains("--db"))
        XCTAssertTrue(args.contains("--threads"))
        XCTAssertTrue(args.contains("8"))
        XCTAssertTrue(args.contains("--confidence"))
        XCTAssertTrue(args.contains("0.3"))
        XCTAssertTrue(args.contains("--minimum-hit-groups"))
        XCTAssertTrue(args.contains("3"))
        XCTAssertTrue(args.contains("--memory-mapping"))
        XCTAssertTrue(args.contains("--quick"))
        XCTAssertTrue(args.contains("--report-minimizer-data"))
        XCTAssertFalse(args.contains("--paired"))
        XCTAssertTrue(args.last?.hasSuffix("reads.fastq") == true)
    }

    func testKraken2ArgumentsPairedEnd() {
        let config = ClassificationConfig(
            inputFiles: [
                URL(fileURLWithPath: "/data/R1.fastq"),
                URL(fileURLWithPath: "/data/R2.fastq"),
            ],
            isPairedEnd: true,
            databaseName: "std",
            databasePath: URL(fileURLWithPath: "/db"),
            outputDirectory: URL(fileURLWithPath: "/out")
        )
        let args = config.kraken2Arguments()
        XCTAssertTrue(args.contains("--paired"))
    }

    func testCodableRoundTrip() throws {
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: [URL(fileURLWithPath: "/a.fq"), URL(fileURLWithPath: "/b.fq")],
            isPairedEnd: true,
            databaseName: "PlusPF-8",
            databaseVersion: "20240904",
            databasePath: URL(fileURLWithPath: "/db"),
            confidence: 0.1,
            minimumHitGroups: 1,
            threads: 16,
            memoryMapping: true,
            quickMode: false,
            outputDirectory: URL(fileURLWithPath: "/results")
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ClassificationConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testInputFilesMutable() {
        var config = ClassificationConfig(
            inputFiles: [URL(fileURLWithPath: "/a.fq")],
            isPairedEnd: false,
            databaseName: "db",
            databasePath: dbPath,
            outputDirectory: tempDir
        )
        config.inputFiles = [URL(fileURLWithPath: "/materialized.fq")]
        XCTAssertEqual(config.inputFiles.count, 1)
        XCTAssertTrue(config.inputFiles[0].path.contains("materialized"))
    }
}

// MARK: - ClassificationConfigError Tests

final class ClassificationConfigErrorRegressionTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(ClassificationConfigError.noInputFiles.errorDescription)
        XCTAssertNotNil(ClassificationConfigError.pairedEndRequiresTwoFiles(got: 1).errorDescription)
        XCTAssertNotNil(ClassificationConfigError.inputFileNotFound(URL(fileURLWithPath: "/x")).errorDescription)
        XCTAssertNotNil(ClassificationConfigError.databaseNotFound(URL(fileURLWithPath: "/db")).errorDescription)
        XCTAssertNotNil(ClassificationConfigError.invalidConfidence(1.5).errorDescription)
    }
}

// MARK: - EsVirituConfig Tests

final class EsVirituConfigRegressionTests: XCTestCase {

    private let input = URL(fileURLWithPath: "/data/reads.fastq")
    private let outDir = URL(fileURLWithPath: "/results/esviritu")
    private let dbPath = URL(fileURLWithPath: "/db/esviritu")

    func testConstruction() {
        let config = EsVirituConfig(
            inputFiles: [input],
            isPairedEnd: false,
            sampleName: "sample1",
            outputDirectory: outDir,
            databasePath: dbPath
        )
        XCTAssertEqual(config.inputFiles.count, 1)
        XCTAssertFalse(config.isPairedEnd)
        XCTAssertEqual(config.sampleName, "sample1")
        XCTAssertTrue(config.qualityFilter)
        XCTAssertEqual(config.minReadLength, 100)
    }

    func testComputedOutputURLs() {
        let config = EsVirituConfig(
            inputFiles: [input],
            isPairedEnd: false,
            sampleName: "MySample",
            outputDirectory: outDir,
            databasePath: dbPath
        )
        XCTAssertTrue(config.detectionOutputURL.lastPathComponent.contains("MySample"))
        XCTAssertTrue(config.assemblyOutputURL.lastPathComponent.contains("MySample"))
        XCTAssertTrue(config.taxProfileURL.lastPathComponent.contains("MySample"))
        XCTAssertTrue(config.coverageURL.lastPathComponent.contains("MySample"))
        XCTAssertTrue(config.logURL.lastPathComponent.contains("MySample"))
        XCTAssertTrue(config.paramsURL.lastPathComponent.contains("MySample"))
    }

    func testEsVirituArguments() {
        let config = EsVirituConfig(
            inputFiles: [input],
            isPairedEnd: false,
            sampleName: "test",
            outputDirectory: outDir,
            databasePath: dbPath,
            qualityFilter: false,
            threads: 8
        )
        let args = config.esVirituArguments()
        XCTAssertTrue(args.contains("-r"))
        XCTAssertTrue(args.contains("-s"))
        XCTAssertTrue(args.contains("test"))
        XCTAssertTrue(args.contains("-o"))
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("unpaired"))
        XCTAssertTrue(args.contains("-t"))
        XCTAssertTrue(args.contains("8"))
        XCTAssertTrue(args.contains("-q"))
        XCTAssertTrue(args.contains("False"))
        XCTAssertTrue(args.contains("--db"))
        XCTAssertTrue(args.contains("--keep"))
        XCTAssertTrue(args.contains("True"))
    }

    func testEsVirituArgumentsPairedEnd() {
        let config = EsVirituConfig(
            inputFiles: [
                URL(fileURLWithPath: "/R1.fq"),
                URL(fileURLWithPath: "/R2.fq"),
            ],
            isPairedEnd: true,
            sampleName: "pe",
            outputDirectory: outDir,
            databasePath: dbPath
        )
        let args = config.esVirituArguments()
        XCTAssertTrue(args.contains("paired"))
    }

    func testCodableRoundTrip() throws {
        let config = EsVirituConfig(
            inputFiles: [input],
            isPairedEnd: false,
            sampleName: "test",
            outputDirectory: outDir,
            databasePath: dbPath,
            qualityFilter: false,
            minReadLength: 50,
            threads: 2
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(EsVirituConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testInputFilesMutable() {
        var config = EsVirituConfig(
            inputFiles: [input],
            isPairedEnd: false,
            sampleName: "s",
            outputDirectory: outDir,
            databasePath: dbPath
        )
        config.inputFiles = [URL(fileURLWithPath: "/new.fq")]
        XCTAssertEqual(config.inputFiles[0].lastPathComponent, "new.fq")
    }
}

// MARK: - EsVirituConfigError Tests

final class EsVirituConfigErrorRegressionTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(EsVirituConfigError.noInputFiles.errorDescription)
        XCTAssertNotNil(EsVirituConfigError.pairedEndRequiresTwoFiles(got: 1).errorDescription)
        XCTAssertNotNil(EsVirituConfigError.emptySampleName.errorDescription)
        XCTAssertNotNil(EsVirituConfigError.invalidMinReadLength(-1).errorDescription)
        XCTAssertNotNil(EsVirituConfigError.databaseNotFound(URL(fileURLWithPath: "/db")).errorDescription)
    }
}

// MARK: - TaxTriageConfig Tests

final class TaxTriageConfigRegressionTests: XCTestCase {

    private func makeSample(id: String = "S1") -> TaxTriageSample {
        TaxTriageSample(
            sampleId: id,
            fastq1: URL(fileURLWithPath: "/data/\(id)_R1.fq"),
            fastq2: URL(fileURLWithPath: "/data/\(id)_R2.fq"),
            platform: .illumina
        )
    }

    func testConstruction() {
        let config = TaxTriageConfig(
            samples: [makeSample()],
            platform: .illumina,
            outputDirectory: URL(fileURLWithPath: "/results")
        )
        XCTAssertEqual(config.samples.count, 1)
        XCTAssertEqual(config.platform, .illumina)
        XCTAssertNil(config.kraken2DatabasePath)
        XCTAssertEqual(config.classifiers, ["kraken2"])
        XCTAssertEqual(config.topHitsCount, 10)
        XCTAssertEqual(config.k2Confidence, 0.2)
        XCTAssertEqual(config.rank, "S")
        XCTAssertTrue(config.skipAssembly)
        XCTAssertFalse(config.skipKrona)
        XCTAssertEqual(config.maxMemory, "16.GB")
        XCTAssertEqual(config.profile, "docker")
        XCTAssertNil(config.containerRuntime)
        XCTAssertEqual(config.revision, TaxTriageConfig.defaultRevision)
        XCTAssertNotEqual(config.revision, "main")
    }

    func testPlatformAllCases() {
        let platforms = TaxTriageConfig.Platform.allCases
        XCTAssertEqual(platforms.count, 3)
        XCTAssertEqual(TaxTriageConfig.Platform.illumina.rawValue, "ILLUMINA")
        XCTAssertEqual(TaxTriageConfig.Platform.oxford.rawValue, "OXFORD")
        XCTAssertEqual(TaxTriageConfig.Platform.pacbio.rawValue, "PACBIO")
    }

    func testPlatformDisplayNames() {
        XCTAssertEqual(TaxTriageConfig.Platform.illumina.displayName, "Illumina")
        XCTAssertEqual(TaxTriageConfig.Platform.oxford.displayName, "Oxford Nanopore")
        XCTAssertEqual(TaxTriageConfig.Platform.pacbio.displayName, "PacBio")
    }

    func testSamplesheetURL() {
        let config = TaxTriageConfig(
            samples: [makeSample()],
            outputDirectory: URL(fileURLWithPath: "/results")
        )
        XCTAssertEqual(config.samplesheetURL.lastPathComponent, "samplesheet.csv")
    }

    func testPipelineRepository() {
        XCTAssertEqual(TaxTriageConfig.pipelineRepository, "jhuapl-bio/taxtriage")
    }

    func testNextflowArguments() {
        let config = TaxTriageConfig(
            samples: [makeSample()],
            outputDirectory: URL(fileURLWithPath: "/results"),
            kraken2DatabasePath: URL(fileURLWithPath: "/db"),
            topHitsCount: 5,
            k2Confidence: 0.3,
            rank: "G",
            skipAssembly: true,
            skipKrona: true
        )
        let args = config.nextflowArguments()
        XCTAssertTrue(args.contains("jhuapl-bio/taxtriage"))
        XCTAssertTrue(args.contains("-r"))
        XCTAssertTrue(args.contains(TaxTriageConfig.defaultRevision))
        XCTAssertTrue(args.contains("-profile"))
        XCTAssertTrue(args.contains("--input"))
        XCTAssertTrue(args.contains("--outdir"))
        XCTAssertTrue(args.contains("--db"))
        XCTAssertTrue(args.contains("--top_hits_count"))
        XCTAssertTrue(args.contains("5"))
        XCTAssertTrue(args.contains("--k2_confidence"))
        XCTAssertTrue(args.contains("--rank"))
        XCTAssertTrue(args.contains("G"))
        XCTAssertTrue(args.contains("--skip_assembly"))
        XCTAssertTrue(args.contains("--skip_krona"))
        XCTAssertTrue(args.contains("--max_memory"))
        XCTAssertTrue(args.contains("--max_cpus"))
    }

    func testNextflowArgumentsNoDB() {
        let config = TaxTriageConfig(
            samples: [makeSample()],
            outputDirectory: URL(fileURLWithPath: "/results"),
            kraken2DatabasePath: nil,
            skipAssembly: false,
            skipKrona: false
        )
        let args = config.nextflowArguments()
        XCTAssertFalse(args.contains("--db"))
        XCTAssertFalse(args.contains("--skip_assembly"))
        XCTAssertFalse(args.contains("--skip_krona"))
    }

    func testCodableRoundTrip() throws {
        let config = TaxTriageConfig(
            samples: [makeSample(id: "A"), makeSample(id: "B")],
            platform: .oxford,
            outputDirectory: URL(fileURLWithPath: "/out"),
            kraken2DatabasePath: URL(fileURLWithPath: "/db"),
            topHitsCount: 20,
            k2Confidence: 0.1,
            rank: "F",
            skipAssembly: false,
            skipKrona: true,
            revision: "v2.0"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TaxTriageConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}

// MARK: - TaxTriageSample Tests

final class TaxTriageSampleRegressionTests: XCTestCase {

    func testConstruction() {
        let sample = TaxTriageSample(
            sampleId: "Patient001",
            fastq1: URL(fileURLWithPath: "/data/R1.fq"),
            fastq2: URL(fileURLWithPath: "/data/R2.fq"),
            platform: .illumina
        )
        XCTAssertEqual(sample.id, "Patient001")
        XCTAssertEqual(sample.sampleId, "Patient001")
        XCTAssertNotNil(sample.fastq2)
        XCTAssertEqual(sample.platform, .illumina)
        XCTAssertFalse(sample.isNegativeControl)
        XCTAssertNil(sample.metadata)
    }

    func testIsPairedEnd() {
        let paired = TaxTriageSample(
            sampleId: "P",
            fastq1: URL(fileURLWithPath: "/R1.fq"),
            fastq2: URL(fileURLWithPath: "/R2.fq")
        )
        XCTAssertTrue(paired.isPairedEnd)

        let single = TaxTriageSample(
            sampleId: "S",
            fastq1: URL(fileURLWithPath: "/reads.fq")
        )
        XCTAssertFalse(single.isPairedEnd)
    }

    func testAllFiles() {
        let paired = TaxTriageSample(
            sampleId: "P",
            fastq1: URL(fileURLWithPath: "/R1.fq"),
            fastq2: URL(fileURLWithPath: "/R2.fq")
        )
        XCTAssertEqual(paired.allFiles.count, 2)

        let single = TaxTriageSample(
            sampleId: "S",
            fastq1: URL(fileURLWithPath: "/reads.fq")
        )
        XCTAssertEqual(single.allFiles.count, 1)
    }

    func testIsAnyNegativeControl() {
        let normal = TaxTriageSample(sampleId: "N", fastq1: URL(fileURLWithPath: "/x.fq"))
        XCTAssertFalse(normal.isAnyNegativeControl)

        let negCtrl = TaxTriageSample(
            sampleId: "NC",
            fastq1: URL(fileURLWithPath: "/x.fq"),
            isNegativeControl: true
        )
        XCTAssertTrue(negCtrl.isAnyNegativeControl)
    }

    func testMutableFastqPaths() {
        var sample = TaxTriageSample(
            sampleId: "S",
            fastq1: URL(fileURLWithPath: "/original.fq")
        )
        sample.fastq1 = URL(fileURLWithPath: "/materialized.fq")
        sample.fastq2 = URL(fileURLWithPath: "/materialized_R2.fq")
        XCTAssertTrue(sample.fastq1.path.contains("materialized"))
        XCTAssertNotNil(sample.fastq2)
    }

    func testCodableRoundTripBackwardCompatible() throws {
        // Encode without isNegativeControl and verify decoding defaults to false
        let json = """
        {
            "sampleId": "S1",
            "fastq1": "file:///data/R1.fq",
            "platform": "ILLUMINA"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TaxTriageSample.self, from: data)
        XCTAssertEqual(decoded.sampleId, "S1")
        XCTAssertFalse(decoded.isNegativeControl)
        XCTAssertNil(decoded.fastq2)
        XCTAssertNil(decoded.metadata, "metadata should not be serialized")
    }
}

// MARK: - TaxTriageConfigError Tests

final class TaxTriageConfigErrorRegressionTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(TaxTriageConfigError.noSamples.errorDescription)
        XCTAssertNotNil(TaxTriageConfigError.emptySampleId.errorDescription)
        XCTAssertNotNil(TaxTriageConfigError.duplicateSampleIds(["A", "B"]).errorDescription)
        XCTAssertNotNil(TaxTriageConfigError.invalidK2Confidence(2.0).errorDescription)
        XCTAssertNotNil(TaxTriageConfigError.invalidTopHitsCount(-1).errorDescription)
    }
}

// MARK: - MetagenomicsTool Tests

final class MetagenomicsToolRegressionTests: XCTestCase {

    func testAllCases() {
        let cases = MetagenomicsTool.allCases
        XCTAssertEqual(cases.count, 7)
        XCTAssertTrue(cases.contains(.kraken2))
        XCTAssertTrue(cases.contains(.bracken))
        XCTAssertTrue(cases.contains(.metaphlan))
        XCTAssertTrue(cases.contains(.krakentools))
        XCTAssertTrue(cases.contains(.esviritu))
        XCTAssertTrue(cases.contains(.taxtriage))
        XCTAssertTrue(cases.contains(.ncbiTaxonomy))
    }

    func testDatabaseSectionTitles() {
        XCTAssertEqual(MetagenomicsTool.kraken2.databaseSectionTitle, "Kraken2 Databases")
        XCTAssertEqual(MetagenomicsTool.esviritu.databaseSectionTitle, "EsViritu Databases")
    }

    func testCodableRoundTrip() throws {
        for tool in MetagenomicsTool.allCases {
            let data = try JSONEncoder().encode(tool)
            let decoded = try JSONDecoder().decode(MetagenomicsTool.self, from: data)
            XCTAssertEqual(decoded, tool)
        }
    }
}

// MARK: - DatabaseCollection Tests

final class DatabaseCollectionRegressionTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(DatabaseCollection.allCases.count, 9)
    }

    func testDisplayNames() {
        XCTAssertEqual(DatabaseCollection.standard.displayName, "Standard")
        XCTAssertEqual(DatabaseCollection.standard8.displayName, "Standard-8")
        XCTAssertEqual(DatabaseCollection.plusPF.displayName, "PlusPF")
        XCTAssertEqual(DatabaseCollection.viral.displayName, "Viral")
    }

    func testSizesArePositive() {
        for collection in DatabaseCollection.allCases {
            XCTAssertGreaterThan(collection.approximateSizeBytes, 0,
                                "\(collection.displayName) should have positive size")
            XCTAssertGreaterThan(collection.approximateRAMBytes, 0,
                                "\(collection.displayName) should have positive RAM requirement")
        }
    }

    func testViralIsSmallest() {
        let viralSize = DatabaseCollection.viral.approximateSizeBytes
        for collection in DatabaseCollection.allCases where collection != .viral {
            XCTAssertLessThan(viralSize, collection.approximateSizeBytes,
                              "Viral should be smaller than \(collection.displayName)")
        }
    }

    func testCodableRoundTrip() throws {
        for collection in DatabaseCollection.allCases {
            let data = try JSONEncoder().encode(collection)
            let decoded = try JSONDecoder().decode(DatabaseCollection.self, from: data)
            XCTAssertEqual(decoded, collection)
        }
    }
}

// MARK: - DatabaseStatus Tests

final class DatabaseStatusRegressionTests: XCTestCase {

    func testAllRawValues() {
        XCTAssertEqual(DatabaseStatus.ready.rawValue, "ready")
        XCTAssertEqual(DatabaseStatus.downloading.rawValue, "downloading")
        XCTAssertEqual(DatabaseStatus.verifying.rawValue, "verifying")
        XCTAssertEqual(DatabaseStatus.corrupt.rawValue, "corrupt")
        XCTAssertEqual(DatabaseStatus.volumeNotMounted.rawValue, "volumeNotMounted")
        XCTAssertEqual(DatabaseStatus.missing.rawValue, "missing")
    }
}

// MARK: - ValidationResult Tests

final class ValidationResultRegressionTests: XCTestCase {

    func testValid() {
        let result = ValidationResult.valid
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testInvalid() {
        let error = ValidationError(message: "Something wrong")
        let result = ValidationResult.invalid(reasons: [error])
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testCombinedBothValid() {
        let combined = ValidationResult.valid.combined(with: .valid)
        XCTAssertTrue(combined.isValid)
    }

    func testCombinedOneInvalid() {
        let error = ValidationError(message: "err")
        let combined = ValidationResult.valid.combined(with: .invalid(reasons: [error]))
        XCTAssertFalse(combined.isValid)
        XCTAssertEqual(combined.errors.count, 1)
    }

    func testCombinedBothInvalid() {
        let e1 = ValidationError(message: "a")
        let e2 = ValidationError(message: "b")
        let combined = ValidationResult.invalid(reasons: [e1])
            .combined(with: .invalid(reasons: [e2]))
        XCTAssertEqual(combined.errors.count, 2)
    }

    func testEquatable() {
        XCTAssertEqual(ValidationResult.valid, ValidationResult.valid)
    }

    func testDescription() {
        XCTAssertEqual(ValidationResult.valid.description, "Valid")
        let invalid = ValidationResult.invalid(reasons: [ValidationError(message: "oops")])
        XCTAssertTrue(invalid.description.contains("oops"))
    }
}

// MARK: - ValidationError Tests

final class ValidationErrorRegressionTests: XCTestCase {

    func testConstruction() {
        let error = ValidationError(message: "missing file", suggestion: "add a file")
        XCTAssertEqual(error.message, "missing file")
        XCTAssertEqual(error.suggestion, "add a file")
        XCTAssertEqual(error.category, .requirement)
    }

    func testCategories() {
        XCTAssertEqual(ErrorCategory.allCases.count, 5)
        XCTAssertTrue(ErrorCategory.allCases.contains(.capability))
        XCTAssertTrue(ErrorCategory.allCases.contains(.count))
        XCTAssertTrue(ErrorCategory.allCases.contains(.format))
        XCTAssertTrue(ErrorCategory.allCases.contains(.requirement))
        XCTAssertTrue(ErrorCategory.allCases.contains(.compatibility))
    }

    func testFactoryMethods() {
        let tooFew = ValidationError.tooFewInputs(expected: 2, actual: 1)
        XCTAssertEqual(tooFew.category, .count)
        XCTAssertTrue(tooFew.message.contains("2"))

        let tooMany = ValidationError.tooManyInputs(expected: 1, actual: 3)
        XCTAssertEqual(tooMany.category, .count)

        let missing = ValidationError.missingCapabilities("alignment", inputIndex: 0)
        XCTAssertEqual(missing.category, .capability)
        XCTAssertTrue(missing.message.contains("input 0"))

        let format = ValidationError.formatMismatch(preferred: "BAM", actual: "SAM")
        XCTAssertEqual(format.category, .format)
    }

    func testDescription() {
        let withSuggestion = ValidationError(message: "err", suggestion: "fix it")
        XCTAssertTrue(withSuggestion.description.contains("fix it"))

        let withoutSuggestion = ValidationError(message: "err")
        XCTAssertEqual(withoutSuggestion.description, "err")
    }
}

// MARK: - ContainerImageError Tests

final class ContainerImageErrorRegressionTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(ContainerImageError.imageNotFound("samtools").errorDescription)
        XCTAssertNotNil(ContainerImageError.imageAlreadyRegistered("samtools").errorDescription)
        XCTAssertNotNil(ContainerImageError.pullFailed("ubuntu", "timeout").errorDescription)
        XCTAssertNotNil(ContainerImageError.invalidReference(":::").errorDescription)
    }
}

// MARK: - ImageAvailability Tests

final class ImageAvailabilityRegressionTests: XCTestCase {

    func testUnavailableStatic() {
        let unavailable = ImageAvailability.unavailable
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertNil(unavailable.localSizeBytes)
        XCTAssertNil(unavailable.pulledAt)
        XCTAssertNil(unavailable.digest)
    }

    func testAvailable() {
        let available = ImageAvailability(
            isAvailable: true,
            localSizeBytes: 500_000_000,
            pulledAt: Date(),
            digest: "sha256:abc"
        )
        XCTAssertTrue(available.isAvailable)
        XCTAssertEqual(available.localSizeBytes, 500_000_000)
        XCTAssertNotNil(available.pulledAt)
        XCTAssertEqual(available.digest, "sha256:abc")
    }
}
