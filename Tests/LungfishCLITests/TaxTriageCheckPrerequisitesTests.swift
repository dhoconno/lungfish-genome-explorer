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
    private var originalProbe: (any ContainerRuntimeProbing)!

    override func setUp() {
        super.setUp()
        originalProbe = Subcommand.containerRuntimeProbe
    }

    override func tearDown() {
        Subcommand.containerRuntimeProbe = originalProbe
        super.tearDown()
    }

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
        XCTAssertTrue(downLines[0].contains("Container runtime: NOT AVAILABLE (Docker Desktop is not running)"), downLines[0])
        XCTAssertTrue(downLines[1].contains("lungfish debug container"))
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
        XCTAssertTrue(missingLines[0].contains("Container runtime: NOT AVAILABLE (Docker Desktop is not installed)"), missingLines[0])

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

    /// The subcommand's injection point is what `run()` hands the pipeline.
    func testSubcommandExposesInjectableProbe() {
        let stub = StubProbe(
            dockerPath: nil,
            daemon: DockerDaemonProbe(reachable: false, clientVersion: nil, serverVersion: nil, detail: nil),
            apple: AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
        )
        Subcommand.containerRuntimeProbe = stub
        XCTAssertNil(Subcommand.containerRuntimeProbe.dockerCLIPath())
    }
}
