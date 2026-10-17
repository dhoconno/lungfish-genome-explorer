// NaoMgsBlastLineageTests.swift - The NAO-MGS taxon BLAST names the result its reads came from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A65 M2, review fix F2 (BIO 6, BIO's vote on Q-A1). The record `blast submit` saves names
// the result the sequences came from (`lineage.sourceResult`), which lets a person walk from a search back to
// its reads. The NAO-MGS site passes the folder of the result its viewer shows, and the search's folder still
// sits under the project's `blast-verifications/`, never inside the NAO-MGS result. The begin tests of the
// three sites hold their own cases, so this class holds the lineage of the NAO-MGS plan.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class NaoMgsBlastLineageTests: XCTestCase {
    func testTheTaxonSearchRecordsTheResultFolderItsReadsCameFromAndSavesUnderTheProject() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-blast-lineage")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/naomgs-flu-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        // Two reads and a count of 4 draw both, so the samples are fixed.
        let reads = [("read_1", "S2"), ("read_2", "S1")].map { Self.hit(id: $0.0, sample: $0.1) }

        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Influenza A virus", taxId: 11320, readCount: 4, reads: reads,
            projectURL: project, sourceResultURL: result
        )
        let reporter = RecordingOperationReporter()
        ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: "Influenza A virus", taxId: 11320, cliCommand: plan.cliCommand, reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        XCTAssertEqual(command.sourceResult, result.path, "the lineage names the NAO-MGS result folder")
        XCTAssertEqual(plan.request.sourceResultURL, result)
        let output = URL(fileURLWithPath: command.outputPath)
        XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().deletingLastPathComponent().path, project.path)
        XCTAssertFalse(command.outputPath.hasPrefix(result.path + "/"), "the search never lands inside the NAO-MGS result")
        XCTAssertEqual(command.sample, "S1,S2", "the rest of the lineage is unchanged")
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.subsampleCount, 2)
    }

    /// A NAO-MGS read of `id` from `sample`, 20 bases long.
    private static func hit(id: String, sample: String) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: id, taxId: 11320, bestAlignmentScore: 40,
            cigar: "20M", queryStart: 0, queryEnd: 20, refStart: 0, refEnd: 20,
            readSequence: "ACGTACGTACGTACGTACGT", readQuality: String(repeating: "I", count: 20),
            subjectSeqId: "NC_026438.1", subjectTitle: "Influenza A virus", bitScore: 40, eValue: 1e-5,
            percentIdentity: 100, editDistance: 0, fragmentLength: 20, isReverseComplement: false,
            pairStatus: "CP", queryLength: 20
        )
    }
}
