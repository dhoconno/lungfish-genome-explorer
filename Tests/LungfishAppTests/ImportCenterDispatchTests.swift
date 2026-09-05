import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp

@MainActor
final class ImportCenterDispatchTests: XCTestCase {
    func testDropCannotSilentlyTruncateMultipleSampleSheets() throws {
        try assertRejectedDrop(cardID: "fastq-sample-sheet", names: ["first.csv", "second.csv"])
    }

    func testDropUsesPanelFileTypePolicy() throws {
        try assertRejectedDrop(cardID: "fastq-sample-sheet", names: ["wrong.txt"])
    }

    func testWizardDropRejectsIncompatibleInputWithoutDispatchHistory() throws {
        try assertRejectedDrop(cardID: "cz-id", names: ["wrong.png"])
    }

    func testWizardDispatchRetainsDroppedSourceAndReportsConfigurationThenCancellation() throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        let source = URL(fileURLWithPath: "/tmp/invented-import-source.tsv")
        var outcomes: [ImportDispatchOutcome] = []
        let request = ImportWizardRequest(sourceURL: source) { outcomes.append($0) }
        delegate.launchNaoMgsImport(request)
        let panel = try XCTUnwrap(controller.window?.attachedSheet)
        defer { controller.window?.endSheet(panel) }
        let host = try XCTUnwrap(panel.contentViewController as? NSHostingController<NaoMgsImportSheet>)
        XCTAssertEqual(host.rootView.initialSourceURL, source)
        XCTAssertEqual(outcomes, [.configuring])
        host.rootView.onCancel?()
        XCTAssertEqual(outcomes, [.configuring, .cancelled])
    }

    func testWizardHistoryUsesAcceptedSourceForBothDroppedAndPanelEntry() {
        let originalHistory = UserDefaults.standard.object(forKey: "importHistory")
        defer { UserDefaults.standard.set(originalHistory, forKey: "importHistory") }
        let model = ImportCenterViewModel()
        model.importHistory = []
        let dropped = URL(fileURLWithPath: "/tmp/original-A.tsv")
        let accepted = URL(fileURLWithPath: "/tmp/selected-B.tsv")
        let dropRequest = model.makeWizardRequest(action: .naoMgs, sourceURL: dropped)
        dropRequest.started(sourceURL: accepted)
        let panelRequest = model.makeWizardRequest(action: .naoMgs, sourceURL: nil)
        panelRequest.started(sourceURL: accepted)
        XCTAssertEqual(model.importHistory.map(\.fileName), ["selected-B.tsv", "selected-B.tsv"])
    }

    func testWizardCannotReportStartedAfterProjectlessDestinationRejection() throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        var outcomes: [ImportDispatchOutcome] = []
        let request = ImportWizardRequest(sourceURL: nil) { outcomes.append($0) }
        delegate.launchNaoMgsImport(request)
        let panel = try XCTUnwrap(controller.window?.attachedSheet)
        defer {
            if let attached = controller.window?.attachedSheet { controller.window?.endSheet(attached) }
        }
        let host = try XCTUnwrap(panel.contentViewController as? NSHostingController<NaoMgsImportSheet>)
        host.rootView.onImport?(URL(fileURLWithPath: "/tmp/invented-result.tsv"))
        XCTAssertFalse(outcomes.contains(.started), "A rejected destination cannot be recorded as a started operation")
        if case .rejected = outcomes.last {} else { XCTFail("Destination rejection must be reported to the dispatch owner") }
    }

    private func assertRejectedDrop(cardID: String, names: [String]) throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "importHistory")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.set(original, forKey: "importHistory")
            try? FileManager.default.removeItem(at: root)
        }
        let urls = try names.map { name in
            let url = root.appendingPathComponent(name)
            try Data("synthetic fixture".utf8).write(to: url)
            return url
        }
        let model = ImportCenterViewModel()
        model.importHistory = []
        let card = try XCTUnwrap(model.allCards.first { $0.id == cardID })
        model.performDropImport(urls: urls, for: card)
        XCTAssertTrue(model.importHistory.isEmpty, "Rejected input must not be recorded as a dispatched import")
    }
}
