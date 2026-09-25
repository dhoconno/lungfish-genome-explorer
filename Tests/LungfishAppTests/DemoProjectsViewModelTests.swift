// DemoProjectsViewModelTests.swift - Help > Demo Projects… state, folder store and download flow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class DemoProjectsViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-projects-vm-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "DemoProjectsViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
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
                loader: LocalFileLoader(fileURL: archiveURL),
                appVersion: "2026.9.44",
                trash: { _ in nil }
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

    func setCancelHandler(id: UUID, handler: @escaping @Sendable () -> Void) {}
    func report(id: UUID, phase: DemoProjectInstallPhase) { phases.append(phase) }
    func complete(id: UUID, projectURL: URL) { completed.append(projectURL) }
    func fail(id: UUID, message: String) {
        failures.append(message)
        onFail?()
    }
    func acknowledgeCancellation(id: UUID) {}
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
