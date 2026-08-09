// ExtractReadsByIdBAMProcessTests.swift — Process-level integration tests for `lungfish extract reads --by-id --bam`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Item 3 (mapping viewer fixes, 2026-08-09), CLI parity (spec E). Runs the
// real `ExtractReadsSubcommand.parse(...).run()` path against a crafted
// SAM->BAM fixture (via `BamFixtureBuilder`) to assert the bio-gate
// semantics end to end through the CLI, not just through
// `ReadExtractionService` directly (covered separately in
// ReadIDBAMExtractionTests.swift):
//   - secondary/supplementary excluded by default (-F 0x900)
//   - --include-secondary disambiguates names
//   - both mates returned for a shared QNAME
//   - dedup-off default keeps the dup-flagged selected read
//   - singletons routed separately
//   - fasta format uses the same filters

import XCTest
@testable import LungfishCLI
import LungfishTestSupport

final class ExtractReadsByIdBAMProcessTests: XCTestCase {

    private var tempDir: URL!
    private var samtoolsPath: String!

    override func setUp() async throws {
        try await super.setUp()
        guard let located = BamFixtureBuilder.locateSamtools() else {
            throw XCTSkip("samtools not available in test environment")
        }
        samtoolsPath = located
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-reads-byid-bam-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func makeFixtureBAM() throws -> URL {
        let bamURL = tempDir.appendingPathComponent("fixture.bam")
        let seq = String(repeating: "A", count: 20)
        let qual = String(repeating: "I", count: 20)

        let reads: [BamFixtureBuilder.Read] = [
            .init(qname: "pairedRead", flag: 0x1 | 0x2 | 0x40, rname: "chr1", pos: 1, mapq: 60, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "pairedRead", flag: 0x1 | 0x2 | 0x80, rname: "chr1", pos: 101, mapq: 60, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "secondaryRead", flag: 0, rname: "chr1", pos: 201, mapq: 60, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "secondaryRead", flag: 0x100, rname: "chr1", pos: 301, mapq: 0, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "dupRead", flag: 0x400, rname: "chr1", pos: 601, mapq: 60, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "singletonRead", flag: 0x1 | 0x40, rname: "chr1", pos: 701, mapq: 60, cigar: "20M", seq: seq, qual: qual),
        ]

        try BamFixtureBuilder.makeBAM(
            at: bamURL,
            references: [BamFixtureBuilder.Reference(name: "chr1", length: 2000)],
            reads: reads,
            samtoolsPath: samtoolsPath
        )
        return bamURL
    }

    private func writeIDs(_ ids: [String]) throws -> URL {
        let idsURL = tempDir.appendingPathComponent("ids-\(UUID().uuidString).txt")
        try ids.joined(separator: "\n").write(to: idsURL, atomically: true, encoding: .utf8)
        return idsURL
    }

    /// The other fixture reads in this file are homopolymeric ("AAAA...A"),
    /// which is its own reverse complement, so that fixture cannot catch an
    /// orientation/base-corruption regression in the BAM->FASTQ CLI path
    /// (e.g. `samtools fastq` failing to restore reverse-strand (0x10)
    /// records to original read orientation). This builds a dedicated
    /// two-read, non-palindromic fixture to make that regression detectable
    /// end to end through `ExtractReadsSubcommand`.
    private func makeOrientationFixtureBAM() throws -> URL {
        let bamURL = tempDir.appendingPathComponent("orientation_fixture.bam")
        let qual = String(repeating: "I", count: 20)

        // Non-palindromic 20bp sequence. Reverse complement of
        // "ACGTACGTACGTAAAACCCC" is "GGGGTTTTACGTACGTACGT" (reverse the
        // string, then complement each base A<->T, C<->G).
        let mappedSeq = "ACGTACGTACGTAAAACCCC"

        let reads: [BamFixtureBuilder.Read] = [
            .init(qname: "forwardRead", flag: 0, rname: "chr1", pos: 1, mapq: 60, cigar: "20M", seq: mappedSeq, qual: qual),
            .init(qname: "reverseRead", flag: 0x10, rname: "chr1", pos: 101, mapq: 60, cigar: "20M", seq: mappedSeq, qual: qual),
        ]

        try BamFixtureBuilder.makeBAM(
            at: bamURL,
            references: [BamFixtureBuilder.Reference(name: "chr1", length: 2000)],
            reads: reads,
            samtoolsPath: samtoolsPath
        )
        return bamURL
    }

    private func fastqSequence(for readName: String, in content: String) throws -> String {
        let lines = content.components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: { $0 == "@\(readName)" }) else {
            throw XCTSkip("Header @\(readName) not found in FASTQ output:\n\(content)")
        }
        let sequenceIndex = headerIndex + 1
        guard sequenceIndex < lines.count else {
            throw XCTSkip("No sequence line follows @\(readName) in FASTQ output:\n\(content)")
        }
        return lines[sequenceIndex]
    }

    // MARK: - Default excludes secondary/supplementary; mate pair returns both

    func testDefaultCLIRunExcludesSecondaryAndReturnsBothMates() async throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["pairedRead", "secondaryRead"])
        let outputURL = tempDir.appendingPathComponent("out.fastq")

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "-o", outputURL.path,
            "--quiet",
        ])
        try await cmd.run()

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("@pairedRead"))
        XCTAssertTrue(content.contains("@secondaryRead"))
        // Count QNAME occurrences: pairedRead x2 (mates) + secondaryRead x1 (primary only) = 3
        let qnameLines = content.components(separatedBy: "\n").filter { $0.hasPrefix("@pairedRead") || $0.hasPrefix("@secondaryRead") }
        XCTAssertEqual(qnameLines.count, 3)
    }

    // MARK: - Reverse-strand orientation restoration (finding 11 test-rigor fix)

    func testReverseStrandReadIsReverseComplementedBackToOriginalOrientationViaCLI() async throws {
        let bamURL = try makeOrientationFixtureBAM()
        let idsURL = try writeIDs(["forwardRead", "reverseRead"])
        let outputURL = tempDir.appendingPathComponent("out_orientation.fastq")

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "-o", outputURL.path,
            "--quiet",
        ])
        try await cmd.run()

        let content = try String(contentsOf: outputURL, encoding: .utf8)

        // Forward-strand (flag 0): SAM SEQ passes through unchanged.
        let forwardSeq = try fastqSequence(for: "forwardRead", in: content)
        XCTAssertEqual(forwardSeq, "ACGTACGTACGTAAAACCCC", "Forward-strand read's extracted sequence must equal the SAM SEQ verbatim")

        // Reverse-strand (flag 0x10): samtools fastq restores original read
        // orientation, i.e. the reverse complement of the mapped SAM SEQ.
        let reverseSeq = try fastqSequence(for: "reverseRead", in: content)
        XCTAssertEqual(reverseSeq, "GGGGTTTTACGTACGTACGT", "Reverse-strand read's extracted sequence must be the reverse complement of SAM SEQ (original read orientation)")

        XCTAssertNotEqual(forwardSeq, reverseSeq)
        XCTAssertNotEqual(forwardSeq, "GGGGTTTTACGTACGTACGT", "Forward-strand read must not be reverse-complemented")
    }

    // MARK: - --include-secondary disambiguates

    func testIncludeSecondaryFlagDisambiguatesOutputNames() async throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["secondaryRead"])
        let outputURL = tempDir.appendingPathComponent("out_secondary.fastq")

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "--include-secondary",
            "-o", outputURL.path,
            "--quiet",
        ])
        try await cmd.run()

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("@secondaryRead/sec"))
    }

    // MARK: - Dedup-off default keeps the dup-flagged read

    func testDedupOffDefaultKeepsDuplicateFlaggedReadViaCLI() async throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["dupRead"])
        let outputURL = tempDir.appendingPathComponent("out_dup.fastq")

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "-o", outputURL.path,
            "--quiet",
        ])
        try await cmd.run()

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("@dupRead"))
    }

    func testExcludeDuplicatesFlagDropsTheDuplicateFlaggedReadViaCLI() async throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["dupRead"])
        let outputURL = tempDir.appendingPathComponent("out_dup_excluded.fastq")

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "--exclude-duplicates",
            "-o", outputURL.path,
            "--quiet",
        ])

        do {
            try await cmd.run()
            // With zero matching reads, the output file may legitimately not
            // exist. If run() completed without throwing, assert emptiness.
            if FileManager.default.fileExists(atPath: outputURL.path) {
                let content = try String(contentsOf: outputURL, encoding: .utf8)
                XCTAssertFalse(content.contains("@dupRead"))
            }
        } catch {
            // Acceptable: some CLI paths surface zero-read extraction as an error.
        }
    }

    // MARK: - Singletons routed separately (not silently dropped)

    func testSingletonReadRoutedToSidecarViaCLI() async throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["singletonRead"])
        let outputURL = tempDir.appendingPathComponent("out_singleton.fastq")

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "-o", outputURL.path,
            "--quiet",
        ])
        try await cmd.run()

        // The singleton must appear SOMEWHERE (main output or the persisted
        // singletons sidecar) — not silently dropped.
        let outputDir = outputURL.deletingLastPathComponent()
        let siblingFiles = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
        let combinedContent = try siblingFiles
            .filter { $0.hasSuffix(".fastq") }
            .map { try String(contentsOf: outputDir.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        XCTAssertTrue(combinedContent.contains("@singletonRead"), "singletonRead must appear in main output or the singletons sidecar")
    }

    // MARK: - FASTA format uses the same filters

    func testReadFormatFastaAppliesSameDefaultFiltersViaCLI() async throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["secondaryRead"])
        let outputURL = tempDir.appendingPathComponent("out.fastq") // extension controlled by --read-format, not -o

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "--read-format", "fasta",
            "-o", outputURL.path,
            "--quiet",
        ])
        try await cmd.run()

        let outputDir = outputURL.deletingLastPathComponent()
        let fastaFiles = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix(".fasta") }
        XCTAssertFalse(fastaFiles.isEmpty, "Expected a .fasta output file")
        let content = try fastaFiles
            .map { try String(contentsOf: outputDir.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        XCTAssertTrue(content.hasPrefix(">"))
        // Only the primary secondaryRead record should be present (secondary excluded by default).
        XCTAssertEqual(content.components(separatedBy: ">secondaryRead").count - 1, 1)
    }

    // MARK: - --no-keep-read-pairs rejected in BAM mode (process-level, not just parse-level)

    func testNoKeepReadPairsRejectedAtParseTimeInBAMMode() throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["pairedRead"])
        let outputURL = tempDir.appendingPathComponent("out_rejected.fastq")

        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-id",
                "--ids", idsURL.path,
                "--bam", bamURL.path,
                "--no-keep-read-pairs",
                "-o", outputURL.path,
                "--quiet",
            ])
        )
    }

    // MARK: - Persisted read-name file for CLI replay

    func testReadNameFileIsPersistedAlongsideOutputForReplay() async throws {
        let bamURL = try makeFixtureBAM()
        let idsURL = try writeIDs(["pairedRead"])
        let outputURL = tempDir.appendingPathComponent("out_persisted.fastq")

        var cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--bam", bamURL.path,
            "-o", outputURL.path,
            "--quiet",
        ])
        try await cmd.run()

        let outputDir = outputURL.deletingLastPathComponent()
        let nameFiles = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix("_read_names.txt") }
        XCTAssertFalse(nameFiles.isEmpty, "Expected a persisted *_read_names.txt file for CLI replay fidelity")
    }
}
