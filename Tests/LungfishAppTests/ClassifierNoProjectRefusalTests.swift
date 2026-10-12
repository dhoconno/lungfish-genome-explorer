// ClassifierNoProjectRefusalTests.swift - A classifier launch with no project open is refused
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A12 (decision L1, UX U14). A launch with no project open used to take the
// in-process route and write its result beside the first input, where no project lists it. It now
// shows the `No Project Open` sheet and launches nothing: no row on the Operations panel, and no
// byte written under the folder of the reads (UX-6).

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ClassifierNoProjectRefusalTests: XCTestCase {
    private var root: URL!
    private var reads: URL!
    private var rowIDs: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "classifier-no-project")
        reads = root.appendingPathComponent("Reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        rowIDs.forEach { OperationCenter.shared.clearItem(id: $0) }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Kraken2

    /// The dialog's launch refuses a Kraken2 run with no project, for one sample and for a batch.
    func testAKraken2LaunchWithNoProjectIsRefused() async throws {
        for (name, context) in noProjectContexts() {
            for sampleCount in [1, 2] {
                let configs = try kraken2Configs(count: sampleCount)
                let outcome = try await launch { delegate, viewer in
                    delegate.launchClassification(configs: configs, viewerController: viewer, routeContext: context)
                }
                assertRefused(outcome, tool: "Kraken2", "launchClassification, \(sampleCount) sample(s), \(name)")
            }
        }
    }

    /// The CLI route's own entry, which the dialog's launch forwards to, refuses a launch with no project.
    func testTheKraken2CLIEntryRefusesALaunchWithNoProject() async throws {
        for (name, context) in noProjectContexts() {
            for sampleCount in [1, 2] {
                let configs = try kraken2Configs(count: sampleCount)
                let outcome = try await launch { delegate, viewer in
                    delegate.runClassificationThroughCLI(configs: configs, viewerController: viewer, routeContext: context)
                }
                assertRefused(outcome, tool: "Kraken2", "runClassificationThroughCLI, \(sampleCount) sample(s), \(name)")
            }
        }
    }

    // MARK: - EsViritu

    func testAnEsVirituLaunchWithNoProjectIsRefused() async throws {
        for (name, context) in noProjectContexts() {
            for sampleCount in [1, 2] {
                let configs = try esVirituConfigs(count: sampleCount)
                let outcome = try await launch { delegate, viewer in
                    delegate.launchEsViritu(configs: configs, viewerController: viewer, routeContext: context)
                }
                assertRefused(outcome, tool: "EsViritu", "launchEsViritu, \(sampleCount) sample(s), \(name)")
            }
        }
    }

    func testTheEsVirituCLIEntryRefusesALaunchWithNoProject() async throws {
        for (name, context) in noProjectContexts() {
            for sampleCount in [1, 2] {
                let configs = try esVirituConfigs(count: sampleCount)
                let outcome = try await launch { delegate, viewer in
                    delegate.runEsVirituThroughCLI(configs: configs, viewerController: viewer, routeContext: context)
                }
                assertRefused(outcome, tool: "EsViritu", "runEsVirituThroughCLI, \(sampleCount) sample(s), \(name)")
            }
        }
    }

    // MARK: - A launch with nothing to run

    /// An empty launch is not a launch, so it shows no sheet and starts nothing, as before.
    func testALaunchOfNoSamplesWithNoProjectShowsNothing() async throws {
        for (name, context) in noProjectContexts() {
            let kraken2 = try await launch(expectingASheet: false) { delegate, viewer in
                delegate.runClassificationThroughCLI(configs: [], viewerController: viewer, routeContext: context)
            }
            let esViritu = try await launch(expectingASheet: false) { delegate, viewer in
                delegate.runEsVirituThroughCLI(configs: [], viewerController: viewer, routeContext: context)
            }
            for (tool, outcome) in [("Kraken2", kraken2), ("EsViritu", esViritu)] {
                XCTAssertNil(outcome.sheet, "\(tool), \(name)")
                XCTAssertEqual(outcome.startedRows, [], "\(tool), \(name)")
            }
        }
    }

    // MARK: - One launch

    /// What one launch left behind.
    private struct Outcome {
        /// The text fields of the sheet on the viewer's window, top to bottom, or nil for no sheet.
        let sheet: String?
        /// The titles of the rows the launch registered.
        let startedRows: [String]
        /// Whether the folder of the reads and everything under it kept every byte.
        let readsUnchanged: Bool
    }

    /// The sheet a refused launch shows for `tool`, in the words decision L1 gives.
    private func refusalText(tool: String) -> String {
        "No Project Open\nOpen or create a project before running \(tool). LGE saves its results in the project's Analyses folder."
    }

    private func assertRefused(
        _ outcome: Outcome,
        tool: String,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(outcome.sheet, refusalText(tool: tool), "\(name): the sheet", file: file, line: line)
        XCTAssertEqual(outcome.startedRows, [], "\(name): a refused launch registers no row", file: file, line: line)
        XCTAssertTrue(outcome.readsUnchanged, "\(name): a refused launch writes nothing beside the reads", file: file, line: line)
    }

    /// Runs `start` with an app delegate and a viewer in a window that is never ordered front,
    /// whose sheet holds the refusal.
    private func launch(
        expectingASheet expectsSheet: Bool = true,
        _ start: (AppDelegate, ViewerViewController) -> Void
    ) async throws -> Outcome {
        let before = try ClassifierRouteFixtures.snapshot(of: root)
        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }

        let existing = Set(OperationCenter.shared.items.map(\.id))
        start(delegate, viewer)
        let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        rowIDs.append(contentsOf: started.map(\.id))
        if expectsSheet {
            _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
        }
        return Outcome(
            sheet: window.attachedSheet.map(Self.texts(in:)),
            startedRows: started.map(\.title),
            readsUnchanged: try ClassifierRouteFixtures.snapshot(of: root) == before
        )
    }

    /// The route contexts of a launch with no project: none at all, which reads the open window
    /// (this process has none), and a window that shows no project.
    private func noProjectContexts() -> [(name: String, context: OperationRouteContext?)] {
        [
            ("no route context", nil),
            ("a window with no project", OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())),
        ]
    }

    // MARK: - Helpers

    private func readsInputs(count: Int) throws -> [URL] {
        try (1...count).map { index in
            let url = reads.appendingPathComponent("sample\(index).fastq")
            try "@r1\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private func kraken2Configs(count: Int) throws -> [ClassificationConfig] {
        try readsInputs(count: count).map { input in
            ClassificationConfig(
                goal: .profile,
                inputFiles: [input],
                isPairedEnd: false,
                databaseName: "Viral",
                databasePath: root.appendingPathComponent("Databases/Viral"),
                brackenProfileRequest: .automaticDefault,
                confidence: 0.2,
                minimumHitGroups: 2,
                threads: 1,
                memoryMapping: false,
                quickMode: false,
                outputDirectory: reads.appendingPathComponent("classification-\(input.deletingPathExtension().lastPathComponent)"),
                extraArguments: []
            )
        }
    }

    private func esVirituConfigs(count: Int) throws -> [EsVirituConfig] {
        try readsInputs(count: count).map { input in
            let sample = input.deletingPathExtension().lastPathComponent
            return EsVirituConfig(
                inputFiles: [input],
                isPairedEnd: false,
                sampleName: sample,
                outputDirectory: reads.appendingPathComponent("esviritu-\(sample)"),
                databasePath: root.appendingPathComponent("Databases/esviritu"),
                qualityFilter: true,
                threads: 1,
                extraArguments: [],
                readFormat: .unpaired,
                inputLayout: nil
            )
        }
    }

    /// The text fields of a sheet, top to bottom, one per line.
    private static func texts(in window: NSWindow) -> String {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return texts.joined(separator: "\n")
    }
}
