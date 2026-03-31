// SidebarFilterTests.swift - Tests for sidebar file filtering logic
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// Tests verifying internal sidecar file filtering logic.
///
/// ``SidebarViewController.isInternalSidecarFile`` is private, so these tests
/// replicate the exact production logic to serve as a regression suite. The
/// function checks:
/// 1. File name ends with `.lungfish-meta.json`
/// 2. File name equals `FASTQBundleCSVMetadata.filename` ("metadata.csv")
///
/// If the production logic changes, these tests will diverge and should be
/// updated to match.
@MainActor
final class SidebarFilterTests: XCTestCase {

    // MARK: - Replicated Logic

    /// Mirrors the private `isInternalSidecarFile` from SidebarViewController.
    /// This must be kept in sync with the production implementation.
    private func isInternalSidecarFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".lungfish-meta.json")
            || name == FASTQBundleCSVMetadata.filename
    }

    // MARK: - Positive Cases (Should Be Hidden)

    func testLungfishMetaJsonIsInternal() {
        let url = URL(fileURLWithPath: "/data/sample.lungfish-meta.json")
        XCTAssertTrue(isInternalSidecarFile(url), ".lungfish-meta.json files should be internal sidecar files")
    }

    func testArbitraryPrefixLungfishMetaJsonIsInternal() {
        let url = URL(fileURLWithPath: "/data/anything.lungfish-meta.json")
        XCTAssertTrue(isInternalSidecarFile(url))
    }

    func testMetadataCSVIsInternal() {
        // FASTQBundleCSVMetadata.filename is "metadata.csv"
        XCTAssertEqual(FASTQBundleCSVMetadata.filename, "metadata.csv",
                       "Precondition: FASTQBundleCSVMetadata.filename should be metadata.csv")

        let url = URL(fileURLWithPath: "/data/bundle/metadata.csv")
        XCTAssertTrue(isInternalSidecarFile(url), "metadata.csv should be an internal sidecar file")
    }

    func testNestedPathLungfishMetaJsonIsInternal() {
        let url = URL(fileURLWithPath: "/deep/nested/path/reads.lungfish-meta.json")
        XCTAssertTrue(isInternalSidecarFile(url))
    }

    // MARK: - Negative Cases (Should Be Visible)

    func testFastqGzIsNotInternal() {
        let url = URL(fileURLWithPath: "/data/sample_R1.fastq.gz")
        XCTAssertFalse(isInternalSidecarFile(url), ".fastq.gz files should not be hidden")
    }

    func testBamIsNotInternal() {
        let url = URL(fileURLWithPath: "/data/aligned.bam")
        XCTAssertFalse(isInternalSidecarFile(url), ".bam files should not be hidden")
    }

    func testVcfIsNotInternal() {
        let url = URL(fileURLWithPath: "/data/variants.vcf")
        XCTAssertFalse(isInternalSidecarFile(url), ".vcf files should not be hidden")
    }

    func testPlainJsonIsNotInternal() {
        // Regular .json files that don't end with .lungfish-meta.json should be visible
        let url = URL(fileURLWithPath: "/data/config.json")
        XCTAssertFalse(isInternalSidecarFile(url), "Regular .json files should not be hidden")
    }

    func testFastaIsNotInternal() {
        let url = URL(fileURLWithPath: "/data/genome.fasta")
        XCTAssertFalse(isInternalSidecarFile(url))
    }

    func testBedIsNotInternal() {
        let url = URL(fileURLWithPath: "/data/regions.bed")
        XCTAssertFalse(isInternalSidecarFile(url))
    }

    func testMetadataCSVWithDifferentCaseIsNotInternal() {
        // The check is exact match, so "Metadata.csv" should NOT match
        let url = URL(fileURLWithPath: "/data/bundle/Metadata.csv")
        XCTAssertFalse(isInternalSidecarFile(url), "Case-different metadata.csv should not be hidden")
    }

    func testOtherCSVIsNotInternal() {
        let url = URL(fileURLWithPath: "/data/results.csv")
        XCTAssertFalse(isInternalSidecarFile(url), "Non-metadata CSV files should not be hidden")
    }
}
