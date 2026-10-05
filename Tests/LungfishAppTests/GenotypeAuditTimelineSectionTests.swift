import XCTest
import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAuditTimelineSectionTests: XCTestCase {
    func testRendersEmptyStateWithoutCrash() {
        let view = GenotypeAuditTimelineSection(entries: [])
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    func testRendersMixedEntries() {
        let entries: [GenotypeAnnotationSidecar.AuditEntry] = [
            .init(action: "override", sample: "S1", locus: "MHC-A", slot: .h2,
                  before: "M2A", after: "A1_063", color: nil,
                  reason: "contamination", rationale: "low M2",
                  author: "dho", timestamp: "2026-05-22T16:02:11Z"),
            .init(action: "setSampleStatus", sample: "S2", locus: nil, slot: nil,
                  before: nil, after: "needsReview", color: nil,
                  reason: nil, rationale: nil,
                  author: "dho", timestamp: "2026-05-22T16:05:00Z"),
            .init(action: "setCellHighlight", sample: "S2", locus: "MHC-B", slot: .h1,
                  before: nil, after: nil, color: "#FFEB3B",
                  reason: nil, rationale: nil,
                  author: "dho", timestamp: "2026-05-22T16:06:00Z"),
        ]
        let view = GenotypeAuditTimelineSection(entries: entries)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    /// Ruling U15. Undoing a status command back to "no status" writes a
    /// `clearSampleStatus` entry whose `after` is nil.
    func testClearSampleStatusRowNamesTheChangeAndTheRemovedStatus() {
        let entry = GenotypeAnnotationSidecar.AuditEntry(
            action: "clearSampleStatus", sample: "S2", locus: nil, slot: nil,
            before: "confirmed", after: nil, color: nil,
            reason: nil, rationale: nil,
            author: "dho", timestamp: "2026-10-05T16:05:00Z"
        )

        XCTAssertEqual(GenotypeAuditTimelineSection.displayName(for: entry.action), "Clear status")
        XCTAssertEqual(GenotypeAuditTimelineSection.changeSummary(entry), "confirmed → none")

        let host = NSHostingView(rootView: GenotypeAuditTimelineSection(entries: [entry]))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// Only status rows gain "<before> → none". Other removals keep showing
    /// their rationale, exactly as before ruling U15.
    func testOtherRemovalRowsStillShowTheirRationale() {
        let clearedReview = GenotypeAnnotationSidecar.AuditEntry(
            action: "clearMatrixReview", sample: "S1", locus: "MHC-A", slot: nil,
            before: "falsePositive", after: nil, color: nil,
            reason: "matrix-review", rationale: "cell S1 MHC-A",
            author: "dho", timestamp: "2026-10-05T16:06:00Z"
        )
        let deletedCohort = GenotypeAnnotationSidecar.AuditEntry(
            action: "deleteSmartCohort", sample: "bundle", locus: nil, slot: nil,
            before: "name=Needs review; scope=bundle", after: nil, color: nil,
            reason: "smartCohort", rationale: "Samples that need another look.",
            author: "dho", timestamp: "2026-10-05T16:06:30Z"
        )

        XCTAssertEqual(GenotypeAuditTimelineSection.changeSummary(clearedReview), "cell S1 MHC-A")
        XCTAssertEqual(
            GenotypeAuditTimelineSection.changeSummary(deletedCohort),
            "Samples that need another look."
        )
    }

    func testStatusRowsShowThePriorStatusWhenOneExisted() {
        let replaced = GenotypeAnnotationSidecar.AuditEntry(
            action: "setSampleStatus", sample: "S2", locus: nil, slot: nil,
            before: "reviewed", after: "confirmed", color: nil,
            reason: nil, rationale: nil,
            author: "dho", timestamp: "2026-10-05T16:07:00Z"
        )
        let first = GenotypeAnnotationSidecar.AuditEntry(
            action: "setSampleStatus", sample: "S3", locus: nil, slot: nil,
            before: nil, after: "needsReview", color: nil,
            reason: nil, rationale: nil,
            author: "dho", timestamp: "2026-10-05T16:08:00Z"
        )

        XCTAssertEqual(GenotypeAuditTimelineSection.displayName(for: replaced.action), "Status")
        XCTAssertEqual(GenotypeAuditTimelineSection.changeSummary(replaced), "reviewed → confirmed")
        XCTAssertEqual(GenotypeAuditTimelineSection.changeSummary(first), "→ needsReview")
    }

    func testEntryLimitCapsDisplayedEntries() {
        let entries: [GenotypeAnnotationSidecar.AuditEntry] = (0..<25).map { i in
            .init(action: "override", sample: "S\(i)", locus: "MHC-A", slot: .h1,
                  before: "x", after: "y", color: nil,
                  reason: nil, rationale: nil,
                  author: "u", timestamp: "2026-05-22T10:00:0\(i % 10)Z")
        }
        let view = GenotypeAuditTimelineSection(entries: entries, entryLimit: 5)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        // Smoke test: just confirm no crash; SwiftUI ForEach renders the slice.
        XCTAssertGreaterThan(host.frame.width, 0)
    }
}
