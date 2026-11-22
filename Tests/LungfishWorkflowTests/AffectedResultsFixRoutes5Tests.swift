// AffectedResultsFixRoutes5Tests.swift - Stable 2026.11.14's patch build, the RNA-seq kind and the adopted plan's import record (FIX-ROUTES-5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// BIO-ROUTES-4 items 2, 6 and 15 (sub-phase 5.6). Stable 2026.11.14 is build 13927, packaged from a patch branch of
// v2026.11.7 (build 12972). `git log v2026.11.7..v2026.11.14` holds one result fix, the port of DEMUX-SHARED-NAME-GZIP
// (`bbfe6550d`, red `83741bccd`), and the TOOL and NOTES commits of the patch, so 13927 holds every row that 12972 holds
// except that one. The kinds are read by their raw values, so the tests build at the base.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class AffectedResultsFixRoutes5Tests: XCTestCase {
    /// The rows a build holds for `kind`, by the text of Stable 2026.11.14's own app version.
    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forAppVersion: "Lungfish 2026.11.14 (\(build))", kind: kind).map(\.backlogID)
    }

    /// Item 6. A result of 13927 shows every row of 12972 for its kind, less the row the patch carries.
    func testAPatchBuildHoldsTheRowsOfItsBaseExceptTheOnesItCarries() {
        for kind in AffectedResultKind.allCases {
            XCTAssertEqual(ids(13927, kind), ids(12972, kind).filter { $0 != "DEMUX-SHARED-NAME-GZIP" }, kind.rawValue)
        }
        let named: Set<String> = ["VIRALRECON-READ-ORDER", "VIRALRECON-SE-ADAPTER-GUESS", "FASTQ-TRIM-READ-ORDER"]
        XCTAssertEqual(ids(13927, .viralRecon).filter(named.contains), ["VIRALRECON-READ-ORDER", "VIRALRECON-SE-ADAPTER-GUESS"])
        XCTAssertEqual(ids(13927, .fastqTrim).filter(named.contains), ["FASTQ-TRIM-READ-ORDER"])
        // The carried row. Version 2026.11.7 lacks the port, and the patch has it.
        XCTAssertEqual(ids(12972, .fastqDemultiplexSharedNameGzip).filter { $0 == "DEMUX-SHARED-NAME-GZIP" }, ["DEMUX-SHARED-NAME-GZIP"])
        XCTAssertEqual(ids(13927, .fastqDemultiplexSharedNameGzip).filter { $0 == "DEMUX-SHARED-NAME-GZIP" }, [])
    }

    /// Item 6. Only the patch build is read as its base. Every other build is read as itself, so a row that ends at 12972
    /// holds 12972 and the patch and no Preview build after them.
    func testOnlyThePatchBuildIsReadAsItsBase() {
        let order = AffectedResults.rows.first { $0.backlogID == "VIRALRECON-READ-ORDER" }
        XCTAssertEqual([12972, 13927, 13924, 13190, 14072].map { order?.holds(build: $0) }, [true, true, false, false, false])
        let carried = AffectedResults.rows.first { $0.backlogID == "DEMUX-SHARED-NAME-GZIP" }
        XCTAssertEqual([12972, 13764, 13927, 14072].map { carried?.holds(build: $0) }, [true, true, false, false])
        let loose = AffectedResults.rows.first { $0.backlogID == "LOOSE-PAIR-OUT-OF-STEP" }
        XCTAssertEqual([13927, 14072, 14073].map { loose?.holds(build: $0) }, [true, true, false])
    }

    // MARK: - Item 5, the RNA-seq kind

    private func record(_ workflow: String) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope.fixture()
        envelope.workflowName = workflow
        return envelope
    }

    /// Item 5. The adopt of a plan's counts writes the root record "RNA-seq adopt" (`ExecutorRunAdoption+RNASeqRecord.swift:31`),
    /// which names no read file, so a staged loose pair and a bundle's pair look alike and the kind holds every such record.
    /// A quant on this Mac plans one bundle and checks its pairs, and only the root name counts.
    func testAnRNASeqAdoptRecordIsTheRNASeqPlanRunKind() {
        XCTAssertEqual(AffectedResults.kind(of: record("RNA-seq adopt"))?.rawValue, "rnaSeqPlanRun")
        XCTAssertEqual(AffectedResults.kind(of: record("RNA-seq salmon quant"))?.rawValue, nil)
        XCTAssertEqual(AffectedResults.kind(of: record("RNA-seq adopt preview"))?.rawValue, nil)
    }

    // MARK: - Item 15, the adopted plan's import record

    /// Item 15. A plan's node returns the import bundle, and the adopt writes its record with `r1` and `r2` as files of the
    /// returned folder (`ExecutorRunAdoption+Bundle.swift:522-525`, `FASTQBatchImporter.swift:1801-1802`). The real adopted
    /// record of build 11392 names fastp's adapter guess, so it is the recipe kind. With the guess left out of its steps,
    /// which an import with no recipe has never had, the same record is the loose pair import kind.
    func testTheImportRecordOfAnAdoptedPlanWithNoFastpGuessIsTheLoosePairImportKind() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/provenance-adopted-run/Imports/SRR24403534.lungfishfastq/.lungfish-provenance.json")
        var adopted = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: url)?.envelope)
        XCTAssertEqual(AffectedResults.kind(of: adopted), .fastqRecipeImport)
        adopted.steps = adopted.steps.map { step in
            var step = step
            step.argv = step.argv.filter { $0 != AffectedResults.fastpPairedAdapterGuess }
            return step
        }
        XCTAssertEqual(AffectedResults.importedTwoLooseFiles(adopted), true)
        XCTAssertEqual(AffectedResults.kind(of: adopted), .fastqLoosePairImport)
    }
}
