import AppKit
import XCTest
import SwiftUI
@testable import LungfishApp

final class PrimerBindingInspectionTests: XCTestCase {
    func testReversePrimerComparisonUsesReverseComplement() {
        let result = compare(row: "ACGG", primer: "CCGT", strand: "-")
        XCTAssertEqual(result.mismatchCount, 0)
        XCTAssertEqual(compare(row: "ACGG", primer: "CCGT", strand: "+").mismatchCount, 2)
    }

    func testMismatchPositionsUseDisplayedReferenceOrientation() {
        XCTAssertEqual(compare(row: "ACGG", primer: "CCGT").mismatchPositions, [0, 3])
        // Reverse complement of ACGG is CCGT: a mismatch at primer offset zero is site offset three.
        XCTAssertEqual(compare(row: "ACGG", primer: "ACGT", strand: "-").mismatchPositions, [3])
        XCTAssertEqual(compare(row: "ACGG", primer: "CCGA", strand: "-").mismatchPositions, [0])
        XCTAssertTrue(compare(row: "ANGG", primer: "ACGT", strand: "-").mismatchPositions.isEmpty)
    }

    func testDisplayHeaderRejectsControlAndNewlineInjection() {
        XCTAssertTrue(PrimerBindingInspectionContext.isSafeDisplayHeader("MHC row with spaces"))
        for header in ["row\n>injected", "row\rsequence", "row\tname", "row\u{2028}>injected", "row\u{0}name", " "] {
            XCTAssertFalse(PrimerBindingInspectionContext.isSafeDisplayHeader(header))
        }
    }

    func testPrimerDegeneracyIsCompatibleButTargetAmbiguityRemainsUnknown() {
        XCTAssertEqual(compare(row: "ACGT", primer: "AYGT").mismatchCount, 0)
        XCTAssertNil(compare(row: "AYGT", primer: "ACGT").mismatchCount)
        XCTAssertTrue(compare(row: "AYGT", primer: "ACGT").status.contains("ambiguous"))
    }

    func testInternalGapsAndTerminalMissingnessAreDistinct() {
        let internalGap = compare(row: "A-GT", primer: "ACGT")
        let missingEnd = compare(row: "--GT", primer: "ACGT")
        XCTAssertNil(internalGap.mismatchCount)
        XCTAssertNil(missingEnd.mismatchCount)
        XCTAssertTrue(internalGap.status.contains("internal"))
        XCTAssertTrue(missingEnd.status.contains("uncovered"))
    }

    func testNoncontiguousReferenceAndLengthDisagreementsRemainUnavailable() {
        let result = PrimerBindingInspectionContext.compare(id: 0, name: "row", row: Array("AACGT"),
            lower: 0, upper: 5, primer: "ACGT", strand: "+", contiguousReference: false)
        XCTAssertNil(result.mismatchCount)
        XCTAssertTrue(result.status.contains("reference mapping"))
    }

    func testSelectedPrimerComparisonPreservesEveryRowWithoutStoredCrossProduct() throws {
        let first = PrimerBindingInspectionPrimer(id: "first", name: "first", sequence: "AC", strand: "+",
            alignedStart: 0, alignedEnd: 2, contiguousReference: true)
        let second = PrimerBindingInspectionPrimer(id: "second", name: "second", sequence: "TT", strand: "+",
            alignedStart: 2, alignedEnd: 4, contiguousReference: true)
        let rows = (0..<2000).map { PrimerBindingInspectionContext.Row(name: "row-\($0)", sequence: Array("ACGT")) }
        let context = PrimerBindingInspectionContext(id: "context", title: "synthetic", alignedFASTA: "",
            annotations: [], primers: [first, second], unavailableReason: nil, rows: rows)
        let comparisons = try context.comparisons(for: second)
        XCTAssertEqual(comparisons.count, 2000)
        XCTAssertEqual(comparisons.last?.rowName, "row-1999")
        XCTAssertTrue(comparisons.allSatisfy { $0.mismatchCount == 1 && $0.alignedSite == "GT" })
    }

    @MainActor
    func testReadOnlyCanvasHasNoMutableBundleIdentity() throws {
        let controller = MultipleSequenceAlignmentViewController()
        try controller.displayReadOnlyAlignment(fasta: ">reference\nACGT\n>other\nATGT\n", annotations: [])
        XCTAssertNil(controller.bundleURL)
        XCTAssertNil(controller.onAddAnnotationRequested)
        XCTAssertNil(controller.onProjectAnnotationRequested)
    }

    @MainActor
    func testStoredNativeAlignmentInspectionAndOptionalRender() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_BINDING_BUNDLE"] else {
            throw XCTSkip("Set LUNGFISH_PRIMER_BINDING_BUNDLE to inspect a stored native MHC analysis")
        }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: URL(fileURLWithPath: path))
        let contexts = try PrimerBindingInspectionContext.load(bundle: snapshot.bundle, schemes: snapshot.primalSchemeResults)
        XCTAssertFalse(contexts.isEmpty)
        XCTAssertTrue(contexts.allSatisfy { $0.unavailableReason == nil })
        XCTAssertTrue(contexts.contains { !$0.primers.isEmpty && !$0.annotations.isEmpty })
        for context in contexts {
            if let first = context.primers.first {
                XCTAssertEqual(try context.comparisons(for: first).count, context.rows.count)
            }
        }
        if let output = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] {
            let bundleURL = URL(fileURLWithPath: path)
            let model = PrimerAnalysisViewerModel()
            await model.load(from: bundleURL)
            guard case .loaded = model.state else { return XCTFail("Native binding render did not load") }
            let host = NSHostingView(rootView: PrimerAnalysisViewerView(bundleURL: bundleURL, model: model, selectedSection: .binding))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("primer-binding-native.png"))
            window.close()
        }
    }

    private func compare(row: String, primer: String, strand: String = "+") -> PrimerBindingRowComparison {
        PrimerBindingInspectionContext.compare(id: 0, name: "row", row: Array(row), lower: 0,
            upper: row.count, primer: primer, strand: strand, contiguousReference: true)
    }
}
