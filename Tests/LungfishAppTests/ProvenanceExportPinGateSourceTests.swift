// ProvenanceExportPinGateSourceTests.swift - Both GUI export paths show the pin sheet before their save panel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P5b, plan decision S7. File > Export > Provenance and the
// Inspector's export menu each need a window to show a sheet, and the screen may
// be locked when this runs. The decision itself is tested through
// `ProvenanceExportPinGatePresenter.decide` in ProvenanceExportPinGatePresenterTests.
// These tests read the order of the calls from each path's source.

import XCTest
import LungfishTestSupport

final class ProvenanceExportPinGateSourceTests: XCTestCase {
    /// The two paths, each as the file, the function the menu calls and the function that opens the save panel.
    private static let paths: [(file: String, entry: String, savePanel: String)] = [
        ("Sources/LungfishApp/App/AppDelegate+ImportExport.swift",
         "private func presentProvenanceExportSheet(", "private func presentProvenanceSavePanel("),
        ("Sources/LungfishApp/Views/Inspector/InspectorViewController+Notifications.swift",
         "func presentProvenanceExport(format: ProvenanceExportFormat)", "private func presentProvenanceSavePanel("),
    ]

    func testEachPathOpensItsSavePanelOnlyFromThePinSheetsContinuation() throws {
        for path in Self.paths {
            let source = try readRepositorySource(ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent(path.file))
            let entry = try XCTUnwrap(Self.body(of: path.entry, in: source), path.file)
            let savePanel = try XCTUnwrap(Self.body(of: path.savePanel, in: source), path.file)

            // The menu's function asks the presenter and opens no panel itself.
            let present = try XCTUnwrap(entry.range(of: "ProvenanceExportPinGatePresenter.present("), path.file)
            XCTAssertNil(entry.range(of: "beginSheetModal"), path.file)
            // The save panel opens from the presenter's continuation, the only call of the panel's function.
            let call = try XCTUnwrap(entry.range(of: "presentProvenanceSavePanel(request, allowUnpinned: allowUnpinned"), path.file)
            XCTAssertLessThan(present.lowerBound, call.lowerBound, path.file)
            XCTAssertEqual(source.components(separatedBy: "presentProvenanceSavePanel(").count, 3, path.file)
            // The panel's function writes with the override the sheet returned.
            XCTAssertNotNil(savePanel.range(of: "savePanel.beginSheetModal("), path.file)
            XCTAssertNotNil(savePanel.range(of: "request.write(to: outputDirectory, allowUnpinned: allowUnpinned"), path.file)
            XCTAssertNil(source.range(of: "ProvenanceExporter().exportBundle("), path.file)
        }
    }

    /// The text of the function that starts with `signature`, up to the next declaration at its indent.
    private static func body(of signature: String, in source: String) -> Substring? {
        guard let start = source.range(of: signature) else { return nil }
        let rest = source[start.upperBound...]
        let next = ["\n    func ", "\n    private func ", "\n    public func ", "\n    @objc func ", "\n}"]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min() ?? rest.endIndex
        return source[start.lowerBound..<next]
    }
}
