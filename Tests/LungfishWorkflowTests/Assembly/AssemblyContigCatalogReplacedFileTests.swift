// AssemblyContigCatalogReplacedFileTests.swift - A contigs file with an old index beside it is read as it is now
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REPLACED (ruling BIO-ASSEMBLY-REPLACED, Fix C). A run into the same folder, or a Finder Replace of the
// contigs file, leaves the earlier `.fai` beside the new file. Its offsets then read other bases, and a reopen does not cure
// it. The catalog now builds the index from the file it is given and writes it only when it differs.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class AssemblyContigCatalogReplacedFileTests: XCTestCase {
    private let oldContigs = ">a len=8\nACGTACGT\n>b len=8\nTTTTCCCC\n"
    private let newContigs = ">a len=12\nGGGGAAAATTTT\n>b len=12\nCCCCGGGGAAAA\n"

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-replaced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func makeResult(contigs contigsURL: URL) throws -> AssemblyResult {
        let folder = contigsURL.deletingLastPathComponent()
        return AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: folder.appendingPathComponent("assembly_graph.gfa"),
            logPath: folder.appendingPathComponent("spades.log"),
            assemblerVersion: "4.0.0",
            commandLine: "spades.py -o \(folder.path)",
            outputDirectory: folder,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 1,
            scaffoldsPath: folder.appendingPathComponent("scaffolds.fasta"),
            paramsPath: folder.appendingPathComponent("params.txt")
        )
    }

    /// The first run's contigs with their true index, then a second run's file over them with the first index left in place.
    private func leaveTheOldIndexBesideTheNewFile() throws -> (result: AssemblyResult, indexURL: URL) {
        let contigsURL = try makeFolder().appendingPathComponent("contigs.fasta")
        try oldContigs.write(to: contigsURL, atomically: true, encoding: .utf8)
        try FASTAIndexBuilder.buildAndWrite(for: contigsURL)
        let indexURL = contigsURL.appendingPathExtension("fai")
        XCTAssertEqual(try String(contentsOf: indexURL, encoding: .utf8), "a\t8\t9\t8\t9\nb\t8\t27\t8\t9\n")
        try newContigs.write(to: contigsURL, atomically: true, encoding: .utf8)
        return (try makeResult(contigs: contigsURL), indexURL)
    }

    func testACatalogBesideAnOldIndexReadsTheFileAsItIsNow() async throws {
        let (result, _) = try leaveTheOldIndexBesideTheNewFile()

        let catalog = try await AssemblyContigCatalog(result: result)

        let a = try await catalog.sequenceFASTA(for: "a", lineWidth: 0)
        let b = try await catalog.sequenceFASTA(for: "b", lineWidth: 0)
        XCTAssertEqual(a, ">a len=12\nGGGGAAAATTTT\n")
        XCTAssertEqual(b, ">b len=12\nCCCCGGGGAAAA\n")
        let records = try await catalog.records()
        let first = try XCTUnwrap(records.first { $0.name == "a" })
        XCTAssertEqual(first.lengthBP, 12)
        XCTAssertEqual(first.gcPercent, 100.0 / 3.0, accuracy: 0.01, "G and C are 4 of the 12 bases")
        XCTAssertEqual(first.previewSequence, "GGGGAAAATTTT")
    }

    func testACatalogRewritesAnIndexThatDiffersAndLeavesOneThatMatches() async throws {
        let (result, indexURL) = try leaveTheOldIndexBesideTheNewFile()

        _ = try await AssemblyContigCatalog(result: result)
        XCTAssertEqual(
            try String(contentsOf: indexURL, encoding: .utf8),
            "a\t12\t10\t12\t13\nb\t12\t33\t12\t13\n",
            "the index now describes the file beside it"
        )

        let aLongTimeAgo = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: aLongTimeAgo], ofItemAtPath: indexURL.path)
        _ = try await AssemblyContigCatalog(result: result)
        let attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, aLongTimeAgo, "an index that matches is not written again")
    }

    func testAFileWithARepeatedNameThrowsInWordsAndDoesNotCrash() async throws {
        let contigsURL = try makeFolder().appendingPathComponent("contigs.fasta")
        try ">a\nAC\n>a\nGT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
        let result = try makeResult(contigs: contigsURL)

        for opening in ["first", "second, which meets the index the first one wrote"] {
            do {
                _ = try await AssemblyContigCatalog(result: result)
                XCTFail("the \(opening) open must throw for a repeated name")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Duplicate contig name"), error.localizedDescription)
            }
        }
    }
}
