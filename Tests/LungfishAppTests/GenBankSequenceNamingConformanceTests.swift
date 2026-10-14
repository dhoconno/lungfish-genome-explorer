// GenBankSequenceNamingConformanceTests.swift - How a GenBank record bundle names its one sequence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Phase 2.10 lane A45, BIO's binding test T4 (`A44-M3-BIO.md`) and A44's ruling M3-2 term 4. The
/// browser's nucleotide rows name the one sequence of a record bundle by the accession with its
/// version, the name a VCF's CHROM and the GFF3 rows carry, and list the bare accession and the
/// LOCUS name as aliases, so a file written against the older LOCUS name still resolves. The
/// in-process route keeps the LOCUS name for one release behind the row's hidden key. Each case runs
/// the managed bgzip and samtools faidx on a recorded NCBI response, so the class sits in the
/// conformance tier and skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.
final class GenBankSequenceNamingConformanceTests: XCTestCase {
    private let accession = NCBIDownloadPinFixtures.genBankAccession
    private let bareAccession = "ZZ000001"

    func testAccessionVersionNamingNamesTheSequenceByTheVersionedAccession() async throws {
        let (bundle, root) = try await build(sequenceNaming: .accessionVersion)
        defer { TestTempDirectory.cleanup(root) }

        let chromosomes = try XCTUnwrap(try BundleManifest.load(from: bundle).genome).chromosomes
        XCTAssertEqual(chromosomes.map(\.name), [accession])
        XCTAssertTrue(chromosomes.first?.aliases.contains(bareAccession) ?? false, "\(chromosomes)")
        let fai = try String(
            contentsOf: bundle.appendingPathComponent("genome/sequence.fa.gz.fai"), encoding: .utf8)
        XCTAssertTrue(fai.hasPrefix("\(accession)\t"), fai)
    }

    /// T4. A variant or a track on the bare accession, the name an older bundle of this record
    /// gave its sequence, still maps to the sequence, and the versioned name needs no mapping.
    func testTheBareAccessionStaysAnAliasOfTheVersionedSequence() async throws {
        let (bundle, root) = try await build(sequenceNaming: .accessionVersion)
        defer { TestTempDirectory.cleanup(root) }

        let chromosomes = try XCTUnwrap(try BundleManifest.load(from: bundle).genome).chromosomes
        XCTAssertEqual(mapVCFChromosomes([bareAccession], toBundleChromosomes: chromosomes), [bareAccession: accession])
        XCTAssertEqual(mapVCFChromosomes([accession], toBundleChromosomes: chromosomes), [:])
    }

    /// The track built from the record's FEATURES, when NCBI serves no GFF3 or the row turns it
    /// off, names the sequence the way the FASTA does.
    func testTheFeaturesTrackRowsAreOnTheVersionedName() async throws {
        let (bundle, root) = try await build(sequenceNaming: .accessionVersion, includeGFF3Annotations: false)
        defer { TestTempDirectory.cleanup(root) }

        let database = try AnnotationDatabase(
            url: bundle.appendingPathComponent("annotations/ncbi_genbank_annotations.db"), readWrite: false)
        XCTAssertEqual(database.allChromosomes(), [accession])
    }

    /// Today's name is the default, so the in-process route and the pins of lane A44 keep it.
    func testLocusNamingIsTheDefault() async throws {
        let (bundle, root) = try await build(sequenceNaming: nil)
        defer { TestTempDirectory.cleanup(root) }

        let chromosomes = try XCTUnwrap(try BundleManifest.load(from: bundle).genome).chromosomes
        XCTAssertEqual(chromosomes.map(\.name), [bareAccession])
        XCTAssertTrue(chromosomes.first?.aliases.contains(accession) ?? false, "\(chromosomes)")
    }

    // MARK: - Helpers

    private func build(
        sequenceNaming: GenBankDownloadBundleBuilder.SequenceNaming?,
        includeGFF3Annotations: Bool = true
    ) async throws -> (bundle: URL, root: URL) {
        let client = RecordedNCBIEFetchClient(
            genBank: NCBIDownloadPinFixtures.genBankRecord, gff3: .found(NCBIDownloadPinFixtures.genBankGFF3))
        let builder = GenBankDownloadBundleBuilder(
            ncbiService: NCBIService(apiKey: nil, httpClient: client, environment: [:]))
        do {
            try await builder.validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let root = try TestTempDirectory.make(prefix: "genbank-naming")
        let bundle: URL
        if let sequenceNaming {
            bundle = try await builder.downloadAndBuild(
                accession: accession, outputDirectory: root, includeGFF3Annotations: includeGFF3Annotations,
                sequenceNaming: sequenceNaming)
        } else {
            bundle = try await builder.downloadAndBuild(
                accession: accession, outputDirectory: root, includeGFF3Annotations: includeGFF3Annotations)
        }
        return (bundle, root)
    }
}
