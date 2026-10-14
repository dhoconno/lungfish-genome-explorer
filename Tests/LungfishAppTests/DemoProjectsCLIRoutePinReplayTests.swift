// DemoProjectsCLIRoutePinReplayTests.swift - The Demo Projects window's pins, run on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M4, panel decision C9. The replace of an existing project (SWIFT) and the row's progress,
// cancel and opening (UX) were pinned on the in-process install, in DemoProjectsViewModelTests, before the flip
// (C4) took that install out. This class holds the same seven cases on the window's one route, which starts one
// `lungfish-cli demo fetch` child through `CLISubprocessTransport`, and the window behaves as it did.
//
// The archive comes from the loopback stand-in (`DemoArchiveStandIn`) to the child, and the child names the
// project's list, the stand-in origin and the Trash folder through the process environment, so no test reaches
// GitHub or the user's Trash. It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to
// the integration tier.

import Foundation
import XCTest
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class DemoProjectsCLIRoutePinReplayTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var cli: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "demo-cli-route")
        defaults = makeTestDefaultsSuite(prefix: "DemoProjectsCLIRoutePinReplayTests").defaults
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Pins

    /// A replace downloads and verifies the new copy before it touches the old one, then moves the old copy
    /// to the Trash, puts the new one in its place and opens it.
    func testReplacingAClosedProjectTrashesTheOldCopyOnceTheNewOneIsVerifiedThenOpensTheNewOne() async throws {
        let standIn = try serve()
        let opened = expectation(description: "project opened")
        let harness = makeHarness(standIn: standIn, onOpen: { _ in opened.fulfill() })
        try writeInstalledCopy(of: standIn.project, in: harness.installed, version: "2026.1.1")
        try Data("old".utf8).write(to: harness.target.appendingPathComponent("old-marker.txt"))
        harness.model.refreshStatuses()

        harness.model.download(standIn.project, replaceExisting: true)
        XCTAssertTrue(harness.reporter.begun[0].cliCommand.hasSuffix(" --force"), "the row's command replaces the copy")
        await fulfillment(of: [opened], timeout: 60)

        XCTAssertEqual(harness.projectOpens.value, [harness.target])
        XCTAssertEqual(harness.reporter.completed, [harness.target])
        XCTAssertTrue(harness.reporter.failures.isEmpty)
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: harness.target)?.version, standIn.project.version)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: harness.target.appendingPathComponent("old-marker.txt").path),
            "the old files are not in the new copy")
        XCTAssertEqual(
            try String(
                contentsOf: harness.trash.appendingPathComponent(harness.target.lastPathComponent).appendingPathComponent("old-marker.txt"),
                encoding: .utf8),
            "old", "the old copy went to the Trash whole")
        let beside = try FileManager.default.contentsOfDirectory(atPath: harness.installed.path)
        XCTAssertEqual(beside, [harness.target.lastPathComponent], "no staging folder is left beside the project")
    }

    /// A replace whose archive fails its checksum leaves the existing copy where it is and trashes nothing.
    func testAFailedReplaceLeavesTheExistingCopyAndTrashesNothing() async throws {
        let standIn = try serve(declaredSHA256: String(repeating: "cd", count: 32))
        let failed = expectation(description: "failure reported")
        let harness = makeHarness(standIn: standIn)
        harness.reporter.onFail = { failed.fulfill() }
        try writeInstalledCopy(of: standIn.project, in: harness.installed, version: "2026.1.1")
        try Data("old".utf8).write(to: harness.target.appendingPathComponent("old-marker.txt"))

        harness.model.download(standIn.project, replaceExisting: true)
        await fulfillment(of: [failed], timeout: 60)

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.trash.path), "the old copy is not touched before the new one verifies")
        XCTAssertEqual(try String(contentsOf: harness.target.appendingPathComponent("old-marker.txt"), encoding: .utf8), "old")
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: harness.target)?.version, "2026.1.1")
        XCTAssertTrue(harness.model.alert?.message.contains("SHA-256") == true, "\(String(describing: harness.model.alert))")
        XCTAssertTrue(harness.reporter.failures.first?.contains("SHA-256") == true, "\(harness.reporter.failures)")
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
    }

    /// The byte reports reach Operations in order, the first from zero, and the install phases follow.
    func testTheByteProgressReachesOperationsInOrderBeforeTheProjectOpens() async throws {
        let standIn = try serve(payloadBytes: 6_000_000)
        let opened = expectation(description: "project opened")
        let harness = makeHarness(standIn: standIn, onOpen: { _ in opened.fulfill() })
        harness.model.download(standIn.project, replaceExisting: false)
        await fulfillment(of: [opened], timeout: 60)

        let received = harness.reporter.phases.compactMap { phase -> Int64? in
            if case let .downloading(bytes, _) = phase { return bytes }
            return nil
        }
        XCTAssertEqual(received.first, 0, "the first report is the start of the transfer")
        XCTAssertGreaterThan(received.count, 2, "the bar moves while the transfer runs: \(received)")
        XCTAssertEqual(received, received.sorted(), "the bytes never step back")
        let totals = harness.reporter.phases.compactMap { phase -> Int64? in
            if case let .downloading(_, total) = phase { return total }
            return nil
        }
        XCTAssertTrue(totals.allSatisfy { $0 == standIn.project.archive.bytes }, "\(totals)")
        XCTAssertTrue(harness.reporter.phases.contains(.verifying) && harness.reporter.phases.contains(.installing), "\(harness.reporter.phases)")
    }

    /// Cancel on the row stops the transfer. The row reads Cancelled with no alert and no failure, nothing
    /// opens, and no project or staging folder is left.
    func testCancellingTheRowEndsCancelledWithNoAlertAndLeavesNoFolder() async throws {
        let hold = StandInHold()
        let standIn = try serve(hold: hold)
        let acknowledged = expectation(description: "cancel acknowledged")
        let harness = makeHarness(standIn: standIn)
        harness.reporter.onAcknowledge = { acknowledged.fulfill() }
        harness.model.download(standIn.project, replaceExisting: false)
        let reached = await LungfishTestSupport.waitUntil(timeout: .seconds(30)) { Self.asked(standIn) }
        XCTAssertTrue(reached, "the child asked for the archive")

        let cancel = try XCTUnwrap(harness.reporter.cancelHandler, "the row has a Cancel")
        cancel()
        await fulfillment(of: [acknowledged], timeout: 60)
        hold.release()

        XCTAssertEqual(harness.reporter.acknowledgedCancellations, 1)
        XCTAssertNil(harness.model.alert, "a cancel raises no alert")
        XCTAssertTrue(harness.reporter.failures.isEmpty)
        XCTAssertTrue(harness.reporter.completed.isEmpty)
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
        XCTAssertFalse(harness.model.isDownloading(standIn.project))
        XCTAssertEqual(harness.model.status(for: standIn.project), .notDownloaded)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: harness.installed.path)) ?? []
        XCTAssertEqual(left, [], "no staging folder or project is left")
    }

    /// A cancelled replace never touches the copy the user has.
    func testCancellingAReplaceKeepsTheExistingCopy() async throws {
        let hold = StandInHold()
        let standIn = try serve(hold: hold)
        let acknowledged = expectation(description: "cancel acknowledged")
        let harness = makeHarness(standIn: standIn)
        harness.reporter.onAcknowledge = { acknowledged.fulfill() }
        try writeInstalledCopy(of: standIn.project, in: harness.installed, version: "2026.1.1")
        try Data("old".utf8).write(to: harness.target.appendingPathComponent("old-marker.txt"))

        harness.model.download(standIn.project, replaceExisting: true)
        let reached = await LungfishTestSupport.waitUntil(timeout: .seconds(30)) { Self.asked(standIn) }
        XCTAssertTrue(reached, "the child asked for the archive")
        try XCTUnwrap(harness.reporter.cancelHandler)()
        await fulfillment(of: [acknowledged], timeout: 60)
        hold.release()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.trash.path))
        XCTAssertEqual(try String(contentsOf: harness.target.appendingPathComponent("old-marker.txt"), encoding: .utf8), "old")
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: harness.target)?.version, "2026.1.1")
        XCTAssertNil(harness.model.alert)
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
        let beside = try FileManager.default.contentsOfDirectory(atPath: harness.installed.path)
        XCTAssertEqual(beside, [harness.target.lastPathComponent], "the cancelled child left no staging folder")
    }

    /// The first download of a project runs through Operations, closes the sheet and opens the project.
    func testDownloadRunsThroughOperationsThenOpensTheProject() async throws {
        let standIn = try serve()
        let opened = expectation(description: "project opened")
        let harness = makeHarness(standIn: standIn, onOpen: { _ in opened.fulfill() })

        harness.model.performPrimaryAction(for: standIn.project)
        XCTAssertEqual(harness.reporter.begun.count, 1)
        XCTAssertTrue(harness.reporter.begun[0].cliCommand.hasPrefix("lungfish-cli demo fetch demo-fixture --dest "))
        XCTAssertTrue(harness.model.isDownloading(standIn.project))
        await fulfillment(of: [opened], timeout: 60)

        XCTAssertEqual(harness.projectOpens.value, [harness.target])
        XCTAssertEqual(harness.reporter.completed, [harness.target])
        XCTAssertTrue(harness.reporter.failures.isEmpty)
        XCTAssertEqual(harness.dismissCount.value, 1)
        XCTAssertFalse(harness.model.isDownloading(standIn.project))
        XCTAssertEqual(harness.model.status(for: standIn.project), .downloaded(version: standIn.project.version))
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: harness.target)?.id, DemoArchiveStandIn.projectID)
    }

    /// A checksum failure reaches Operations and the sheet with the command's own words.
    func testChecksumFailureIsReportedToOperationsAndTheSheet() async throws {
        let standIn = try serve(declaredSHA256: String(repeating: "ab", count: 32))
        let failed = expectation(description: "failure reported")
        let harness = makeHarness(standIn: standIn)
        harness.reporter.onFail = { failed.fulfill() }

        harness.model.download(standIn.project, replaceExisting: false)
        await fulfillment(of: [failed], timeout: 60)

        XCTAssertTrue(harness.reporter.failures.first?.contains("SHA-256") == true, "\(harness.reporter.failures)")
        XCTAssertTrue(harness.model.alert?.message.contains("SHA-256") == true)
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
        XCTAssertEqual(harness.model.status(for: standIn.project), .notDownloaded)
    }

    // MARK: - Harness

    private static func asked(_ standIn: DemoArchiveStandIn) -> Bool {
        standIn.server.requests.contains { $0.path == DemoArchiveStandIn.archivePath }
    }

    /// The stand-in, with the process environment the child inherits: the list, the stand-in origin and a Trash
    /// folder of the test's own.
    private func serve(payloadBytes: Int = 0, declaredSHA256: String? = nil, hold: StandInHold? = nil) throws -> DemoArchiveStandIn {
        let standIn = try DemoArchiveStandIn.start(
            in: root.appendingPathComponent("served", isDirectory: true), payloadBytes: payloadBytes,
            declaredSHA256: declaredSHA256, hold: hold)
        var set = standIn.environment
        set[DemoLocationOptions.manifestVariable] = standIn.manifestURL.path
        set[DemoFetchRun.trashFolderVariable] = root.appendingPathComponent("Trash", isDirectory: true).path
        let saved = ProcessEnvironmentOverride(set: set, unset: ["NCBI_API_KEY"])
        addTeardownBlock {
            hold?.release()
            standIn.stop()
            saved.restore()
        }
        return standIn
    }

    private struct Harness {
        let model: DemoProjectsViewModel
        let reporter: CLIRouteReporter
        let projectOpens: CLIRouteBox<[URL]>
        let dismissCount: CLIRouteBox<Int>
        let installed: URL
        let trash: URL

        var target: URL { installed.appendingPathComponent(DemoArchiveStandIn.projectFolderName, isDirectory: true) }
    }

    private func makeHarness(standIn: DemoArchiveStandIn, onOpen: @escaping (URL) -> Void = { _ in }) -> Harness {
        let installed = root.appendingPathComponent("Installed", isDirectory: true)
        let store = DemoProjectLocationStore(defaults: defaults, homeDirectory: root)
        store.directory = installed
        let reporter = CLIRouteReporter()
        let projectOpens = CLIRouteBox<[URL]>([])
        let dismissCount = CLIRouteBox(0)
        let project = standIn.project
        let environment = DemoProjectsEnvironment(
            loadManifest: { DemoProjectManifest(projects: [project]) },
            installer: DemoProjectInstaller(appVersion: "2026.9.44"),
            locationStore: store,
            operations: reporter,
            openProject: { url in
                projectOpens.value.append(url)
                onOpen(url)
            },
            revealInFinder: { _ in },
            openURL: { _ in },
            isProjectOpen: { _ in false },
            cliURL: cli
        )
        let model = DemoProjectsViewModel(environment: environment)
        model.onDismiss = { dismissCount.value += 1 }
        return Harness(
            model: model, reporter: reporter, projectOpens: projectOpens, dismissCount: dismissCount,
            installed: installed, trash: root.appendingPathComponent("Trash", isDirectory: true))
    }

    private func writeInstalledCopy(of project: DemoProject, in installed: URL, version: String) throws {
        let folder = installed.appendingPathComponent(project.projectFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DemoProjectInstallRecord(id: project.id, version: version, sha256: "x", installedAt: Date()))
            .write(to: folder.appendingPathComponent(".lgedemo.json"))
    }
}

@MainActor
private final class CLIRouteBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// What the window reports to Operations, as `DemoProjectsViewModelTests` records it for the in-process install.
@MainActor
private final class CLIRouteReporter: DemoProjectOperationReporting {
    struct Begun { let title: String; let cliCommand: String }
    private(set) var begun: [Begun] = []
    private(set) var completed: [URL] = []
    private(set) var failures: [String] = []
    private(set) var phases: [DemoProjectInstallPhase] = []
    private(set) var cancelHandler: (@Sendable () -> Void)?
    private(set) var acknowledgedCancellations = 0
    var onFail: (() -> Void)?
    var onAcknowledge: (() -> Void)?

    func begin(title: String, detail: String, cliCommand: String) -> UUID? {
        begun.append(Begun(title: title, cliCommand: cliCommand))
        return UUID()
    }

    func setCancelHandler(id: UUID, handler: @escaping @Sendable () -> Void) { cancelHandler = handler }
    func report(id: UUID, phase: DemoProjectInstallPhase) { phases.append(phase) }
    func complete(id: UUID, projectURL: URL) { completed.append(projectURL) }
    func fail(id: UUID, message: String) {
        failures.append(message)
        onFail?()
    }

    func acknowledgeCancellation(id: UUID) {
        acknowledgedCancellations += 1
        onAcknowledge?()
    }
}
