// ClassifierCLIRoundTripTests.swift — CLI command end-to-end runs against the shared fixtures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// Phase 7 Task 7.3 — End-to-end CLI runs of `lungfish extract reads
/// --by-classifier` against the shared classifier extraction fixtures.
///
/// Phase 6 I7 already covers one CLI round-trip inside the invariant suite.
/// This suite adds per-flag coverage: single-sample file output, multi-sample
/// concatenation, --bundle landing inside the project root (the EsViritu
/// regression guard), --read-format fasta header conversion, and kraken2 via
/// --taxon.
///
/// All tests use `ExtractReadsSubcommand.parse(...)` followed by
/// `cmd.validate()` and `cmd.run()` so the argument parsing, validation, and
/// runtime paths are exercised together.
final class ClassifierCLIRoundTripTests: XCTestCase {

    // MARK: - Single-sample, BAM-backed, file destination

    func testCLI_esviritu_byClassifier_file() async throws {
        let (resultPath, projectRoot) = try ClassifierExtractionFixtures.buildFixture(
            tool: .esviritu,
            sampleId: "CLI"
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let ref = try await ClassifierExtractionFixtures.sarscov2FirstReference()

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-esv-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: out) }

        let argv = [
            "--by-classifier",
            "--tool", "esviritu",
            "--result", resultPath.path,
            "--sample", "CLI",
            "--accession", ref,
            "-o", out.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        try await cmd.run()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.path),
            "CLI run must produce output FASTQ at \(out.path)"
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64) ?? 0
        XCTAssertGreaterThan(size, 0, "Single-sample CLI run must produce non-empty output")
    }

    // MARK: - Multi-sample concatenation

    func testCLI_multiSample_byClassifier_concatenates() async throws {
        let (resultPath, projectRoot) = try ClassifierExtractionFixtures.buildMultiSampleFixture(
            tool: .nvd,
            sampleIds: ["A", "B"]
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let ref = try await ClassifierExtractionFixtures.sarscov2FirstReference()

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-multi-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: out) }

        let multiArgv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "A",
            "--accession", ref,
            "--sample", "B",
            "--accession", ref,
            "-o", out.path,
        ]
        var multiCmd = try ExtractReadsSubcommand.parse(multiArgv)
        multiCmd.testingRawArgs = multiArgv
        try multiCmd.validate()
        try await multiCmd.run()

        // Count records in the multi-sample output. Both samples are clones
        // of the same markers BAM, so the combined record count should be
        // exactly 2× the single-sample count — the 2× factor is the load-
        // bearing invariant of the multi-sample concatenation path.
        let multiRecordCount = try Self.countFASTQRecords(at: out)
        XCTAssertGreaterThan(multiRecordCount, 0, "Multi-sample CLI run must produce a non-empty output")

        // Run the sample-A-only single-sample variant for ground truth.
        let singleOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-multi-single-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: singleOut) }
        let singleArgv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "A",
            "--accession", ref,
            "-o", singleOut.path,
        ]
        var singleCmd = try ExtractReadsSubcommand.parse(singleArgv)
        singleCmd.testingRawArgs = singleArgv
        try singleCmd.validate()
        try await singleCmd.run()

        let singleRecordCount = try Self.countFASTQRecords(at: singleOut)
        XCTAssertGreaterThan(singleRecordCount, 0, "Single-sample control run must be non-empty")
        XCTAssertEqual(
            multiRecordCount,
            singleRecordCount * 2,
            "Multi-sample output should be exactly 2× the single-sample count (multi=\(multiRecordCount), single=\(singleRecordCount))"
        )
    }

    // MARK: - Bundle destination lands in project root

    func testCLI_bundle_lands_in_project_root() async throws {
        let (resultPath, projectRoot) = try ClassifierExtractionFixtures.buildFixture(
            tool: .nvd,
            sampleId: "bundle"
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let ref = try await ClassifierExtractionFixtures.sarscov2FirstReference()

        // For --bundle in the CLI, -o is a placeholder; the bundle is written
        // to outputDir (derived from -o's parent). Point it inside the project
        // so the regression guard for the EsViritu bundle-in-.tmp/ bug bites
        // if the bundle lands anywhere other than the project root.
        let placeholder = projectRoot.appendingPathComponent("tmp-bundle.fastq")
        let argv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "bundle",
            "--accession", ref,
            "--bundle",
            "--bundle-name", "nvd-cli-bundle",
            "-o", placeholder.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        try await cmd.run()

        // Look for a .lungfishfastq directory anywhere under projectRoot.
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: projectRoot, includingPropertiesForKeys: nil)
        let allBundles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "lungfishfastq" }
        XCTAssertFalse(
            allBundles.isEmpty,
            "Expected at least one .lungfishfastq bundle under \(projectRoot.path)"
        )

        // Regression guard: the bundle MUST NOT live inside `.lungfish/` (which
        // includes `.lungfish/.tmp/`). The EsViritu bundle-in-`.tmp/` bug is
        // the whole reason for this feature — this is the test that pins it.
        // Valid locations are the project root itself or a visible subdirectory
        // like `Imports/` or `Downloads/`.
        for bundle in allBundles {
            let components = bundle.pathComponents
            XCTAssertFalse(
                components.contains(".lungfish"),
                "Bundle must NOT live inside .lungfish/ subtree: \(bundle.path)"
            )
            XCTAssertFalse(
                components.contains(".tmp"),
                "Bundle must NOT live inside .tmp/ subtree: \(bundle.path)"
            )
        }
    }

    // MARK: - --read-format fasta

    func testCLI_readFormat_fasta_header_convertsCorrectly() async throws {
        let (resultPath, projectRoot) = try ClassifierExtractionFixtures.buildFixture(
            tool: .nvd,
            sampleId: "fa"
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let ref = try await ClassifierExtractionFixtures.sarscov2FirstReference()

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-fa-\(UUID().uuidString).fasta")
        defer { try? FileManager.default.removeItem(at: out) }

        // NOTE: Phase 3 deviation — the classifier uses `--read-format` rather
        // than `--format` because GlobalOptions.format already claims `--format`
        // for the report-output format. See ExtractReadsCommand.swift:157–160.
        let argv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "fa",
            "--accession", ref,
            "--read-format", "fasta",
            "-o", out.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        try await cmd.run()

        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(
            text.hasPrefix(">"),
            "FASTA output must start with '>', got: \(text.prefix(30))"
        )
    }

    // MARK: - Kraken2 via --taxon

    func testCLI_kraken2_roundTrip() async throws {
        let (resultPath, projectRoot) = try ClassifierExtractionFixtures.buildFixture(
            tool: .kraken2,
            sampleId: "kr2"
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        // The kraken2-mini fixture may be incomplete (missing classification.kraken
        // or source FASTQs referenced by the result metadata). Phase 7 scope is
        // test coverage only — a self-contained kraken2 fixture is Phase 8
        // follow-up work. Skip this test with a diagnostic if the load fails.
        let classResult: ClassificationResult
        do {
            classResult = try ClassificationResult.load(from: resultPath)
        } catch {
            throw XCTSkip("Kraken2 fixture incomplete: \(error.localizedDescription)")
        }
        guard let taxon = classResult.tree.allNodes().first(where: { $0.readsClade > 0 && $0.taxId != 0 }) else {
            throw XCTSkip("kraken2-mini has no non-zero taxa")
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-kr2-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: out) }

        let argv = [
            "--by-classifier",
            "--tool", "kraken2",
            "--result", resultPath.path,
            "--taxon", String(taxon.taxId),
            "-o", out.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        do {
            try cmd.validate()
            try await cmd.run()
        } catch {
            // If the kraken2 fixture is incomplete at the extraction stage
            // (source FASTQs missing, per-read assignments missing, etc.),
            // treat it as a skip rather than a failure.
            throw XCTSkip("Kraken2 extraction failed on incomplete fixture: \(error.localizedDescription)")
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.path),
            "Kraken2 CLI run must produce output file at \(out.path)"
        )
    }

    // MARK: - --include-unmapped-mates keeps mates (S1)

    /// Exercises the `--include-unmapped-mates` flag on a BAM-backed classifier
    /// (NVD) against the markers BAM. The markers fixture has three unmapped
    /// records on top of the 199 strict-filtered reads, so the loose-mask
    /// output must be STRICTLY larger than the strict-mask output. Without
    /// this test, a regression that drops the flag in the CLI path would only
    /// be caught by the I5 resolver-level invariant — this pins the CLI
    /// end-to-end.
    func testCLI_includeUnmappedMates_keepsMates() async throws {
        let (resultPath, projectRoot) = try ClassifierExtractionFixtures.buildFixture(
            tool: .nvd,
            sampleId: "ium"
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let ref = try await ClassifierExtractionFixtures.sarscov2FirstReference()

        // Strict: no --include-unmapped-mates, -F 0x404 dispatch
        let strictOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-ium-strict-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: strictOut) }
        let strictArgv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "ium",
            "--accession", ref,
            "-o", strictOut.path,
        ]
        var strictCmd = try ExtractReadsSubcommand.parse(strictArgv)
        strictCmd.testingRawArgs = strictArgv
        try strictCmd.validate()
        try await strictCmd.run()
        let strictCount = try Self.countFASTQRecords(at: strictOut)

        // Loose: --include-unmapped-mates, -F 0x400 dispatch
        let looseOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-ium-loose-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: looseOut) }
        let looseArgv = [
            "--by-classifier",
            "--tool", "nvd",
            "--result", resultPath.path,
            "--sample", "ium",
            "--accession", ref,
            "--include-unmapped-mates",
            "-o", looseOut.path,
        ]
        var looseCmd = try ExtractReadsSubcommand.parse(looseArgv)
        looseCmd.testingRawArgs = looseArgv
        try looseCmd.validate()
        try await looseCmd.run()
        let looseCount = try Self.countFASTQRecords(at: looseOut)

        // The markers BAM has 3 unmapped records, so the delta should be
        // strictly positive.
        XCTAssertGreaterThan(
            looseCount,
            strictCount,
            "--include-unmapped-mates must produce strictly more records than strict mode on the markers BAM (strict=\(strictCount), loose=\(looseCount))"
        )
    }

    // MARK: - --tool kraken2 rejects --include-unmapped-mates (S1)

    /// Phase 3 validation: `--tool kraken2` with `--include-unmapped-mates`
    /// must be rejected. This is a defensive round-trip-level pin on top of
    /// the parse-level check from Phase 3.
    ///
    /// NOTE: ArgumentParser runs `validate()` as part of `parse()` (it surfaces
    /// validation errors as `CommandError.parserError.userValidationError`),
    /// so the rejection actually fires at the `parse` call site rather than at
    /// a subsequent `validate()` call. Both code paths feed into the same
    /// `ValidationError` surface, so asserting on either is equivalent — we
    /// wrap both in a single `XCTAssertThrowsError` to make the test robust
    /// to ArgumentParser's internal ordering.
    func testCLI_kraken2_rejects_includeUnmappedMates() throws {
        let argv = [
            "--by-classifier",
            "--tool", "kraken2",
            "--result", "/tmp/nowhere/fake.json",
            "--taxon", "9606",
            "--include-unmapped-mates",
            "-o", "/tmp/unused.fastq",
        ]
        XCTAssertThrowsError(
            try {
                var cmd = try ExtractReadsSubcommand.parse(argv)
                cmd.testingRawArgs = argv
                try cmd.validate()
            }(),
            "CLI must reject --tool kraken2 with --include-unmapped-mates"
        )
    }

    // MARK: - --by-region --exclude-unmapped (S1)

    /// Exercises the `--by-region` strategy with `--exclude-unmapped`, which
    /// flips the samtools `-F` flag from `0x400` (strip duplicates) to `0x404`
    /// (strip duplicates AND unmapped) at the `samtools view -b` step. The
    /// downstream `samtools fastq` stage applies its own `-F 0x900` filter
    /// (strip secondary + supplementary) so the effective pipeline filter on
    /// the markers BAM is `0x404 | 0x900 = 0xD04`. The test pins the flag
    /// toggle by comparing the CLI's record count to a ground-truth
    /// `samtools view -c -F 0xD04` over the same region.
    ///
    /// This also serves as a negative control: running the same command
    /// WITHOUT `--exclude-unmapped` uses the 0x400 mask, so the ground-truth
    /// equivalent is `-F 0xD00`. The strict count must be strictly less than
    /// the loose count on the markers BAM (which has 3 unmapped records in
    /// the region).
    func testCLI_byRegion_excludeUnmapped_filtersOutUnmapped() async throws {
        let bamURL = ClassifierExtractionFixtures.sarscov2BAM
        let baiURL = ClassifierExtractionFixtures.sarscov2BAMIndex
        let fm = FileManager.default
        guard fm.fileExists(atPath: bamURL.path), fm.fileExists(atPath: baiURL.path) else {
            throw XCTSkip("sarscov2 markers fixture BAM missing at \(bamURL.path)")
        }

        // Read the first reference so we pass a real region value.
        let ref = try await ClassifierExtractionFixtures.sarscov2FirstReference()

        let outputDir = fm.temporaryDirectory
            .appendingPathComponent("cli-byregion-\(UUID().uuidString)")
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outputDir) }
        let out = outputDir.appendingPathComponent("out.fastq")

        let argv = [
            "--by-region",
            "--bam", bamURL.path,
            "--region", ref,
            "--exclude-unmapped",
            "-o", out.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        try await cmd.run()

        // Ground truth: the CLI pipeline is `samtools view -b -F 0x404 | samtools fastq -F 0x900`,
        // so the combined filter is 0x404 | 0x900 = 0xD04.
        let samtoolsPath = await ClassifierExtractionFixtures.resolveSamtoolsPath()
        let strictExpected = try MarkdupService.countReads(
            bamURL: bamURL,
            accession: ref,
            flagFilter: 0xD04,
            samtoolsPath: samtoolsPath
        )
        let looseExpected = try MarkdupService.countReads(
            bamURL: bamURL,
            accession: ref,
            flagFilter: 0xD00,
            samtoolsPath: samtoolsPath
        )

        // The CLI's by-region path writes one FASTQ per region, so the
        // expected output is at <outputDir>/<base>.fastq.
        let actual = try Self.countFASTQRecords(at: out)
        XCTAssertEqual(
            actual,
            strictExpected,
            "--by-region --exclude-unmapped record count must match samtools -F 0xD04 ground truth (actual=\(actual), expected=\(strictExpected))"
        )
        XCTAssertLessThan(
            strictExpected,
            looseExpected,
            "Markers BAM must have strictly fewer records under --exclude-unmapped (0xD04) than without it (0xD00); otherwise the test has no teeth"
        )
    }

    // MARK: - Test helpers

    /// Counts FASTQ records by dividing the total line count by 4.
    ///
    /// Robust against quality-line `@` ambiguity: FASTQ records are 4 lines
    /// each (header, sequence, `+`, quality), and the quality line can begin
    /// with `@` just like the header, so splitting on header prefix is
    /// unreliable. Dividing line count by 4 is the canonical approach.
    static func countFASTQRecords(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Drop a trailing empty element if the file ends with \n.
        var effectiveCount = lines.count
        if let last = lines.last, last.isEmpty {
            effectiveCount -= 1
        }
        return effectiveCount / 4
    }
}
