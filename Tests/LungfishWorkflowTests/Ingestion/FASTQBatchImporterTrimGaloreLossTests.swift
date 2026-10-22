// FASTQBatchImporterTrimGaloreLossTests.swift - an import through Trim Galore records and says what it removed (CHTC lane C2-TGFIX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Trim Galore 2.3.0 adapter- and quality-trims every read it stores and removes the reads its trim leaves under the
/// length cutoff, a pair as a unit, and no option set of 2.3.0 turns this off (review of lane C2-TRIMGALORE). The owner
/// keeps it as the most laptop-safe storage tool and asked that the loss be noted in provenance (Q12, 2026-10-22), so
/// the Trim Galore step of the record and the import's notice after storage both say what it did and what it removed.
final class FASTQBatchImporterTrimGaloreLossTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-trim-galore-loss")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testTheRecordAndTheNoticeSayWhatTrimGaloreRemovedFromTheReviewPairs() async throws {
        _ = try await ToolAvailability.require("trim_galore", environment: "trim_galore")
        _ = try await ToolAvailability.require("reformat.sh", environment: "bbtools")
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let r1 = input.appendingPathComponent("s_R1.fastq")
        let r2 = input.appendingPathComponent("s_R2.fastq")
        try MixedStorageFASTQ.writeReviewPairs(r1: r1, r2: r2)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let recorder = ImportLogEventRecorder()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "s", r1: r1, r2: r2)],
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: true,
                clumpingTool: .trimGalore,
                threads: 2
            ),
            log: { recorder.append($0) }
        )

        XCTAssertEqual(result.completed, 1, "\(result.errors)")
        let bundle = project.appendingPathComponent("Imports/s.lungfishfastq", isDirectory: true)
        XCTAssertEqual(
            try FASTQPairInterleaver.countRecords(in: bundle.appendingPathComponent("s.fastq.gz")), 22,
            "11 of the 12 pairs are stored"
        )

        // The record: the Trim Galore step names the version, its cutoffs, what the call does and what it removed.
        let url = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let data = PortablePath.resolveJSON(try Data(contentsOf: url), forFileAt: url)
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
        let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "trim_galore" })
        XCTAssertEqual(step.resolvedOptions["trimGaloreVersion"], .string("2.3.0"))
        XCTAssertEqual(step.resolvedOptions["length_cutoff"], .integer(20))
        XCTAssertEqual(step.resolvedOptions["quality_cutoff"], .integer(20))
        XCTAssertEqual(step.resolvedOptions["pairsRead"], .integer(12))
        XCTAssertEqual(step.resolvedOptions["pairsWritten"], .integer(11))
        XCTAssertEqual(step.resolvedOptions["pairsRemoved"], .integer(1))
        let statement = try XCTUnwrap(step.resolvedOptions["storageReadRemoval"]?.stringValue)
        for phrase in [
            "Trim Galore 2.3.0", "adapter- and quality-trims", "quality cutoff 20", "length cutoff of 20",
            "a pair as a unit", "No Trim Galore 2.3.0 option set turns this off", "removed 1 of 12 pairs",
        ] {
            XCTAssertTrue(statement.contains(phrase), "'\(phrase)' in: \(statement)")
        }

        // The notice after storage says the same in one sentence with the counts.
        let notices = recorder.events.compactMap { event -> String? in
            if case let .notice(_, message) = event { return message }
            return nil
        }
        let notice = try XCTUnwrap(notices.first { $0.contains("Trim Galore") }, "\(notices)")
        for phrase in ["Trim Galore 2.3.0", "quality 20", "shorter than 20 bases", "1 of 12 pairs", "no Trim Galore 2.3.0 option"] {
            XCTAssertTrue(notice.contains(phrase), "'\(phrase)' in: \(notice)")
        }
        let stops = notice.replacingOccurrences(of: "2.3.0", with: "").filter { $0 == "." || $0 == ";" }
        XCTAssertEqual(stops, ".", "one plain sentence: \(notice)")
    }
}
