// TaxaCollectionBatchExtractionPinTests.swift - The taxa collection Extract button at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A66 M1, freeze first (QA 1). Every pin here passes at the base with no `Sources`
// edit and says what the Extract button of the taxa collections drawer does before lane A66 routes
// it through a command. The viewer runs `TaxonomyExtractionPipeline.extractBatch` in the app into
// `extracted-<collection id>` beside the classification result and ends its row with
// `Extracted N taxa from <name>`. A taxon becomes one gzip FASTQ whose name is its display name with
// spaces as underscores and its tax ID. A result of two read files gives one file per taxon with each
// pair's mates together. A taxon without reads is skipped and not counted. A cancel stops at the
// next taxon and keeps the files already written.
//
// Since lane 12.11 M3 the leaf runs the collection through `ClassifierReadResolver.extractCollection`.
// `extractBatch` is the old engine these pins were captured on, and they hold unchanged.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxaCollectionBatchExtractionPinTests: XCTestCase {
    private var root: URL!
    private var fixtures: TaxaCollectionFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxa-collection-pin")
        fixtures = try TaxaCollectionFixtures(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The folder the viewer's Extract button writes into for `collection`, beside the result's files.
    private func extractedFolder(of result: ClassificationResult, _ collection: TaxaCollection) -> URL {
        result.config.outputDirectory.appendingPathComponent("extracted-\(collection.id)", isDirectory: true)
    }

    private func runBatch(
        _ collection: TaxaCollection = TaxaCollectionFixtures.collection,
        resultFolder: URL,
        log: TaxaCollectionProgressLog = TaxaCollectionProgressLog()
    ) async throws -> (outputs: [URL], folder: URL) {
        let result = try ClassificationResult.load(from: resultFolder)
        let folder = extractedFolder(of: result, collection)
        let outputs = try await ClassifierReadResolver().extractCollection(
            collection,
            resultPath: resultFolder,
            classification: result,
            outputDirectory: folder,
            progress: { _, message in log.append(message) }
        )
        return (outputs, folder)
    }

    /// The scratch folders in the project's `.tmp`, where the resolver works (the review of lane 12.11,
    /// fix 8e). A run leaves none behind.
    private func projectScratch() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: ProjectTempDirectory.tempRoot(for: fixtures.projectURL).path)) ?? [])
    }

    // MARK: - The collection on the resolver (extractBatch until lane 12.11 M3)

    func testATwoTaxonCollectionWritesOneGzipFilePerTaxonUnderTheExtractedFolder() async throws {
        let log = TaxaCollectionProgressLog()
        let scratchBefore = projectScratch()
        let run = try await runBatch(resultFolder: fixtures.singleEnd, log: log)

        XCTAssertEqual(run.folder.lastPathComponent, "extracted-a66-genus-and-b")
        XCTAssertEqual(run.folder.deletingLastPathComponent().standardizedFileURL.path, fixtures.singleEnd.standardizedFileURL.path)
        XCTAssertEqual(
            run.outputs.map(\.lastPathComponent),
            ["Genus_A_taxid10.fastq.gz", "Species_B_taxid20.fastq.gz"],
            "one file per taxon, in the order of the collection"
        )
        for output in run.outputs {
            XCTAssertEqual(output.deletingLastPathComponent().standardizedFileURL.path, run.folder.standardizedFileURL.path)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
                "\(output.lastPathComponent) has its provenance sidecar"
            )
        }
        XCTAssertEqual(try TaxaCollectionFixtures.recordNames(in: run.outputs[0]), ["a1", "a2", "a3"], "a target with children reads its species")
        XCTAssertEqual(try TaxaCollectionFixtures.recordNames(in: run.outputs[1]), ["b1", "b2"], "a target without children reads its own taxon")
        XCTAssertEqual(log.messages.first, "Starting batch extraction: A66 genus and B (2 taxa)")
        XCTAssertEqual(log.messages.last, "Batch complete: 2 of 2 taxa extracted (0 skipped)")
        XCTAssertEqual(projectScratch(), scratchBefore, "the scratch folders of the run go at the end")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: run.folder.path).filter { $0.hasPrefix(".") },
            [".lungfish-provenance.json"],
            "the extracted folder holds no scratch, only the last record"
        )
    }

    func testAPairedResultWritesEachTaxonsMatesTogetherInOneFile() async throws {
        let run = try await runBatch(resultFolder: fixtures.paired)

        XCTAssertEqual(run.outputs.map(\.lastPathComponent), ["Genus_A_taxid10.fastq.gz", "Species_B_taxid20.fastq.gz"])
        XCTAssertEqual(
            try TaxaCollectionFixtures.recordNames(in: run.outputs[0]),
            ["p1/1", "p1/2", "p3/1", "p3/2"],
            "each pair's R1 record is followed by its R2 record"
        )
        XCTAssertEqual(try TaxaCollectionFixtures.recordNames(in: run.outputs[1]), ["p2/1", "p2/2"])
    }

    func testATaxonWithoutReadsIsSkippedAndNotCounted() async throws {
        let collection = TaxaCollection(
            id: "a66-skips", name: "A66 skips", description: "", sfSymbol: "circle",
            taxa: [
                // The report gives genus 10 reads in its species, none of its own.
                TaxonTarget(name: "Genus A", taxId: TaxaCollectionFixtures.genus, includeChildren: false),
                TaxonTarget(name: "Species B", taxId: TaxaCollectionFixtures.speciesB, includeChildren: false),
                // The report does not hold taxon 999.
                TaxonTarget(name: "Absent", taxId: 999, includeChildren: true),
            ]
        )
        let log = TaxaCollectionProgressLog()
        let run = try await runBatch(collection, resultFolder: fixtures.singleEnd, log: log)

        XCTAssertEqual(run.outputs.map(\.lastPathComponent), ["Species_B_taxid20.fastq.gz"], "N in the row's detail counts the files written")
        XCTAssertTrue(log.messages.contains("Skipped Genus A (no matching reads)"))
        XCTAssertTrue(log.messages.contains("Skipped Absent (0 reads)"))
        XCTAssertEqual(log.messages.last, "Batch complete: 1 of 3 taxa extracted (2 skipped)")
    }

    /// The review of lane 12.11, fix 8b. A result whose read file is gone fails the batch with the words
    /// of the missing source, never as skipped taxa, and writes no taxon file.
    func testAResultWhoseReadFileIsGoneFailsWithTheMissingSourceWords() async throws {
        try FileManager.default.removeItem(at: fixtures.singleEndReads)
        do {
            let run = try await runBatch(resultFolder: fixtures.singleEnd)
            XCTFail("a missing read file fails the batch, it wrote \(run.outputs.map(\.lastPathComponent))")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The FASTQ reads this Kraken2 result was made from are missing. They are not in this project or where the run "
                    + "recorded them. Put their bundle back into this project and try again, or run the classification again in "
                    + "this project."
            )
        }
        let folder = extractedFolder(of: try ClassificationResult.load(from: fixtures.singleEnd), TaxaCollectionFixtures.collection)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".fastq.gz") } ?? []
        XCTAssertEqual(files, [], "no taxon file is written")
    }

    func testACancelBetweenTaxaStopsTheBatchAndKeepsTheFilesAlreadyWritten() async throws {
        let collection = TaxaCollectionFixtures.collection
        let result = try ClassificationResult.load(from: fixtures.singleEnd)
        let folder = extractedFolder(of: result, collection)
        let cancel = TaxaCollectionCancelBox()
        let resultFolder: URL = fixtures.singleEnd
        let scratchBefore = projectScratch()

        let task = Task.detached {
            try await ClassifierReadResolver().extractCollection(
                collection,
                resultPath: resultFolder,
                classification: result,
                outputDirectory: folder,
                progress: { _, message in
                    if message.hasPrefix("Extracting Species B (2 of 2)") { cancel.cancel() }
                }
            )
        }
        cancel.install(task)

        do {
            let outputs = try await task.value
            XCTFail("a cancelled batch throws, it returned \(outputs.map(\.lastPathComponent))")
        } catch is CancellationError {
            // The batch stopped at the second taxon.
        } catch {
            XCTFail("a cancelled batch throws CancellationError, it threw \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Genus_A_taxid10.fastq.gz").path), "the first taxon's file stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Species_B_taxid20.fastq.gz").path))
        XCTAssertEqual(projectScratch(), scratchBefore, "a cancel removes the run's scratch folders in the project's .tmp too")
    }

    // MARK: - A second run into the same folder (Phase 2.12 lane 12.11 M1, BIO 6)

    /// Runs `extract taxa-collection` in process on the argv the Extract button hands it, over the
    /// single-end result, and returns every entry of the folder, its gzip files and the outputs the
    /// folder's root record names.
    private func runLeaf(_ collection: TaxaCollection) async throws -> (entries: [String], files: [String], recorded: [String]) {
        let result = try ClassificationResult.load(from: fixtures.singleEnd)
        let folder = extractedFolder(of: result, collection)
        let arguments = ViewerViewController.taxaCollectionExtractionArguments(
            collection: collection, resultDirectory: fixtures.singleEnd, outputDirectory: folder
        )
        let command = try ExtractTaxaCollectionSubcommand.parse(Array(arguments.dropFirst(2)))
        _ = try await command.extract(events: CLIEventEmitter(enabled: false, emit: { _ in }))
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "the folder holds the leaf's root record")
        let recorded = record.outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
        return (entries, entries.filter { $0.hasSuffix(".fastq.gz") }, recorded)
    }

    func testASecondRunOfTheSameCollectionLeavesOnlyTheFilesItsRecordNames() async throws {
        let first = try await runLeaf(TaxaCollectionFixtures.collection)
        XCTAssertEqual(first.files, ["Genus_A_taxid10.fastq.gz", "Species_B_taxid20.fastq.gz"])
        XCTAssertEqual(first.recorded, first.files)

        let second = try await runLeaf(TaxaCollectionFixtures.collection)
        XCTAssertEqual(second.entries, first.entries, "a second run rewrites the same entries")
        XCTAssertEqual(second.recorded, second.files, "the second record names every file of the folder")
        XCTAssertEqual(
            second.entries,
            [
                ".lungfish-provenance.json",
                "Genus_A_taxid10.fastq.gz", "Genus_A_taxid10.fastq.gz.lungfish-provenance.json",
                "Species_B_taxid20.fastq.gz", "Species_B_taxid20.fastq.gz.lungfish-provenance.json",
            ],
            "the folder after a second run"
        )
    }

    /// BIO 6 at the base. A person edits a collection, keeping its id, and runs it again into the same
    /// `extracted-<id>` folder. The folder keeps the file and the sidecar of the taxon the edit removed,
    /// and the new root record does not name that file.
    func testASecondRunOfAnEditedCollectionKeepsAFileItsRecordDoesNotName() async throws {
        let original = TaxaCollectionFixtures.collection
        _ = try await runLeaf(original)
        let kept = try keptGenusFiles(original)
        let edited = TaxaCollection(
            id: original.id, name: original.name, description: "", sfSymbol: "circle",
            taxa: [TaxonTarget(name: "Species B", taxId: TaxaCollectionFixtures.speciesB, includeChildren: false)]
        )

        let second = try await runLeaf(edited)
        XCTAssertEqual(second.recorded, ["Species_B_taxid20.fastq.gz"], "the new record names the one file it wrote")
        XCTAssertEqual(
            Set(second.files).subtracting(second.recorded), ["Genus_A_taxid10.fastq.gz"],
            "the removed taxon's file stays, which the new record does not name"
        )
        XCTAssertTrue(second.entries.contains("Genus_A_taxid10.fastq.gz.lungfish-provenance.json"), "its sidecar stays too")
        // BIO's ruling on lane 12.11, Q1 condition 1. The leaf never rewrites a file this run does not write.
        let after = try keptGenusFiles(original)
        XCTAssertEqual(after.file, kept.file, "a kept file and its record are not rewritten")
        XCTAssertEqual(after.sidecar, kept.sidecar, "a kept file and its record are not rewritten")
    }

    /// BIO's ruling on lane 12.11, Q1. A taxon renamed between two runs of one collection leaves the
    /// earlier file beside the new one, and the new record names only the new name. Both hold the reads.
    func testASecondRunWithARenamedTaxonKeepsTheEarlierFileAndRecordsOnlyTheNewName() async throws {
        let original = TaxaCollectionFixtures.collection
        _ = try await runLeaf(original)
        let renamed = TaxaCollection(
            id: original.id, name: original.name, description: "", sfSymbol: "circle",
            taxa: [
                TaxonTarget(name: "Genus A2", taxId: TaxaCollectionFixtures.genus, includeChildren: true),
                TaxonTarget(name: "Species B", taxId: TaxaCollectionFixtures.speciesB, includeChildren: false),
            ]
        )

        let second = try await runLeaf(renamed)
        XCTAssertTrue(second.files.contains("Genus_A_taxid10.fastq.gz"), "the earlier file stays")
        XCTAssertTrue(second.files.contains("Genus_A2_taxid10.fastq.gz"), "the new name is written")
        XCTAssertEqual(second.recorded, ["Genus_A2_taxid10.fastq.gz", "Species_B_taxid20.fastq.gz"], "the new record names only this run's files")
        let folder = extractedFolder(of: try ClassificationResult.load(from: fixtures.singleEnd), original)
        XCTAssertEqual(
            try TaxaCollectionFixtures.recordNames(in: folder.appendingPathComponent("Genus_A_taxid10.fastq.gz")),
            try TaxaCollectionFixtures.recordNames(in: folder.appendingPathComponent("Genus_A2_taxid10.fastq.gz")),
            "the two Genus files hold the same reads"
        )
    }

    /// The bytes of Genus A's file and its sidecar in the collection's folder.
    private func keptGenusFiles(_ collection: TaxaCollection) throws -> (file: Data, sidecar: Data) {
        let folder = extractedFolder(of: try ClassificationResult.load(from: fixtures.singleEnd), collection)
        return (
            try Data(contentsOf: folder.appendingPathComponent("Genus_A_taxid10.fastq.gz")),
            try Data(contentsOf: folder.appendingPathComponent("Genus_A_taxid10.fastq.gz.lungfish-provenance.json"))
        )
    }
}

/// Cancels a task from inside its own progress callback, once the task exists.
private final class TaxaCollectionCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<[URL], any Error>?
    private var requested = false

    func install(_ task: Task<[URL], any Error>) {
        lock.lock()
        self.task = task
        let cancelNow = requested
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
