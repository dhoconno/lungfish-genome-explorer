import AppKit
import SwiftUI
import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// The primer binding comparison and the saved order's oligos are native
/// tables, so AX clients read every row and cell, not just the rows near the
/// viewport.
@MainActor
final class PrimerTableAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    /// The table's row proxies. AppKit's private proxies answer only the legacy
    /// attribute API, so the role is read from `AXRole`.
    private func tableRows(in table: NSObject) -> [NSObject] {
        AccessibilityTreeProbe.children(of: table).filter {
            ($0.accessibilityAttributeValue(.role) as? String) == NSAccessibility.Role.row.rawValue
        }
    }

    private func texts(in row: NSObject) -> [String] {
        AccessibilityTreeProbe.all(in: row).compactMap { element in
            guard AccessibilityTreeProbe.role(element) == NSAccessibility.Role.staticText.rawValue else { return nil }
            return AccessibilityTreeProbe.value(element) ?? AccessibilityTreeProbe.label(element)
        }
    }

    func testBindingComparisonRowsAreTableRows() throws {
        let primer = PrimerBindingInspectionPrimer(id: "p", name: "p", sequence: "AC", strand: "+",
            alignedStart: 0, alignedEnd: 2, contiguousReference: true)
        let rows = (0..<40).map { PrimerBindingInspectionContext.Row(name: "row-\($0)", sequence: Array($0 % 5 == 0 ? "TT" : "AC")) }
        let context = PrimerBindingInspectionContext(id: "context", title: "synthetic", alignedFASTA: "",
            annotations: [], primers: [primer], unavailableReason: nil, rows: rows)
        let window = AccessibilityTreeProbe.host(
            PrimerBindingComparisonTable(context: context, primer: primer), size: CGSize(width: 640, height: 500)
        )
        windows.append(window)
        AccessibilityTreeProbe.waitUntil(timeout: 8) {
            AccessibilityTreeProbe.element(in: window, identifier: "primerAnalysisViewer.bindingRows") != nil
        }
        let table = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "primerAnalysisViewer.bindingRows"),
            "tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertEqual(tableRows(in: table).count, 40, "all rows, not only the visible ones; tree:\n" + AccessibilityTreeProbe.dump(table))
    }

    func testSavedOrderOligosAreTableRowsWithNamedCells() throws {
        let document = makeDocument(count: 30)
        let window = AccessibilityTreeProbe.host(
            PrimerOrderResultContent(document: document, orderURL: URL(fileURLWithPath: document.outputDirectoryPath)),
            size: CGSize(width: 900, height: 900)
        )
        windows.append(window)
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "primerOrderResult.oligos") != nil
        }
        let table = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "primerOrderResult.oligos"),
            "tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertTrue(
            [NSAccessibility.Role.table.rawValue, NSAccessibility.Role.outline.rawValue].contains(AccessibilityTreeProbe.role(table) ?? ""),
            "a SwiftUI Table reaches AX as a table or an outline"
        )
        XCTAssertEqual(tableRows(in: table).count, 30, "every oligo is a row; tree:\n" + AccessibilityTreeProbe.dump(table))
        let lastRow = try XCTUnwrap(tableRows(in: table).last)
        XCTAssertTrue(texts(in: lastRow).contains("oligo_30"), "cells read as text: \(texts(in: lastRow))")
        let pools = AccessibilityTreeProbe.all(in: window).filter { (AccessibilityTreeProbe.label($0) ?? "").hasSuffix("oligos") }
        XCTAssertFalse(pools.isEmpty, "pool summaries stay in the tree")
    }

    private func makeDocument(count: Int) -> PrimerOrderDocument {
        let url = URL(fileURLWithPath: "/Project/Analyses/Saved design.lungfishprimeranalysis")
        let artifact = PrimerAnalysisArtifact(relativePath: "provenance.json", role: "provenance",
            format: "json", sha256: String(repeating: "0", count: 64), byteSize: 0)
        let manifest = PrimerAnalysisManifest(analysisID: UUID(), runID: UUID(), inputs: [], results: [],
            artifacts: [], provenance: artifact, grouping: .independent, publishedRootPath: url.path)
        let oligos = (1...count).map { index in
            PrimerOrderOligo(primerID: "primer-\(index)", targetID: "target-\(index % 2)",
                sourceResultID: "scheme-\(index % 2)", schemeLabel: "Scheme \(index % 2 + 1)",
                poolName: "Scheme \(index % 2 + 1) · Pool 1", pool: 1, referenceID: "reference-\(index % 2)",
                name: "oligo_\(index)", sequence: "ACGTACGTACGTACGTACGT", start: 0, end: 20,
                strand: index % 2 == 0 ? "+" : "-", ampliconIDs: ["amplicon-\(index)"], compatibility: nil)
        }
        let selection = PrimerOrderSelection(capturedAt: Date(timeIntervalSince1970: 100), analysisURL: url,
            manifest: manifest, settings: .init(), compatibilityReady: false, compatibilitySummaries: [:],
            selectedPrimerIDs: oligos.map(\.primerID))
        return PrimerOrderDocument(schemaVersion: 1, metadata: .init(name: "Reviewed primer order"),
            selection: selection, oligos: oligos, outputDirectoryPath: "/Project/Analyses/Reviewed order",
            templateSHA256: String(repeating: "0", count: 64), sequenceSemantics: "saved-5prime-to-3prime")
    }
}
