// AnnotationTableExportCLIGUIParityReplayTests+BundleCDS.swift - The bundle-wide CDS read of the derived columns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.38 M2 (rows M854 and M863, BIO ruling on M854 items 6 to 11, V1-1 and R-QB2). A region
// selection keeps its bytes and its digest. A new selection names the annotation tracks whose CDS the leaf reads across
// the bundle over the exported rows, and the drawer reads the same CDS for its filter and sort.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

extension AnnotationTableExportCLIGUIParityReplayTests {
    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// BIO ruling on M854 items 8 and 9. A selection with the region chr1 0-120, as the base wrote it, still writes the
    /// selection bytes and the payload pinned at 9a0922e66 with M1's commits, so a replay of a record made by 2.12 or
    /// by 2.13 before M2 regenerates its digest (BIO 6).
    func testRegionSelectionReplaysItsDigest() async throws {
        let root = deepRoot("region-replay")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeDerivedFixture(root)
        let collected = try await Self.collectDerived(Case(tab: .variants, format: .csv, derived: true), in: root)
        XCTAssertEqual(
            collected.table.codingFeatureRegion,
            AnnotationTableFeatureRegion(chromosome: "chr1", start: 0, end: 120, trackIDs: [Self.cdsTrackID])
        )
        let output = Self.outputURL(in: root, .csv)
        let run = try await runC(root, collected, format: .csv, output: output)
        XCTAssertTrue(run.completed, run.detail)
        let selection = URL(fileURLWithPath: try XCTUnwrap(run.invocation.selection))
        let selectionText = try String(contentsOf: selection, encoding: .utf8)
        XCTAssertTrue(selectionText.contains("\"schemaVersion\" : 2"), selectionText)
        XCTAssertEqual(try Self.sha256(selection), "7f37a4ea5ea3fba30faccc3893049a92b4c04a6bf5e1c9caa54e58c81b14709d", "the region selection's bytes\n\(selectionText)")
        let payload = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(try Self.sha256(output), "4f761a94c20ac07e3d441bfbe04cb6fc85306c3d95d36fbb59fed4109e8ea132", "the payload pinned at the base\n\(payload)")
    }
}
