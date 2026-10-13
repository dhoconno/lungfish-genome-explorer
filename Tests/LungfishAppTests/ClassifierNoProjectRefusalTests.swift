// ClassifierNoProjectRefusalTests.swift - A classifier launch with no project open is refused
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A12 (decision L1, UX U14). A launch with no project open used to take the
// in-process route and write its result beside the first input, where no project lists it. It now
// shows the `No Project Open` sheet and launches nothing: no row on the Operations panel, and no
// byte written under the folder of the reads.
//
// Phase 2.10 lane A35 (panel decision A4). A classifier item chosen with no main window used to
// beep, so the refusal never ran. It now shows the same refusal app-modal through the presenter
// seam (NoProjectAlertPresenter.swift), and these tests bind a recording presenter, since no test
// can click an application-modal alert away. An item of any other category still only beeps.

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

    // MARK: - No main window

    /// Phase 2.10 lane A35 (panel decision A4). The Tools menu reaches `showFASTQOperationsDialog`
    /// from a delegate with no main window, as it does with no project window open. A classifier
    /// entry shows the `No Project Open` refusal app-modal, with no window given, in decision L1's
    /// words and with the Tools menu's tool word. It starts nothing and writes nothing.
    func testEveryClassifierEntryWithNoMainWindowShowsNoProjectOpenAndStartsNothing() throws {
        let input = try readsInputs(count: 1)[0]
        let entries: [(name: String, tool: String, call: (AppDelegate) -> Void)] = [
            ("launchKraken2Classification", "Kraken2", { $0.launchKraken2Classification(nil) }),
            ("launchEsVirituDetection", "EsViritu", { $0.launchEsVirituDetection(nil) }),
            ("launchTaxTriage", "TaxTriage", { $0.launchTaxTriage(nil) }),
            // The generic item has no tool id, so it names the category the way the Tools menu does.
            ("classifyReads", "Classification", { $0.classifyReads(nil) }),
            ("the Tools menu's Kraken2 item", "Kraken2", { $0.launchFASTQOperationToolFromMenu(Self.menuItem(for: .kraken2)) }),
            ("the Tools menu's EsViritu item", "EsViritu", { $0.launchFASTQOperationToolFromMenu(Self.menuItem(for: .esViritu)) }),
            ("the Tools menu's TaxTriage item", "TaxTriage", { $0.launchFASTQOperationToolFromMenu(Self.menuItem(for: .taxTriage)) }),
            ("the dialog with Kraken2 and inputs", "Kraken2", {
                $0.showFASTQOperationsDialog(nil, initialCategory: .classification, initialToolID: .kraken2, preferredInputURLs: [input])
            }),
        ]
        for entry in entries {
            let outcome = try startWithNoMainWindow(entry.call)
            XCTAssertEqual(outcome.presentations.map(\.title), ["No Project Open"], "\(entry.name): one refusal, titled by L1")
            XCTAssertEqual(outcome.presentations.map(\.message), [refusalMessage(tool: entry.tool)], "\(entry.name): L1's words")
            XCTAssertEqual(outcome.presentations.map { $0.window == nil }, [true], "\(entry.name): no window is given, so it is app-modal")
            XCTAssertEqual(outcome.startedRows, [], "\(entry.name): starts no row")
            XCTAssertTrue(outcome.readsUnchanged, "\(entry.name): writes nothing beside the reads")
        }
    }

    /// An item of any other category keeps its beep. It presents nothing, starts nothing and writes
    /// nothing with no main window (panel decision A4).
    func testAnEntryOfAnotherCategoryWithNoMainWindowPresentsNothingAndStartsNothing() throws {
        let input = try readsInputs(count: 1)[0]
        for category in FASTQOperationCategoryID.allCases where category != .classification {
            let outcome = try startWithNoMainWindow {
                $0.showFASTQOperationsDialog(nil, initialCategory: category, preferredInputURLs: [input])
            }
            XCTAssertEqual(outcome.presentations.count, 0, "\(category.displayName): the beep is all it does")
            XCTAssertEqual(outcome.startedRows, [], "\(category.displayName): starts no row")
            XCTAssertTrue(outcome.readsUnchanged, "\(category.displayName): writes nothing beside the reads")
        }
        let otherTools: [FASTQOperationToolID] = [.spades, .minimap2, .fastpTrim]
        for toolID in otherTools {
            let outcome = try startWithNoMainWindow { $0.launchFASTQOperationToolFromMenu(Self.menuItem(for: toolID)) }
            XCTAssertEqual(outcome.presentations.count, 0, "\(toolID.title): the beep is all it does")
            XCTAssertEqual(outcome.startedRows, [], "\(toolID.title): starts no row")
            XCTAssertTrue(outcome.readsUnchanged, "\(toolID.title): writes nothing beside the reads")
        }
    }

    /// The Tools menu item of `toolID`, as `MainMenu+Tools.swift` builds it.
    private static func menuItem(for toolID: FASTQOperationToolID) -> NSMenuItem {
        let item = NSMenuItem(title: "\(toolID.title)\u{2026}", action: nil, keyEquivalent: "")
        item.representedObject = toolID
        return item
    }

    /// What a call on a delegate with no main window left behind. The delegate has no window to
    /// hold a sheet, so the outcome holds what the presenter received, the rows and the bytes.
    private func startWithNoMainWindow(
        _ start: (AppDelegate) -> Void
    ) throws -> (presentations: [RecordingNoProjectPresenter.Presentation], startedRows: [String], readsUnchanged: Bool) {
        let before = try ClassifierRouteFixtures.snapshot(of: root)
        let delegate = makeAppDelegateWithTemporaryState()
        // The premise. A main window left open by another test would open the real dialog.
        guard delegate.activeMainWindowController(sender: nil) == nil else {
            XCTFail("this process has a main window")
            return ([], [], true)
        }
        let recorder = RecordingNoProjectPresenter()
        let existing = Set(OperationCenter.shared.items.map(\.id))
        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) { start(delegate) }
        let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        rowIDs.append(contentsOf: started.map(\.id))
        return (recorder.presentations, started.map(\.title), try ClassifierRouteFixtures.snapshot(of: root) == before)
    }

    // MARK: - Where the refusal goes

    /// A launch from a window hands that window to the presenter, which puts the sheet on it
    /// (decision L1). A launch whose viewer sits in no window hands none, and the refusal reaches
    /// the user app-modal where `showAlert` used to find nothing to show it on.
    func testARefusedLaunchHandsTheViewersWindowToThePresenterOrNoneAtAll() throws {
        let configs = try kraken2Configs(count: 1)
        let delegate = makeAppDelegateWithTemporaryState()
        let windowless = ViewerViewController()
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        defer {
            window.contentViewController = nil
            window.close()
        }
        let recorder = RecordingNoProjectPresenter()
        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
            delegate.launchClassification(configs: configs, viewerController: viewer, routeContext: nil)
            delegate.launchClassification(configs: configs, viewerController: windowless, routeContext: nil)
        }

        XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open", "No Project Open"])
        XCTAssertEqual(recorder.presentations.map(\.message), Array(repeating: refusalMessage(tool: "Kraken2"), count: 2))
        XCTAssertTrue(recorder.presentations.first?.window === window, "a launch from a window: the sheet sits on it")
        XCTAssertNil(recorder.presentations.last?.window, "a viewer in no window: the refusal is app-modal")
    }

    /// The one refusal takes the tool's name and an optional window, and hands the presenter L1's
    /// words with that window.
    func testTheOneRefusalTakesAToolNameAndAnOptionalWindow() {
        let delegate = makeAppDelegateWithTemporaryState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = RecordingNoProjectPresenter()
        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
            delegate.refuseClassifierLaunchWithoutProject(tool: "Kraken2", window: window)
            delegate.refuseClassifierLaunchWithoutProject(tool: "EsViritu", window: nil)
        }

        XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open", "No Project Open"])
        XCTAssertEqual(recorder.presentations.map(\.message), [refusalMessage(tool: "Kraken2"), refusalMessage(tool: "EsViritu")])
        XCTAssertTrue(recorder.presentations.first?.window === window)
        XCTAssertNil(recorder.presentations.last?.window)
    }

    /// The live presenter puts a sheet on a given window and shows an application-modal alert with
    /// none. The modal branch is not run here, since a unit test cannot click it away.
    func testTheLivePresenterChoosesASheetOnlyForAGivenWindow() {
        XCTAssertEqual(LiveNoProjectAlertPresenter.mode(hasWindow: true), .sheet)
        XCTAssertEqual(LiveNoProjectAlertPresenter.mode(hasWindow: false), .applicationModal)
    }

    func testTheLivePresenterShowsTheTitleAndTextAsASheetOnAGivenWindow() async throws {
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }
        LiveNoProjectAlertPresenter().present(title: "No Project Open", message: refusalMessage(tool: "Kraken2"), on: window)
        _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
        XCTAssertEqual(window.attachedSheet.map(Self.texts(in:)), refusalText(tool: "Kraken2"))
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
        "No Project Open\n\(refusalMessage(tool: tool))"
    }

    /// The text under the title of the refusal for `tool`, in decision L1's words.
    private func refusalMessage(tool: String) -> String {
        "Open or create a project before running \(tool). LGE saves its results in the project's Analyses folder."
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

/// Records what the `No Project Open` refusal hands to its presenter, in place of showing it. An
/// application-modal alert in a unit test waits for a click that never comes, so a test that can
/// reach the refusal with no window binds this through `AppDelegate.NoProjectPresenterSeam`.
@MainActor
final class RecordingNoProjectPresenter: NoProjectAlertPresenting {
    struct Presentation {
        let title: String
        let message: String
        let window: NSWindow?
    }

    private(set) var presentations: [Presentation] = []

    func present(title: String, message: String, on window: NSWindow?) {
        presentations.append(Presentation(title: title, message: message, window: window))
    }
}
