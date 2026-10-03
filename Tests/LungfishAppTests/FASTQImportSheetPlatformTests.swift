// FASTQImportSheetPlatformTests.swift - The Import FASTQ sheet's Platform popup preselection and evidence line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport

/// The sheet preselects the platform with the same detector
/// `import fastq --platform auto` uses and shows the evidence. Before owner
/// decision 3 it read the first header with a different detector, preselected
/// Unknown for runid-only nanopore headers and showed no evidence.
final class FASTQImportSheetPlatformTests: XCTestCase {

    private func pair(_ fixture: String) -> FASTQFilePair {
        FASTQFilePair(r1: PlatformHeaderFixtures.url(fixture), r2: nil)
    }

    func testDoradoReadsPreselectNanoporeWithTheEvidence() {
        let summary = FASTQImportConfigSheet.platformDetectionSummary(
            pairs: [pair("ont-dorado-samtags-tab.fastq")], fallback: .unknown
        )
        XCTAssertEqual(summary.platform, .oxfordNanopore)
        XCTAssertFalse(summary.perSample)
        XCTAssertEqual(summary.line, "Detected from read headers: dorado SAM tags in 4 of 4 sampled reads (high confidence).")
    }

    func testSamplesOfDifferentPlatformsAreDetectedPerSample() {
        let summary = FASTQImportConfigSheet.platformDetectionSummary(
            pairs: [pair("ont-minknow-full.fastq"), pair("illumina-novaseq6000.fastq")], fallback: .unknown
        )
        XCTAssertTrue(summary.perSample)
        XCTAssertTrue(summary.line.hasPrefix("Detected per sample:"), summary.line)
    }

    func testUnrecognisedReadsPreselectUnknownAndSaySo() {
        let summary = FASTQImportConfigSheet.platformDetectionSummary(
            pairs: [pair("sra-renamed-short.fastq")], fallback: .unknown
        )
        XCTAssertEqual(summary.platform, .unknown)
        XCTAssertTrue(summary.line.hasPrefix("Not detected."), summary.line)
    }

    func testRunsNotYetDownloadedKeepTheArchivePlatform() {
        let placeholder = FASTQFilePair(r1: URL(fileURLWithPath: "/SRR000001_1.fastq.gz"), r2: nil)
        let summary = FASTQImportConfigSheet.platformDetectionSummary(pairs: [placeholder], fallback: .pacbio)
        XCTAssertEqual(summary.platform, .pacbio)
        XCTAssertEqual(summary.line, "Platform from the archive record: PacBio.")
    }

    func testThePopupListsEveryPlatformInOrder() {
        XCTAssertEqual(
            FASTQImportConfigSheet.platformChoices.map(\.platform),
            [.illumina, .oxfordNanopore, .pacbio, .element, .ultima, .mgi, .unknown]
        )
    }
}
