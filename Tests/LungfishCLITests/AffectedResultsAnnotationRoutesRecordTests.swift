// AffectedResultsAnnotationRoutesRecordTests.swift - The kinds of the annotation S1 rows, held against records their writers made
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO
import LungfishTestSupport

/// Lane AFFECTED-ANNOT (AFFECTED-WORDS-17 item 2). `extract sequence --bundle` and the annotation import write their own
/// records, and `AffectedResults.kind(of:)` reads them by their root name and keys. These tests run the writers, so
/// they sit in the conformance tier beside `ExtractSequenceBundleConformanceTests` and skip without the managed bgzip and
/// samtools unless `LUNGFISH_REQUIRE_TOOLS=1`.
final class AffectedResultsAnnotationRoutesRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "affected-annotation-routes")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func requireTools() async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            if ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1" { throw error }
            throw XCTSkip("The managed bgzip and samtools are not installed: \(error)")
        }
    }

    private func rootRecord(of bundle: URL) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self, from: Data(contentsOf: bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
    }

    private func extract(_ arguments: [String], from source: URL, to name: String) async throws -> ProvenanceEnvelope {
        let output = root.appendingPathComponent("Extractions/\(name).lungfishref", isDirectory: true)
        let command = try ExtractSequenceSubcommand.parse([source.path] + arguments + ["--output", output.path, "--quiet"])
        try await command.run()
        return try rootRecord(of: output)
    }

    func testTheRecordsOfExtractSequenceBundleNameTheExtractionKindAndTheNarrowerKindOfAJoinedPart() async throws {
        try await requireTools()
        let source = try await ExtractSequenceBundleConformanceTests.makeSourceBundle(in: root)

        let region = try await extract(["chr1:11-40", "--bundle"], from: source, to: "Region_1")
        XCTAssertEqual(region.workflowName, AffectedResults.RecordName.extractSequence)
        XCTAssertEqual(AffectedResults.kind(of: region), .sequenceExtractionBundle)
        XCTAssertEqual(AffectedResults.narrowerKinds(of: region, beside: .sequenceExtractionBundle), [])

        let onePart = try await extract(
            ["chr1:11-40", "--bundle", "--feature-name=geneA", "--feature-type", "gene", "--concatenate-exons"],
            from: source, to: "Gene_1"
        )
        XCTAssertEqual(AffectedResults.kind(of: onePart), .sequenceExtractionBundle)
        XCTAssertEqual(
            AffectedResults.narrowerKinds(of: onePart, beside: .sequenceExtractionBundle), [.sequenceExtractionJoinedExons],
            "exons joined and one part"
        )

        let twoParts = try await extract(
            ["chr1:3-6,11-14", "--bundle", "--feature-name=cdsA", "--feature-type", "CDS", "--strand", "-",
             "--concatenate-exons", "--reverse-complement"],
            from: source, to: "CDS_1"
        )
        XCTAssertEqual(AffectedResults.kind(of: twoParts), .sequenceExtractionBundle)
        XCTAssertEqual(
            AffectedResults.narrowerKinds(of: twoParts, beside: .sequenceExtractionBundle), [],
            "the command lists two parts, so the old GTF read is not the cause"
        )
    }

    func testTheRecordOfAnAttachedGFF3TrackNamesTheImportKindAndABEDTrackNamesNone() async throws {
        try await requireTools()
        let source = try await ExtractSequenceBundleConformanceTests.makeSourceBundle(in: root)
        let service = ReferenceBundleAnnotationImportService(
            toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind
        )

        let gff = root.appendingPathComponent("two-genes.gff3")
        try """
        ##gff-version 3
        chr1\tRefSeq\tgene\t2\t8\t.\t+\t.\tID=geneA;Name=Gene A
        chr1\tRefSeq\tgene\t2\t8\t.\t+\t.\tID=geneB;Name=Gene A

        """.write(to: gff, atomically: true, encoding: .utf8)
        _ = try await service.attachAnnotationTrack(sourceURL: gff, bundleURL: source)
        let imported = try rootRecord(of: source)
        XCTAssertEqual(imported.workflowName, AffectedResults.RecordName.annotationTrackImport)
        XCTAssertEqual(AffectedResults.kind(of: imported), .annotationTrackImport)

        let bed = root.appendingPathComponent("primers.bed")
        try "chr1\t1\t12\tprimer\t0\t+\n".write(to: bed, atomically: true, encoding: .utf8)
        _ = try await service.attachAnnotationTrack(sourceURL: bed, bundleURL: source)
        XCTAssertNil(AffectedResults.kind(of: try rootRecord(of: source)), "a BED track is no kind")
    }
}
