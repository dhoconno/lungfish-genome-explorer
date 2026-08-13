// AlignmentConsensusScopeTests.swift - Explicit alignment consensus scope tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class AlignmentConsensusScopeTests: XCTestCase {
    func testWholeContigResolvesTheActiveContigOnly() throws {
        let context = try makeContext()

        XCTAssertEqual(
            try AlignmentConsensusScope.wholeContig.resolve(in: context, selection: nil),
            .init(scope: .wholeContig, contig: "chrSynthetic", start: 0, end: 40)
        )
    }

    func testSelectedRegionRequiresAnExplicitSelectionAndNeverFallsBack() throws {
        let context = try makeContext()

        XCTAssertEqual(
            try AlignmentConsensusScope.selectedRegion.resolve(
                in: context,
                selection: .init(contig: "chrSynthetic", start: 4, end: 9)
            ),
            .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9)
        )
        XCTAssertThrowsError(try AlignmentConsensusScope.selectedRegion.resolve(in: context, selection: nil)) {
            XCTAssertEqual(
                $0 as? AlignmentConsensusScopeError,
                .selectionRequired("Select a region in the viewer first")
            )
        }
    }

    func testSelectedRegionClampsOnlyTheExplicitSelection() throws {
        let context = try makeContext()

        XCTAssertEqual(
            try AlignmentConsensusScope.selectedRegion.resolve(
                in: context,
                selection: .init(contig: "chrSynthetic", start: -4, end: 44)
            ),
            .init(scope: .selectedRegion, contig: "chrSynthetic", start: 0, end: 40)
        )
    }

    func testSelectedRegionRejectsACrossContigSelection() throws {
        let context = try makeContext()

        XCTAssertThrowsError(try AlignmentConsensusScope.selectedRegion.resolve(
            in: context,
            selection: .init(contig: "other", start: 4, end: 9)
        )) {
            XCTAssertEqual(
                $0 as? AlignmentConsensusScopeError,
                .crossContigSelection(expected: "chrSynthetic", actual: "other")
            )
        }
    }

    func testChangingEvidenceIdentityClearsSelectionButRetainsScopePreference() throws {
        let controller = ViewerViewController()
        _ = controller.view
        controller.alignmentConsensusScope = .selectedRegion
        controller.alignmentActionContext = try makeContext()
        controller.explicitAlignmentSelection = .init(contig: "chrSynthetic", start: 4, end: 9)
        controller.viewerView.testSetSelectedReadIDs([UUID()])

        controller.alignmentActionContext = try makeContext(resultID: "run-2")

        XCTAssertEqual(controller.alignmentConsensusScope, .selectedRegion)
        XCTAssertNil(controller.explicitAlignmentSelection)
        XCTAssertTrue(controller.viewerView.testSelectedReadIDs.isEmpty)
    }

    private func makeContext(resultID: String = "run-1") throws -> AlignmentActionContext {
        let bamURL = URL(fileURLWithPath: "/tmp/reads.bam")
        let baiURL = URL(fileURLWithPath: "/tmp/reads.bam.bai")
        return try AlignmentActionContext(
            identity: .init(workflow: "EsViritu", resultID: resultID, sampleID: "sample-1", evidenceID: "chrSynthetic"),
            alignmentURL: bamURL,
            indexURL: baiURL,
            decodingReferenceURL: nil,
            contig: "chrSynthetic",
            contigLength: 40,
            alignmentSnapshot: .init(url: bamURL, byteCount: 512, sha256: "abc"),
            indexSnapshot: .init(url: baiURL, byteCount: 96, sha256: "def"),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12,
                           excludedFlags: 0x904, readGroups: []),
            outputCapability: .userSelectedDestination,
            sourceReads: .bamFallback,
            presentationLabel: "sample-1 chrSynthetic"
        )
    }
}
