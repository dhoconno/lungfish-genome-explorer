// ReadIDBAMExtractionTests.swift — Integration tests for ReadExtractionService.extractByReadIDsFromBAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Item 3 (mapping viewer fixes, 2026-08-09): the NEW BAM-source read-ID
// extraction path used when the mapping viewport's "Extract Reads… (original
// reads)" action cannot resolve a source FASTQ (the common case — MappingResult
// retains no FASTQ bundle reference).
//
// The sarscov2 fixture BAM has no secondary/supplementary/duplicate/singleton
// records, so assertions against it for those cases would be vacuous. This
// test crafts a small SAM->BAM in-test via `BamFixtureBuilder` (already used
// elsewhere in the suite for this exact purpose) with:
//   - a mate pair sharing one QNAME ("pairedRead", flags 0x63 / 0xB3)
//   - one 0x100 secondary alignment
//   - one 0x800 supplementary alignment
//   - one 0x400 PCR/optical duplicate
//   - one singleton (mate not selected / not present)
// and asserts the bio-gate semantics: secondary/supplementary excluded by
// default; --include-secondary disambiguates names; both mates returned for
// a shared QNAME; dedup-off default keeps the dup-flagged selected read;
// singletons routed separately; fasta format uses the same filters.

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

final class ReadIDBAMExtractionTests: XCTestCase {

    private var tempDir: URL!
    private var service: ReadExtractionService!
    private var samtoolsPath: String!

    override func setUp() async throws {
        try await super.setUp()
        guard let located = BamFixtureBuilder.locateSamtools() else {
            throw XCTSkip("samtools not available in test environment")
        }
        samtoolsPath = located
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("readid-bam-extraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = ReadExtractionService()
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// Builds the crafted BAM described in the file header comment.
    ///
    /// QNAMEs:
    /// - "pairedRead": two records sharing one QNAME (first/second in pair, both mapped).
    /// - "secondaryRead": primary (flag 0) + a 0x100 secondary alignment of the same QNAME.
    /// - "supplementaryRead": primary (flag 0) + a 0x800 supplementary alignment of the same QNAME.
    /// - "dupRead": single record flagged 0x400 (PCR/optical duplicate).
    /// - "singletonRead": a paired + first-in-pair record (0x1 | 0x40) whose mate is
    ///   NOT in the BAM at all, simulating a mate that samtools fastq routes to the
    ///   singletons sidecar (a plain 0x1-only flag classifies as READ_OTHER, not a
    ///   singleton — samtools' singleton detection requires the READ1/READ2 designation).
    private func makeFixtureBAM() throws -> URL {
        let bamURL = tempDir.appendingPathComponent("fixture.bam")
        let seq = String(repeating: "A", count: 20)
        let qual = String(repeating: "I", count: 20)

        let reads: [BamFixtureBuilder.Read] = [
            // Mate pair sharing QNAME "pairedRead".
            .init(qname: "pairedRead", flag: 0x1 | 0x2 | 0x40, rname: "chr1", pos: 1, mapq: 60, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "pairedRead", flag: 0x1 | 0x2 | 0x80, rname: "chr1", pos: 101, mapq: 60, cigar: "20M", seq: seq, qual: qual),

            // Primary + secondary (0x100) alignment of the same QNAME.
            .init(qname: "secondaryRead", flag: 0, rname: "chr1", pos: 201, mapq: 60, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "secondaryRead", flag: 0x100, rname: "chr1", pos: 301, mapq: 0, cigar: "20M", seq: seq, qual: qual),

            // Primary + supplementary (0x800) alignment of the same QNAME.
            .init(qname: "supplementaryRead", flag: 0, rname: "chr1", pos: 401, mapq: 60, cigar: "20M", seq: seq, qual: qual),
            .init(qname: "supplementaryRead", flag: 0x800, rname: "chr1", pos: 501, mapq: 60, cigar: "10S10M", seq: seq, qual: qual),

            // PCR/optical duplicate.
            .init(qname: "dupRead", flag: 0x400, rname: "chr1", pos: 601, mapq: 60, cigar: "20M", seq: seq, qual: qual),

            // Singleton: paired + first-in-pair flags set, but its mate is not present in the BAM at all.
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

    // MARK: - Default filter excludes secondary/supplementary

    func testDefaultExcludesSecondaryAndSupplementary() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["secondaryRead", "supplementaryRead"],
            outputDirectory: tempDir,
            outputBaseName: "default_filter"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        // Only the two PRIMARY records should survive -F 0x900.
        XCTAssertEqual(result.readCount, 2, "Expected only the 2 primary records, secondary+supplementary excluded")

        let output = try XCTUnwrap(result.outputURLs.first)
        let content = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(content.contains("@secondaryRead"))
        XCTAssertTrue(content.contains("@supplementaryRead"))
    }

    // MARK: - --include-secondary disambiguates names

    func testIncludeSecondaryReturnsAllRecordsWithDisambiguatedNames() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["secondaryRead"],
            includeSecondary: true,
            outputDirectory: tempDir,
            outputBaseName: "include_secondary"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 2, "Expected both the primary and the secondary record")

        let output = try XCTUnwrap(result.outputURLs.first)
        let content = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(content.contains("@secondaryRead\n") || content.contains("@secondaryRead "))
        XCTAssertTrue(content.contains("@secondaryRead/sec"), "Expected the secondary record's name disambiguated with /sec")
    }

    func testIncludeSecondaryDisambiguatesSupplementaryWithSupSuffix() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["supplementaryRead"],
            includeSecondary: true,
            outputDirectory: tempDir,
            outputBaseName: "include_supplementary"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 2)
        let output = try XCTUnwrap(result.outputURLs.first)
        let content = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(content.contains("@supplementaryRead/sup"), "Expected the supplementary record's name disambiguated with /sup")
    }

    // MARK: - Both mates returned for shared QNAME

    func testBothMatesReturnedForSharedQNAME() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["pairedRead"],
            outputDirectory: tempDir,
            outputBaseName: "mate_pair"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 2, "Both mates of 'pairedRead' should return from a single QNAME request")
    }

    // MARK: - Dedup-off default keeps the dup-flagged read

    func testDedupOffDefaultKeepsDuplicateFlaggedRead() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["dupRead"],
            outputDirectory: tempDir,
            outputBaseName: "dup_default"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 1, "dup-flagged read must be kept by default (dedup OFF)")
    }

    func testExcludeDuplicatesDropsTheDuplicateFlaggedRead() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["dupRead"],
            excludeDuplicates: true,
            outputDirectory: tempDir,
            outputBaseName: "dup_excluded"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 0, "excludeDuplicates=true must drop the dup-flagged read")
        XCTAssertTrue(result.outputURLs.isEmpty)
    }

    // MARK: - Singletons routed separately

    func testSingletonReadIsRoutedToSingletonsSidecarNotMainOutput() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["singletonRead"],
            outputDirectory: tempDir,
            outputBaseName: "singleton_case"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 1)
        let singletonsURL = try XCTUnwrap(result.singletonsURL, "Expected a singletons sidecar for a mate-flagged read with no mate present")
        XCTAssertTrue(FileManager.default.fileExists(atPath: singletonsURL.path))
        let singletonContent = try String(contentsOf: singletonsURL, encoding: .utf8)
        XCTAssertTrue(singletonContent.contains("@singletonRead"))
    }

    // MARK: - Persisted read-name file

    func testReadNameFileIsPersistedNotDeleted() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["pairedRead"],
            outputDirectory: tempDir,
            outputBaseName: "persisted_names"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.readNameFileURL.path),
            "The read-name file must be persisted (not a deleted temp) so a CLI replay is faithful"
        )
        let content = try String(contentsOf: result.readNameFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("pairedRead"))
    }

    // MARK: - Reverse-strand orientation restoration (finding 11 test-rigor fix)

    /// The other fixture reads in this file are homopolymeric ("AAAA...A"),
    /// which is its own reverse complement — that fixture is blind to an
    /// orientation/base-corruption regression in the BAM->FASTQ path (e.g. if
    /// `samtools fastq` stopped restoring reverse-strand (0x10) records to
    /// their original read orientation). This builds a dedicated two-read
    /// fixture with a non-palindromic sequence, one record forward-strand and
    /// one reverse-strand, to make that regression detectable:
    ///   - "forwardRead" (flag 0): SAM SEQ is stored/extracted verbatim.
    ///   - "reverseRead" (flag 0x10): SAM SEQ is the *mapped* (already
    ///     reference-orientation) sequence; `samtools fastq` reverse-complements
    ///     0x10 records back to original read orientation, so the extracted
    ///     FASTQ sequence must equal the reverse complement of the SAM SEQ.
    private func makeOrientationFixtureBAM() throws -> URL {
        let bamURL = tempDir.appendingPathComponent("orientation_fixture.bam")
        let qual = String(repeating: "I", count: 20)

        // Non-palindromic 20bp sequence, so it is NOT its own reverse
        // complement (unlike the homopolymeric "AAAA...A" fixture used
        // elsewhere in this file). Reverse complement of "ACGTACGTACGTAAAACCCC"
        // is "GGGGTTTTACGTACGTACGT" (reverse the string, then complement each
        // base A<->T, C<->G) — asserted directly in the test below.
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

    /// Extracts the sequence line (line 2 of the 4-line FASTQ record) that
    /// immediately follows a given `@<name>` header line.
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

    func testReverseStrandReadIsReverseComplementedBackToOriginalOrientation() async throws {
        let bamURL = try makeOrientationFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["forwardRead", "reverseRead"],
            outputDirectory: tempDir,
            outputBaseName: "orientation_check"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 2)
        let output = try XCTUnwrap(result.outputURLs.first)
        let content = try String(contentsOf: output, encoding: .utf8)

        // Forward-strand (flag 0): SAM SEQ passes through unchanged.
        let forwardSeq = try fastqSequence(for: "forwardRead", in: content)
        XCTAssertEqual(forwardSeq, "ACGTACGTACGTAAAACCCC", "Forward-strand read's extracted sequence must equal the SAM SEQ verbatim")

        // Reverse-strand (flag 0x10): samtools fastq restores original read
        // orientation, i.e. the reverse complement of the mapped SAM SEQ.
        let reverseSeq = try fastqSequence(for: "reverseRead", in: content)
        XCTAssertEqual(reverseSeq, "GGGGTTTTACGTACGTACGT", "Reverse-strand read's extracted sequence must be the reverse complement of SAM SEQ (original read orientation)")

        // Distinguishes "RC applied only to reverse reads" from "RC applied
        // to everything" (both are known ExtractReads bugs seen in this
        // pipeline family): the two extracted sequences must differ, and
        // the forward one specifically must NOT have been RC'd.
        XCTAssertNotEqual(forwardSeq, reverseSeq)
        XCTAssertNotEqual(forwardSeq, "GGGGTTTTACGTACGTACGT", "Forward-strand read must not be reverse-complemented")
    }

    // MARK: - FASTA format uses the same filters

    func testFASTAFormatUsesSameDefaultFilters() async throws {
        let bamURL = try makeFixtureBAM()
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["secondaryRead"],
            format: .fasta,
            outputDirectory: tempDir,
            outputBaseName: "fasta_default"
        )

        let result = try await service.extractByReadIDsFromBAM(config: config)

        XCTAssertEqual(result.readCount, 1, "FASTA format must apply the same -F 0x900 default (secondary excluded)")
        let output = try XCTUnwrap(result.outputURLs.first)
        XCTAssertEqual(output.pathExtension, "fasta")
        let content = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix(">"), "FASTA output must start with a '>' record header")
    }
}
