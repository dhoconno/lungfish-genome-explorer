// DemoProjectsViewModelTests.swift - Help > Demo Projects… state, folder store and download flow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class DemoProjectsViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-projects-vm-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = makeTestDefaultsSuite(prefix: "DemoProjectsViewModelTests").defaults
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Folder store

    func testLocationStoreDefaultsToDocumentsAndRemembersAChoice() {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let store = DemoProjectLocationStore(defaults: defaults, homeDirectory: home)
        XCTAssertEqual(store.directory.path, home.appendingPathComponent("Documents/LGE Demo Projects").path)
        XCTAssertTrue(store.isUsingDefault)

        let custom = tempDir.appendingPathComponent("Elsewhere", isDirectory: true)
        store.directory = custom
        XCTAssertFalse(store.isUsingDefault)
        XCTAssertEqual(DemoProjectLocationStore(defaults: defaults, homeDirectory: home).directory.path, custom.path)

        store.resetToDefault()
        XCTAssertTrue(store.isUsingDefault)
        XCTAssertNil(defaults.string(forKey: DemoProjectLocationStore.defaultsKey))
    }

    // MARK: - Presentation

    func testStatusAndButtonTextFollowTheInstalledCopy() throws {
        let fixture = try makeFixture()
        let harness = makeHarness(project: fixture.project, archiveURL: fixture.archiveURL)
        let model = harness.model
        let project = fixture.project

        XCTAssertEqual(model.statusText(for: project), "Not downloaded")
        XCTAssertEqual(model.primaryButtonTitle(for: project), "Download & Open")
        XCTAssertEqual(model.sizeText(for: project), ByteCountFormatter.string(fromByteCount: project.archive.bytes, countStyle: .file))

        try writeInstalledCopy(of: project, version: project.version)
        model.refreshStatuses()
        XCTAssertEqual(model.statusText(for: project), "Downloaded")
        XCTAssertEqual(model.primaryButtonTitle(for: project), "Open")

        try writeInstalledCopy(of: project, version: "2026.1.1")
        model.refreshStatuses()
        XCTAssertEqual(model.statusText(for: project), "Update available (\(project.version))")
        XCTAssertEqual(model.primaryButtonTitle(for: project), "Download & Open")

        model.performPrimaryAction(for: project)
        XCTAssertEqual(model.existingCopyPrompt, project, "an existing copy must prompt, not overwrite")
        XCTAssertTrue(harness.reporter.begun.isEmpty)
    }

    func testChapterLinksOpenTheManualAndRevealUsesFinder() throws {
        let fixture = try makeFixture()
        let harness = makeHarness(project: fixture.project, archiveURL: fixture.archiveURL)
        harness.model.openChapter(fixture.project.chapters[0])
        XCTAssertEqual(
            harness.openedURLs.value.map(\.absoluteString),
            ["https://lungfish-genome-explorer.readthedocs.io/en/latest/chapters/02-sequences/01-importing-and-viewing/"]
        )

        try writeInstalledCopy(of: fixture.project, version: fixture.project.version)
        harness.model.refreshStatuses()
        harness.model.reveal(fixture.project)
        XCTAssertEqual(harness.revealed.value, [harness.model.projectURL(for: fixture.project)])
    }

    func testPlaceholderProjectShowsAClearAlertAndStartsNoOperation() throws {
        let fixture = try makeFixture()
        let placeholder = DemoProject(
            id: fixture.project.id, title: "Placeholder", summary: "",
            chapters: [], projectFolderName: "Placeholder.lungfish",
            archive: .init(url: fixture.project.archive.url, sha256: String(repeating: "0", count: 64), bytes: 0),
            version: "2026.9.44", minimumAppVersion: nil
        )
        let harness = makeHarness(project: placeholder, archiveURL: fixture.archiveURL)
        XCTAssertEqual(harness.model.sizeText(for: placeholder), "Not yet published")
        harness.model.performPrimaryAction(for: placeholder)
        XCTAssertTrue(harness.reporter.begun.isEmpty)
        XCTAssertTrue(harness.model.alert?.message.contains("has not been published yet") == true)
    }

    func testReplacingAnOpenProjectIsRefused() throws {
        let fixture = try makeFixture()
        let harness = makeHarness(project: fixture.project, archiveURL: fixture.archiveURL, openProjects: true)
        try writeInstalledCopy(of: fixture.project, version: "2026.1.1")
        harness.model.refreshStatuses()
        harness.model.download(fixture.project, replaceExisting: true)
        XCTAssertTrue(harness.reporter.begun.isEmpty)
        XCTAssertTrue(harness.model.alert?.message.contains("Close that window") == true)
    }

    func testDownloadRunsThroughOperationsThenOpensTheProject() async throws {
        let fixture = try makeFixture()
        let opened = expectation(description: "project opened")
        let harness = makeHarness(project: fixture.project, archiveURL: fixture.archiveURL, onOpen: { _ in opened.fulfill() })

        harness.model.performPrimaryAction(for: fixture.project)
        XCTAssertEqual(harness.reporter.begun.count, 1)
        XCTAssertTrue(harness.reporter.begun[0].cliCommand.hasPrefix("lungfish-cli demo fetch demo-fixture --dest "))
        XCTAssertTrue(harness.model.isDownloading(fixture.project))

        await fulfillment(of: [opened], timeout: 30)

        let target = harness.model.projectURL(for: fixture.project)
        XCTAssertEqual(harness.projectOpens.value, [target])
        XCTAssertEqual(harness.reporter.completed, [target])
        XCTAssertTrue(harness.reporter.failures.isEmpty)
        XCTAssertEqual(harness.dismissCount.value, 1)
        XCTAssertFalse(harness.model.isDownloading(fixture.project))
        XCTAssertEqual(harness.model.status(for: fixture.project), .downloaded(version: fixture.project.version))
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: target)?.id, "demo-fixture")
    }

    func testChecksumFailureIsReportedToOperationsAndTheSheet() async throws {
        let fixture = try makeFixture()
        let bad = DemoProject(
            id: fixture.project.id, title: fixture.project.title, summary: fixture.project.summary,
            chapters: fixture.project.chapters, projectFolderName: fixture.project.projectFolderName,
            archive: .init(url: fixture.project.archive.url, sha256: String(repeating: "ab", count: 32), bytes: fixture.project.archive.bytes),
            version: fixture.project.version, minimumAppVersion: nil
        )
        let failed = expectation(description: "failure reported")
        let harness = makeHarness(project: bad, archiveURL: fixture.archiveURL)
        harness.reporter.onFail = { failed.fulfill() }

        harness.model.download(bad, replaceExisting: false)
        await fulfillment(of: [failed], timeout: 30)

        XCTAssertTrue(harness.reporter.failures.first?.contains("SHA-256") == true)
        XCTAssertTrue(harness.model.alert?.message.contains("SHA-256") == true)
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
        XCTAssertEqual(harness.model.status(for: bad), .notDownloaded)
    }

    func testCLICommandQuotesTheFolder() throws {
        let fixture = try makeFixture()
        let command = DemoProjectsViewModel.cliCommand(
            for: fixture.project,
            directory: URL(fileURLWithPath: "/Users/me/Documents/LGE Demo Projects"),
            replaceExisting: true
        )
        XCTAssertEqual(command, "lungfish-cli demo fetch demo-fixture --dest '/Users/me/Documents/LGE Demo Projects' --force")
    }

    /// The row `download` records parses with the shipped parser and names
    /// the project, folder and replace choice the run uses
    /// (docs/contracts/CLI-EQUIVALENCE.md).
    func testCLICommandParsesWithTheValuesTheDownloadUses() throws {
        let fixture = try makeFixture()
        for replaceExisting in [false, true] {
            let command = DemoProjectsViewModel.cliCommand(
                for: fixture.project,
                directory: URL(fileURLWithPath: "/Users/me/Documents/LGE Demo Projects"),
                replaceExisting: replaceExisting
            )
            let parsed = try RecordedCLICommand.parse(command, as: DemoCommand.FetchSubcommand.self)
            XCTAssertEqual(parsed.id, fixture.project.id)
            XCTAssertEqual(parsed.location.destination, "/Users/me/Documents/LGE Demo Projects")
            XCTAssertEqual(parsed.force, replaceExisting)
        }
    }

    // MARK: - Pins at the base (Phase 2.10 lane A45 M4, panel decision C9)
    //
    // The window installs in process today. M4 moves the install onto `lungfish-cli demo fetch`, so the
    // replace of an existing project (SWIFT) and the row's progress, cancel and opening (UX) are fixed first.

    /// A replace downloads and verifies the new copy before it touches the old one, then moves the old copy
    /// to the Trash, puts the new one in its place and opens it.
    func testReplacingAClosedProjectTrashesTheOldCopyOnceTheNewOneIsVerifiedThenOpensTheNewOne() async throws {
        let fixture = try makeFixture()
        let trashFolder = tempDir.appendingPathComponent("Trash", isDirectory: true)
        let opened = expectation(description: "project opened")
        let harness = makeHarness(
            project: fixture.project, archiveURL: fixture.archiveURL,
            trash: { url in
                try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
                let moved = trashFolder.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: moved)
                return moved
            },
            onOpen: { _ in opened.fulfill() })
        try writeInstalledCopy(of: fixture.project, version: "2026.1.1")
        let target = harness.model.projectURL(for: fixture.project)
        try Data("old".utf8).write(to: target.appendingPathComponent("old-marker.txt"))
        harness.model.refreshStatuses()

        harness.model.download(fixture.project, replaceExisting: true)
        XCTAssertTrue(harness.reporter.begun[0].cliCommand.hasSuffix(" --force"), "the row's command replaces the copy")
        await fulfillment(of: [opened], timeout: 30)

        XCTAssertEqual(harness.projectOpens.value, [target])
        XCTAssertEqual(harness.reporter.completed, [target])
        XCTAssertTrue(harness.reporter.failures.isEmpty)
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: target)?.version, fixture.project.version)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("old-marker.txt").path), "the old files are not in the new copy")
        XCTAssertEqual(
            try String(contentsOf: trashFolder.appendingPathComponent(target.lastPathComponent).appendingPathComponent("old-marker.txt"), encoding: .utf8),
            "old", "the old copy went to the Trash whole")
        let beside = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(beside, [target.lastPathComponent], "no staging folder is left beside the project")
    }

    /// A replace whose archive fails its checksum leaves the existing copy where it is and trashes nothing.
    func testAFailedReplaceLeavesTheExistingCopyAndTrashesNothing() async throws {
        let fixture = try makeFixture()
        let bad = DemoProject(
            id: fixture.project.id, title: fixture.project.title, summary: fixture.project.summary,
            chapters: fixture.project.chapters, projectFolderName: fixture.project.projectFolderName,
            archive: .init(url: fixture.project.archive.url, sha256: String(repeating: "cd", count: 32), bytes: fixture.project.archive.bytes),
            version: fixture.project.version, minimumAppVersion: nil)
        let trashed = StartedFlag()
        let failed = expectation(description: "failure reported")
        let harness = makeHarness(project: bad, archiveURL: fixture.archiveURL, trash: { _ in trashed.set(); return nil })
        harness.reporter.onFail = { failed.fulfill() }
        try writeInstalledCopy(of: bad, version: "2026.1.1")
        let target = harness.model.projectURL(for: bad)
        try Data("old".utf8).write(to: target.appendingPathComponent("old-marker.txt"))

        harness.model.download(bad, replaceExisting: true)
        await fulfillment(of: [failed], timeout: 30)

        XCTAssertFalse(trashed.isSet, "the old copy is not touched before the new one verifies")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("old-marker.txt"), encoding: .utf8), "old")
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: target)?.version, "2026.1.1")
        XCTAssertTrue(harness.model.alert?.message.contains("SHA-256") == true)
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
    }

    /// The byte reports reach Operations in order, the first from zero, and the install phases follow.
    func testTheByteProgressReachesOperationsInOrderBeforeTheProjectOpens() async throws {
        let fixture = try makeFixture()
        let opened = expectation(description: "project opened")
        let harness = makeHarness(
            project: fixture.project, archiveURL: nil,
            loader: SteppedFileLoader(fileURL: fixture.archiveURL, steps: 20), onOpen: { _ in opened.fulfill() })
        harness.model.download(fixture.project, replaceExisting: false)
        await fulfillment(of: [opened], timeout: 30)

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
        XCTAssertTrue(totals.allSatisfy { $0 == fixture.project.archive.bytes }, "\(totals)")
    }

    /// Cancel on the row stops the transfer. The row reads Cancelled with no alert and no failure, nothing
    /// opens, and no project or staging folder is left.
    func testCancellingTheRowEndsCancelledWithNoAlertAndLeavesNoFolder() async throws {
        let fixture = try makeFixture()
        let started = StartedFlag()
        let acknowledged = expectation(description: "cancel acknowledged")
        let harness = makeHarness(project: fixture.project, archiveURL: nil, loader: HangingLoader(started: started))
        harness.reporter.onAcknowledge = { acknowledged.fulfill() }
        harness.model.download(fixture.project, replaceExisting: false)
        let reached = await waitUntil(timeout: .seconds(30)) { started.isSet }
        XCTAssertTrue(reached, "the transfer started")

        let cancel = try XCTUnwrap(harness.reporter.cancelHandler, "the row has a Cancel")
        cancel()
        await fulfillment(of: [acknowledged], timeout: 30)

        XCTAssertEqual(harness.reporter.acknowledgedCancellations, 1)
        XCTAssertNil(harness.model.alert, "a cancel raises no alert")
        XCTAssertTrue(harness.reporter.failures.isEmpty)
        XCTAssertTrue(harness.reporter.completed.isEmpty)
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
        XCTAssertFalse(harness.model.isDownloading(fixture.project))
        XCTAssertEqual(harness.model.status(for: fixture.project), .notDownloaded)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.appendingPathComponent("Installed").path)) ?? []
        XCTAssertEqual(left, [], "no staging folder or project is left")
    }

    /// A cancelled replace never touches the copy the user has.
    func testCancellingAReplaceKeepsTheExistingCopy() async throws {
        let fixture = try makeFixture()
        let started = StartedFlag()
        let trashed = StartedFlag()
        let acknowledged = expectation(description: "cancel acknowledged")
        let harness = makeHarness(
            project: fixture.project, archiveURL: nil, loader: HangingLoader(started: started), trash: { _ in trashed.set(); return nil })
        harness.reporter.onAcknowledge = { acknowledged.fulfill() }
        try writeInstalledCopy(of: fixture.project, version: "2026.1.1")
        let target = harness.model.projectURL(for: fixture.project)
        try Data("old".utf8).write(to: target.appendingPathComponent("old-marker.txt"))

        harness.model.download(fixture.project, replaceExisting: true)
        let reached = await waitUntil(timeout: .seconds(30)) { started.isSet }
        XCTAssertTrue(reached)
        try XCTUnwrap(harness.reporter.cancelHandler)()
        await fulfillment(of: [acknowledged], timeout: 30)

        XCTAssertFalse(trashed.isSet)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("old-marker.txt"), encoding: .utf8), "old")
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: target)?.version, "2026.1.1")
        XCTAssertNil(harness.model.alert)
        XCTAssertTrue(harness.projectOpens.value.isEmpty)
    }

    // MARK: - Harness

    private struct Fixture {
        let project: DemoProject
        let archiveURL: URL
    }

    /// Builds a tiny project archive with /usr/bin/zip (no network).
    private func makeFixture() throws -> Fixture {
        let source = tempDir.appendingPathComponent("source", isDirectory: true)
        let projectDir = source.appendingPathComponent("Demo Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projectDir.appendingPathComponent("metadata.json"))
        let archive = tempDir.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-r", "-y", archive.path, "Demo Fixture.lungfish"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let bytes = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        let project = DemoProject(
            id: "demo-fixture",
            title: "Demo Fixture",
            summary: "A fixture.",
            chapters: [.init(title: "Importing", path: "chapters/02-sequences/01-importing-and-viewing/")],
            projectFolderName: "Demo Fixture.lungfish",
            archive: .init(url: URL(string: "https://example.invalid/demo.zip")!, sha256: try FileDigest.sha256(of: archive), bytes: bytes),
            version: "2026.9.44",
            minimumAppVersion: "2026.9.1"
        )
        return Fixture(project: project, archiveURL: archive)
    }

    private struct Harness {
        let model: DemoProjectsViewModel
        let reporter: RecordingReporter
        let openedURLs: Box<[URL]>
        let revealed: Box<[URL]>
        let projectOpens: Box<[URL]>
        let dismissCount: Box<Int>
    }

    private func makeHarness(
        project: DemoProject,
        archiveURL: URL?,
        openProjects: Bool = false,
        loader: (any DemoProjectArchiveLoading)? = nil,
        trash: @escaping DemoProjectInstaller.TrashHandler = { _ in nil },
        onOpen: @escaping (URL) -> Void = { _ in }
    ) -> Harness {
        let store = DemoProjectLocationStore(defaults: defaults, homeDirectory: tempDir)
        store.directory = tempDir.appendingPathComponent("Installed", isDirectory: true)
        let reporter = RecordingReporter()
        let openedURLs = Box<[URL]>([])
        let revealed = Box<[URL]>([])
        let projectOpens = Box<[URL]>([])
        let dismissCount = Box(0)
        let environment = DemoProjectsEnvironment(
            loadManifest: { DemoProjectManifest(projects: [project]) },
            installer: DemoProjectInstaller(
                loader: loader ?? LocalFileLoader(fileURL: archiveURL),
                appVersion: "2026.9.44",
                trash: trash
            ),
            locationStore: store,
            operations: reporter,
            openProject: { url in
                projectOpens.value.append(url)
                onOpen(url)
            },
            revealInFinder: { revealed.value.append($0) },
            openURL: { openedURLs.value.append($0) },
            isProjectOpen: { _ in openProjects }
        )
        let model = DemoProjectsViewModel(environment: environment)
        model.onDismiss = { dismissCount.value += 1 }
        return Harness(model: model, reporter: reporter, openedURLs: openedURLs, revealed: revealed,
                       projectOpens: projectOpens, dismissCount: dismissCount)
    }

    private func writeInstalledCopy(of project: DemoProject, version: String) throws {
        let folder = tempDir.appendingPathComponent("Installed", isDirectory: true)
            .appendingPathComponent(project.projectFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DemoProjectInstallRecord(id: project.id, version: version, sha256: "x", installedAt: Date()))
            .write(to: folder.appendingPathComponent(".lgedemo.json"))
    }
}

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class RecordingReporter: DemoProjectOperationReporting {
    struct Begun { let title: String; let cliCommand: String }
    private(set) var begun: [Begun] = []
    private(set) var completed: [URL] = []
    private(set) var failures: [String] = []
    private(set) var phases: [DemoProjectInstallPhase] = []
    var onFail: (() -> Void)?

    func begin(title: String, detail: String, cliCommand: String) -> UUID? {
        begun.append(Begun(title: title, cliCommand: cliCommand))
        return UUID()
    }

    private(set) var cancelHandler: (@Sendable () -> Void)?
    private(set) var acknowledgedCancellations = 0
    var onAcknowledge: (() -> Void)?

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

/// Copies a local file in `steps` reports of growing byte counts, as a transfer that reports as it goes.
private struct SteppedFileLoader: DemoProjectArchiveLoading {
    let fileURL: URL
    let steps: Int

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let total = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        for step in 1...steps { progress(total * Int64(step) / Int64(steps), total) }
        try FileManager.default.copyItem(at: fileURL, to: destination)
    }
}

/// A transfer that never ends until its task is cancelled, and says when it started.
private struct HangingLoader: DemoProjectArchiveLoading {
    let started: StartedFlag

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        progress(10, 100)
        started.set()
        try await Task.sleep(for: .seconds(600))
    }
}

private final class StartedFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// Copies a local file instead of downloading.
private struct LocalFileLoader: DemoProjectArchiveLoading {
    let fileURL: URL?

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard let fileURL else { throw DemoProjectError.notFound(url) }
        try FileManager.default.copyItem(at: fileURL, to: destination)
        progress(1, 1)
    }
}
