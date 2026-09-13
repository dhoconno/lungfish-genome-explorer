import AppKit
import SwiftUI
import ViewInspector
import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAuditTimelineExpansionTests: XCTestCase {
    func testShowAllAndShowRecentPreserveEveryAuditEntry() throws {
        let entries = (0..<13).map { index in
            GenotypeAnnotationSidecar.AuditEntry(action: "override", sample: "Entry-\(index)", locus: nil, slot: nil,
                before: nil, after: nil, color: nil, reason: nil, rationale: nil, author: "Analyst", timestamp: "2026-09-12T12:00:00Z")
        }
        let host = NSHostingView(rootView: GenotypeAuditTimelineSection(entries: entries))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 1200)
        host.layoutSubtreeIfNeeded()
        XCTAssertThrowsError(try host.rootView.inspect().find(text: "Entry-0"))
        try host.rootView.inspect().find(button: "Show all").tap()
        host.layoutSubtreeIfNeeded()
        XCTAssertNoThrow(try host.rootView.inspect().find(text: "Entry-0"))
        try host.rootView.inspect().find(button: "Show recent").tap()
        host.layoutSubtreeIfNeeded()
        XCTAssertThrowsError(try host.rootView.inspect().find(text: "Entry-0"))
        XCTAssertEqual(host.rootView.entries, entries)
        XCTAssertEqual(host.rootView.entries.count, 13)
    }
}
