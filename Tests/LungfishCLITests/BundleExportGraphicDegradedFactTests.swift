// BundleExportGraphicDegradedFactTests.swift - Each degraded fact of bundle export-graphic reaches the record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 fix, BIO review Fix 2 and QA review Fix 4 (BIOR 7). One fixture for each kind of limit a unit
// fixture can reach. The alignment kinds, `readRowCap` and `readSample`, are in `ViewerGraphicsExportAlignmentReplayTests`
// since they need a BAM.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class BundleExportGraphicDegradedFactTests: XCTestCase {
    private typealias Words = BundleExportGraphicRowWordsTests

    private var scratch: URL!
    private var folder: URL!
    private var bundle: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "BundleExportGraphicDegradedFact")
        // Four levels below the scratch folder, so the provenance lookup never lists the user temp folder (QA review Fix 3).
        folder = scratch.appendingPathComponent("levels/deep/run/case", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bundle = try BundleExportGraphicCommandTests.makeBundle(in: folder)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// A sequence track at a block scale (`scaleMode`), a gene whose label does not fit (`labelsOmitted` with a count), a
    /// variant track cut to one of its two sample rows (`annotationLimit` with a count) and a signal track with no builder
    /// (`trackNotDrawn`). The record holds the track, the kind, the reason and the count of each, and standard error
    /// and the event stream carry one line for each, a warning when data is left out and a note when it is not.
    func testExportGraphicRecordsEachDegradedFact() async throws {
        // 34 points hold the summary bar (20), its gap (2) and one 12 point sample row of the two.
        let viewState = folder.appendingPathComponent("view-state.json")
        try ViewerGraphicViewState(tracks: [.init(id: "calls", height: 34)]).encoded().write(to: viewState)
        let output = folder.appendingPathComponent("facts.png")
        let said = try await Words.said(
            [bundle.path, "--region", "chr1:1-3000", "--width", "250", "--track", "sequence", "--track", "genes",
             "--track", "calls", "--track", "signal", "--view-state", viewState.path, "--output-format", "png",
             "-o", output.path],
            in: folder
        )
        let facts = try Words.degraded(of: output)
        let expected: [(track: String, kind: String, count: Int?, warns: Bool)] = [
            ("sequence", "scaleMode", 3000, false), // the count is the bases drawn as blocks
            ("genes", "labelsOmitted", 1, false),
            ("calls", "annotationLimit", 1, true),
            ("signal", "trackNotDrawn", nil, true),
        ]
        XCTAssertEqual(
            Set(facts.map { "\($0["trackID"]?.stringValue ?? "").\($0["kind"]?.stringValue ?? "")" }),
            Set(expected.map { "\($0.track).\($0.kind)" }), "\(facts)"
        )
        for item in expected {
            let fact = try XCTUnwrap(
                facts.first { $0["trackID"] == .string(item.track) && $0["kind"] == .string(item.kind) }, item.kind
            )
            XCTAssertEqual(
                Set(fact.keys), Set(item.count == nil ? ["trackID", "kind", "reason"] : ["trackID", "kind", "reason", "count"]),
                item.kind
            )
            XCTAssertFalse(fact["reason"]?.stringValue?.isEmpty ?? true, item.kind)
            XCTAssertEqual(fact["count"], item.count.map { ParameterValue.integer($0) }, item.kind)
        }

        let warns = expected.filter(\.warns).count
        XCTAssertEqual(said.logs.filter { $0.level == "warning" }.count, warns, "\(said.logs)")
        XCTAssertEqual(said.logs.filter { $0.level == "info" }.count, expected.count - warns, "\(said.logs)")
        XCTAssertEqual(said.standardError.filter { $0.hasPrefix("Warning: ") }.count, warns, "\(said.standardError)")
        XCTAssertEqual(said.standardError.filter { $0.hasPrefix("Note: ") }.count, expected.count - warns, "\(said.standardError)")
        XCTAssertTrue(
            said.standardError.contains(
                "Warning: The calls track stopped at a limit (sample rows past the track height of 34 points, 1 left out)."
            ), "\(said.standardError)"
        )
        XCTAssertTrue(
            said.standardError.contains("Warning: The signal track was not drawn in full (no figure builder)."),
            "\(said.standardError)"
        )
        XCTAssertTrue(
            said.standardError.contains { $0.hasPrefix("Note: The genes track left out labels (") }, "\(said.standardError)"
        )
        XCTAssertTrue(
            said.standardError.contains {
                $0.hasPrefix("Note: The sequence track drew a summary at this zoom (bases drawn as blocks")
            }, "\(said.standardError)"
        )

        // A font that fell back is one fact however many times the figure used it, and it is a note.
        let fallback = ViewerFigureFontResolution(requested: "LungfishNoSuchFace-Regular", resolved: "Menlo-Regular", size: 9)
        let scene = ViewerFigureScene(
            width: 10, height: 10, appearance: .light, background: ViewerFigurePaint(.textBackground), frame: nil,
            fonts: [fallback, fallback], items: []
        )
        let fontFacts = ViewerGraphicExport.degradedFacts(of: scene)
        XCTAssertEqual(fontFacts.count, 1, "\(fontFacts)")
        XCTAssertEqual(fontFacts.first?.trackID, "figure")
        XCTAssertEqual(fontFacts.first?.kind, .fontFallback)
        XCTAssertNil(fontFacts.first?.count)
        XCTAssertTrue(
            fontFacts.first?.reason.hasPrefix("LungfishNoSuchFace-Regular fell back to Menlo-Regular at 9") ?? false,
            "\(fontFacts)"
        )
        XCTAssertTrue(
            BundleExportGraphicRecord.warning(fontFacts[0]).hasPrefix("The figure used another font (LungfishNoSuchFace-Regular fell back"),
            BundleExportGraphicRecord.warning(fontFacts[0])
        )
    }
}
