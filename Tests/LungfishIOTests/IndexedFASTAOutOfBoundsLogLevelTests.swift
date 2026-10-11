// IndexedFASTAOutOfBoundsLogLevelTests.swift - A read past the last base logs at debug, a wrong read keeps its error
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import OSLog
import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO

/// Walk finding F13. The indexed FASTA readers logged every read that failed the bounds check at
/// error level, including the window a caller makes on purpose, one that begins inside a record
/// and runs past its last base. The caller treats the thrown error as an empty result, so the
/// error log was noise that read as a fault. That read now logs at debug. A region that begins at
/// or after the end of the record names coordinates the record does not have, and keeps its error.
/// Both reads still throw `regionOutOfBounds`.
final class IndexedFASTAOutOfBoundsLogLevelTests: XCTestCase {
    // MARK: - The rule

    func testAReadThatBeginsInsideTheSequenceAndRunsPastItsEndLogsAtDebug() {
        let overhangs: [(start: Int, end: Int, length: Int)] = [
            (4, 11, 8), (7, 9, 8), (0, 29_904, 29_903), (29_902, 29_904, 29_903),
        ]
        for read in overhangs {
            XCTAssertEqual(
                FASTAOutOfBoundsLog.level(start: read.start, end: read.end, length: read.length), .debug,
                "\(read.start)-\(read.end) of \(read.length) begins inside the sequence"
            )
        }
    }

    func testAnyOtherReadThatFailsTheBoundsCheckKeepsItsError() {
        let wrongReads: [(start: Int, end: Int, length: Int)] = [
            (8, 9, 8), (9, 13, 8), (100, 200, 8), (-1, 3, 8), (-5, 20, 8),
        ]
        for read in wrongReads {
            XCTAssertEqual(
                FASTAOutOfBoundsLog.level(start: read.start, end: read.end, length: read.length), .error,
                "\(read.start)-\(read.end) of \(read.length) names coordinates the sequence does not have"
            )
        }
    }

    // MARK: - The logs a reader writes

    /// The error-level messages of this process since `date` that mention `text`, read back from
    /// the unified log, waiting for `expected` to show up so a slow flush cannot pass for silence.
    private func errorMessages(containing text: String, since date: Date, waitingFor expected: String) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        // The bgzip reader logs under the IO subsystem and the reference bundle under the Core one.
        let subsystems = [LogSubsystem.io, LogSubsystem.core]
        var messages: [String] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            messages = try store.getEntries(at: store.position(date: date))
                .compactMap { $0 as? OSLogEntryLog }
                .filter { subsystems.contains($0.subsystem) && $0.level == .error && $0.composedMessage.contains(text) }
                .map(\.composedMessage)
            if messages.contains(where: { $0.contains(expected) }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return messages
    }

    private func makeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishTests-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Tiny.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try ">chr1\nACGTACGT".write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t8\t6\t8\t9\n".write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            formatVersion: "1.0",
            name: "Tiny",
            identifier: "test.tiny",
            source: SourceInfo(organism: "Test", assembly: "chr1", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 8,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 8, offset: 6, lineBases: 8, lineWidth: 9)]
            )
        ).save(to: bundle)
        return bundle
    }

    func testAReferenceBundleLogsAnOverhangAtDebugAndARealOutOfBoundsReadAtError() async throws {
        let bundle = try await ReferenceBundle(url: try makeBundle())
        let since = Date().addingTimeInterval(-1)

        for (start, end) in [(4, 11), (9, 13)] {
            XCTAssertThrowsError(
                try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr1", start: start, end: end))
            ) { error in
                guard case ReferenceBundleError.regionOutOfBounds = error else {
                    return XCTFail("\(start)-\(end) throws regionOutOfBounds, not \(error)")
                }
            }
        }

        let errors = try errorMessages(containing: "Region out of bounds", since: since, waitingFor: "end=13")
        XCTAssertTrue(errors.contains { $0.contains("end=13") }, "A read that begins past the end keeps its error. \(errors)")
        XCTAssertFalse(errors.contains { $0.contains("end=11") }, "A read that overhangs the end is not an error. \(errors)")
        XCTAssertEqual(
            try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr1", start: 2, end: 6)), "GTAC",
            "A read inside the sequence is unchanged."
        )
    }

    func testTheBgzipReaderLogsAnOverhangAtDebugAndARealOutOfBoundsReadAtError() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            throw XCTSkip("samtools and bgzip are not available in this environment")
        }
        let bgzip = URL(fileURLWithPath: samtools).deletingLastPathComponent().appendingPathComponent("bgzip").path
        guard FileManager.default.isExecutableFile(atPath: bgzip) else {
            throw XCTSkip("samtools and bgzip are not available in this environment")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BgzipOutOfBounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let fasta = folder.appendingPathComponent("tiny.fa")
        try ">chr1\nACGTACGT\n>chr2\nACGTACGTACGT\n".write(to: fasta, atomically: true, encoding: .utf8)
        let compressed = folder.appendingPathComponent("tiny.fa.gz")
        FileManager.default.createFile(atPath: compressed.path, contents: nil)
        let output = try FileHandle(forWritingTo: compressed)
        let compress = Process()
        compress.executableURL = URL(fileURLWithPath: bgzip)
        compress.arguments = ["-c", fasta.path]
        compress.standardOutput = output
        try compress.run()
        compress.waitUntilExit()
        try output.close()
        XCTAssertEqual(compress.terminationStatus, 0)
        let index = Process()
        index.executableURL = URL(fileURLWithPath: samtools)
        index.arguments = ["faidx", compressed.path]
        try index.run()
        index.waitUntilExit()
        XCTAssertEqual(index.terminationStatus, 0)

        let reader = try SyncBgzipFASTAReader(
            url: compressed,
            faiURL: URL(fileURLWithPath: compressed.path + ".fai"),
            gziURL: URL(fileURLWithPath: compressed.path + ".gzi")
        )
        let since = Date().addingTimeInterval(-1)
        // The region is logged as private text, so the two reads are told apart by the length of
        // the record they ran past, 8 for chr1 and 12 for chr2.
        for (chromosome, start, end) in [("chr1", 4, 11), ("chr2", 14, 20)] {
            XCTAssertThrowsError(
                try reader.fetchSync(region: GenomicRegion(chromosome: chromosome, start: start, end: end))
            ) { error in
                guard case BgzipError.regionOutOfBounds = error else {
                    return XCTFail("\(chromosome):\(start)-\(end) throws regionOutOfBounds, not \(error)")
                }
            }
        }

        let errors = try errorMessages(containing: "Region out of bounds", since: since, waitingFor: "> 12")
        XCTAssertTrue(errors.contains { $0.hasSuffix("> 12") }, "A read that begins past the end keeps its error. \(errors)")
        XCTAssertFalse(errors.contains { $0.hasSuffix("> 8") }, "A read that overhangs the end is not an error. \(errors)")
    }
}
