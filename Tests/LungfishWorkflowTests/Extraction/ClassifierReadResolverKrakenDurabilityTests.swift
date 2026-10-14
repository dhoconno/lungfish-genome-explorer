// ClassifierReadResolverKrakenDurabilityTests.swift - The Kraken2 extraction's pairs and reads files publish whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, the follow-up grant. The Kraken2 extraction gathers
/// every sample's pairs into `kraken2-pairs.fastq` and every other read into
/// `kraken2-reads.fastq` in its project scratch, and joins the two. The base
/// held two open handles across the whole async loop, so neither file was
/// synced and a part file sat under each name until the loop ended. The loop
/// now only extracts, and the two files are written afterwards through
/// `DurableReplace`, in one transaction.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback. The byte pins are
/// `ReadWriterHandleSitePinTests`.
final class ClassifierReadResolverKrakenDurabilityTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!
    private var project: URL!
    private var resultDirectory: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-scratch-durability")
        project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".lungfish"),
            withIntermediateDirectories: true
        )
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/kraken2-bracken-reopen")
        resultDirectory = analyses.appendingPathComponent("kraken2-2026-09-24T23-36-28")
        try FileManager.default.copyItem(at: fixture, to: resultDirectory)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func extract() async throws {
        _ = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: resultDirectory,
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [3050292])],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: project,
                displayName: "kraken2_Simplexvirus_durability",
                metadata: ExtractionMetadata(
                    sourceDescription: "kraken2_Simplexvirus_durability",
                    toolName: "Kraken2",
                    parameters: ["taxIds": "3050292"]
                )
            )
        )
    }

    private func stageFilesLeft() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: project.path)
        return (enumerator?.allObjects as? [String] ?? []).filter { $0.contains(DurableReplace.stageInfix) }
    }

    /// The fixture's source is one interleaved file, so its reads are adjacent
    /// mates and go to the reads file. The pairs file stays empty.
    func testAFullDiskWhileWritingTheReadsFileIsAThrownErrorAndLeavesNoStageFile() async throws {
        let tally = Fixtures.Tally()
        let operations = Fixtures.fullDisk(afterWrites: 0, matching: ".kraken2-reads.fastq.lungfish-stage-", tally: tally)

        let error = await Fixtures.capturedError {
            try await DurableReplace.$overrideOperations.withValue(operations) { try await extract() }
        }

        Fixtures.assertFullDisk(error)
        XCTAssertEqual(tally["stageWrites"], 1, "the write after the failure never ran")
        XCTAssertEqual(stageFilesLeft(), [])
    }

    func testBothScratchFilesAreSyncedBeforeTheyAreNamed() async throws {
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(syncFile: { descriptor in
            let path = Fixtures.path(of: descriptor)
            if path.contains(".kraken2-pairs.fastq.lungfish-stage-") { tally.add("pairs") }
            if path.contains(".kraken2-reads.fastq.lungfish-stage-") { tally.add("reads") }
            return Darwin.fsync(descriptor)
        })

        try await DurableReplace.$overrideOperations.withValue(operations) { try await extract() }

        XCTAssertEqual(tally["pairs"], 1, "the pairs file is synced once, empty as it is for this result")
        XCTAssertEqual(tally["reads"], 1, "the reads file is synced once")
        XCTAssertEqual(stageFilesLeft(), [])
    }

    // MARK: - The stage form of writeExtractedReads

    func testTheStageFormWritesWhatTheHandleFormWritesForTwoSamples() throws {
        let folder = root.appendingPathComponent("stage-form", isDirectory: true)
        let first = try Fixtures.extraction("a", folder: folder)
        let second = try Fixtures.extraction("b", folder: folder)
        let pairsFile = folder.appendingPathComponent("pairs.fastq")
        let readsFile = folder.appendingPathComponent("reads.fastq")

        let counts: [Int] = try DurableReplace.transaction {
            try ReadFileWriters.publish(pairsFile) { pairsStage in
                try ReadFileWriters.publish(readsFile) { readsStage in
                    try [first, second].map {
                        try TaxonomyExtractionPipeline.writeExtractedReads(
                            $0.outputs, of: $0.files, pairs: pairsStage, reads: readsStage
                        )
                    }
                }
            }
        }

        XCTAssertEqual(counts, [2, 2])
        XCTAssertEqual(try Data(contentsOf: pairsFile), first.pairs + second.pairs)
        XCTAssertEqual(try Data(contentsOf: readsFile), first.reads + second.reads)
        XCTAssertEqual(try Fixtures.entries(of: folder).filter { $0.contains(DurableReplace.stageInfix) }, [])
    }

    func testAFullDiskInTheReadsFileNamesNeitherFileAndLeavesNoStageFile() throws {
        let folder = root.appendingPathComponent("stage-full", isDirectory: true)
        let extracted = try Fixtures.extraction("a", folder: folder)
        let pairsFile = folder.appendingPathComponent("pairs.fastq")
        let readsFile = folder.appendingPathComponent("reads.fastq")
        let operations = Fixtures.fullDisk(afterWrites: 0, matching: ".reads.fastq.lungfish-stage-", tally: Fixtures.Tally())

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(operations) {
                try DurableReplace.transaction {
                    try ReadFileWriters.publish(pairsFile) { pairsStage in
                        try ReadFileWriters.publish(readsFile) { readsStage in
                            _ = try TaxonomyExtractionPipeline.writeExtractedReads(
                                extracted.outputs, of: extracted.files, pairs: pairsStage, reads: readsStage
                            )
                        }
                    }
                }
            }
        ) { Fixtures.assertFullDisk($0) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: pairsFile.path), "a failed write names neither file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: readsFile.path))
        XCTAssertEqual(try Fixtures.entries(of: folder).filter { $0.contains(DurableReplace.stageInfix) }, [])
    }
}
