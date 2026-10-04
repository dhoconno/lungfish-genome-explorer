// ViralReconReadSetCLITests.swift - workflow run nf-core/viralrecon reads every read of a bundle in the right roles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A bundle used to resolve to its first file, so a paired derivative (L5b)
// gave R1, a merge or repair derivative (L5c, L5d) gave one role file, and a
// virtual derivative (L6) gave its preview. The samplesheet then refused the
// uncompressed file, and a chunked root (L4) of gzip chunks ran its first two
// chunks as R1 and R2. Inside the run the read-set resolver now plans every
// bundle row: pairs run as a gzip R1 and R2 row, a sample that mixes pairs and
// single reads runs as one gzip single-end row of every read with the reason
// recorded, and a virtual bundle is materialized first. A root of one file
// keeps its row byte for byte (docs/contracts/READ-PAIRING.md, Phase 1.5 A6b).

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class ViralReconReadSetCLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-read-sets-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Stand-in Nextflow

    /// One samplesheet row as Nextflow was launched with it, with the read
    /// names of each FASTQ it names, read while the run's scratch exists.
    struct LaunchedRow: Equatable {
        let sample: String
        let fastq1: String
        let fastq2: String
        let reads1: [String]
        let reads2: [String]
    }

    final class CapturingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        private(set) var launches: [(arguments: [String], rows: [LaunchedRow])] = []

        func runNextflow(arguments: [String], workingDirectory: URL, environment: [String: String]) async throws -> NFCoreWorkflowProcessResult {
            var rows: [LaunchedRow] = []
            if let index = arguments.firstIndex(of: "--input"), index + 1 < arguments.count {
                let text = (try? String(contentsOf: URL(fileURLWithPath: arguments[index + 1]), encoding: .utf8)) ?? ""
                for line in text.split(separator: "\n").dropFirst() {
                    let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    let fastq2 = fields.count > 2 ? fields[2] : ""
                    rows.append(LaunchedRow(
                        sample: fields[0],
                        fastq1: fields[1],
                        fastq2: fastq2,
                        reads1: await Self.readNames(fields[1]),
                        reads2: fastq2.isEmpty ? [] : await Self.readNames(fastq2)
                    ))
                }
            }
            launches.append((arguments, rows))
            if let index = arguments.firstIndex(of: "--outdir"), index + 1 < arguments.count {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: arguments[index + 1]), withIntermediateDirectories: true)
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
        }

        static func readNames(_ path: String) async -> [String] {
            guard let records = try? await FASTQReader(validateSequence: false).readAll(from: URL(fileURLWithPath: path)) else {
                return ["<unreadable \(path)>"]
            }
            return records.map { record in
                record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
            }
        }
    }

    private struct ViralReconRun {
        let runBundleURL: URL
        let rows: [LaunchedRow]
        let arguments: [String]

        var callerSamplesheet: URL { runBundleURL.appendingPathComponent("inputs/samplesheet.csv") }

        func decisions() throws -> [ViralReconReadPairingDecision] {
            try XCTUnwrap(ViralReconReadPairing.loadDecisions(
                from: runBundleURL.appendingPathComponent("inputs/\(ViralReconReadPairing.decisionsFilename)")
            ))
        }
    }

    /// Runs `lungfish-cli workflow run nf-core/viralrecon --input <input>`
    /// with the stand-in Nextflow.
    private func runViralRecon(input: URL, name: String = "viralrecon") async throws -> ViralReconRun {
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        let runner = CapturingNextflowRunner()
        RunSubcommand.nfCoreWorkflowProcessRunner = runner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        let runBundleURL = root.appendingPathComponent("\(name).lungfishrun", isDirectory: true)
        let results = root.appendingPathComponent("\(name)-results", isDirectory: true)
        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", input.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", runBundleURL.path,
            "--version", "3.0.0",
            "--param", "protocol=amplicon",
            "--quiet",
        ]).run()
        let launch = try XCTUnwrap(runner.launches.first, "Nextflow was never launched")
        return ViralReconRun(runBundleURL: runBundleURL, rows: launch.rows, arguments: launch.arguments)
    }

    private func samplesheetRows(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private func gzip(_ url: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return URL(fileURLWithPath: url.path + ".gz")
    }

    private static func fastq(_ names: [String]) -> String {
        ReadSetFixtures.fastq(names)
    }

    // MARK: - Derived bundles

    /// L5b. Before: R1 alone, refused as an uncompressed file.
    func testAPairedDerivativeRunsAsOneGzipR1AndR2Row() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let run = try await runViralRecon(input: fixtures.pairedDerivative)

        XCTAssertEqual(run.rows.count, 1)
        let row = try XCTUnwrap(run.rows.first)
        XCTAssertEqual(row.sample, "paired")
        XCTAssertTrue(row.fastq1.hasSuffix(".fastq.gz"), row.fastq1)
        XCTAssertTrue(row.fastq2.hasSuffix(".fastq.gz"), row.fastq2)
        XCTAssertEqual(row.reads1, ["p1/1", "p2/1"])
        XCTAssertEqual(row.reads2, ["p1/2", "p2/2"])
        XCTAssertFalse(row.fastq1.contains(" "), "staged on a whitespace-free path")

        // The caller's samplesheet names the bundle the user chose, so the
        // recorded command plans it again.
        XCTAssertEqual(try canonicalRows(run.callerSamplesheet), [["paired", canonical(fixtures.pairedDerivative.path), ""]])
        let decision = try XCTUnwrap(try run.decisions().first)
        XCTAssertTrue(decision.runsPaired)
        XCTAssertNil(decision.warning)
        XCTAssertEqual(decision.pairCount, 2)
    }

    /// L5c. Before: the merged reads alone, refused as an uncompressed file.
    func testAMergeDerivativeRunsAsOneGzipSingleEndRowOfEveryReadWithTheReason() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let run = try await runViralRecon(input: fixtures.mergeDerivative)

        XCTAssertEqual(run.rows.count, 1)
        let row = try XCTUnwrap(run.rows.first)
        XCTAssertEqual(row.sample, "merge")
        XCTAssertTrue(row.fastq1.hasSuffix(".fastq.gz"), row.fastq1)
        XCTAssertEqual(row.fastq2, "")
        XCTAssertEqual(row.reads1, ["u1/1", "u1/2", "x1", "x2", "x3"])

        let decision = try XCTUnwrap(try run.decisions().first)
        XCTAssertFalse(decision.runsPaired)
        let warning = try XCTUnwrap(decision.warning)
        XCTAssertTrue(warning.contains("single"), warning)
    }

    /// L5d. Before: R1 alone, refused as an uncompressed file.
    func testARepairDerivativeRunsAsOneGzipSingleEndRowOfEveryRead() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let run = try await runViralRecon(input: fixtures.repairDerivative)

        let row = try XCTUnwrap(run.rows.first)
        XCTAssertEqual(run.rows.count, 1)
        XCTAssertEqual(row.fastq2, "")
        XCTAssertEqual(row.reads1, ["r1/1", "r2/1", "r1/2", "r2/2", "o1"])
        XCTAssertNotNil(try run.decisions().first?.warning)
    }

    // MARK: - A chunked root of gzip chunks

    /// L4. Before: the two chunks ran as R1 and R2 of one pair.
    func testAChunkedRootOfGzipChunksRunsAsOneSingleEndRowNotAsAPair() async throws {
        let bundle = root.appendingPathComponent("chunked.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Self.fastq(["c1", "c2"]).write(to: chunks.appendingPathComponent("run_0.fastq"), atomically: true, encoding: .utf8)
        try Self.fastq(["c3"]).write(to: chunks.appendingPathComponent("run_1.fastq"), atomically: true, encoding: .utf8)
        let chunk0 = try gzip(chunks.appendingPathComponent("run_0.fastq"))
        _ = try gzip(chunks.appendingPathComponent("run_1.fastq"))
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .illumina), for: chunk0)
        try Self.fastq(["c1"]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq.gz", originalPath: "/orig/run_0.fastq.gz", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq.gz", originalPath: "/orig/run_1.fastq.gz", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)

        let run = try await runViralRecon(input: bundle)

        XCTAssertEqual(run.rows.count, 1)
        let row = try XCTUnwrap(run.rows.first)
        XCTAssertEqual(row.fastq2, "", "chunks of single reads are not mates")
        XCTAssertEqual(row.reads1, ["c1", "c2", "c3"])
    }

    // MARK: - A virtual bundle (seqkit)

    /// L6. Before: the preview, refused as an uncompressed file.
    func testAVirtualSubsetIsMaterializedThenSplitIntoGzipR1AndR2() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
        let subset = try makeIlluminaSubset()

        let run = try await runViralRecon(input: subset)

        let row = try XCTUnwrap(run.rows.first)
        XCTAssertEqual(run.rows.count, 1)
        XCTAssertEqual(row.reads1, ["f1 1:N:0:1", "f3 1:N:0:1"])
        XCTAssertEqual(row.reads2, ["f1 2:N:0:1", "f3 2:N:0:1"])
        XCTAssertEqual(try run.decisions().first?.pairCount, 2)
    }

    // MARK: - Roots of one file keep their row

    /// L1, L2 and L3 of gzip files. The caller's samplesheet names the file
    /// as before, an L1 or L3 file reaches Nextflow untouched and an L2 file
    /// is split into R1 and R2 as before.
    func testARootOfOneGzipFileKeepsItsRowByteForByte() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let single = try gzip(fixtures.singleRoot.appendingPathComponent("single.fastq"))
        let mixedFile = fixtures.mixedRoot.appendingPathComponent("reads.fastq")
        let mixedSidecar = try XCTUnwrap(FASTQMetadataStore.load(for: mixedFile))
        let mixed = try gzip(mixedFile)
        try? FileManager.default.removeItem(at: FASTQMetadataStore.metadataURL(for: mixedFile))
        var gzipClassification = mixedSidecar
        gzipClassification.readClassification = gzipClassification.readClassification.map { classification in
            ReadClassification(files: classification.files.map { .init(filename: mixed.lastPathComponent, role: $0.role, readCount: $0.readCount) })
        }
        FASTQMetadataStore.save(gzipClassification, for: mixed)

        let singleRun = try await runViralRecon(input: fixtures.singleRoot, name: "single")
        XCTAssertEqual(try canonicalRows(singleRun.callerSamplesheet), [["single", canonical(single.path), ""]])
        XCTAssertEqual(singleRun.rows.map { canonical($0.fastq1) }, [canonical(single.path)])
        XCTAssertEqual(singleRun.rows.first?.reads1, ["s1", "s2", "s3"])
        XCTAssertTrue(singleRun.arguments.contains(singleRun.callerSamplesheet.path), "no staging, the caller's samplesheet is launched")

        let mixedRun = try await runViralRecon(input: fixtures.mixedRoot, name: "mixed")
        XCTAssertEqual(try canonicalRows(mixedRun.callerSamplesheet), [["mixed-root", canonical(mixed.path), ""]])
        XCTAssertEqual(mixedRun.rows.map { canonical($0.fastq1) }, [canonical(mixed.path)])
        XCTAssertEqual(try mixedRun.decisions().map(\.handling), [.asSingle])
        XCTAssertTrue(mixedRun.arguments.contains(mixedRun.callerSamplesheet.path))
    }

    /// `/private/var` and `/var` name the same folder, and the CLI records
    /// whichever spelling it standardized.
    private func canonical(_ path: String) -> String {
        path.isEmpty ? path : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func canonicalRows(_ url: URL) throws -> [[String]] {
        try samplesheetRows(url).map { row in row.enumerated().map { $0.offset == 0 ? $0.element : canonical($0.element) } }
    }

    // MARK: - Nanopore

    /// A virtual ONT bundle used to run on its preview, copied into
    /// `fastq_pass`. It is now refused before anything is written.
    func testAVirtualNanoporeBundleIsRefusedWithTheMaterializeCommand() async throws {
        let subset = try makeNanoporeSubset()
        let command = try RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", subset.path,
            "--results-dir", root.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", root.appendingPathComponent("nanopore.lungfishrun", isDirectory: true).path,
            "--version", "3.0.0",
            "--prepare-only",
            "--quiet",
        ])
        do {
            try await command.run()
            XCTFail("a virtual Nanopore bundle must be refused")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains(subset.lastPathComponent), message)
            XCTAssertTrue(message.contains("lungfish-cli fastq materialize"), message)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("nanopore.lungfishrun/inputs/fastq_pass").path),
            "no preview was staged for the pipeline"
        )
    }

    // MARK: - Fixtures

    /// A virtual length-filter subset of an Illumina root of Casava pairs
    /// f1 to f3, listing f1 and f3, with the preview of f1.
    private func makeIlluminaSubset() throws -> URL {
        let imports = root.appendingPathComponent("Subset.lungfish/Imports", isDirectory: true)
        let rootBundle = imports.appendingPathComponent("pairs.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFile = rootBundle.appendingPathComponent("reads.fastq")
        try Self.fastq(["f1 1:N:0:1", "f1 2:N:0:1", "f2 1:N:0:1", "f2 2:N:0:1", "f3 1:N:0:1", "f3 2:N:0:1"])
            .write(to: rootFile, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .illumina), for: rootFile)
        return try makeSubset(of: "pairs", in: imports, listing: ["f1", "f3"], preview: ["f1 1:N:0:1", "f1 2:N:0:1"], pairing: .interleaved)
    }

    /// A virtual subset of an ONT root of 1,200-base reads, listing two of
    /// its three. The read length alone makes it Nanopore.
    private func makeNanoporeSubset() throws -> URL {
        let imports = root.appendingPathComponent("Nanopore.lungfish/Imports", isDirectory: true)
        let rootBundle = imports.appendingPathComponent("ont.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFile = rootBundle.appendingPathComponent("reads.fastq")
        try Self.longReads(["n1", "n2", "n3"]).write(to: rootFile, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: rootFile)
        return try makeSubset(of: "ont", in: imports, listing: ["n1", "n3"], preview: Self.longReads(["n1"]), pairing: .singleEnd)
    }

    private static func longReads(_ names: [String]) -> String {
        let sequence = String(repeating: "ACGT", count: 300)
        return names.map { "@\($0)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n" }.joined()
    }

    private func makeSubset(
        of rootName: String,
        in imports: URL,
        listing: [String],
        preview: [String],
        pairing: IngestionMetadata.PairingMode
    ) throws -> URL {
        try makeSubset(of: rootName, in: imports, listing: listing, preview: Self.fastq(preview), pairing: pairing)
    }

    private func makeSubset(
        of rootName: String,
        in imports: URL,
        listing: [String],
        preview previewText: String,
        pairing: IngestionMetadata.PairingMode
    ) throws -> URL {
        let bundle = imports.appendingPathComponent("\(rootName)-subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try (listing.joined(separator: "\n") + "\n").write(to: bundle.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try previewText.write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .lengthFilter)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "\(rootName)-subset",
                parentBundleRelativePath: "@/Imports/\(rootName).lungfishfastq",
                rootBundleRelativePath: "@/Imports/\(rootName).lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: listing.count, baseCount: 0),
                pairingMode: pairing
            ),
            in: bundle
        )
        return bundle.standardizedFileURL
    }
}
