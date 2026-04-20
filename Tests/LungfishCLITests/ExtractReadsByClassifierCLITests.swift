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
        // no longer parse against --by-db. This test exercises the legacy
        // `--taxid` spelling: because `--taxid` no longer exists on
        // `ExtractReadsSubcommand`, ArgumentParser raises an unknown-option
        // diagnostic.
        //
        // NOTE on test construction: ArgumentParser evaluates its
        // "unknown option" check AFTER its "missing required argument" check.
        // If we passed only `--by-db --database ... --taxid 562 -o ...`,
        // validate() would fire FIRST with the "At least one --db-taxid or
        // --db-accession is required" ValidationError and mask the unknown-
        // option diagnostic. So we ALSO pass a valid `--db-accession` to
        // satisfy validate(); that way parsing reaches the unknown-option
        // path and the parser emits the "Unknown option '--taxid'" message
        // we actually want to assert on.
        //
        // The assertion pattern-matches on the error message so a regressed
        // rename (where --taxid still exists as a valid @Option) would parse
        // cleanly, validate cleanly, and this test would correctly FAIL.
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-db",
                "--database", "/tmp/fake.db",
                "--db-accession", "NC_000913",
                "--taxid", "562",
                "-o", "/tmp/out.fastq",
            ])
        ) { error in
            let message = ExtractReadsSubcommand.fullMessage(for: error)
                .lowercased()
            XCTAssertTrue(
                message.contains("unknown") || message.contains("unexpected"),
                "Expected an 'unknown option' diagnostic from the parser for the legacy --taxid flag, got: \(message)"
            )
        }
    }

    // MARK: - --by-classifier individual mutual-exclusion pairs
    //
    // `testParse_byClassifier_multipleStrategiesFails` already covers
    // (--by-classifier + --by-region). These two pin the remaining pairs so
    // all three combinations are explicitly tested.

    func testParse_byClassifier_vs_byId_mutuallyExclusive() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier", "--by-id",
                "--tool", "esviritu",
                "--result", "/tmp/fake.sqlite",
                "--accession", "X",
                "--ids", "/tmp/ids.txt",
                "--source", "/tmp/reads.fastq",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    func testParse_byClassifier_vs_byDb_mutuallyExclusive() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-classifier", "--by-db",
                "--tool", "esviritu",
                "--result", "/tmp/fake.sqlite",
                "--accession", "X",
                "--database", "/tmp/fake.db",
                "--db-taxid", "562",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    // MARK: - Equals-form and mixed-form argv walker tests
    //
    // ArgumentParser accepts both `--sample A` (space-separated) and
    // `--sample=A` (equals-joined). The raw-argv walker in
    // `buildClassifierSelectors` must handle both. Phase 3 review #1 flagged
    // this as a critical bug because the original walker only matched on
    // literal tokens, silently producing an empty selector list for any caller
    // that used the equals form.

    func testParse_byClassifier_equalsForm_sampleAndAccession() throws {
        let argv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", "/tmp/fake.sqlite",
            "--sample=A",
            "--accession=NC_001",
            "--sample=B",
            "--accession=NC_002",
            "-o", "/tmp/out.fastq",
        ]
        let cmd = try ExtractReadsSubcommand.parse(argv)
        XCTAssertNoThrow(try cmd.validate())
        let selectors = cmd.buildClassifierSelectors(rawArgs: argv)
        XCTAssertEqual(selectors.count, 2)
        XCTAssertEqual(selectors[0].sampleId, "A")
        XCTAssertEqual(selectors[0].accessions, ["NC_001"])
        XCTAssertEqual(selectors[1].sampleId, "B")
        XCTAssertEqual(selectors[1].accessions, ["NC_002"])
    }

    func testParse_byClassifier_equalsForm_taxon() throws {
        let argv = [
            "--by-classifier",
            "--tool", "kraken2",
            "--result", "/tmp/fake",
            "--sample=S1",
            "--taxon=9606",
            "--taxon=562",
            "-o", "/tmp/out.fastq",
        ]
        let cmd = try ExtractReadsSubcommand.parse(argv)
        XCTAssertNoThrow(try cmd.validate())
        let selectors = cmd.buildClassifierSelectors(rawArgs: argv)
        XCTAssertEqual(selectors.count, 1)
        XCTAssertEqual(selectors[0].sampleId, "S1")
        XCTAssertEqual(selectors[0].taxIds, [9606, 562])
    }

    func testParse_byClassifier_mixedForm_spaceAndEquals() throws {
        // A single invocation that mixes space-separated and equals-joined
        // flag forms. The walker must handle both within one argv.
        let argv = [
            "--by-classifier",
            "--tool", "esviritu",
            "--result", "/tmp/fake.sqlite",
            "--sample", "A",
            "--accession=NC_001",
            "--accession", "NC_002",
            "--sample=B",
            "--accession", "NC_003",
            "-o", "/tmp/out.fastq",
        ]
        let cmd = try ExtractReadsSubcommand.parse(argv)
        XCTAssertNoThrow(try cmd.validate())
        let selectors = cmd.buildClassifierSelectors(rawArgs: argv)
        XCTAssertEqual(selectors.count, 2)
        XCTAssertEqual(selectors[0].sampleId, "A")
        XCTAssertEqual(selectors[0].accessions, ["NC_001", "NC_002"])
        XCTAssertEqual(selectors[1].sampleId, "B")
        XCTAssertEqual(selectors[1].accessions, ["NC_003"])
    }

    // MARK: - makeExtractionOptions flow-through
    //
    // Pins that CLI flags (--read-format, --include-unmapped-mates) are
    // correctly translated into the `ExtractionOptions` struct that
    // `runByClassifier` hands to `ClassifierReadResolver`. This is the parse-
    // level proof that the flags do anything at all without having to run a
    // full extraction pipeline.

    func testMakeExtractionOptions_defaults_areFastqAndNoMates() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-classifier",
            "--tool", "esviritu",
            "--result", "/tmp/fake.sqlite",
            "--accession", "X",
            "-o", "/tmp/out.fastq",
        ])
        let options = cmd.makeExtractionOptions()
        XCTAssertEqual(options.format, .fastq)
        XCTAssertFalse(options.includeUnmappedMates)
        // Sanity-check the samtools flag derivation (the resolver reads this).
        XCTAssertEqual(options.samtoolsExcludeFlags, 0x404)
    }

    func testMakeExtractionOptions_includeUnmappedMates_flowsThrough() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-classifier",
            "--tool", "esviritu",
            "--result", "/tmp/fake.sqlite",
            "--accession", "X",
            "--include-unmapped-mates",
            "-o", "/tmp/out.fastq",
        ])
        let options = cmd.makeExtractionOptions()
        XCTAssertTrue(options.includeUnmappedMates)
        // With --include-unmapped-mates, samtools should drop the 0x004 bit.
        XCTAssertEqual(options.samtoolsExcludeFlags, 0x400)
    }

    func testMakeExtractionOptions_readFormatFasta_flowsThrough() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-classifier",
            "--tool", "nvd",
            "--result", "/tmp/fake.sqlite",
            "--accession", "X",
            "--read-format", "fasta",
            "-o", "/tmp/out.fasta",
        ])
        let options = cmd.makeExtractionOptions()
        XCTAssertEqual(options.format, .fasta)
    }

    // MARK: - Nonexistent --result surfacing
    //
    // Regression guard: runByClassifier must pre-check `fm.fileExists(…)` on
    // the classifier result path BEFORE calling into the resolver. Without
    // this, a typo'd `--result` path would fall through to a lower-level
    // resolver error (`bamNotFound`, `sqliteOpenFailed`, etc.) and dump a raw
    // Swift error instead of the friendly formatter.error(...).

    func testRun_byClassifier_nonexistentResult_failsWithReadableMessage() async throws {
        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-nx-out-\(UUID().uuidString).fastq")
            .standardizedFileURL
        defer { removeIfPresent(tempOut) }

        // A path that definitely doesn't exist. We don't have to worry about
        // accidentally hitting a real file because the UUID is unique.
        let bogusResult = "/does/not/exist/\(UUID().uuidString).sqlite"

        let argv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", bogusResult,
            "--sample", "s2",
            "--accession", "anything",
            "-o", tempOut.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()

        // The pre-flight check in runByClassifier should throw ExitCode.failure.
        do {
            try await cmd.run()
            XCTFail("Expected run() to throw when --result points to a nonexistent path")
        } catch {
            // Accept either ExitCode.failure (what runByClassifier throws) or
            // any Swift error whose description mentions exit status 1.
            // `ExitCode` is a CustomStringConvertible so the fallback branch
            // is for future refactors that might rethrow a different type.
            if let exit = error as? ExitCode {
                XCTAssertEqual(exit, ExitCode.failure)
            } else {
                // Leaving the soft-assert here rather than XCTFail so a
                // future refactor that switches to a more informative error
                // type doesn't silently break this test.
                XCTAssertFalse(
                    "\(error)".isEmpty,
                    "Expected a non-empty error description"
                )
            }
        }

        // The output file must NOT have been created.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempOut.path),
            "Pre-flight check should fail before any output file is created"
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
    /// BAM + BAI into the `bam/{sampleId}.filtered.bam` layout that
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
        let bamDirectory = root.appendingPathComponent("bam", isDirectory: true)
        try fm.createDirectory(at: bamDirectory, withIntermediateDirectories: true)
        let dest = bamDirectory.appendingPathComponent("\(sampleId).filtered.bam")
        try fm.copyItem(at: bam, to: dest)
        try fm.copyItem(at: bai, to: URL(fileURLWithPath: dest.path + ".bai"))
        return root.appendingPathComponent("fake-nvd.sqlite")
    }

    func testRun_byClassifier_nvd_endToEnd() async throws {
        let resultPath = try makeSarscov2NVDFixture(sampleId: "s2")
        let fixtureRoot = resultPath.deletingLastPathComponent()
        defer { removeIfPresent(fixtureRoot) }

        // Discover the actual BAM reference name so we don't hard-code
        // MN908947.3 and accidentally couple the test to the specific fixture
        // version. The resolver itself uses `BAMRegionMatcher` internally; we
        // mirror that here.
        let fixtureBAM = fixtureRoot.appendingPathComponent("bam/s2.filtered.bam")
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: fixtureBAM,
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-nvd-out-\(UUID().uuidString).fastq")
            .standardizedFileURL
        defer { removeIfPresent(tempOut) }

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
        defer { removeIfPresent(fixtureRoot) }

        let fixtureBAM = fixtureRoot.appendingPathComponent("bam/s2.filtered.bam")
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: fixtureBAM,
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-nvd-out-\(UUID().uuidString).fasta")
            .standardizedFileURL
        defer { removeIfPresent(tempOut) }

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

private func removeIfPresent(_ url: URL) {
    let normalizedURL = url.standardizedFileURL
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: normalizedURL.path) else {
        return
    }
    try? fileManager.removeItem(at: normalizedURL)
}
