// DebugContainerCommandTests.swift - `debug container` reports the runtime the pipelines use
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishWorkflow

/// A probe whose answers are fixed by the test.
private struct StubContainerRuntimeProbe: ContainerRuntimeProbing {
    var dockerPath: String?
    var daemon: DockerDaemonProbe
    var apple: AppleContainerProbe
    let recordedTimeouts = TimeoutRecorder()

    func dockerCLIPath() -> String? { dockerPath }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        recordedTimeouts.append(timeout)
        return daemon
    }

    func appleContainerRuntime() async -> AppleContainerProbe { apple }
}

private final class TimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var all: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

final class DebugContainerCommandTests: XCTestCase {
    private static let reachable = StubContainerRuntimeProbe(
        dockerPath: "/usr/local/bin/docker",
        daemon: DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil),
        apple: AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)
    )

    private static let daemonDown = StubContainerRuntimeProbe(
        dockerPath: "/usr/local/bin/docker",
        daemon: DockerDaemonProbe(
            reachable: false,
            clientVersion: "28.3.2",
            serverVersion: nil,
            detail: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
        ),
        apple: AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)
    )

    private static let noDocker = StubContainerRuntimeProbe(
        dockerPath: nil,
        daemon: DockerDaemonProbe(reachable: false, clientVersion: nil, serverVersion: nil, detail: nil),
        apple: AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: "requires macOS 26 or later on Apple Silicon")
    )

    private var originalProbe: (any ContainerRuntimeProbing)!

    override func setUp() {
        super.setUp()
        originalProbe = ContainerSubcommand.probe
    }

    override func tearDown() {
        ContainerSubcommand.probe = originalProbe
        super.tearDown()
    }

    // MARK: Report

    func testReportIsReadyOnlyWhenDockerDaemonAnswers() async {
        let ready = await ContainerRuntimeReport.collect(probe: Self.reachable, timeout: 5)
        XCTAssertTrue(ready.pipelineRuntimeReady)
        XCTAssertNil(ready.exitError)
        XCTAssertEqual(ready.dockerCLIPath, "/usr/local/bin/docker")
        XCTAssertEqual(ready.dockerClientVersion, "28.3.2")
        XCTAssertEqual(ready.dockerServerVersion, "28.3.2")
        XCTAssertTrue(ready.appleContainerizationAvailable)
        XCTAssertEqual(ready.probeTimeoutSeconds, 5)

        let down = await ContainerRuntimeReport.collect(probe: Self.daemonDown, timeout: 5)
        XCTAssertFalse(down.pipelineRuntimeReady)
        guard case .containerUnavailable? = down.exitError else {
            return XCTFail("expected containerUnavailable, got \(String(describing: down.exitError))")
        }
        XCTAssertEqual(down.exitError?.exitCode, .containerError)
        XCTAssertEqual(down.exitError?.exitCode.rawValue, 65)
        XCTAssertEqual(down.dockerClientVersion, "28.3.2")
        XCTAssertNil(down.dockerServerVersion)
        XCTAssertTrue(down.dockerDetail?.contains("Is the docker daemon running") == true)
        // The Apple runtime being ready must not turn the verdict green: no
        // pipeline launches through it.
        XCTAssertTrue(down.appleContainerRuntimeReady)
    }

    func testReportWithoutDockerCLISkipsDaemonProbeAndFails() async {
        let report = await ContainerRuntimeReport.collect(probe: Self.noDocker, timeout: 5)
        XCTAssertNil(report.dockerCLIPath)
        XCTAssertFalse(report.dockerDaemonReachable)
        guard case .containerUnavailable? = report.exitError else {
            return XCTFail("expected containerUnavailable, got \(String(describing: report.exitError))")
        }
        XCTAssertTrue(report.dockerDetail?.contains("not found") == true)
        XCTAssertTrue(Self.noDocker.recordedTimeouts.all.isEmpty, "no CLI means nothing to run")
        XCTAssertFalse(report.appleContainerizationAvailable)
    }

    func testReportPassesTimeoutToProbe() async {
        let probe = StubContainerRuntimeProbe(
            dockerPath: "/usr/local/bin/docker",
            daemon: Self.reachable.daemon,
            apple: Self.reachable.apple
        )
        _ = await ContainerRuntimeReport.collect(probe: probe, timeout: 2.5)
        XCTAssertEqual(probe.recordedTimeouts.all, [2.5])
    }

    func testTextRenderingNamesDockerAsThePipelineRuntimeAndNeverHardcodesReady() async {
        let formatter = TerminalFormatter(useColors: false)

        let ready = await ContainerRuntimeReport.collect(probe: Self.reachable, timeout: 5)
        let readyText = ready.textLines(formatter: formatter).joined(separator: "\n")
        XCTAssertTrue(readyText.contains("Docker Desktop"))
        XCTAssertTrue(readyText.contains("-profile docker"))
        XCTAssertTrue(readyText.contains("Docker daemon reachable"))
        XCTAssertTrue(readyText.contains("28.3.2"))
        XCTAssertTrue(readyText.contains("Apple Containerization (not used by pipelines)"))
        XCTAssertFalse(readyText.contains("VM Type"))
        XCTAssertFalse(readyText.contains("Status"))

        let down = await ContainerRuntimeReport.collect(probe: Self.daemonDown, timeout: 5)
        let downText = down.textLines(formatter: formatter).joined(separator: "\n")
        XCTAssertTrue(downText.contains("Docker daemon unreachable"))
        XCTAssertTrue(downText.contains("Is the docker daemon running"))
        XCTAssertTrue(downText.contains("Start Docker Desktop"))
        XCTAssertFalse(downText.contains("Docker daemon reachable"))

        let none = await ContainerRuntimeReport.collect(probe: Self.noDocker, timeout: 5)
        let noneText = none.textLines(formatter: formatter).joined(separator: "\n")
        XCTAssertTrue(noneText.contains("not installed"))
        XCTAssertTrue(noneText.contains("requires macOS 26 or later on Apple Silicon"))
    }

    func testReportEncodesToJSONWithStableKeys() async throws {
        let report = await ContainerRuntimeReport.collect(probe: Self.daemonDown, timeout: 5)
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["dockerDaemonReachable"] as? Bool, false)
        XCTAssertEqual(object["dockerCLIPath"] as? String, "/usr/local/bin/docker")
        XCTAssertEqual(object["dockerClientVersion"] as? String, "28.3.2")
        XCTAssertEqual(object["appleContainerizationAvailable"] as? Bool, true)
        XCTAssertEqual(object["probeTimeoutSeconds"] as? Double, 5)
        let decoded = try JSONDecoder().decode(ContainerRuntimeReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    // MARK: Command

    func testCommandThrowsContainerUnavailableWhenDaemonIsDown() async throws {
        ContainerSubcommand.probe = Self.daemonDown
        let command = try ContainerSubcommand.parse(["--no-color"])
        do {
            try await command.run()
            XCTFail("expected containerUnavailable")
        } catch let error as CLIError {
            guard case .containerUnavailable = error else {
                return XCTFail("expected containerUnavailable, got \(error)")
            }
            XCTAssertEqual(error.exitCode, .containerError)
        }
    }

    func testCommandSucceedsWhenDaemonIsReachable() async throws {
        ContainerSubcommand.probe = Self.reachable
        let command = try ContainerSubcommand.parse(["--no-color", "--timeout", "3"])
        XCTAssertEqual(command.timeoutSeconds, 3)
        try await command.run()
    }

    func testCommandRejectsNonPositiveTimeout() {
        XCTAssertThrowsError(try ContainerSubcommand.parse(["--timeout", "0"]))
    }

    func testCommandDefaultsToShortTimeout() throws {
        let command = try ContainerSubcommand.parse([])
        XCTAssertEqual(command.timeoutSeconds, 5)
        XCTAssertFalse(command.pullTest)
    }

    func testFullImageReferenceFillsRegistryAndNamespace() {
        XCTAssertEqual(ContainerSubcommand.fullImageReference("alpine"), "docker.io/library/alpine")
        XCTAssertEqual(ContainerSubcommand.fullImageReference("library/alpine"), "docker.io/library/alpine")
        XCTAssertEqual(ContainerSubcommand.fullImageReference("docker.io/library/alpine:3"), "docker.io/library/alpine:3")
    }

    // MARK: Help text

    func testHelpTextDescribesDockerDesktopNotAppleContainerization() {
        let container = ContainerSubcommand.helpMessage()
        XCTAssertTrue(container.contains("Docker"))
        XCTAssertTrue(container.contains("65"))
        XCTAssertTrue(container.contains("--timeout"))

        let workflowRun = RunSubcommand.helpMessage()
        XCTAssertTrue(workflowRun.contains("Docker Desktop"))
        XCTAssertFalse(workflowRun.contains("Apple Containerization"))

        let workflow = WorkflowCommand.helpMessage()
        XCTAssertTrue(workflow.contains("Docker Desktop"))
        XCTAssertFalse(workflow.contains("Apple Containerization"))

        let root = LungfishCLI.helpMessage()
        XCTAssertTrue(root.contains("Docker Desktop"))
        XCTAssertFalse(root.contains("Apple Containerization"))
    }

    func testContainerUnavailableErrorNamesDockerDesktop() {
        let message = CLIError.containerUnavailable.errorDescription ?? ""
        XCTAssertTrue(message.contains("Docker daemon unreachable"))
        XCTAssertTrue(message.contains("Docker Desktop"))
        XCTAssertFalse(message.contains("macOS 26"))
    }
}
