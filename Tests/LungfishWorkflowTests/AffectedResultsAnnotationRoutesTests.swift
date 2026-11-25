// AffectedResultsAnnotationRoutesTests.swift - The affected rows of the annotation S1 fixes and the records that name their kinds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Lane AFFECTED-ANNOT (AFFECTED-WORDS-17). Four rows, each of the annotation S1 fixes before Preview 2026.11.17, and the four
/// kinds that name them: a region bundle (`sequenceExtractionBundle`) and its narrower kind with exons joined
/// (`sequenceExtractionJoinedExons`), a track a GFF3 or GTF import wrote (`annotationTrackImport`), and iVar calls with codon
/// merging off (`variantCallsWithoutCodonMerging`, a narrower `variantCalls`). The records here have the keys the writers give
/// them (`SequenceExtractionPipeline.extractionExplicitOptions`, `ReferenceBundleAnnotationImportService`), and the CLI
/// tests hold the kinds against records the writers made (`AffectedResultsAnnotationRoutesRecordTests`).
final class AffectedResultsAnnotationRoutesTests: XCTestCase {
    private typealias Name = AffectedResults.RecordName
    private let missingTrack = "ANNOT-EXPORT-MISSING-TRACK"
    private let extractDedup = "EXTRACT-SAME-SITE-DEDUP"
    private let importDedup = "ANNOT-IMPORT-SAME-SITE-DEDUP"
    private let gtfSplice = "GTF-SPLICE"

    private func rowNamed(_ id: String) throws -> AffectedResultRow {
        try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == id }, id)
    }

    private func record(
        _ workflow: String, app: String = "Lungfish 2026.11.16 (14223)", explicit: [String: ParameterValue] = [:],
        argv: [String] = [], inputs: [String] = [], steps: [ProvenanceStep] = []
    ) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope.fixture()
        envelope.workflowName = workflow
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: app)
        envelope.options = ProvenanceOptions(explicit: explicit)
        envelope.argv = argv
        envelope.files = inputs.map {
            ProvenanceFileDescriptor(
                path: $0, checksumSHA256: String(repeating: "a", count: 64), fileSize: 12, format: .unknown, role: .input
            )
        }
        envelope.steps = steps
        return envelope
    }

    private func step(_ tool: String, argv: [String]) -> ProvenanceStep {
        ProvenanceStep(
            toolName: tool, toolVersion: "1", argv: argv, inputs: [], outputs: [], exitStatus: 0, wallTimeSeconds: 1,
            stderr: nil, startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func ids(_ envelope: ProvenanceEnvelope, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(for: envelope, kind: kind).map(\.backlogID)
    }

    /// The keys `SequenceExtractionPipeline.extractionExplicitOptions` writes, which both extraction routes record
    /// (`source_bundle` is null for a FASTA input).
    private func extractionOptions(sourceBundle: Bool, joined: Bool) -> [String: ParameterValue] {
        [
            "operation": .string("sequence-extraction"),
            "source_bundle": sourceBundle ? .file(URL(fileURLWithPath: "/p/Source.lungfishref")) : .null,
            "concatenate_exons": .boolean(joined),
        ]
    }

    private func extraction(
        _ workflow: String = Name.extractSequence, app: String = "Lungfish 2026.11.16 (14223)", sourceBundle: Bool = true,
        joined: Bool = false, region: String = "chr1:3-6"
    ) -> ProvenanceEnvelope {
        record(
            workflow, app: app, explicit: extractionOptions(sourceBundle: sourceBundle, joined: joined),
            argv: ["lungfish-cli", "extract", "sequence", "/p/Source.lungfishref", region, "--bundle"]
                + (joined ? ["--concatenate-exons"] : [])
        )
    }

    func testTheFourRowsNameTheirKindsAndBuilds() throws {
        let expected: [(String, [AffectedResultKind], Int?)] = [
            (missingTrack, [.sequenceExtractionBundle, .variantCallsWithoutCodonMerging], nil),
            (extractDedup, [.sequenceExtractionBundle], 256),
            (importDedup, [.annotationTrackImport], 54),
            (gtfSplice, [.sequenceExtractionJoinedExons], nil),
        ]
        for (id, kinds, first) in expected {
            let row = try rowNamed(id)
            XCTAssertEqual(row.kinds, kinds, id)
            XCTAssertEqual(row.firstBuild, first, id)
            XCTAssertEqual(row.lastBuild, 14223, "\(id) ends at Preview 2026.11.16")
            XCTAssertTrue(row.holds(build: 14223), id)
            XCTAssertTrue(row.holds(build: 13927), "\(id) holds Stable 2026.11.14, a patch build")
            XCTAssertFalse(row.holds(build: 14224), "\(id) does not hold the build after Preview 2026.11.16")
        }
        XCTAssertTrue(try rowNamed(extractDedup).holds(build: 256))
        XCTAssertFalse(try rowNamed(extractDedup).holds(build: 255))
        XCTAssertTrue(try rowNamed(importDedup).holds(build: 54))
        XCTAssertFalse(try rowNamed(importDedup).holds(build: 53))
    }

    func testAnExtractionRecordNamesItsKindOnlyWhenItNamesASourceBundle() {
        for root in [Name.extractSequence, Name.guiSequenceExtraction] {
            XCTAssertEqual(AffectedResults.kind(of: extraction(root)), .sequenceExtractionBundle, root)
            XCTAssertNil(
                AffectedResults.kind(of: extraction(root, sourceBundle: false)), "\(root) of a FASTA input carries no tracks"
            )
        }
        // A record whose options hold no `source_bundle` names the bundle in its command.
        let older = record(Name.guiSequenceExtraction, argv: ["lungfish-cli", "sequence", "extract-bundle", "--source-bundle", "/p/S"])
        XCTAssertEqual(AffectedResults.kind(of: older), .sequenceExtractionBundle)
        XCTAssertNil(AffectedResults.kind(of: record(Name.extractSequence, argv: ["lungfish-cli", "extract", "sequence", "a.fa"])))
        XCTAssertEqual(Name.extractSequence, "lungfish extract sequence")
        XCTAssertEqual(Name.guiSequenceExtraction, "lungfish gui sequence extraction")
    }

    func testARegionBundleShowsTheTwoRowsAndTheSpliceRowOnlyForExonsJoinedWithNoSecondPart() {
        XCTAssertEqual(ids(extraction(), .sequenceExtractionBundle), [missingTrack, extractDedup])
        XCTAssertEqual(
            ids(extraction(joined: true), .sequenceExtractionBundle), [missingTrack, extractDedup, gtfSplice],
            "exons joined and one part"
        )
        XCTAssertEqual(
            ids(extraction(joined: true, region: "chr1:3-6,11-14"), .sequenceExtractionBundle), [missingTrack, extractDedup],
            "the command lists two parts, so no GTF row reads it as one"
        )
        // The window's own route names a span and no parts, so a joined run keeps the row and its words say "If".
        let window = record(
            Name.guiSequenceExtraction, explicit: extractionOptions(sourceBundle: true, joined: true),
            argv: ["lungfish-cli", "sequence", "extract-bundle", "--source-bundle", "/p/S", "--chromosome", "chr1", "--start",
                   "2", "--end", "14", "--concatenate-exons"]
        )
        XCTAssertEqual(ids(window, .sequenceExtractionBundle), [missingTrack, extractDedup, gtfSplice])
        XCTAssertEqual(ids(extraction(), .sequenceExtractionJoinedExons), [gtfSplice], "the narrower kind alone names its row")
    }

    func testTheRowsHoldPreview20261116AndStable20261114ButNotPreview20261117() {
        for app in ["Lungfish 2026.11.16 (14223)", "Lungfish 2026.11.15 (14072)", "Lungfish 2026.11.14 (13927)"] {
            XCTAssertEqual(ids(extraction(app: app), .sequenceExtractionBundle), [missingTrack, extractDedup], app)
        }
        XCTAssertEqual(ids(extraction(app: "Lungfish 2026.11.17 (14643)"), .sequenceExtractionBundle), [], "an unpublished build")
        XCTAssertEqual(ids(extraction(app: "Lungfish 2026.11.17 (dev)"), .sequenceExtractionBundle), [], "a dev build")
    }

    func testIVarCallsWithNoAnnotationFileAreTheNarrowerKindAndCallsWithOneAreNot() {
        let samtools = step("samtools", argv: ["/tools/samtools", "mpileup", "-aa"])
        let base = ["/tools/ivar", "variants", "-p", "p", "-q", "20", "-r", "ref.fa"]
        let app = "Lungfish 2026.11.7 (12972)"
        let without = record(Name.variantsCall, app: app, steps: [samtools, step("ivar", argv: base)])
        XCTAssertEqual(AffectedResults.kind(of: without), .variantCalls, "the broader kind is unchanged")
        XCTAssertEqual(ids(without, .variantCalls), ["IVAR-CODON-MERGE", missingTrack])
        let with = record(Name.variantsCall, app: app, steps: [samtools, step("ivar", argv: base + ["-g", "/tmp/genes.gff3"])])
        XCTAssertEqual(ids(with, .variantCalls), ["IVAR-CODON-MERGE"], "codon merging ran")
        let lofreq = record(Name.variantsCall, app: app, steps: [step("lofreq", argv: ["/tools/lofreq", "call"])])
        XCTAssertNil(AffectedResults.kind(of: lofreq), "only iVar calls are a kind")
    }

    func testAnAnnotationImportOfAGFF3OrGTFFileNamesTheImportKind() {
        let gff = record(Name.annotationTrackImport, inputs: ["/data/genes.gff3"])
        XCTAssertEqual(AffectedResults.kind(of: gff), .annotationTrackImport)
        XCTAssertEqual(ids(gff, .annotationTrackImport), [importDedup])
        for file in ["/data/genes.gtf.gz", "/data/genes.GFF", "/data/genes.gff3.gz"] {
            XCTAssertEqual(
                AffectedResults.kind(of: record(Name.annotationTrackImport, inputs: [file])), .annotationTrackImport, file
            )
        }
        XCTAssertNil(
            AffectedResults.kind(of: record(Name.annotationTrackImport, inputs: ["/data/primers.bed"])),
            "a BED track holds no feature that shares a place"
        )
        XCTAssertEqual(
            AffectedResults.kind(of: record(Name.nativeBundleBuild, inputs: ["/data/ref.fa", "/data/genes.gff"])),
            .annotationTrackImport, "a bundle built with a GFF3 file"
        )
        XCTAssertNil(AffectedResults.kind(of: record(Name.nativeBundleBuild, inputs: ["/data/ref.fa"])))
        XCTAssertEqual(ids(record(Name.annotationTrackImport, app: "Lungfish 2026.11.17 (14643)", inputs: ["/d/g.gff3"]),
                           .annotationTrackImport), [])
    }
}
