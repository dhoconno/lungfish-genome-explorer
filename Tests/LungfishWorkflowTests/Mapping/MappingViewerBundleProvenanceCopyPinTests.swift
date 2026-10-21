// MappingViewerBundleProvenanceCopyPinTests.swift - The mapping result record a publication copies
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, scope row B3. `MappingViewerBundlePublicationService.publish` reads the mapping
// result's canonical record, refreshes its descriptors and appends the publication step
// (`rewriteCanonicalProvenance`, line 910). The fixture is the finalizer tests', so this extension sits
// beside them and reuses it. The pin sends each of the three sources of `EnvelopeCopySources` through
// the publication and checks what the rewritten record holds.

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

extension MappingViewerBundleProvenanceFinalizerTests {
    func testPublishKeepsTheStatusOfACancelledMappingRecord() throws {
        try assertPublishCopiesFaithfully(.cancelled)
    }

    func testPublishKeepsTheStatusOfAFailedMappingRecordWhoseLastStepExitedZero() throws {
        try assertPublishCopiesFaithfully(.failedLastStepExitedZero)
    }

    func testPublishKeepsTheReadSetPlanOfAPreTwoFourMappingRecord() throws {
        try assertPublishCopiesFaithfully(.preTwoFourNestedPlan)
    }

    private func assertPublishCopiesFaithfully(_ kind: EnvelopeCopySources.Kind) throws {
        let fixture = try makeFixture()
        let canonical = fixture.resultDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try EnvelopeCopySources.rewriteSidecar(at: canonical, as: kind)
        let source = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: canonical))

        try MappingViewerBundlePublicationService.publish(
            result: fixture.preparedResult,
            resultDirectoryURL: fixture.resultDirectory,
            sourceReferenceBundleURL: fixture.sourceBundle,
            viewerBundleURL: fixture.viewerBundle
        )

        let copy = try EnvelopeCopySources.capture(
            site: "mapping-publish", kind: kind, sidecar: canonical, projectRoot: tempDirectory
        )
        EnvelopeCopySources.assertFaithfulCopy(
            site: "MappingViewerBundlePublicationService:910", kind: kind, copy: copy,
            keeping: source
        )
        XCTAssertEqual(copy.id, source.id, "the publication extends the mapping run's record")
        XCTAssertEqual(copy.steps.count, source.steps.count + 1)
        XCTAssertEqual(copy.steps.last?.toolName, LungfishAppIdentity.recordedToolName)
    }
}
