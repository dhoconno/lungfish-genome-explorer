// FASTQToolIntegrationTests.swift - End-to-end FASTQ processing tests using real tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// Integration tests for FASTQ processing operations using real bioinformatics tools.
///
/// These tests exercise the complete tool execution pipeline:
/// NativeToolRunner → resolved tool binary → file I/O verification.
///
/// Test data is synthetic FASTQ created in-memory (20 reads, variable lengths,
/// mixed quality) to avoid network dependencies.
final class FASTQToolIntegrationTests: XCTestCase {

    // MARK: - Fixture Setup

    private var tempDir: URL!
    private var inputFastqURL: URL!
    private let runner = NativeToolRunner.shared

    /// 20-read synthetic FASTQ with variable read lengths and quality patterns.
    /// Reads 1-10: 96-100 bp, Q40 (all I)
    /// Reads 11-12: 144 bp, Q40
    /// Reads 13-14: 72 bp, Q40
    /// Read 5: mixed quality (I/5 alternating blocks)
    /// Reads 15-20: 96-99 bp, Q40
    private static let syntheticFastq = """
        @read_001
        ATCGATCGTTAGCAATCCGGTACAGTCATGCTTAAGGCCATTGCAATCGGTTACAGTCATGCTTAAGGCCAATTAGGCAATCCGGTACAGTCATGCTTAA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_002
        GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_003
        TTAGGCAATCCGGTACAGTCATGCTTAAGGCCATTGCAATCGGTTACAGTCATGCTTAAGGCCAATTAGGCAATCCGGTACAGTCATGCTTAAGGCCATT
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_004
        CCAGTGTTACGGATCAACTTAGCGTCAGGTTACGATCCAGTGTTACGGATCAACTTAGCGTCAGGTTACGATCCAGTGTTACGGATCAACTTAGCGTCAG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_005
        AGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTC
        +
        IIIII55555IIIII55555IIIII55555IIIII55555IIIII55555IIIII55555IIIII55555IIIII55555IIIII55555IIIII55555
        @read_006
        TGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_007
        ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_008
        CGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGAT
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_009
        TAGGCTTAACGGTCAACTGCATTAGGCTTAACGGTCAACTGCATTAGGCTTAACGGTCAACTGCATTAGGCTTAACGGTCAACTGCATTAGGCTTAACGG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_010
        GAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAAC
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_011
        ATCGATCGTTAGCAATCCGGTACAGTCATGCTTAAGGCCATTGCAATCGGTTACAGTCATGCTTAAGGCCAATTAGGCAATCCGGTACAGTCATGCTTAAGGCCATTGCAATCGGTTACAGTCATGCTTAAGGCCAATTAGGCAATCCGG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_012
        GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTACCAGTGTTACGGATCAACTTAGCGTCAGGTTACGATCCAGTGTTACGGATCAACTTAGCGTCAGGTTACG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_013/1
        TTAGGCAATCCGGTACAGTCATGCTTAAGGCCATTGCAATCGGTTACAGTCATGCTTAAGGCCAATTAGGCAATC
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_013/2
        GATTGCCTAATTGGCCTTAAGCATGACTGTAACCGATTGCAATGGCCTTAAGCATGACTGTACCGGATTGCCTAA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_014/1
        CCAGTGTTACGGATCAACTTAGCGTCAGGTTACGATCCAGTGTTACGGATCAACTTAGCGTCAGGTTACGATCCA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_014/2
        TGGATCGTAACCTGACGCTAAGTTGATCCGTAACACTGGATCGTAACCTGACGCTAAGTTGATCCGTAACACTGG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_015
        TTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGCCAATTAGGCAATCCGGTACAGTCATGCTTAAGGCCATTGCAATCGGTTACAGTCATGCTTAAG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_016
        AGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGCCAGTGTTACGGATCAACTTAGCGTCAGGTTACGATCCAGTGTTACGGATCAACTTAGCGTCAGGT
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_017
        GCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCAT
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_018
        TACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGGTACGG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_019
        CAACTGCATTAGGCTTAACGGTCAACTGCATTAGGCTTAACGGTCAACTGCATTAGGCTTAACGGTCAACTGCATTAGGCTTAACGGTCAACTGCATTAG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read_020
        GGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAACCTTGGAA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII

        """

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        inputFastqURL = tempDir.appendingPathComponent("input.fastq")
        try Self.syntheticFastq.write(to: inputFastqURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    private func countFastqRecords(at url: URL) throws -> Int {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        // FASTQ records are exactly 4 lines: header, sequence, +, quality
        return lines.count / 4
    }

    private func bbToolsEnv(for tool: NativeTool) async throws -> [String: String] {
        try await requireManagedTool(tool)

        return CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        )
    }

    private func requireManagedTool(_ tool: NativeTool) async throws {
        guard (try? await runner.toolPath(for: tool)) != nil else {
            try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
        }
    }

    // MARK: - Seqkit Operations

    func testSeqkitSubsampleByProportion() async throws {
        let outputURL = tempDir.appendingPathComponent("subsample.fastq")
        let result = try await runner.run(.seqkit, arguments: [
            "sample", "-p", "0.5", inputFastqURL.path, "-o", outputURL.path,
        ])
        XCTAssertTrue(result.isSuccess, "seqkit sample should succeed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let count = try countFastqRecords(at: outputURL)
        XCTAssertGreaterThan(count, 0, "Subsampled output should have at least 1 read")
        XCTAssertLessThanOrEqual(count, 22, "Subsampled output should have fewer than all reads")
    }

    func testSeqkitSubsampleByCount() async throws {
        let outputURL = tempDir.appendingPathComponent("subsample_n.fastq")
        let result = try await runner.run(.seqkit, arguments: [
            "sample", "-n", "5", inputFastqURL.path, "-o", outputURL.path,
        ])
        XCTAssertTrue(result.isSuccess, "seqkit sample -n should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertGreaterThan(count, 0, "Should have at least 1 read")
        XCTAssertLessThanOrEqual(count, 22, "Should not exceed total read count")
    }

    func testSeqkitLengthFilter() async throws {
        let outputURL = tempDir.appendingPathComponent("length_filtered.fastq")
        let result = try await runner.run(.seqkit, arguments: [
            "seq", "-m", "90", "-M", "100", inputFastqURL.path, "-o", outputURL.path,
        ])
        XCTAssertTrue(result.isSuccess, "seqkit length filter should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertGreaterThan(count, 0, "Some reads should pass the 90-100bp filter")
    }

    func testSeqkitStats() async throws {
        let result = try await runner.run(.seqkit, arguments: [
            "stats", "--tabular", inputFastqURL.path,
        ])
        XCTAssertTrue(result.isSuccess, "seqkit stats should succeed: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("22"), "Stats should show 22 records")
    }

    func testSeqkitDeduplicate() async throws {
        // Create input with duplicates
        let dupURL = tempDir.appendingPathComponent("dups.fastq")
        let dupContent = """
            @dup1
            ACGTACGT
            +
            IIIIIIII
            @dup2
            ACGTACGT
            +
            IIIIIIII
            @unique
            TTTTAAAA
            +
            IIIIIIII

            """
        try dupContent.write(to: dupURL, atomically: true, encoding: .utf8)

        let outputURL = tempDir.appendingPathComponent("dedup.fastq")
        let result = try await runner.run(.seqkit, arguments: [
            "rmdup", "-s", dupURL.path, "-o", outputURL.path,
        ])
        XCTAssertTrue(result.isSuccess, "seqkit rmdup should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertEqual(count, 2, "Should have 2 unique sequences after dedup")
    }

    func testSeqkitSearchByIdentifier() async throws {
        let outputURL = tempDir.appendingPathComponent("search_by_id.fastq")
        let result = try await runner.run(.seqkit, arguments: [
            "grep", "-r", "-p", "read_00[1-2]", inputFastqURL.path, "-o", outputURL.path,
        ])
        XCTAssertTrue(result.isSuccess, "seqkit grep by ID should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertEqual(count, 2, "Expected exactly 2 ID-matched reads")
    }

    func testSeqkitSearchByMotif() async throws {
        let outputURL = tempDir.appendingPathComponent("search_by_motif.fastq")
        let result = try await runner.run(.seqkit, arguments: [
            "grep", "-s", "-p", "CCAGTGTTACGGATCAACTTAGCGTCA", inputFastqURL.path, "-o", outputURL.path,
        ])
        XCTAssertTrue(result.isSuccess, "seqkit grep by motif should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertGreaterThanOrEqual(count, 1, "Motif search should match at least one read")
    }

    // MARK: - Fastp Operations

    func testFastpQualityTrim() async throws {
        try await requireManagedTool(.fastp)
        let outputURL = tempDir.appendingPathComponent("qtrim.fastq")
        let result = try await runner.run(.fastp, arguments: [
            "-i", inputFastqURL.path,
            "-o", outputURL.path,
            "-W", "4", "-M", "20",
            "--cut_right",
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ])
        XCTAssertTrue(result.isSuccess, "fastp quality trim should succeed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let count = try countFastqRecords(at: outputURL)
        XCTAssertGreaterThan(count, 0, "Quality-trimmed output should have reads")
    }

    func testFastpAdapterTrim() async throws {
        try await requireManagedTool(.fastp)
        let outputURL = tempDir.appendingPathComponent("adapter_trim.fastq")
        let result = try await runner.run(.fastp, arguments: [
            "-i", inputFastqURL.path,
            "-o", outputURL.path,
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ])
        XCTAssertTrue(result.isSuccess, "fastp adapter trim should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertGreaterThan(count, 0, "Adapter-trimmed output should have reads")
    }

    func testFastpFixedTrim() async throws {
        try await requireManagedTool(.fastp)
        let outputURL = tempDir.appendingPathComponent("fixed_trim.fastq")
        let result = try await runner.run(.fastp, arguments: [
            "-i", inputFastqURL.path,
            "-o", outputURL.path,
            "--trim_front1", "5",
            "--trim_tail1", "5",
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ])
        XCTAssertTrue(result.isSuccess, "fastp fixed trim should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertGreaterThan(count, 0, "Fixed-trimmed output should have reads")
    }

    // MARK: - BBTools Operations

    func testBBDukContaminantFilter() async throws {
        let outputURL = tempDir.appendingPathComponent("filtered.fastq")
        let env = try await bbToolsEnv(for: .bbduk)

        // Resolve the PhiX reference path from the bbtools resources directory
        let phixRef = await runner.getToolsDirectory()?
            .appendingPathComponent("bbtools/resources/phix174_ill.ref.fa.gz")
        let refArg: String
        if let phixRef, FileManager.default.fileExists(atPath: phixRef.path) {
            refArg = "ref=\(phixRef.path)"
        } else {
            // Fallback: use a synthetic reference (a sequence not in our test data)
            let syntheticRef = tempDir.appendingPathComponent("contam_ref.fa")
            try ">contam\nNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN\n".write(
                to: syntheticRef, atomically: true, encoding: .utf8
            )
            refArg = "ref=\(syntheticRef.path)"
        }

        let result = try await runner.run(.bbduk, arguments: [
            "in=\(inputFastqURL.path)",
            "out=\(outputURL.path)",
            refArg,
            "k=31",
            "hdist=1",
        ], environment: env, timeout: 120)

        XCTAssertTrue(result.isSuccess, "bbduk contaminant filter should succeed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let count = try countFastqRecords(at: outputURL)
        // Our synthetic reads don't contain contaminant sequences, so all should pass
        XCTAssertEqual(count, 22, "All reads should pass contaminant filter")
    }

    /// bbduk's entropy filter must drop tandem-repeat reads while keeping
    /// normal-complexity reads. This is the property the whole operation exists
    /// for, and the one fastp's complexity metric cannot deliver.
    /// Regression guard for the NativeToolRunner BBTools space shim: bbduk.sh
    /// word-splits paths containing spaces (its wrapper rebuilds the java
    /// command line), so the runner symlinks such paths before launch. Running
    /// a real bbduk from a directory WITH a space in its name proves the shim
    /// stays wired for inputs and outputs alike.
    func testBBDukEntropyFilterSurvivesPathsWithSpaces() async throws {
        let spacedDir = tempDir.appendingPathComponent("space dir input")
        try FileManager.default.createDirectory(at: spacedDir, withIntermediateDirectories: true)
        let input = spacedDir.appendingPathComponent("reads with space.fastq")
        let lowComplexity = String(repeating: "ATC", count: 50)
        var fastq = ""
        for index in 0..<5 {
            fastq += "@repeat\(index)\n\(lowComplexity)\n+\n\(String(repeating: "I", count: lowComplexity.count))\n"
        }
        fastq += "@normal\nAGCTTAGCTAGGATCCAGTCAAGGTTACCAGTGGATCAAGTCCGGATAAG\n+\n\(String(repeating: "I", count: 50))\n"
        try fastq.write(to: input, atomically: true, encoding: .utf8)
        let output = spacedDir.appendingPathComponent("filtered with space.fastq")

        let result = try await runner.run(.bbduk, arguments: [
            "in=\(input.path)",
            "out=\(output.path)",
            "entropy=0.6", "entropywindow=50", "entropyk=5", "ow=t",
        ])

        XCTAssertTrue(result.isSuccess, "bbduk must succeed from a space-containing directory: \(result.stderr.suffix(400))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "output must land at the space-containing path")
        let survivors = try countFastqRecords(at: output)
        XCTAssertEqual(survivors, 1, "the 5 ATC-repeat reads are removed and the normal read kept")
    }

    func testBBDukEntropyFilterRemovesTandemRepeatReads() async throws {
        let env = try await bbToolsEnv(for: .bbduk)

        let mixedInputURL = tempDir.appendingPathComponent("entropy_input.fastq")
        let outputURL = tempDir.appendingPathComponent("entropy_filtered.fastq")

        // 5 ATCx50 microsatellite reads and 5 normal-complexity reads, 150 bp each.
        let repeatSequence = String(repeating: "ATC", count: 50)
        let normalSequences = [
            "GCTAGCTTAGCCATGGACTTCAGGATCCGTAACGGTTACCAGTTCAGGCATCGGATTACCGGTAAGCTTCCAGGATCGTTACGGATCCAGTTACGGATCAGGTTCAGCCATGGATTACGGCATCGGTTACCAGGATCCGTTACGGATCA",
            "TTACGGCATCCAGTTACGGATCAGGCATGGTTACCAGGATCCGTAACGGTTACCAGTTCAGGCATCGGATTACCGGTAAGCTTCCAGGATCGTTACGGATCCAGTTACGGATCAGGTTCAGCCATGGATTACGGCATCGGTTACCAGGA",
            "AGCTTCCAGGATCGTTACGGATCCAGTTACGGATCAGGTTCAGCCATGGATTACGGCATCGGTTACCAGGATCCGTTACGGATCAGCTAGCTTAGCCATGGACTTCAGGATCCGTAACGGTTACCAGTTCAGGCATCGGATTACCGGTA",
            "CATCGGATTACCGGTAAGCTTCCAGGATCGTTACGGATCCAGTTACGGATCAGGTTCAGCCATGGATTACGGCATCGGTTACCAGGATCCGTTACGGATCAGCTAGCTTAGCCATGGACTTCAGGATCCGTAACGGTTACCAGTTCAGG",
            "GGATCCGTAACGGTTACCAGTTCAGGCATCGGATTACCGGTAAGCTTCCAGGATCGTTACGGATCCAGTTACGGATCAGGTTCAGCCATGGATTACGGCATCGGTTACCAGGATCCGTTACGGATCAGCTAGCTTAGCCATGGACTTCA",
        ]

        var lines: [String] = []
        for index in 0..<5 {
            lines += [
                "@repeat_\(index)",
                repeatSequence,
                "+",
                String(repeating: "I", count: repeatSequence.count),
            ]
        }
        for (index, sequence) in normalSequences.enumerated() {
            lines += [
                "@normal_\(index)",
                sequence,
                "+",
                String(repeating: "I", count: sequence.count),
            ]
        }
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: mixedInputURL, atomically: true, encoding: .utf8)

        let result = try await runner.run(.bbduk, arguments: [
            "in=\(mixedInputURL.path)",
            "out=\(outputURL.path)",
            "entropy=0.6",
            "entropywindow=50",
            "entropyk=5",
            "ow=t",
        ], environment: env, timeout: 120)

        XCTAssertTrue(result.isSuccess, "bbduk entropy filter should succeed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let survivors = try String(contentsOf: outputURL, encoding: .utf8)
        for index in 0..<5 {
            XCTAssertFalse(
                survivors.contains("@repeat_\(index)"),
                "ATCx50 read repeat_\(index) should be discarded at entropy 0.6"
            )
        }
        let keptNormal = (0..<5).filter { survivors.contains("@normal_\($0)") }.count
        XCTAssertEqual(keptNormal, 5, "All normal-complexity reads should be retained at entropy 0.6")
    }

    /// End-to-end proof for the compressed-output naming change: bbduk must
    /// gzip natively when the `out=` path ends in `.gz`, and the reads it
    /// produces must be identical to the uncompressed run. The planner only
    /// names an output `.fastq.gz` because of this behavior, so if bbduk ever
    /// stopped honoring the extension this test catches it -- otherwise
    /// `discoverOutputs` would silently find nothing.
    func testBBDukEntropyFilterCompressesOutputWhenOutputPathEndsInGz() async throws {
        let env = try await bbToolsEnv(for: .bbduk)

        let inputURL = tempDir.appendingPathComponent("entropy_gz_input.fastq")
        let plainOutputURL = tempDir.appendingPathComponent("entropy_plain.fastq")
        let gzOutputURL = tempDir.appendingPathComponent("entropy_compressed.fastq.gz")

        let repeatSequence = String(repeating: "ATC", count: 50)
        let normalSequence =
            "GCTAGCTTAGCCATGGACTTCAGGATCCGTAACGGTTACCAGTTCAGGCATCGGATTACCGGTAAGCTT"
            + "CCAGGATCGTTACGGATCCAGTTACGGATCAGGTTCAGCCATGGATTACGGCATCGGTTACCAGGATCC"
            + "GTTACGGATCA"

        var lines: [String] = []
        for index in 0..<3 {
            lines += [
                "@repeat_\(index)", repeatSequence, "+",
                String(repeating: "I", count: repeatSequence.count),
            ]
        }
        for index in 0..<3 {
            lines += [
                "@normal_\(index)", normalSequence, "+",
                String(repeating: "I", count: normalSequence.count),
            ]
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: inputURL, atomically: true, encoding: .utf8)

        func runEntropyFilter(outputPath: String) async throws {
            let result = try await runner.run(.bbduk, arguments: [
                "in=\(inputURL.path)",
                "out=\(outputPath)",
                "entropy=0.6", "entropywindow=50", "entropyk=5", "ow=t",
            ], environment: env, timeout: 120)
            XCTAssertTrue(
                result.isSuccess,
                "bbduk entropy filter should succeed for \(outputPath): \(result.stderr)"
            )
        }

        try await runEntropyFilter(outputPath: plainOutputURL.path)
        try await runEntropyFilter(outputPath: gzOutputURL.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: gzOutputURL.path))

        // The compressed output must be real gzip, identified by its magic
        // bytes -- not plain text wearing a `.gz` name.
        let gzHeader = try FileHandle(forReadingFrom: gzOutputURL).readData(ofLength: 2)
        XCTAssertEqual(
            [UInt8](gzHeader), [0x1F, 0x8B],
            "bbduk must emit real gzip when out= ends in .gz"
        )

        // Decompressed reads must match the uncompressed run exactly.
        let reader = FASTQReader(validateSequence: false)
        var gzIDs: [String] = []
        for try await record in reader.records(from: gzOutputURL) {
            gzIDs.append(record.id)
        }
        var plainIDs: [String] = []
        for try await record in reader.records(from: plainOutputURL) {
            plainIDs.append(record.id)
        }

        XCTAssertEqual(
            gzIDs, plainIDs,
            "Compressed and uncompressed entropy-filter runs must keep the same reads"
        )
        XCTAssertFalse(gzIDs.isEmpty, "Expected the normal-complexity reads to survive")
        for index in 0..<3 {
            XCTAssertFalse(
                gzIDs.contains { $0.hasPrefix("repeat_\(index)") },
                "Tandem-repeat reads must still be filtered on the compressed path"
            )
        }
    }

    func testCutadaptPrimerRemoval() async throws {
        let outputURL = tempDir.appendingPathComponent("primer_trimmed.fastq")

        // Trim a 5' primer that matches the start of read_001 and read_011.
        let primer = "ATCGATCGTTAGCAATCCGGTACA"
        let result = try await runner.run(.cutadapt, arguments: [
            "-g", "^\(primer)",
            "--overlap", "12",
            "-e", "0.15",
            "-o", outputURL.path,
            inputFastqURL.path,
        ], timeout: 120)

        XCTAssertTrue(result.isSuccess, "cutadapt primer removal should succeed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let trimmed = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertFalse(trimmed.contains(primer), "Trimmed FASTQ should not retain the 5' primer prefix")
    }

    func testBBMergePairedEnd() async throws {
        // Create a simple interleaved FASTQ with overlapping PE reads
        let interleavedURL = tempDir.appendingPathComponent("interleaved.fastq")
        let overlap = "ATCGATCGATCGATCGATCG"
        let r1Tail = "AAAAAAAAAAAAAAAAAAAAA"
        let r2Head = "TTTTTTTTTTTTTTTTTTTTT"
        let r1Seq = r1Tail + overlap  // 41bp
        let r2Seq = overlap + r2Head  // 41bp  (20bp overlap)
        let r2RC = String(r2Seq.reversed().map { c -> Character in
            switch c {
            case "A": return "T"; case "T": return "A"
            case "C": return "G"; case "G": return "C"
            default: return c
            }
        })
        let qual = String(repeating: "I", count: r1Seq.count)
        let content = """
            @pair1/1
            \(r1Seq)
            +
            \(qual)
            @pair1/2
            \(r2RC)
            +
            \(qual)

            """
        try content.write(to: interleavedURL, atomically: true, encoding: .utf8)

        let mergedURL = tempDir.appendingPathComponent("merged.fastq")
        let unmergedURL = tempDir.appendingPathComponent("unmerged.fastq")
        let env = try await bbToolsEnv(for: .bbmerge)

        let result = try await runner.run(.bbmerge, arguments: [
            "in=\(interleavedURL.path)",
            "out=\(mergedURL.path)",
            "outu=\(unmergedURL.path)",
            "minoverlap=10",
        ], environment: env, timeout: 120)

        XCTAssertTrue(result.isSuccess, "bbmerge should succeed: \(result.stderr)")
        // Check either merged or unmerged has data
        let mergedExists = FileManager.default.fileExists(atPath: mergedURL.path)
        let unmergedExists = FileManager.default.fileExists(atPath: unmergedURL.path)
        XCTAssertTrue(mergedExists || unmergedExists, "bbmerge should produce output files")
    }

    func testBBRepairPairedEnd() async throws {
        // Create an interleaved FASTQ (already in order — repair should pass through)
        let interleavedURL = tempDir.appendingPathComponent("paired.fastq")
        let content = """
            @pair1/1
            ACGTACGTACGT
            +
            IIIIIIIIIIII
            @pair1/2
            TGCATGCATGCA
            +
            IIIIIIIIIIII
            @pair2/1
            GGCCTTAAGGCC
            +
            IIIIIIIIIIII
            @pair2/2
            TTAAGGCCTTAA
            +
            IIIIIIIIIIII

            """
        try content.write(to: interleavedURL, atomically: true, encoding: .utf8)

        let repairedURL = tempDir.appendingPathComponent("repaired.fastq")
        let singletonsURL = tempDir.appendingPathComponent("singletons.fastq")
        let env = try await bbToolsEnv(for: .repair)

        let result = try await runner.run(.repair, arguments: [
            "in=\(interleavedURL.path)",
            "out=\(repairedURL.path)",
            "outs=\(singletonsURL.path)",
        ], environment: env, timeout: 120)

        XCTAssertTrue(result.isSuccess, "repair.sh should succeed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repairedURL.path))
        let count = try countFastqRecords(at: repairedURL)
        XCTAssertEqual(count, 4, "All 4 reads should be in repaired output (pairs intact)")
    }

    func testTadpoleErrorCorrection() async throws {
        let outputURL = tempDir.appendingPathComponent("corrected.fastq")
        let env = try await bbToolsEnv(for: .tadpole)

        let result = try await runner.run(.tadpole, arguments: [
            "in=\(inputFastqURL.path)",
            "out=\(outputURL.path)",
            "mode=correct",
            "ecc=t",
            "k=31",
        ], environment: env, timeout: 120)

        XCTAssertTrue(result.isSuccess, "tadpole error correction should succeed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let count = try countFastqRecords(at: outputURL)
        // Tadpole may drop reads it cannot correct (e.g., too short for k-mer size)
        XCTAssertGreaterThan(count, 0, "Error correction should produce output reads")
        XCTAssertLessThanOrEqual(count, 22, "Should not create reads")
    }

    func testReformatDeinterleave() async throws {
        // Create an interleaved FASTQ
        let interleavedURL = tempDir.appendingPathComponent("interleaved_deint.fastq")
        let content = """
            @pair1/1
            ACGTACGTACGT
            +
            IIIIIIIIIIII
            @pair1/2
            TGCATGCATGCA
            +
            IIIIIIIIIIII
            @pair2/1
            GGCCTTAAGGCC
            +
            IIIIIIIIIIII
            @pair2/2
            TTAAGGCCTTAA
            +
            IIIIIIIIIIII

            """
        try content.write(to: interleavedURL, atomically: true, encoding: .utf8)

        let r1URL = tempDir.appendingPathComponent("R1.fastq")
        let r2URL = tempDir.appendingPathComponent("R2.fastq")
        let env = try await bbToolsEnv(for: .reformat)

        let result = try await runner.run(.reformat, arguments: [
            "in=\(interleavedURL.path)",
            "out1=\(r1URL.path)",
            "out2=\(r2URL.path)",
            "interleaved=t",
        ], environment: env, timeout: 120)

        XCTAssertTrue(result.isSuccess, "reformat deinterleave should succeed: \(result.stderr)")
        let r1Count = try countFastqRecords(at: r1URL)
        let r2Count = try countFastqRecords(at: r2URL)
        XCTAssertEqual(r1Count, 2, "R1 should have 2 reads")
        XCTAssertEqual(r2Count, 2, "R2 should have 2 reads")
    }

    func testReformatInterleave() async throws {
        // Create separate R1/R2 files
        let r1URL = tempDir.appendingPathComponent("sep_R1.fastq")
        let r2URL = tempDir.appendingPathComponent("sep_R2.fastq")
        try """
            @pair1/1
            ACGTACGTACGT
            +
            IIIIIIIIIIII
            @pair2/1
            GGCCTTAAGGCC
            +
            IIIIIIIIIIII

            """.write(to: r1URL, atomically: true, encoding: .utf8)
        try """
            @pair1/2
            TGCATGCATGCA
            +
            IIIIIIIIIIII
            @pair2/2
            TTAAGGCCTTAA
            +
            IIIIIIIIIIII

            """.write(to: r2URL, atomically: true, encoding: .utf8)

        let outputURL = tempDir.appendingPathComponent("interleaved_out.fastq")
        let env = try await bbToolsEnv(for: .reformat)

        let result = try await runner.run(.reformat, arguments: [
            "in1=\(r1URL.path)",
            "in2=\(r2URL.path)",
            "out=\(outputURL.path)",
        ], environment: env, timeout: 120)

        XCTAssertTrue(result.isSuccess, "reformat interleave should succeed: \(result.stderr)")
        let count = try countFastqRecords(at: outputURL)
        XCTAssertEqual(count, 4, "Interleaved output should have 4 reads (2 pairs)")
    }

    // MARK: - Roundtrip Tests

    func testDeinterleaveInterleaveRoundtrip() async throws {
        // Create interleaved input
        let inputURL = tempDir.appendingPathComponent("roundtrip_input.fastq")
        let content = """
            @pair_A/1
            ACGTACGTACGTACGT
            +
            IIIIIIIIIIIIIIII
            @pair_A/2
            TGCATGCATGCATGCA
            +
            IIIIIIIIIIIIIIII
            @pair_B/1
            GGCCTTAAGGCCTTAA
            +
            IIIIIIIIIIIIIIII
            @pair_B/2
            TTAAGGCCTTAAGGCC
            +
            IIIIIIIIIIIIIIII

            """
        try content.write(to: inputURL, atomically: true, encoding: .utf8)

        let r1URL = tempDir.appendingPathComponent("rt_R1.fastq")
        let r2URL = tempDir.appendingPathComponent("rt_R2.fastq")
        let reinterleavedURL = tempDir.appendingPathComponent("rt_reinterleaved.fastq")
        let env = try await bbToolsEnv(for: .reformat)

        // Deinterleave
        let deintResult = try await runner.run(.reformat, arguments: [
            "in=\(inputURL.path)",
            "out1=\(r1URL.path)",
            "out2=\(r2URL.path)",
            "interleaved=t",
        ], environment: env, timeout: 120)
        XCTAssertTrue(deintResult.isSuccess, "Deinterleave should succeed: \(deintResult.stderr)")

        // Re-interleave
        let intResult = try await runner.run(.reformat, arguments: [
            "in1=\(r1URL.path)",
            "in2=\(r2URL.path)",
            "out=\(reinterleavedURL.path)",
        ], environment: env, timeout: 120)
        XCTAssertTrue(intResult.isSuccess, "Re-interleave should succeed: \(intResult.stderr)")

        // Verify roundtrip preserves record count
        let originalCount = try countFastqRecords(at: inputURL)
        let roundtripCount = try countFastqRecords(at: reinterleavedURL)
        XCTAssertEqual(originalCount, roundtripCount, "Roundtrip should preserve record count")
    }

    func testSubsampleFilterPipeline() async throws {
        // Multi-step pipeline: subsample → length filter → quality trim
        try await requireManagedTool(.fastp)
        let step1URL = tempDir.appendingPathComponent("step1_subsample.fastq")
        let step2URL = tempDir.appendingPathComponent("step2_lenfilter.fastq")
        let step3URL = tempDir.appendingPathComponent("step3_qtrim.fastq")

        // Step 1: Subsample to 15 reads
        let r1 = try await runner.run(.seqkit, arguments: [
            "sample", "-n", "15", inputFastqURL.path, "-o", step1URL.path,
        ])
        XCTAssertTrue(r1.isSuccess, "Subsample failed: \(r1.stderr)")

        // Step 2: Length filter ≥ 80bp
        let r2 = try await runner.run(.seqkit, arguments: [
            "seq", "-m", "80", step1URL.path, "-o", step2URL.path,
        ])
        XCTAssertTrue(r2.isSuccess, "Length filter failed: \(r2.stderr)")

        // Step 3: Quality trim
        let r3 = try await runner.run(.fastp, arguments: [
            "-i", step2URL.path, "-o", step3URL.path,
            "-W", "4", "-M", "20", "--cut_right",
            "--disable_adapter_trimming", "--disable_quality_filtering",
            "--disable_length_filtering", "--json", "/dev/null", "--html", "/dev/null",
        ])
        XCTAssertTrue(r3.isSuccess, "Quality trim failed: \(r3.stderr)")

        // Verify decreasing record count through pipeline
        let c1 = try countFastqRecords(at: step1URL)
        let c3 = try countFastqRecords(at: step3URL)
        XCTAssertGreaterThan(c1, 0, "Subsample should produce reads")
        XCTAssertLessThanOrEqual(c1, 22, "Subsample should not exceed total")
        XCTAssertGreaterThan(c3, 0, "Final output should have at least 1 read")
        XCTAssertLessThanOrEqual(c3, c1, "Pipeline should not create reads")
    }

    // MARK: - Edge Cases

    func testEmptyInputHandling() async throws {
        let emptyURL = tempDir.appendingPathComponent("empty.fastq")
        try "".write(to: emptyURL, atomically: true, encoding: .utf8)
        let outputURL = tempDir.appendingPathComponent("empty_out.fastq")

        let result = try await runner.run(.seqkit, arguments: [
            "seq", emptyURL.path, "-o", outputURL.path,
        ])
        // seqkit should handle empty input gracefully
        XCTAssertTrue(result.isSuccess, "seqkit should handle empty input: \(result.stderr)")
    }

    func testSingleReadInput() async throws {
        let singleURL = tempDir.appendingPathComponent("single.fastq")
        try """
            @single_read
            ACGTACGTACGTACGT
            +
            IIIIIIIIIIIIIIII

            """.write(to: singleURL, atomically: true, encoding: .utf8)

        let outputURL = tempDir.appendingPathComponent("single_out.fastq")
        let result = try await runner.run(.seqkit, arguments: [
            "seq", "--upper-case", singleURL.path, "-o", outputURL.path,
        ])
        XCTAssertTrue(result.isSuccess)
        let count = try countFastqRecords(at: outputURL)
        XCTAssertEqual(count, 1)
    }
}
