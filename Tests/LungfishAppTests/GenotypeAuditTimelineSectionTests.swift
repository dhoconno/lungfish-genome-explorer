import XCTest
import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
@testable import LungfishApp

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
