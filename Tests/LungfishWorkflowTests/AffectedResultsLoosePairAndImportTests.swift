// AffectedResultsLoosePairAndImportTests.swift - The affected rows of the S1 fixes of sub-phase 5.6
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane AFFECTED-5.6 (SAD:107, BIO-ROUTES-3 item 8). Five S1 fixes of 5.6 left wrong results in older projects: bundles
// named like two mates run as one sample (TAXTRIAGE-BUNDLE-NAMES-PAIRED), files of one name from two folders paired in a
// command line batch (GROUPER-CROSS-FOLDER-PAIR), a loose pair of unequal counts (LOOSE-PAIR-SHORT-MATE) or of equal counts
// out of step by name (LOOSE-PAIR-OUT-OF-STEP), and a CZ ID report table imported with 0 reads (CZID-REAL-EXPORT-FORMAT).
// Every published build up to Preview 2026.11.15 (14072) lacks each fix, and so does Stable 2026.11.14, build 13927 of a
// patch branch. The new kinds are read by their raw values and the record names as literal text, so the tests build at
// the base.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class AffectedResultsLoosePairAndImportTests: XCTestCase {
    private let newRows: Set<String> = [
        "TAXTRIAGE-BUNDLE-NAMES-PAIRED", "GROUPER-CROSS-FOLDER-PAIR", "LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP",
        "CZID-REAL-EXPORT-FORMAT",
    ]

    /// The new rows a build holds for the kind of raw value `kind`, or nil when no such kind exists.
    private func ids(_ build: Int, _ kind: String) -> [String]? {
        AffectedResultKind(rawValue: kind).map {
            AffectedResults.rows(forAppVersion: "Lungfish 2026.11.15 (\(build))", kind: $0).map(\.backlogID)
                .filter(newRows.contains)
        }
    }

    /// The new rows that hold each kind at a build without the fixes, by raw value.
    private let heldAtTheLastBuild: [String: [String]] = [
        "taxTriage": ["TAXTRIAGE-BUNDLE-NAMES-PAIRED", "LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP"],
        "kraken2": ["TAXTRIAGE-BUNDLE-NAMES-PAIRED", "GROUPER-CROSS-FOLDER-PAIR", "LOOSE-PAIR-SHORT-MATE",
                    "LOOSE-PAIR-OUT-OF-STEP"],
        "esViritu": ["TAXTRIAGE-BUNDLE-NAMES-PAIRED", "GROUPER-CROSS-FOLDER-PAIR", "LOOSE-PAIR-SHORT-MATE",
                     "LOOSE-PAIR-OUT-OF-STEP"],
        "mappingLoosePair": ["LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP"],
        "assembly": ["LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP"],
        "viralRecon": ["LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP"],
        "fastqRecipeImport": ["LOOSE-PAIR-OUT-OF-STEP"],
        "fastqLoosePairImport": ["LOOSE-PAIR-OUT-OF-STEP"],
        "czIdImport": ["CZID-REAL-EXPORT-FORMAT"],
    ]

    func testEachRowNamesItsKindsBuildsAndFix() {
        // fixCommit, the last code commit of the lane that fixes most of the row's kinds: TT-GROUP's B1 fold for the
        // bundle names, FIX-A for the folders, FIX-ROUTES for both loose-pair rows and FIX-CZID's last fold for CZ ID.
        let expected: [(String, [String], String)] = [
            ("TAXTRIAGE-BUNDLE-NAMES-PAIRED", ["taxTriage", "kraken2", "esViritu"], "61acb5bfc"),
            ("GROUPER-CROSS-FOLDER-PAIR", ["kraken2", "esViritu"], "d998a3371"),
            ("LOOSE-PAIR-SHORT-MATE",
             ["taxTriage", "kraken2", "esViritu", "mappingLoosePair", "assembly", "viralRecon"], "c9ed8e3ef"),
            ("LOOSE-PAIR-OUT-OF-STEP",
             ["taxTriage", "kraken2", "esViritu", "mappingLoosePair", "assembly", "viralRecon", "fastqRecipeImport",
              "fastqLoosePairImport"], "c9ed8e3ef"),
            ("CZID-REAL-EXPORT-FORMAT", ["czIdImport"], "f58ecdaae"),
        ]
        for (id, kinds, fix) in expected {
            let row = AffectedResults.rows.first { $0.backlogID == id }
            XCTAssertEqual(row?.kinds.map(\.rawValue), kinds, id)
            XCTAssertEqual(row.map(\.firstBuild), .some(nil), "\(id) is older than any build a row names")
            XCTAssertEqual(row?.lastBuild, 14072, "\(id): Preview 2026.11.15 is the newest build without the fix")
            XCTAssertEqual(row?.fixCommit, fix, id)
        }
    }

    func testEveryKindHoldsItsRowsUpToPreview20261115AndNoneAfter() {
        for kind in AffectedResultKind.allCases.map(\.rawValue) + ["mappingLoosePair", "fastqLoosePairImport", "czIdImport"] {
            let held = heldAtTheLastBuild[kind] ?? []
            XCTAssertEqual(ids(14072, kind), held, "\(kind) at Preview 2026.11.15")
            XCTAssertEqual(ids(13927, kind), held, "\(kind) at Stable 2026.11.14, a patch build")
            XCTAssertEqual(ids(4192, kind), held, "\(kind) at 2026.8.1, the first published build")
            XCTAssertEqual(ids(14073, kind), [], "\(kind) at the first build with every fix")
        }
    }

    func testTheVersionsOfThe2026Point11Point13To15ReleasesNameTheirBuilds() {
        // 2026.11.13 and 2026.11.15 are the commit counts of their tags. Stable 2026.11.14 was packaged from a patch
        // branch and stamped 13927, so its version names the builds between the two Previews, which hold 13927.
        XCTAssertEqual(AffectedResults.builds(ofVersion: "2026.11.13"), 13765...13924)
        XCTAssertEqual(AffectedResults.builds(ofVersion: "2026.11.14"), 13925...14071)
        XCTAssertEqual(AffectedResults.builds(ofVersion: "2026.11.15"), 13925...14072)
        XCTAssertEqual(AffectedResults.builds(ofVersion: "2026.11.16"), nil)
        var stable = ProvenanceEnvelope.fixture()
        stable.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.14 (13927)")
        XCTAssertEqual(AffectedResults.builds(of: stable), 13927...13927)
    }

    // MARK: - The kind a record names

    private func record(
        _ workflow: String, explicit: [String: ParameterValue] = [:], inputs: [String] = [], steps: [ProvenanceStep] = []
    ) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope.fixture()
        envelope.workflowName = workflow
        envelope.options = ProvenanceOptions(explicit: explicit)
        envelope.files = inputs.map {
            ProvenanceFileDescriptor(path: $0, checksumSHA256: String(repeating: "a", count: 64), fileSize: 12,
                                     format: .fastq, role: .input)
        } + [ProvenanceFileDescriptor(path: "/data/ref.fasta", checksumSHA256: String(repeating: "c", count: 64),
                                      fileSize: 12, format: .fasta, role: .reference)]
        envelope.steps = steps
        return envelope
    }

    private func file(_ path: String) -> ParameterValue { .file(URL(fileURLWithPath: path)) }

    private func kind(_ envelope: ProvenanceEnvelope) -> String? { AffectedResults.kind(of: envelope)?.rawValue }

    func testAnImportOfTwoLooseFilesIsTheLoosePairImportKindAndOneFileOrABundlePairIsNot() {
        // `FASTQBatchImporter.provenanceParameters` records the pair as `r1` and `r2`, `.null` for one file, on this Mac
        // and in the record a plan's node returns (the adopted import of build 11392).
        let r1 = file("/data/run/S_R1.fastq.gz"), r2 = file("/data/run/S_R2.fastq.gz")
        XCTAssertEqual(kind(record("lungfish import fastq", explicit: ["r1": r1, "r2": r2])), "fastqLoosePairImport")
        XCTAssertEqual(kind(record("lungfish import fastq", explicit: ["r1": r1, "r2": .null])), nil, "one file")
        XCTAssertEqual(kind(record("lungfish import fastq", explicit: ["r1": r1])), nil, "no r2 recorded")
        let inBundle = ["r1": file("/p/Imports/S.lungfishfastq/S_R1.fastq.gz"),
                        "r2": file("/p/Imports/S.lungfishfastq/S_R2.fastq.gz")]
        XCTAssertEqual(kind(record("lungfish import fastq", explicit: inBundle)), nil, "a bundle's pair is no loose pair")
        XCTAssertEqual(kind(record("lungfish import fastq run", explicit: ["r1": r1, "r2": r2])), nil, "only the root name")
        // A recipe whose fastp guessed the adapter pair keeps the recipe kind, which LOOSE-PAIR-OUT-OF-STEP names too.
        let guess = ProvenanceStep(toolName: "fastp", toolVersion: "1.0",
                                   argv: ["fastp", "-i", "r1.fq", "-I", "r2.fq", "--detect_adapter_for_pe"], exitStatus: 0)
        XCTAssertEqual(kind(record("lungfish import fastq", explicit: ["r1": r1, "r2": r2], steps: [guess])),
                       "fastqRecipeImport")
    }

    func testTheAdoptedImportOfAPlanKeepsTheRecipeKindAndShowsTheOutOfStepRow() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/provenance-adopted-run/Imports/SRR24403534.lungfishfastq/.lungfish-provenance.json")
        let adopted = try ProvenanceEnvelopeReader.read(fromSidecar: url)?.envelope
        XCTAssertEqual(adopted.flatMap(kind), "fastqRecipeImport")
        XCTAssertEqual(adopted.map { AffectedResults.rows(for: $0, kind: .fastqRecipeImport).map(\.backlogID) },
                       ["FASTQ-TRIM-RECIPE-READ-ORDER", "LOOSE-PAIR-OUT-OF-STEP"], "build 11392")
    }

    func testAMappingOfTwoLooseFilesIsTheLoosePairMappingKindAndOneFileOrABundleIsNot() {
        let paired: [String: ParameterValue] = ["pairedEnd": .boolean(true)]
        let loose = ["/data/run/S_R1.fastq.gz", "/data/run/S_R2.fastq.gz"]
        XCTAssertEqual(kind(record("lungfish map", explicit: paired, inputs: loose)), "mappingLoosePair")
        XCTAssertEqual(kind(record("lungfish map", explicit: ["pairedEnd": .boolean(false)], inputs: loose)), nil,
                       "two files mapped as single reads")
        XCTAssertEqual(kind(record("lungfish map", explicit: paired, inputs: [loose[0]])), nil, "one file")
        let bundle = ["/p/Imports/S.lungfishfastq/S_R1.fastq.gz", "/p/Imports/S.lungfishfastq/S_R2.fastq.gz"]
        XCTAssertEqual(kind(record("lungfish map", explicit: paired, inputs: bundle)), nil, "a bundle pair")
        XCTAssertEqual(kind(record("lungfish.map.input-materialization", explicit: paired, inputs: loose)), nil)
    }

    func testACZIDImportIsTheCZIDKindAndAnotherImportIsNot() {
        XCTAssertEqual(kind(record("CZ-ID Import")), "czIdImport")
        XCTAssertEqual(kind(record("NAO-MGS Import")), nil)
        XCTAssertEqual(kind(record("CZ-ID Import preview")), nil, "only the root name")
    }
}
