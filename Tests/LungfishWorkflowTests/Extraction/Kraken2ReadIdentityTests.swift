// Kraken2ReadIdentityTests.swift - Extract reads only the reads a Kraken2 result was made from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane READ-IDENTITY (BIO-READ-IDENTITY, S1). Import FASTQ's Replace puts other reads with the same read
// names at the place a Kraken2 result names. Extract took the reads by name from whatever file sat there, so reads
// trimmed or filtered after the run came out as the taxon's reads, or fewer of them, with no words. Extract now
// checks that every read the result names is there with the length kraken2 recorded, refuses in words when one is
// not, and says in its completion message when the files changed but the reads it names did not.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class Kraken2ReadIdentityTests: XCTestCase {
    private static let bundlePlace = "Imports/s.lungfishfastq"
    private static let names = ["r1", "r2", "r3", "r4"]
    private static let bases = ["A", "C", "G", "T"]

    /// Four reads of 20 bases, each of one base, as kraken2 classified them.
    private static var classifiedReads: [(String, String)] {
        zip(names, bases).map { ($0, String(repeating: $1, count: 20)) }
    }

    // MARK: - 4.4 tests 1 to 4

    /// The same names with each sequence 5 bases shorter, as fastp leaves them after the run.
    func testExtractRefusesReadsTrimmedAfterTheRun() async throws {
        let project = try makeProject()
        try project.writeResult(lengths: Array(repeating: "20", count: 4))
        try project.replaceReads(Self.classifiedReads.map { ($0.0, String($0.1.dropLast(5))) })

        let error = try await extractExpectingRefusal(project)

        XCTAssertEqual(
            error as? ClassifierExtractionError,
            .kraken2ReadsChanged(place: Self.bundlePlace, missing: 0, otherLength: 4, named: 4)
        )
        XCTAssertEqual(try project.writtenFASTQ(), [], "a refused Extract writes no FASTQ")
    }

    /// One of the four reads removed, as a host depletion or a deduplication leaves them.
    func testExtractRefusesReadsFilteredAfterTheRun() async throws {
        let project = try makeProject()
        try project.writeResult(lengths: Array(repeating: "20", count: 4))
        try project.replaceReads(Array(Self.classifiedReads.dropFirst()))

        let error = try await extractExpectingRefusal(project)

        XCTAssertEqual(
            error as? ClassifierExtractionError,
            .kraken2ReadsChanged(place: Self.bundlePlace, missing: 1, otherLength: 0, named: 4)
        )
        XCTAssertEqual(try project.writtenFASTQ(), [])
    }

    /// The same reads imported again in another order and with other header comments, so the file's size differs
    /// from the size the run recorded. Extract takes all four and says the files changed but the reads did not.
    func testExtractReadsTheSameReadsImportedAgainInAnotherOrder() async throws {
        let project = try makeProject()
        let recordedSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: project.payload.path)[.size] as? UInt64
        )
        try project.writeResult(
            lengths: Array(repeating: "20", count: 4),
            identities: [ReadFileIdentity(url: project.payload, sizeBytes: recordedSize, sha256: nil)]
        )
        try project.replaceReads(Self.classifiedReads.reversed(), comment: " imported-again")
        let messages = ReadIdentityMessages()

        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2, resultPath: project.resultFolder, selections: [ClassifierRowSelector(taxIds: [562])],
            options: ExtractionOptions(), destination: .file(project.output.appendingPathComponent("taxon.fastq")),
            progress: { _, message in messages.append(message) }
        )

        XCTAssertEqual(outcome.readCount, 4)
        let note = "The reads at \(Self.bundlePlace) changed after this result was made. Every read it names is there "
            + "with the length kraken2 saw, so Lungfish extracted them."
        XCTAssertTrue(messages.all.contains { $0.contains(note) }, "no note among \(messages.all)")
    }

    /// A sidecar written before the identity record existed decodes with no record and is still checked.
    func testOlderSidecarWithoutIdentitiesStillChecksLengths() async throws {
        let project = try makeProject()
        try project.writeResult(lengths: Array(repeating: "20", count: 4))
        let sidecar = try String(
            contentsOf: project.resultFolder.appendingPathComponent(ClassificationResult.sidecarFilename), encoding: .utf8
        )
        XCTAssertFalse(sidecar.contains("readFileIdentities"), "an older sidecar has no identity record")
        let config = try ClassificationResult.load(from: project.resultFolder).config
        XCTAssertNil(config.readFileIdentities)
        try project.replaceReads(Self.classifiedReads.map { ($0.0, String($0.1.dropLast(5))) })

        let error = try await extractExpectingRefusal(project)

        XCTAssertEqual(
            error as? ClassifierExtractionError,
            .kraken2ReadsChanged(place: Self.bundlePlace, missing: 0, otherLength: 4, named: 4)
        )
    }

    // MARK: - 4.4 tests 5 and 6

    /// kraken2 read pairs (`L|L`). Only the R2 file was trimmed again, for two of the four pairs, so each of those
    /// fragments has another length on its mate 2.
    func testPairedRunChecksEachMate() async throws {
        let project = try makeProject()
        let r1 = project.imports.appendingPathComponent("p_R1.fastq")
        let r2 = project.imports.appendingPathComponent("p_R2.fastq")
        try Self.fastq(Self.classifiedReads.map { ("\($0.0)/1", $0.1) }).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(Self.classifiedReads.map { ("\($0.0)/2", String($0.1.prefix(18))) })
            .write(to: r2, atomically: true, encoding: .utf8)
        try project.writeResult(lengths: Array(repeating: "20|18", count: 4), inputFiles: [r1, r2], originals: nil, paired: true)
        let trimmed = Self.classifiedReads.enumerated().map { index, read in
            ("\(read.0)/2", String(read.1.prefix(index < 2 ? 15 : 18)))
        }
        try Self.fastq(trimmed).write(to: r2, atomically: true, encoding: .utf8)

        let error = try await extractExpectingRefusal(project)

        guard case .kraken2ReadsChanged(let place, let missing, let otherLength, let named)? = error as? ClassifierExtractionError else {
            return XCTFail("\(error)")
        }
        XCTAssertEqual(place, "Imports/p_R1.fastq and Imports/p_R2.fastq")
        XCTAssertEqual([missing, otherLength, named], [0, 2, 4], "two fragments have another length on mate 2")
        XCTAssertEqual(try project.writtenFASTQ(), [])
    }

    /// A virtual trim derivative: kraken2 classified the trimmed reads, which Extract materializes from the root.
    /// Its reads have the lengths kraken2 saw, so Extract takes them as before.
    func testVirtualTrimDerivativePassesTheCheck() async throws {
        let project = try makeProject()
        let trimBundle = project.imports.appendingPathComponent("trim.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: trimBundle, withIntermediateDirectories: true)
        let table = FASTQTrimPositionFile.formatHeader + "\nread_id\tmate\ttrim_start\ttrim_end\n"
            + Self.names.map { "\($0)#0\t0\t2\t17\n" }.joined()
        try table.write(to: trimBundle.appendingPathComponent(FASTQBundle.trimPositionFilename), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .fixedTrim)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "trim", parentBundleRelativePath: "@/\(Self.bundlePlace)", rootBundleRelativePath: "@/\(Self.bundlePlace)",
                rootFASTQFilename: "reads.fastq", payload: .trim(trimPositionFilename: FASTQBundle.trimPositionFilename),
                lineage: [operation], operation: operation, cachedStatistics: .countsOnlyFixture(readCount: 4, baseCount: 60),
                pairingMode: .singleEnd, sequenceFormat: .fastq
            ),
            in: trimBundle
        )
        let scratch = project.resultFolder.appendingPathComponent(".lungfish-classify-inputs/materialized.fastq")
        try project.writeResult(lengths: Array(repeating: "15", count: 4), inputFiles: [scratch], originals: [trimBundle])

        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2, resultPath: project.resultFolder, selections: [ClassifierRowSelector(taxIds: [562])],
            options: ExtractionOptions(), destination: .file(project.output.appendingPathComponent("taxon.fastq"))
        )

        XCTAssertEqual(outcome.readCount, 4)
    }

    // MARK: - Fixture

    private func makeProject() throws -> ReadIdentityProject {
        let root = try TestTempDirectory.make(prefix: "kraken2-read-identity")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = try ReadIdentityProject(root: root)
        try Self.fastq(Self.classifiedReads).write(to: project.payload, atomically: true, encoding: .utf8)
        return project
    }

    /// Runs the Extract dialog's extraction, which must refuse, and returns its error.
    private func extractExpectingRefusal(_ project: ReadIdentityProject) async throws -> Error {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
            throw XCTSkip("managed seqkit is not installed")
        }
        do {
            let outcome = try await ClassifierReadResolver().resolveAndExtract(
                tool: .kraken2, resultPath: project.resultFolder, selections: [ClassifierRowSelector(taxIds: [562])],
                options: ExtractionOptions(), destination: .file(project.output.appendingPathComponent("taxon.fastq"))
            )
            XCTFail("Extract wrote \(outcome.readCount) reads from reads that are not the ones the result was made from")
            return CancellationError()
        } catch {
            return error
        }
    }

    nonisolated static func fastq(_ records: [(String, String)], comment: String = "") -> String {
        records.map { "@\($0.0)\(comment)\n\($0.1)\n+\n\(String(repeating: "I", count: $0.1.count))\n" }.joined()
    }
}

/// A project that holds the read bundle `Imports/s.lungfishfastq` and a Kraken2 result made from it.
struct ReadIdentityProject {
    let project: URL
    let imports: URL
    let bundle: URL
    let payload: URL
    let resultFolder: URL
    let output: URL

    @MainActor
    init(root: URL) throws {
        project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        _ = try ProjectFile.create(at: project, name: "P")
        imports = project.appendingPathComponent("Imports", isDirectory: true)
        bundle = imports.appendingPathComponent("s.lungfishfastq", isDirectory: true)
        payload = bundle.appendingPathComponent("reads.fastq")
        resultFolder = project.appendingPathComponent("Analyses/kraken2-s", isDirectory: true)
        output = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    /// The bundle's payload replaced by `records` under the same name, as Import FASTQ's Replace leaves it.
    func replaceReads(_ records: [(String, String)], comment: String = "") throws {
        try Kraken2ReadIdentityTests.fastq(records, comment: comment).write(to: payload, atomically: true, encoding: .utf8)
    }

    /// Writes a result whose kraken2 output classifies r1 to r4 to taxon 562 with `lengths`, made from `inputFiles`
    /// (the payload by default) and `originals` (the bundle by default).
    func writeResult(
        lengths: [String],
        inputFiles: [URL]? = nil,
        originals: [URL]? = [],
        paired: Bool = false,
        identities: [ReadFileIdentity]? = nil
    ) throws {
        try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: true)
        let report = resultFolder.appendingPathComponent("classification.kreport")
        try [
            "100.00\t4\t0\tR\t1\troot",
            "100.00\t4\t4\tS\t562\t  Escherichia coli",
        ].joined(separator: "\n").appending("\n").write(to: report, atomically: true, encoding: .utf8)
        let output = resultFolder.appendingPathComponent("classification.kraken")
        try zip(["r1", "r2", "r3", "r4"], lengths).map { "C\t\($0)\t562\t\($1)\t562:5\n" }.joined()
            .write(to: output, atomically: true, encoding: .utf8)
        var config = ClassificationConfig(
            inputFiles: inputFiles ?? [payload],
            isPairedEnd: paired,
            databaseName: "TestDB",
            databasePath: URL(fileURLWithPath: "/nonexistent/db", isDirectory: true),
            outputDirectory: resultFolder
        )
        config.originalInputFiles = originals.map { $0.isEmpty ? [bundle] : $0 }
        config.readFileIdentities = identities
        try ClassificationResult(
            config: config, tree: try KreportParser.parse(url: report), reportURL: report, outputURL: output,
            brackenURL: nil, runtime: 1, toolVersion: "2.1.3", provenanceId: nil
        ).save(to: resultFolder)
    }

    /// The FASTQ files Extract left in its output folder.
    func writtenFASTQ() throws -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        return names.filter { $0.contains(".fastq") }.sorted()
    }
}

/// The progress messages of one extraction, from whatever thread reports them.
final class ReadIdentityMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
