// AffectedResultsLoosePairAndImportTests+IngestAndRibo.swift - The kinds of the loose-pair routes FIX-ROUTES-6 refuses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FIX-ROUTES-7 (BIO-ROUTES-5 items 2 to 4). `fastq ingest --pair`, `debug fastq-ingest --pair`, `fastq ribodetector` and
// `fastq deacon-ribo` on two files paired the loose files by position in every build up to Preview 2026.11.15 (14072) and in
// Stable 2026.11.14 (13927). Each pin reads the record by the root name and the keys its writer saves, as literal text, so
// the tests build at the base. The records the writers of `fastq ingest` and `fastq ribodetector` make are pinned in
// `AffectedResultsIngestAndRiboRecordTests` (LungfishCLITests), which reaches the CLI. `fastq deacon-ribo` records after the
// tool, so its envelope is built here with the writer's name and keys (`FastqDeaconRiboSubcommand.swift:379-382`).

import XCTest
import LungfishCore
@testable import LungfishWorkflow

extension AffectedResultsLoosePairAndImportTests {

    private func ingestKeys(_ r1: String, _ r2: String?) -> [String: ParameterValue] {
        ["input": file(r1), "pair": r2.map { file($0) } ?? .null]
    }

    private func rowIDs(_ appVersion: String, _ kind: String) -> [String]? {
        AffectedResultKind(rawValue: kind).map { AffectedResults.rows(forAppVersion: appVersion, kind: $0).map(\.backlogID) }
    }

    func testAnIngestOfTwoLooseFilesIsTheIngestLoosePairKindAndOnlyTheOutOfStepRow() {
        // `FastqIngestSubcommand.swift:194-195` records `input` and `pair` as files, and `pair` as null for one file.
        let loose = ingestKeys("/data/run/S_R1.fastq", "/data/run/S_R2.fastq")
        XCTAssertEqual(kind(record("lungfish fastq ingest", explicit: loose)), "fastqIngestLoosePair")
        XCTAssertEqual(ids(14072, "fastqIngestLoosePair"), ["LOOSE-PAIR-OUT-OF-STEP"], "Preview 2026.11.15")
        XCTAssertEqual(rowIDs("Lungfish 2026.11.14 (13927)", "fastqIngestLoosePair"), ["LOOSE-PAIR-OUT-OF-STEP"], "Stable 2026.11.14")
    }

    func testAnIngestOfOneFileOrABundleIsNoKind() {
        let name = "lungfish fastq ingest"
        XCTAssertEqual(kind(record(name, explicit: ingestKeys("/data/run/S.fastq", nil))), nil, "one file records pair as null")
        XCTAssertEqual(kind(record(name, explicit: ["input": file("/data/run/S.fastq")])), nil, "no pair recorded")
        let inBundle = ingestKeys("/p/Imports/S.lungfishfastq/S_R1.fastq", "/p/Imports/S.lungfishfastq/S_R2.fastq")
        XCTAssertEqual(kind(record(name, explicit: inBundle)), nil, "a bundle's pair is no loose pair")
        let loose = ingestKeys("/data/run/S_R1.fastq", "/data/run/S_R2.fastq")
        XCTAssertEqual(kind(record("lungfish fastq ingest run", explicit: loose)), nil, "only the root name")
    }

    func testARiboFilterOfTwoLooseFilesIsTheRiboFilterLoosePairKindWithBothRows() {
        // `FastqRiboDetectorSubcommand.swift:307` and `FastqDeaconRiboSubcommand.swift:382` record `inputs` as files.
        let inputs: ParameterValue = .array([file("/data/run/S_R1.fastq"), file("/data/run/S_R2.fastq")])
        for name in ["RiboDetector FASTQ filter", "Deacon rRNA FASTQ filter"] {
            XCTAssertEqual(kind(record(name, explicit: ["input": file("/data/run/S_R1.fastq"), "inputs": inputs])),
                           "fastqRiboFilterLoosePair", name)
        }
        let both = ["LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP"]
        XCTAssertEqual(ids(14072, "fastqRiboFilterLoosePair"), both, "Preview 2026.11.15")
        XCTAssertEqual(rowIDs("Lungfish 2026.11.14 (13927)", "fastqRiboFilterLoosePair"), both, "Stable 2026.11.14")
    }

    func testARiboFilterOfOneFileOrABundleIsNoKind() {
        let one: ParameterValue = .array([file("/data/run/S.fastq")])
        let inBundle: ParameterValue = .array([file("/p/Imports/S.lungfishfastq/S_R1.fastq"),
                                               file("/p/Imports/S.lungfishfastq/S_R2.fastq")])
        for name in ["RiboDetector FASTQ filter", "Deacon rRNA FASTQ filter"] {
            XCTAssertEqual(kind(record(name, explicit: ["inputs": one])), nil, "\(name): one file")
            XCTAssertEqual(kind(record(name, explicit: ["inputs": inBundle])), nil, "\(name): a bundle's pair")
            XCTAssertEqual(kind(record(name, explicit: ["input": file("/data/run/S.fastq")])), nil, "\(name): no inputs recorded")
        }
        XCTAssertEqual(kind(record("RiboDetector FASTQ filter run", explicit: ["inputs": one])), nil, "only the root name")
    }

    /// BIO-ROUTES-5 item 4. A merged in-place ingest keeps the root name of the record that stood in the folder, so a record
    /// of another name is the ingest kind only when it holds the ingest step with `--pair` and names two loose files.
    func testARecordOfAnotherNameIsTheIngestLoosePairKindOnlyWhenItHoldsThePairIngestStep() {
        let loose = ingestKeys("/data/run/S_R1.fastq", "/data/run/S_R2.fastq")
        let pairStep = ProvenanceStep(
            toolName: "FASTQIngestionPipeline", toolVersion: "2026.11.15",
            argv: ["lungfish-cli", "fastq", "ingest", "/data/run/S_R1.fastq", "--pair", "/data/run/S_R2.fastq"], exitStatus: 0
        )
        let oneStep = ProvenanceStep(
            toolName: "FASTQIngestionPipeline", toolVersion: "2026.11.15",
            argv: ["lungfish-cli", "fastq", "ingest", "/data/run/S_R1.fastq"], exitStatus: 0
        )
        XCTAssertEqual(kind(record("SRA download", explicit: loose, steps: [pairStep])), "fastqIngestLoosePair")
        XCTAssertEqual(kind(record("SRA download", explicit: loose, steps: [oneStep])), nil, "an ingest of one file")
        XCTAssertEqual(kind(record("SRA download", explicit: loose)), nil, "no ingest step")
    }
}
