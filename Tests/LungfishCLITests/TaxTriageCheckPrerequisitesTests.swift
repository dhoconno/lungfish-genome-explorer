// TaxTriageCheckPrerequisitesTests.swift - `taxtriage check-prerequisites` follows the Docker daemon only
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// A probe whose answers are fixed by the test.
private struct StubProbe: ContainerRuntimeProbing {
    var dockerPath: String?
    var daemon: DockerDaemonProbe
    var apple: AppleContainerProbe

    func dockerCLIPath() -> String? { dockerPath }
    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe { daemon }
    func appleContainerRuntime() async -> AppleContainerProbe { apple }
}

final class TaxTriageCheckPrerequisitesTests: XCTestCase {
    private typealias Subcommand = TaxTriageCommand.CheckPrerequisitesSubcommand

    /// The runtime line is red when the Docker daemon is down even though
    /// the Apple Containerization runtime is ready, because the pipeline
    /// launches with `-profile docker`. The wizard row reads the same probe.
    func testRuntimeLineFollowsDockerDaemonNotAppleRuntime() async {
        let formatter = TerminalFormatter(useColors: false)
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-cli-prereq-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let daemonDownAppleReady = StubProbe(
            dockerPath: "/usr/local/bin/docker",
            daemon: DockerDaemonProbe(reachable: false, clientVersion: "28.3.2", serverVersion: nil, detail: "daemon down"),
            apple: AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)
        )
        let down = await TaxTriagePipeline(
            homeDirectoryProvider: { tempHome },
            appIdentity: .preview,
            containerRuntimeProbe: daemonDownAppleReady
        ).checkPrerequisites()
        let downLines = Subcommand.containerRuntimeLines(status: down, formatter: formatter)
        XCTAssertEqual(downLines.count, 2)
        XCTAssertTrue(downLines[0].contains("Container runtime: not available (Docker Desktop is not running)"), downLines[0])
        XCTAssertTrue(downLines[1].contains("`lungfish-cli debug container`"), downLines[1])
        XCTAssertFalse(downLines.joined().contains("Apple"))

        let noDocker = StubProbe(
            dockerPath: nil,
            daemon: DockerDaemonProbe(reachable: false, clientVersion: nil, serverVersion: nil, detail: nil),
            apple: AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)
        )
        let missing = await TaxTriagePipeline(
            homeDirectoryProvider: { tempHome },
            appIdentity: .preview,
            containerRuntimeProbe: noDocker
        ).checkPrerequisites()
        let missingLines = Subcommand.containerRuntimeLines(status: missing, formatter: formatter)
        XCTAssertTrue(missingLines[0].contains("Container runtime: not available (Docker Desktop is not installed)"), missingLines[0])

        let running = StubProbe(
            dockerPath: "/usr/local/bin/docker",
            daemon: DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil),
            apple: AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
        )
        let ready = await TaxTriagePipeline(
            homeDirectoryProvider: { tempHome },
            appIdentity: .preview,
            containerRuntimeProbe: running
        ).checkPrerequisites()
        let readyLines = Subcommand.containerRuntimeLines(status: ready, formatter: formatter)
        XCTAssertEqual(readyLines.count, 1)
        XCTAssertTrue(readyLines[0].contains("Container runtime: Docker Desktop (running)"), readyLines[0])
    }

    /// The subcommand's injection point is what `run()` hands the pipeline. It is a task-local
    /// value, so a test binds a probe for one scope and nothing outside the scope sees it, and the
    /// default is the system probe that runs `docker version`.
    func testSubcommandProbeIsATaskLocalBoundForOneScope() {
        let stub = StubProbe(
            dockerPath: nil,
            daemon: DockerDaemonProbe(reachable: false, clientVersion: nil, serverVersion: nil, detail: nil),
            apple: AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
        )
        XCTAssertTrue(Subcommand.containerRuntimeProbe is SystemContainerRuntimeProbe, "the default is the system probe")
        Subcommand.$containerRuntimeProbe.withValue(stub) {
            XCTAssertNil(Subcommand.containerRuntimeProbe.dockerCLIPath())
            XCTAssertTrue(Subcommand.containerRuntimeProbe is StubProbe)
        }
        XCTAssertTrue(Subcommand.containerRuntimeProbe is SystemContainerRuntimeProbe, "the binding ends with its scope")
    }

    /// A bound probe reaches the code `run()` awaits, since the task-local value travels with the
    /// task into everything it awaits and into the tasks it starts.
    func testTheBoundProbeReachesAwaitedAndStartedTasks() async {
        let stub = StubProbe(
            dockerPath: "/usr/local/bin/docker",
            daemon: DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil),
            apple: AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
        )
        let seen = await Subcommand.$containerRuntimeProbe.withValue(stub) {
            let awaited = Subcommand.containerRuntimeProbe.dockerCLIPath()
            let started = await Task { Subcommand.containerRuntimeProbe.dockerCLIPath() }.value
            return [awaited, started]
        }
        XCTAssertEqual(seen, ["/usr/local/bin/docker", "/usr/local/bin/docker"])
    }
}
