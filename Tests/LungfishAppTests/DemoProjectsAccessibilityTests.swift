// DemoProjectsAccessibilityTests.swift - Help > Demo Projects… controls work through accessibility
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishWorkflow
@testable import LungfishApp

/// Hosts the real sheet content in an NSPanel sheet, walks the NSAccessibility tree the
/// way VoiceOver does, and presses each control through `accessibilityPerformPress`.
@MainActor
final class DemoProjectsAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        windows.removeAll()
        try await super.tearDown()
    }

    func testDownloadAndOpenIsPressableThroughAccessibility() throws {
        let harness = makeHarness(projects: [Self.genes])
        let root = host(harness)

        let primary = try XCTUnwrap(
            AXTree.element(in: root, identifier: DemoProjectsAccessibilityID.primary(Self.genes.id)),
            "the Download & Open button must be reachable in the accessibility tree"
        )
        XCTAssertEqual(AXTree.role(primary), .button)
        XCTAssertEqual(AXTree.label(primary), "Download and open Genes and Sequences")
        XCTAssertTrue(AXTree.press(primary), "AXPress must be supported")

        XCTAssertEqual(harness.reporter.begun.count, 1, "the press must start the download")
        XCTAssertTrue(harness.reporter.begun.first?.hasPrefix("lungfish-cli demo fetch genes-and-sequences") == true)
        waitUntil { harness.loader.requests == [Self.genes.archive.url] }
        XCTAssertEqual(harness.loader.requests, [Self.genes.archive.url], "the fake loader, never the network, gets the request")
    }

    func testInstalledRowButtonsAndChapterLinksArePressableThroughAccessibility() throws {
        let harness = makeHarness(projects: [Self.genes])
        try harness.writeInstalledCopy(of: Self.genes)
        harness.model.refreshStatuses()
        let root = host(harness)
        let id = Self.genes.id

        let primary = try XCTUnwrap(AXTree.element(in: root, identifier: DemoProjectsAccessibilityID.primary(id)))
        XCTAssertEqual(AXTree.label(primary), "Open Genes and Sequences")

        let reveal = try XCTUnwrap(AXTree.element(in: root, identifier: DemoProjectsAccessibilityID.reveal(id)))
        XCTAssertEqual(AXTree.label(reveal), "Reveal Genes and Sequences in Finder")
        XCTAssertTrue(AXTree.press(reveal))
        XCTAssertEqual(harness.revealed.value, [harness.model.projectURL(for: Self.genes)])

        let replace = try XCTUnwrap(AXTree.element(in: root, identifier: DemoProjectsAccessibilityID.replace(id)))
        XCTAssertEqual(AXTree.label(replace), "Replace Genes and Sequences with a fresh copy")
        XCTAssertTrue(AXTree.press(replace))
        XCTAssertEqual(harness.model.replaceConfirmation, Self.genes)

        let chapter = try XCTUnwrap(AXTree.element(in: root, identifier: DemoProjectsAccessibilityID.chapter(id, 0)))
        XCTAssertEqual(AXTree.role(chapter), .link)
        XCTAssertEqual(AXTree.label(chapter), "Open chapter Importing and Viewing a Sequence")
        XCTAssertTrue(AXTree.press(chapter))
        XCTAssertEqual(harness.openedURLs.value, [Self.genes.chapters[0].url].compactMap { $0 })

        XCTAssertEqual(harness.reporter.begun.count, 0, "none of these presses may start a download")
    }

    func testRowsAreOrdinaryGroupsAndControlsKeepTheirIdentifiers() throws {
        let harness = makeHarness(projects: [Self.genes, Self.reads])
        let root = host(harness)

        let roles = AXTree.all(in: root).compactMap { AXTree.role($0)?.rawValue }
        XCTAssertFalse(
            roles.contains("AXOpaqueProviderGroup"),
            "a lazy stack hides the rows from point-based accessibility clients"
        )

        for project in [Self.genes, Self.reads] {
            let row = try XCTUnwrap(AXTree.element(in: root, identifier: DemoProjectsAccessibilityID.row(project.id)))
            XCTAssertEqual(AXTree.role(row), .group, "each row stays one group so VoiceOver reads it as a unit")
            XCTAssertNotNil(
                AXTree.element(in: row, identifier: DemoProjectsAccessibilityID.primary(project.id)),
                "the row group must expose its button, not swallow it"
            )
        }

        // The sheet identifier must not overwrite the identifiers of the controls inside it.
        for identifier in [
            DemoProjectsAccessibilityID.done,
            DemoProjectsAccessibilityID.changeFolder,
            DemoProjectsAccessibilityID.folderPath,
        ] {
            XCTAssertNotNil(AXTree.element(in: root, identifier: identifier), "missing \(identifier)")
        }
        let done = try XCTUnwrap(AXTree.element(in: root, identifier: DemoProjectsAccessibilityID.done))
        XCTAssertTrue(AXTree.press(done))
        XCTAssertEqual(harness.doneCount.value, 1)
    }

    func testEveryPressableControlCanTakeKeyboardFocus() throws {
        let harness = makeHarness(projects: [Self.genes])
        try harness.writeInstalledCopy(of: Self.genes)
        harness.model.refreshStatuses()
        let root = host(harness)
        let id = Self.genes.id

        for identifier in [
            DemoProjectsAccessibilityID.primary(id),
            DemoProjectsAccessibilityID.reveal(id),
            DemoProjectsAccessibilityID.replace(id),
            DemoProjectsAccessibilityID.chapter(id, 0),
            DemoProjectsAccessibilityID.done,
        ] {
            let element = try XCTUnwrap(AXTree.element(in: root, identifier: identifier), identifier)
            XCTAssertTrue(AXTree.isFocusable(element), "\(identifier) must be reachable with Tab under keyboard navigation")
        }
    }

    // MARK: - Fixtures

    private static let genes = DemoProject(
        id: "genes-and-sequences",
        title: "Genes and Sequences",
        summary: "A fixture.",
        chapters: [.init(title: "Importing and Viewing a Sequence", path: "chapters/02-sequences/01-importing-and-viewing/")],
        projectFolderName: "Genes and Sequences.lungfish",
        archive: .init(url: URL(string: "https://example.invalid/genes.zip")!, sha256: String(repeating: "ab", count: 32), bytes: 1024),
        version: "2026.9.44"
    )

    private static let reads = DemoProject(
        id: "human-reads",
        title: "Human Reads",
        summary: "Another fixture.",
        chapters: [.init(title: "Importing Sequencing Reads", path: "chapters/03-reads/01-importing/")],
        projectFolderName: "Human Reads.lungfish",
        archive: .init(url: URL(string: "https://example.invalid/reads.zip")!, sha256: String(repeating: "cd", count: 32), bytes: 2048),
        version: "2026.9.44"
    )

    private struct Harness {
        let model: DemoProjectsViewModel
        let reporter: AccessibilityRecordingReporter
        let loader: RecordingLoader
        let openedURLs: AccessibilityBox<[URL]>
        let revealed: AccessibilityBox<[URL]>
        let doneCount: AccessibilityBox<Int>
        let installDirectory: URL

        func writeInstalledCopy(of project: DemoProject) throws {
            let folder = installDirectory.appendingPathComponent(project.projectFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(DemoProjectInstallRecord(id: project.id, version: project.version, sha256: "x", installedAt: Date()))
                .write(to: folder.appendingPathComponent(".lgedemo.json"))
        }
    }

    private func makeHarness(projects: [DemoProject]) -> Harness {
        let suite = "DemoProjectsAccessibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-projects-ax-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = DemoProjectLocationStore(defaults: defaults, homeDirectory: root)
        let installDirectory = root.appendingPathComponent("Installed", isDirectory: true)
        store.directory = installDirectory

        let reporter = AccessibilityRecordingReporter()
        let loader = RecordingLoader()
        let openedURLs = AccessibilityBox<[URL]>([])
        let revealed = AccessibilityBox<[URL]>([])
        let environment = DemoProjectsEnvironment(
            loadManifest: { DemoProjectManifest(projects: projects) },
            installer: DemoProjectInstaller(loader: loader, appVersion: "2026.9.44", trash: { _ in nil }),
            locationStore: store,
            operations: reporter,
            openProject: { _ in },
            revealInFinder: { revealed.value.append($0) },
            openURL: { openedURLs.value.append($0) },
            isProjectOpen: { _ in false }
        )
        return Harness(
            model: DemoProjectsViewModel(environment: environment),
            reporter: reporter,
            loader: loader,
            openedURLs: openedURLs,
            revealed: revealed,
            doneCount: AccessibilityBox(0),
            installDirectory: installDirectory
        )
    }

    /// Presents the view the way `DemoProjectsSheetController` does: an NSPanel sheet
    /// holding an NSHostingController. Returns the panel, the root of the sheet's tree.
    private func host(_ harness: Harness) -> NSObject {
        // SwiftUI builds its accessibility nodes only once an assistive client is
        // attached. This app-level attribute is how such a client announces itself.
        NSApplication.shared.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )

        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        let doneCount = harness.doneCount
        panel.contentViewController = NSHostingController(
            rootView: DemoProjectsView(viewModel: harness.model, onDone: { doneCount.value += 1 })
        )
        panel.setContentSize(NSSize(width: 760, height: 600))
        parent.beginSheet(panel)
        windows.append(parent)

        waitUntil { AXTree.element(in: panel, identifier: DemoProjectsAccessibilityID.done) != nil }
        return panel
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

// MARK: - Accessibility tree walking

/// Reads the NSAccessibility tree through the same informal protocol AppKit's
/// accessibility server uses, so SwiftUI's own nodes are included.
@MainActor
private enum AXTree {
    static func children(of element: NSObject) -> [NSObject] {
        let modern = ((element as AnyObject).accessibilityChildren?() ?? nil) ?? []
        if !modern.isEmpty { return modern.compactMap { $0 as? NSObject } }
        return ((element.accessibilityAttributeValue(.children) as? [Any]) ?? []).compactMap { $0 as? NSObject }
    }

    static func all(in root: NSObject) -> [NSObject] {
        [root] + children(of: root).flatMap { all(in: $0) }
    }

    static func element(in root: NSObject, identifier: String) -> NSObject? {
        all(in: root).first { ($0 as AnyObject).accessibilityIdentifier?() == identifier }
    }

    static func role(_ element: NSObject) -> NSAccessibility.Role? {
        (element as AnyObject).accessibilityRole?() ?? nil
    }

    static func label(_ element: NSObject) -> String? {
        (element as AnyObject).accessibilityLabel?() ?? nil
    }

    static func press(_ element: NSObject) -> Bool {
        (element as AnyObject).accessibilityPerformPress?() ?? false
    }

    static func isFocusable(_ element: NSObject) -> Bool {
        element.accessibilityIsAttributeSettable(.focused)
    }
}

@MainActor
private final class AccessibilityBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class AccessibilityRecordingReporter: DemoProjectOperationReporting {
    private(set) var begun: [String] = []
    func begin(title: String, detail: String, cliCommand: String) -> UUID? {
        begun.append(cliCommand)
        return UUID()
    }
    func setCancelHandler(id: UUID, handler: @escaping @Sendable () -> Void) {}
    func report(id: UUID, phase: DemoProjectInstallPhase) {}
    func complete(id: UUID, projectURL: URL) {}
    func fail(id: UUID, message: String) {}
    func acknowledgeCancellation(id: UUID) {}
}

/// Records the download request and fails it, so nothing touches the network.
private final class RecordingLoader: DemoProjectArchiveLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var requests: [URL] { lock.withLock { recorded } }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        lock.withLock { recorded.append(url) }
        throw DemoProjectError.notFound(url)
    }
}
