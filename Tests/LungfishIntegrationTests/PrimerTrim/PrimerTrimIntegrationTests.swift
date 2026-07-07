// PrimerTrimIntegrationTests.swift - End-to-end checks against the shipped QIASeqDIRECT-SARS2 bundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Integration coverage that pairs the shipped primer-scheme bundle with the
/// resolver. Complements `BAMPrimerTrimPipelineTests` (which exercises the full
/// ivar+samtools happy path against a separate MT192765.1-anchored fixture
/// that matches the sarscov2 BAM) and the equivalent-accession resolver path.
/// Here we verify the canonical bundle's metadata round-trips through
/// `PrimerSchemeBundle.load` and that `PrimerSchemeResolver` rejects target
/// references that are neither canonical nor equivalent.
final class PrimerTrimIntegrationTests: XCTestCase {
    func testShippedQIASeqBundleLoadsWithExpectedMetadata() throws {
        let bundleURL = TestFixtures.qiaseqDirectSARS2.bundleURL

        let scheme = try PrimerSchemeBundle.load(from: bundleURL)
        XCTAssertEqual(scheme.manifest.name, "QIASeqDIRECT-SARS2")
        XCTAssertEqual(scheme.manifest.canonicalAccession, "MN908947.3")
        XCTAssertEqual(scheme.manifest.equivalentAccessions, ["NC_045512.2"])
        XCTAssertEqual(scheme.manifest.primerCount, 563)
        XCTAssertEqual(scheme.manifest.ampliconCount, 223)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scheme.provenanceURL.path))
        XCTAssertNil(scheme.fastaURL, "QIASeq bundle ships without a FASTA — sequences are derivable from MN908947.3.")
    }

    func testResolverRejectsReferenceNotInBundle() throws {
        let bundleURL = TestFixtures.qiaseqDirectSARS2.bundleURL
        let scheme = try PrimerSchemeBundle.load(from: bundleURL)

        XCTAssertThrowsError(
            try PrimerSchemeResolver.resolve(bundle: scheme, targetReferenceName: "ChromosomeNotInThisPanel")
        ) { error in
            guard case PrimerSchemeResolver.ResolveError.unknownAccession(let bundleName, let requested, let known) = error else {
                XCTFail("expected ResolveError.unknownAccession, got \(error)")
                return
            }
            XCTAssertEqual(bundleName, "QIASeqDIRECT-SARS2")
            XCTAssertEqual(requested, "ChromosomeNotInThisPanel")
            XCTAssertEqual(known, ["MN908947.3", "NC_045512.2"])
        }
    }

    func testResolverAcceptsCanonicalAccession() throws {
        let bundleURL = TestFixtures.qiaseqDirectSARS2.bundleURL
        let scheme = try PrimerSchemeBundle.load(from: bundleURL)

        let resolved = try PrimerSchemeResolver.resolve(bundle: scheme, targetReferenceName: "MN908947.3")
        XCTAssertFalse(resolved.isRewritten, "canonical match should reuse the bundle's BED, not rewrite.")
        XCTAssertEqual(resolved.bedURL, scheme.bedURL)
    }
}
