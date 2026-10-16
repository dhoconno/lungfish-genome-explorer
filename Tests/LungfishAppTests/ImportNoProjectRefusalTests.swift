// ImportNoProjectRefusalTests.swift - An import with no project open says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U62 (SW8, inventory facts F22 and F23, decisions U5 and Q-U65). The Import Center
// starts four imports (NAO-MGS results, a primer scheme, NVD results and CZ-ID results) through
// `AppDelegate+ToolsMenu.swift`. With no main window open each only beeped, and the NVD and CZ-ID
// result imports called `showAlert`, which shows nothing when it finds no window. All six now
// refuse in one set of words, `No Project Open` over `Open or create a project before importing
// <thing>.`, through `AppDelegate.NoProjectPresenterSeam`. The tests bind a recording presenter, as
// ClassifierNoProjectRefusalTests does, because no test can click an application-modal alert away.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ImportNoProjectRefusalTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    // MARK: - The six refusals

    /// With no main window each of the four imports refuses app-modal, with no window given. It
    /// starts no row, tells the wizard request nothing and puts no sheet on any window.
    func testEachOfTheFourImportsWithNoMainWindowShowsNoProjectOpenAndStartsNothing() throws {
        for entry in Self.windowlessLaunches {
            let outcome = try run(entry.call)
            XCTAssertEqual(outcome.presentations.map(\.title), ["No Project Open"], "\(entry.name): one refusal")
            XCTAssertEqual(outcome.presentations.map(\.message), [refusalMessage(entry.thing)], entry.name)
            XCTAssertEqual(outcome.presentations.map { $0.window == nil }, [true], "\(entry.name): no window, so app-modal")
            XCTAssertEqual(outcome.startedRows, [], "\(entry.name): starts no row")
            XCTAssertEqual(outcome.dispatched, [], "\(entry.name): the wizard request hears nothing")
            XCTAssertEqual(outcome.sheetsAdded, 0, "\(entry.name): the presenter shows it, not a sheet of the import")
        }
    }

    /// With no project and no window the NVD and CZ-ID result imports refuse in the same words and
    /// still reject to their caller.
    func testTheTwoResultImportsWithNoProjectAndNoWindowShowNoProjectOpenAndRejectTheirCaller() throws {
        for entry in Self.resultImports {
            let outcome = try run(entry.call)
            XCTAssertEqual(outcome.presentations.map(\.title), ["No Project Open"], "\(entry.name): one refusal")
            XCTAssertEqual(outcome.presentations.map(\.message), [refusalMessage(entry.thing)], entry.name)
            XCTAssertEqual(outcome.presentations.map { $0.window == nil }, [true], "\(entry.name): no window, so app-modal")
            XCTAssertEqual(outcome.startedRows, [], "\(entry.name): starts no row")
            XCTAssertEqual(outcome.dispatched, [.rejected("Open a project before importing results.")], entry.name)
            XCTAssertEqual(outcome.sheetsAdded, 0, "\(entry.name): the presenter shows it, not a sheet of the import")
        }
    }

    /// With a project window and no project the same two imports hand the presenter that window, so
    /// the refusal is a sheet on it.
    func testTheTwoResultImportsWithNoProjectOnAWindowShowItOnThatWindow() throws {
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        for entry in Self.resultImports {
            let recorder = RecordingNoProjectPresenter()
            let box = DispatchBox()
            AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) { entry.call(delegate, box) }

            XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open"], entry.name)
            XCTAssertEqual(recorder.presentations.map(\.message), [refusalMessage(entry.thing)], entry.name)
            XCTAssertTrue(recorder.presentations.first?.window === controller.window, "\(entry.name): the sheet sits on the project window")
            XCTAssertEqual(box.values, [.rejected("Open a project before importing results.")], entry.name)
        }
    }

    /// The one refusal takes the thing imported and an optional window, and names no folder.
    func testTheSharedRefusalHandsThePresenterTheWordsAndTheWindow() {
        let delegate = makeAppDelegateWithTemporaryState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = RecordingNoProjectPresenter()
        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
            delegate.refuseImportWithoutProject("BAM files", window: window)
            delegate.refuseImportWithoutProject("VCF files", window: nil)
        }

        XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open", "No Project Open"])
        XCTAssertEqual(recorder.presentations.map(\.message), [refusalMessage("BAM files"), refusalMessage("VCF files")])
        XCTAssertTrue(recorder.presentations.first?.window === window)
        XCTAssertNil(recorder.presentations.last?.window)
        XCTAssertFalse(recorder.presentations.contains { $0.message.contains("Analyses") }, "an import lands in different folders")
    }

    // MARK: - Helpers

    /// The words under the title, in Q-U65's family: one sentence, one final period, no folder.
    private func refusalMessage(_ thing: String) -> String {
        "Open or create a project before importing \(thing)."
    }

    private typealias Launch = (name: String, thing: String, call: (AppDelegate, DispatchBox) -> Void)

    /// The four Import Center imports that reach a delegate with no main window.
    private static let windowlessLaunches: [Launch] = [
        ("launchNaoMgsImport", "NAO-MGS results", { delegate, box in
            delegate.launchNaoMgsImport(ImportWizardRequest(sourceURL: nil) { box.add($0) })
        }),
        ("launchPrimerSchemeImport", "a primer scheme", { delegate, box in
            delegate.launchPrimerSchemeImport(ImportWizardRequest(sourceURL: nil) { box.add($0) })
        }),
        ("launchNvdImport", "NVD results", { delegate, box in
            delegate.launchNvdImport(ImportWizardRequest(sourceURL: nil) { box.add($0) })
        }),
        ("launchCzIdImport", "CZ-ID results", { delegate, box in
            delegate.launchCzIdImport(ImportWizardRequest(sourceURL: nil) { box.add($0) })
        }),
    ]

    /// The NVD and CZ-ID result imports, which refuse once they find no project.
    private static let resultImports: [Launch] = [
        ("importNvdResultFromURL", "NVD results", { delegate, box in
            delegate.importNvdResultFromURL(URL(fileURLWithPath: "/tmp/invented-nvd-run")) { box.add($0) }
        }),
        ("importCzIdResultFromURL", "CZ-ID results", { delegate, box in
            delegate.importCzIdResultFromURL(URL(fileURLWithPath: "/tmp/invented-czid-run")) { box.add($0) }
        }),
    ]

    /// What an import call hands back to its caller.
    private final class DispatchBox: @unchecked Sendable {
        private(set) var values: [ImportDispatchOutcome] = []

        func add(_ value: ImportDispatchOutcome) {
            values.append(value)
        }
    }

    /// What one call on a delegate with no main window left behind.
    private struct Outcome {
        let presentations: [RecordingNoProjectPresenter.Presentation]
        let startedRows: [String]
        let dispatched: [ImportDispatchOutcome]
        let sheetsAdded: Int
    }

    /// Runs `call` on a delegate with no main window, a recording presenter bound, and reads what
    /// it presented, the rows it started and the sheets it put on any window.
    private func run(_ call: (AppDelegate, DispatchBox) -> Void) throws -> Outcome {
        let delegate = makeAppDelegateWithTemporaryState()
        // The premise. A main window left open by another test would open the real wizard.
        guard delegate.activeMainWindowController(sender: nil) == nil else {
            XCTFail("this process has a main window")
            return Outcome(presentations: [], startedRows: [], dispatched: [], sheetsAdded: 0)
        }
        let recorder = RecordingNoProjectPresenter()
        let box = DispatchBox()
        let existing = Set(OperationCenter.shared.items.map(\.id))
        let sheetsBefore = NSApp.windows.filter { $0.attachedSheet != nil }.count
        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) { call(delegate, box) }
        let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        for row in started { OperationCenter.shared.clearItem(id: row.id) }
        let sheetsAfter = NSApp.windows.filter { $0.attachedSheet != nil }.count
        return Outcome(
            presentations: recorder.presentations,
            startedRows: started.map(\.title),
            dispatched: box.values,
            sheetsAdded: sheetsAfter - sheetsBefore
        )
    }
}
