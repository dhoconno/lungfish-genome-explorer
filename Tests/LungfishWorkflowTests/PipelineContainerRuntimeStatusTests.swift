// PipelineContainerRuntimeStatusTests.swift - Wizard readiness follows the Docker daemon only
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// A probe whose answers are fixed by the test.
private struct StubProbe: ContainerRuntimeProbing {
    var dockerPath: String?
    var daemon: DockerDaemonProbe
    var apple: AppleContainerProbe
    let recorder = Recorder()

    func dockerCLIPath() -> String? { dockerPath }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        recorder.record(timeout)
        return daemon
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        recorder.appleConsulted()
        return apple
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []
    private var appleCalls = 0

    func record(_ timeout: TimeInterval) {
        lock.lock(); timeouts.append(timeout); lock.unlock()
    }

    func appleConsulted() {
        lock.lock(); appleCalls += 1; lock.unlock()
    }

    var recordedTimeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }; return timeouts
    }

    var appleCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return appleCalls
    }
}

final class PipelineContainerRuntimeStatusTests: XCTestCase {
    private static let appleReady = AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)

    func testDaemonReachableIsAvailableAndNamesDockerDesktop() async {
        let probe = StubProbe(
            dockerPath: "/usr/local/bin/docker",
            daemon: DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil),
            apple: Self.appleReady
        )
        let status = await PipelineContainerRuntimeStatus.check(probe: probe, timeout: 2.5)
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.label, "Docker Desktop: Running")
        XCTAssertNil(status.detail)
        XCTAssertEqual(status.dockerCLIPath, "/usr/local/bin/docker")
        XCTAssertEqual(probe.recorder.recordedTimeouts, [2.5])
    }

    func testDaemonDownIsUnavailableEvenWhenAppleContainerizationIsReady() async {
        let probe = StubProbe(
            dockerPath: "/usr/local/bin/docker",
            daemon: DockerDaemonProbe(
                reachable: false,
                clientVersion: "28.3.2",
                serverVersion: nil,
                detail: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
            ),
            apple: Self.appleReady
        )
        let status = await PipelineContainerRuntimeStatus.check(probe: probe)
        XCTAssertFalse(status.available, "Apple Containerization being ready must not make a -profile docker pipeline runnable")
        XCTAssertEqual(status.label, "Docker Desktop: Not running")
        XCTAssertEqual(status.unavailableMessage, "Docker Desktop is not running")
        XCTAssertTrue(status.detail?.contains("Is the docker daemon running") == true)
        XCTAssertEqual(probe.recorder.appleCallCount, 0, "the Apple runtime is not consulted for pipeline readiness")
    }

    func testMissingDockerCLISkipsDaemonProbe() async {
        let probe = StubProbe(
            dockerPath: nil,
            daemon: DockerDaemonProbe(reachable: true, clientVersion: "x", serverVersion: "x", detail: nil),
            apple: Self.appleReady
        )
        let status = await PipelineContainerRuntimeStatus.check(probe: probe)
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.label, "Docker Desktop: Not installed")
        XCTAssertEqual(status.unavailableMessage, "Docker Desktop is not installed")
        XCTAssertNil(status.dockerCLIPath)
        XCTAssertTrue(status.detail?.contains("not found") == true)
        XCTAssertTrue(probe.recorder.recordedTimeouts.isEmpty, "no CLI means nothing to run")
    }

    func testDefaultTimeoutMatchesDebugContainerCommand() async {
        let probe = StubProbe(
            dockerPath: "/usr/local/bin/docker",
            daemon: DockerDaemonProbe(reachable: true, clientVersion: "1", serverVersion: "1", detail: nil),
            apple: Self.appleReady
        )
        _ = await PipelineContainerRuntimeStatus.check(probe: probe)
        XCTAssertEqual(probe.recorder.recordedTimeouts, [PipelineContainerRuntimeStatus.defaultProbeTimeout])
        XCTAssertEqual(PipelineContainerRuntimeStatus.defaultProbeTimeout, 5)
    }
}
