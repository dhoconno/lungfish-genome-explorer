// ImportNoProjectRefusalTests.swift - An import with no project open says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U62 (SW8, inventory facts F22 and F23). The Import Center starts four imports
// (NAO-MGS results, a primer scheme, NVD results and CZ-ID results) through `AppDelegate+ToolsMenu.swift`.
// With no main window open each only beeped, and the NVD and CZ-ID result imports called `showAlert`,
// which shows nothing when it finds no window. The tests bind a recording presenter through
// `AppDelegate.NoProjectPresenterSeam`, as ClassifierNoProjectRefusalTests does, because no test can
// click an application-modal alert away.

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

    // MARK: - Pins of the refusals as they stand

    /// With no main window each of the four imports only beeps. It presents nothing, starts nothing
    /// and never tells the wizard request that anything happened.
    func testTheFourImportsWithNoMainWindowPresentNothing() throws {
        for entry in Self.windowlessLaunches {
            let outcome = try run(entry.call)
            XCTAssertEqual(outcome.presentations.count, 0, "\(entry.name): the beep is all it does")
            XCTAssertEqual(outcome.startedRows, [], "\(entry.name): starts no row")
            XCTAssertEqual(outcome.dispatched, [], "\(entry.name): the wizard request hears nothing")
        }
    }

    /// With no window to find, `showAlert` shows nothing for the NVD and CZ-ID result imports. The
    /// import is rejected to its caller and no sheet appears on any window.
    func testTheTwoResultImportsWithNoProjectAndNoWindowShowNothing() throws {
        for entry in Self.resultImports {
            let outcome = try run(entry.call)
            XCTAssertEqual(outcome.presentations.count, 0, "\(entry.name): the recorder receives nothing")
            XCTAssertEqual(outcome.startedRows, [], "\(entry.name): starts no row")
            XCTAssertEqual(outcome.dispatched, [.rejected("Open a project before importing results.")], entry.name)
            XCTAssertEqual(outcome.sheetsAdded, 0, "\(entry.name): no window shows a sheet")
        }
    }

    // MARK: - Helpers

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
