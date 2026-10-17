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

import XCTest
@testable import LungfishApp
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
        let outputs = try await TaxonomyExtractionPipeline().extractBatch(
            collection: collection,
            classificationResult: result,
            tree: result.tree,
            outputDirectory: folder,
            progress: { _, message in log.append(message) }
        )
        return (outputs, folder)
    }

    // MARK: - extractBatch

    func testATwoTaxonCollectionWritesOneGzipFilePerTaxonUnderTheExtractedFolder() async throws {
        let log = TaxaCollectionProgressLog()
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
        let scratch = try FileManager.default.contentsOfDirectory(atPath: run.folder.path).filter { $0.hasPrefix(".kraken2-sources-") }
        XCTAssertEqual(scratch, [], "the scratch folder of the read files goes at the end")
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

    func testACancelBetweenTaxaStopsTheBatchAndKeepsTheFilesAlreadyWritten() async throws {
        let collection = TaxaCollectionFixtures.collection
        let result = try ClassificationResult.load(from: fixtures.singleEnd)
        let folder = extractedFolder(of: result, collection)
        let cancel = TaxaCollectionCancelBox()

        let task = Task.detached {
            try await TaxonomyExtractionPipeline().extractBatch(
                collection: collection,
                classificationResult: result,
                tree: result.tree,
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
        let scratch = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".kraken2-sources-") }
        XCTAssertEqual(scratch, [], "a cancel removes the scratch folder too")
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
