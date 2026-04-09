// ExtractReadsByClassifierCLITests.swift — Parse tests for --by-classifier strategy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import ArgumentParser
import LungfishWorkflow
@testable import LungfishCLI

/// Parse-only tests for the new `--by-classifier` strategy on
/// `lungfish extract reads`, plus the `--by-region --exclude-unmapped` flag and
/// regression coverage for the Option C `--by-db` rename
/// (`--sample`/`--accession`/`--taxid` → `--db-sample`/`--db-accession`/`--db-taxid`).
///
/// These tests do NOT execute extractions — they only confirm that
/// `ExtractReadsSubcommand.parse([...])` accepts/rejects the expected flag
/// combinations and that `validate()` enforces the per-tool requirements.
final class ExtractReadsByClassifierCLITests: XCTestCase {

    // MARK: - --by-classifier parse + validation tests
    //
    // ArgumentParser's `parse(...)` runs `validate()` automatically as part of
    // parsing, so the negative tests assert that `parse(...)` itself throws.
    // The positive tests still call `parse(...)` followed by an explicit
    // `validate()` to make the round-trip explicit.

    func testParse_byClassifier_esviritu_requiresAccession() throws {
        // Missing --accession should fail validation.
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier",
                "--tool", "esviritu",
                "--result", "/tmp/fake.sqlite",
                "--sample", "S1",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_esviritu_withAccession_validates() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-classifier",
            "--tool", "esviritu",
            "--result", "/tmp/fake.sqlite",
            "--sample", "S1",
            "--accession", "NC_001803",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
    }

    func testParse_byClassifier_kraken2_requiresTaxon() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier",
                "--tool", "kraken2",
                "--result", "/tmp/fake",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_kraken2_rejectsIncludeUnmappedMates() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier",
                "--tool", "kraken2",
                "--result", "/tmp/fake",
                "--taxon", "9606",
                "--include-unmapped-mates",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_nonKraken2_acceptsIncludeUnmappedMates() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-classifier",
            "--tool", "taxtriage",
            "--result", "/tmp/fake",
            "--sample", "S1",
            "--accession", "NC_001803",
            "--include-unmapped-mates",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
    }

    func testParse_byClassifier_multipleStrategiesFails() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier", "--by-region",
                "--tool", "esviritu",
                "--result", "/tmp/fake.sqlite",
                "--accession", "X",
                "--bam", "/tmp/x.bam",
                "--region", "chr1",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_invalidToolName_fails() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier",
                "--tool", "bogus",
                "--result", "/tmp/fake",
                "--accession", "X",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_missingTool_fails() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier",
                "--result", "/tmp/fake",
                "--accession", "X",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_missingResult_fails() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier",
                "--tool", "esviritu",
                "--accession", "X",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_invalidFormat_fails() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier",
                "--tool", "nvd",
                "--result", "/tmp/fake",
                "--accession", "X",
                "--read-format", "bam",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_perSampleSelection_groupsAccessions() throws {
        // Two samples; each sample's --accession flags bind to the immediately
        // preceding --sample. The grouping is reconstructed by walking the raw
        // argv, which the test passes to `buildClassifierSelectors(rawArgs:)`
        // explicitly because the production default reads CommandLine.arguments
        // (which holds xctest's argv during the test run).
        let argv = [
            "--by-classifier",
            "--tool", "esviritu",
            "--result", "/tmp/fake.sqlite",
            "--sample", "A",
            "--accession", "NC_111",
            "--accession", "NC_222",
            "--sample", "B",
            "--accession", "NC_333",
            "-o", "/tmp/out.fastq",
        ]
        let cmd = try ExtractReadsSubcommand.parse(argv)
        XCTAssertNoThrow(try cmd.validate())
        let selectors = cmd.buildClassifierSelectors(rawArgs: argv)
        XCTAssertEqual(selectors.count, 2)
        XCTAssertEqual(selectors[0].sampleId, "A")
        XCTAssertEqual(selectors[0].accessions, ["NC_111", "NC_222"])
        XCTAssertEqual(selectors[1].sampleId, "B")
        XCTAssertEqual(selectors[1].accessions, ["NC_333"])
    }

    func testParse_byClassifier_singleUnnamedSample() throws {
        // No --sample at all → one selector with nil sampleId holding all accessions.
        let argv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", "/tmp/fake.sqlite",
            "--accession", "contig1",
            "--accession", "contig2",
            "-o", "/tmp/out.fastq",
        ]
        let cmd = try ExtractReadsSubcommand.parse(argv)
        XCTAssertNoThrow(try cmd.validate())
        let selectors = cmd.buildClassifierSelectors(rawArgs: argv)
        XCTAssertEqual(selectors.count, 1)
        XCTAssertNil(selectors[0].sampleId)
        XCTAssertEqual(selectors[0].accessions, ["contig1", "contig2"])
    }

    func testParse_byClassifier_bundleFlag() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-classifier",
            "--tool", "nvd",
            "--result", "/tmp/fake.sqlite",
            "--accession", "c1",
            "--bundle",
            "--bundle-name", "my-extract",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertTrue(cmd.createBundle)
        XCTAssertEqual(cmd.bundleName, "my-extract")
    }

    func testParse_byClassifier_formatFasta() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-classifier",
            "--tool", "nvd",
            "--result", "/tmp/fake.sqlite",
            "--accession", "c1",
            "--read-format", "fasta",
            "-o", "/tmp/out.fasta",
        ])
        XCTAssertEqual(cmd.classifierFormat, "fasta")
    }

    // MARK: - --by-region --exclude-unmapped

    func testParse_byRegion_excludeUnmapped_setsFlag() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-region",
            "--bam", "/tmp/x.bam",
            "--region", "chr1",
            "--exclude-unmapped",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertTrue(cmd.excludeUnmapped)
    }

    func testParse_byRegion_default_excludeUnmappedIsFalse() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-region",
            "--bam", "/tmp/x.bam",
            "--region", "chr1",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertFalse(cmd.excludeUnmapped)
    }

    // MARK: - --by-db rename regression (Option C)

    func testParse_byDb_renamedFlags_validate() throws {
        // The renamed --db-sample / --db-accession / --db-taxid flags must
        // parse and validate cleanly. This proves the rename landed AND that
        // the new name doesn't shadow --by-classifier's --sample/etc.
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-db",
            "--database", "/tmp/fake.db",
            "--db-sample", "S1",
            "--db-taxid", "562",
            "--db-accession", "NC_000913",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
        XCTAssertEqual(cmd.sample, "S1")
        XCTAssertEqual(cmd.taxIds, ["562"])
        XCTAssertEqual(cmd.accessions, ["NC_000913"])
    }

    func testParse_byDb_oldFlagNames_areRejected() throws {
        // The OLD names (--sample/--taxid/--accession bound to --by-db) must
        // no longer parse against --by-db without something also opting them
        // into the classifier strategy. We test the most clear-cut case:
        // bare --by-db with the legacy --taxid spelling. Because --taxid no
        // longer exists at all, ArgumentParser raises an unknown-option error.
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-db",
                "--database", "/tmp/fake.db",
                "--taxid", "562",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    // MARK: - End-to-end run tests
    //
    // These tests actually execute `ExtractReadsSubcommand.run()` against the
    // sarscov2 fixture BAM to verify the CLI → ClassifierReadResolver → FASTQ
    // pipeline end-to-end. They exercise samtools via `NativeToolRunner.shared`
    // and so are skipped if samtools is unavailable or the fixture is missing.
    //
    // The `testingRawArgs` hook on `ExtractReadsSubcommand` (DEBUG-only) lets
    // us inject a simulated argv so per-sample grouping works from the test
    // without falling through to xctest's own `CommandLine.arguments`.

    /// Set up a fake NVD-style result directory by copying the sarscov2 fixture
    /// BAM + BAI into the `{sampleId}.bam` layout that
    /// `ClassifierReadResolver.resolveBAMURL(tool: .nvd, …)` scans for.
    ///
    /// Returns the fake result path (a .sqlite URL inside the temp dir). Caller
    /// must clean up `returnedURL.deletingLastPathComponent()`.
    ///
    /// The `#filePath` walk here mirrors `ImportFastqE2ETests.fixturesDir`
    /// (LungfishCLITests → Tests → repo root). `TestFixtures.swift` lives in
    /// `LungfishIntegrationTests` and is not importable from this target, so
    /// we duplicate the walk locally rather than introduce a cross-target
    /// dependency for a single helper.
    private func makeSarscov2NVDFixture(sampleId: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cli-nvd-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // LungfishCLITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        // NOTE: the sarscov2 fixture BAM on disk is `test.paired_end.sorted.bam`,
        // not `test.sorted.bam` as the Phase 3 plan originally said.
        let bam = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        let bai = URL(fileURLWithPath: bam.path + ".bai")
        guard fm.fileExists(atPath: bam.path), fm.fileExists(atPath: bai.path) else {
            throw XCTSkip("sarscov2 fixture BAM/BAI missing at \(bam.path)")
        }
        let dest = root.appendingPathComponent("\(sampleId).bam")
        try fm.copyItem(at: bam, to: dest)
        try fm.copyItem(at: bai, to: URL(fileURLWithPath: dest.path + ".bai"))
        return root.appendingPathComponent("fake-nvd.sqlite")
    }

    func testRun_byClassifier_nvd_endToEnd() async throws {
        let resultPath = try makeSarscov2NVDFixture(sampleId: "s2")
        let fixtureRoot = resultPath.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // Discover the actual BAM reference name so we don't hard-code
        // MN908947.3 and accidentally couple the test to the specific fixture
        // version. The resolver itself uses `BAMRegionMatcher` internally; we
        // mirror that here.
        let fixtureBAM = fixtureRoot.appendingPathComponent("s2.bam")
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: fixtureBAM,
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-nvd-out-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let argv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "s2",
            "--accession", region,
            "-o", tempOut.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        try await cmd.run()

        let fm = FileManager.default
        XCTAssertTrue(
            fm.fileExists(atPath: tempOut.path),
            "Expected CLI to write output FASTQ at \(tempOut.path)"
        )
        let size = (try? fm.attributesOfItem(atPath: tempOut.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 0, "Expected non-empty FASTQ output from sarscov2 fixture")
    }

    func testRun_byClassifier_format_fasta_endToEnd() async throws {
        let resultPath = try makeSarscov2NVDFixture(sampleId: "s2")
        let fixtureRoot = resultPath.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let fixtureBAM = fixtureRoot.appendingPathComponent("s2.bam")
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: fixtureBAM,
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-nvd-out-\(UUID().uuidString).fasta")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        // NOTE: the CLI spells this `--read-format` (not `--format`) because
        // `GlobalOptions.outputFormat` already claims `--format` for the report
        // format (text/json/tsv). The parsed property is `classifierFormat`.
        let argv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "s2",
            "--accession", region,
            "--read-format", "fasta",
            "-o", tempOut.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        XCTAssertEqual(cmd.classifierFormat, "fasta")
        try cmd.validate()
        try await cmd.run()

        let fm = FileManager.default
        XCTAssertTrue(
            fm.fileExists(atPath: tempOut.path),
            "Expected CLI to write output FASTA at \(tempOut.path)"
        )
        let size = (try? fm.attributesOfItem(atPath: tempOut.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 0, "Expected non-empty FASTA output from sarscov2 fixture")

        // FASTA records start with '>'. Read just the first byte to avoid
        // loading the full file into memory.
        let handle = try FileHandle(forReadingFrom: tempOut)
        defer { try? handle.close() }
        let firstByte = try handle.read(upToCount: 1) ?? Data()
        XCTAssertEqual(
            firstByte.first,
            UInt8(ascii: ">"),
            "FASTA output should begin with '>' header marker"
        )
    }
}
