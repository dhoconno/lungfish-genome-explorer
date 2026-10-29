// InspectorFailureReportsTests.swift - The Inspector's failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class InspectorFailureReportsTests: XCTestCase {
    private let raw = "posix_spawn ENOENT /tmp/x.lock"

    func testImportSampleMetadata() {
        assertFailureAlert(
            InspectorFailureReports.importSampleMetadata(rawFailureError()),
            title: "Could not import the sample metadata",
            rawErrorText: raw
        )
    }

    func testImportSampleMetadataKeepsTheDuplicateSampleSentenceInTheBody() {
        let report = InspectorFailureReports.importSampleMetadata(SampleMetadataBundleImportError.duplicateCanonicalIdentity("S1"))
        XCTAssertEqual(report.whatHappened, "Multiple metadata rows resolve to sample S1.")
        XCTAssertEqual(report.nextStep, "Keep one row for that sample in the metadata file, then import it again.")
        XCTAssertEqual(report.details?.contains("Multiple metadata rows"), true)
    }

    func testSaveSampleMetadataNamesTheSample() {
        assertFailureAlert(
            InspectorFailureReports.saveSampleMetadata(sampleName: "S12", rawFailureError()),
            title: "Could not save the metadata for S12",
            rawErrorText: raw
        )
    }

    func testLoadPrimerScheme() {
        assertFailureAlert(InspectorFailureReports.loadPrimerScheme(rawFailureError()), title: "Could not load the primer scheme", rawErrorText: raw)
    }

    func testOpenDeduplicatedBundleNamesWhereItWasCreated() {
        let report = InspectorFailureReports.openDeduplicatedBundle(at: "/tmp/Sample.lungfishref", rawFailureError())
        assertFailureAlert(report, title: "Could not open the new bundle", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.contains("/tmp/Sample.lungfishref"))
    }

    func testReloadAfterAFinishedWorkflowSaysTheWorkFinished() {
        let cases: [(FailureReport, String)] = [
            (InspectorFailureReports.reloadBundleAfterDerivedAlignmentRemoval(inMappingViewer: false, rawFailureError()), "The derived alignment was removed"),
            (InspectorFailureReports.reloadBundleAfterMappedReadsAnnotation(trackName: "reads", inMappingViewer: false, rawFailureError()), "The annotation track \"reads\" was created"),
            (InspectorFailureReports.reloadBundleAfterFilteredAlignment(trackName: "filtered", inMappingViewer: false, rawFailureError()), "The filtered alignment track \"filtered\" was created"),
            (InspectorFailureReports.reloadBundleAfterPrimerTrim(rawFailureError()), "The primer trim finished"),
            (InspectorFailureReports.reloadBundleAfterDuplicateMarking(rawFailureError()), "Duplicate marking finished"),
            (InspectorFailureReports.reloadBundleAfterVariantCalling(finished: "GATK completed", inMappingViewer: false, rawFailureError()), "GATK completed"),
        ]
        for (report, finished) in cases {
            assertFailureAlert(report, title: "Could not reload the bundle", rawErrorText: raw)
            XCTAssertTrue(report.whatHappened.hasPrefix(finished), "\(report.whatHappened) starts with \(finished)")
            XCTAssertTrue(report.nextStep.contains("Select the bundle in the sidebar"))
        }
    }

    func testReloadInTheMappingViewerNamesTheMappingViewer() {
        let report = InspectorFailureReports.reloadBundleAfterVariantCalling(
            finished: "Variant calling completed", inMappingViewer: true, rawFailureError()
        )
        assertFailureAlert(report, title: "Could not reload the mapping viewer", rawErrorText: raw)
    }
}
