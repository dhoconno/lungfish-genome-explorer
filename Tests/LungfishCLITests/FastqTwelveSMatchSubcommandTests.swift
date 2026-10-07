import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqTwelveSMatchSubcommandTests: XCTestCase {
    /// Re-review 2. The help says what the command reads, FASTQ files or
    /// .lungfishfastq bundles of merged reads, unmerged pairs or both, that a
    /// pair counts once when its mates agree, and that a file named inside a
    /// bundle is read alone. Neither the help nor the refusal of no input
    /// says the inputs must be merged reads.
    func testHelpSaysWhatTheCommandReadsAndHowAPairCounts() throws {
        let help = FastqTwelveSMatchSubcommand.helpMessage(columns: 400)

        XCTAssertFalse(help.contains("Match merged 12S"), help)
        XCTAssertFalse(help.contains("Merged FASTQ input"), help)
        XCTAssertTrue(help.contains("OVERVIEW: Match 12S amplicon FASTQ reads to a deduplicated reference FASTA"), help)
        XCTAssertTrue(help.contains("FASTQ files, plain or gzip-compressed, or .lungfishfastq bundles of merged reads, unmerged pairs or both"), help)
        XCTAssertTrue(help.contains("A merged read counts once, and so does an unmerged pair whose mates agree."), help)
        XCTAssertTrue(help.contains("A file named inside a bundle, such as SampleA.lungfishfastq/merged.fastq, is read alone"), help)

        var command = try FastqTwelveSMatchSubcommand.parse([
            "reads.fastq", "--reference", "reference.fa", "--output-dir", "out", "--output-name", "sample-12s",
        ])
        command.inputs = []
        XCTAssertThrowsError(try command.validate()) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "At least one FASTQ file or .lungfishfastq bundle is required.")
        }
        XCTAssertEqual(
            TwelveSAmpliconMatchingError.noInputs.errorDescription,
            "At least one FASTQ file or .lungfishfastq bundle is required."
        )
    }

    func testFastqCommandRegistersTwelveSMatch() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("12s-match"))
        XCTAssertTrue(names.contains("12s-reference-metadata"))
        XCTAssertTrue(names.contains("12s-reference-bundle"))
    }

    func testTwelveSReferenceMetadataParsesOptions() throws {
        let command = try FastqTwelveSReferenceMetadataSubcommand.parse([
            "--dedup-fasta", "/tmp/amplicons_12s.fa",
            "--midori-metadata", "/tmp/12s_reference.tsv",
            "--output", "/tmp/12s-target-metadata.tsv",
            "--force",
        ])

        XCTAssertEqual(command.deduplicatedFASTA, "/tmp/amplicons_12s.fa")
        XCTAssertEqual(command.midoriMetadataTSV, "/tmp/12s_reference.tsv")
        XCTAssertEqual(command.output, "/tmp/12s-target-metadata.tsv")
        XCTAssertTrue(command.force)
    }

    func testTwelveSReferenceBundleParsesOptions() throws {
        let command = try FastqTwelveSReferenceBundleSubcommand.parse([
            "--dedup-fasta", "/tmp/amplicons_12s.fa",
            "--midori-metadata", "/tmp/12s_reference.tsv",
            "--output", "/tmp/MIDORI.lungfish12sref",
            "--name", "MIDORI 12S",
            "--source-file", "/tmp/build.log",
            "--source-directory", "/tmp/taxdump",
            "--force",
        ])

        XCTAssertEqual(command.deduplicatedFASTA, "/tmp/amplicons_12s.fa")
        XCTAssertEqual(command.midoriMetadataTSV, "/tmp/12s_reference.tsv")
        XCTAssertEqual(command.output, "/tmp/MIDORI.lungfish12sref")
        XCTAssertEqual(command.name, "MIDORI 12S")
        XCTAssertEqual(command.sourceFiles, ["/tmp/build.log"])
        XCTAssertEqual(command.sourceDirectories, ["/tmp/taxdump"])
        XCTAssertTrue(command.force)
    }

    func testTwelveSMatchParsesOptions() throws {
        let command = try FastqTwelveSMatchSubcommand.parse([
            "/tmp/sampleA.fastq.gz",
            "/tmp/sampleB.fastq.gz",
            "--reference", "/tmp/amplicons_12s.fa",
            "--output-dir", "/tmp/out",
            "--output-name", "wwtp-12s",
            "--reference-metadata", "/tmp/12s-target-metadata.tsv",
            "--sample-metadata", "/tmp/samples.tsv",
            "--min-soft-clip", "2",
            "--max-indels", "4",
            "--matching-mode", "ont-indel",
            "--threads", "4",
            "--no-chimera-review",
            "--force",
        ])

        XCTAssertEqual(command.inputs, ["/tmp/sampleA.fastq.gz", "/tmp/sampleB.fastq.gz"])
        XCTAssertEqual(command.reference, "/tmp/amplicons_12s.fa")
        XCTAssertEqual(command.outputDir, "/tmp/out")
        XCTAssertEqual(command.outputName, "wwtp-12s")
        XCTAssertEqual(command.referenceMetadata, "/tmp/12s-target-metadata.tsv")
        XCTAssertEqual(command.sampleMetadata, "/tmp/samples.tsv")
        XCTAssertEqual(command.minimumSoftClipBases, 2)
        XCTAssertEqual(command.maximumIndelBases, 4)
        XCTAssertEqual(command.matchingMode, "ont-indel")
        XCTAssertEqual(command.globalOptions.threads, 4)
        XCTAssertFalse(command.chimeraReview)
        XCTAssertTrue(command.force)
    }

    func testBuildsWorkflowConfigurationWithReplayableArgv() throws {
        let command = try FastqTwelveSMatchSubcommand.parse([
            "/tmp/sampleA.fastq",
            "--reference", "/tmp/amplicons_12s.fa",
            "--output-dir", "/tmp/out",
            "--output-name", "wwtp-12s",
            "--reference-metadata", "/tmp/12s-target-metadata.tsv",
            "--sample-metadata", "/tmp/samples.tsv",
            "--min-soft-clip", "2",
            "--max-indels", "4",
            "--matching-mode", "ont-indel",
            "--threads", "4",
            "--force",
        ])

        let config = try command.configurationForTesting()

        XCTAssertEqual(config.inputFASTQs.map(\.path), ["/tmp/sampleA.fastq"])
        XCTAssertEqual(config.referenceFASTA.path, "/tmp/amplicons_12s.fa")
        XCTAssertEqual(config.referenceMetadata?.path, "/tmp/12s-target-metadata.tsv")
        XCTAssertEqual(config.sampleMetadata?.path, "/tmp/samples.tsv")
        XCTAssertEqual(config.outputDirectory.path, "/tmp/out")
        XCTAssertEqual(config.outputName, "wwtp-12s")
        XCTAssertEqual(config.minimumSoftClipBases, 2)
        XCTAssertEqual(config.maximumIndelBases, 4)
        XCTAssertEqual(config.matchingMode, .ontIndel)
        XCTAssertEqual(config.threads, 4)
        XCTAssertTrue(config.runChimeraReview)
        XCTAssertTrue(config.forceOverwrite)
        XCTAssertEqual(config.argv.first, "lungfish-cli")
        XCTAssertTrue(config.argv.contains("12s-match"))
        XCTAssertTrue(config.argv.contains("--reference-metadata"))
        XCTAssertTrue(config.argv.contains("--sample-metadata"))
        XCTAssertTrue(config.argv.contains("--matching-mode"))
        XCTAssertTrue(config.argv.contains("ont-indel"))
        XCTAssertTrue(config.argv.contains("--threads"))
    }

    func testTwelveSMatchDefaultsToIlluminaExactMode() throws {
        let command = try FastqTwelveSMatchSubcommand.parse([
            "/tmp/a.fastq", "--reference", "/tmp/ref.fa",
            "--output-dir", "/tmp/out", "--output-name", "x",
        ])

        let config = try command.configurationForTesting()

        XCTAssertEqual(command.matchingMode, "illumina-exact")
        XCTAssertEqual(config.matchingMode, .illuminaExact)
        // The replay names the mode even when it is the default, as the app's
        // recorded command does, so the two are one command.
        XCTAssertEqual(config.argv.suffix(2), ["--matching-mode", "illumina-exact"])
    }

    func testAmbiguityResolutionDefaultsToStrict() throws {
        let command = try FastqTwelveSMatchSubcommand.parse([
            "/tmp/a.fastq", "--reference", "/tmp/ref.fa",
            "--output-dir", "/tmp/out", "--output-name", "x",
        ])
        XCTAssertEqual(command.ambiguityResolution, "strict")
        XCTAssertEqual(command.resolutionPolicy, .anyNonzeroLead)
        // strict is the default → not emitted in replay argv
        let config = try command.configurationForTesting()
        XCTAssertFalse(config.argv.contains("--ambiguity-resolution"))
        XCTAssertEqual(config.ambiguityResolution, .anyNonzeroLead)
    }

    func testAmbiguityResolutionConservativeMapsToFoldRatioAndFloor() throws {
        let command = try FastqTwelveSMatchSubcommand.parse([
            "/tmp/a.fastq", "--reference", "/tmp/ref.fa",
            "--output-dir", "/tmp/out", "--output-name", "x",
            "--ambiguity-resolution", "conservative",
        ])
        XCTAssertEqual(command.resolutionPolicy, .conservative(minFoldRatio: 2.0, absoluteFloor: 10))
        let config = try command.configurationForTesting()
        XCTAssertEqual(config.ambiguityResolution, .conservative(minFoldRatio: 2.0, absoluteFloor: 10))
        XCTAssertTrue(config.argv.contains("--ambiguity-resolution"))
        XCTAssertTrue(config.argv.contains("conservative"))
    }

    func testAmbiguityResolutionRejectsUnknownValue() {
        XCTAssertThrowsError(try {
            let command = try FastqTwelveSMatchSubcommand.parse([
                "/tmp/a.fastq", "--reference", "/tmp/ref.fa",
                "--output-dir", "/tmp/out", "--output-name", "x",
                "--ambiguity-resolution", "bogus",
            ])
            try command.validate()
        }())
    }

    func testBuildsWorkflowConfigurationFromTwelveSReferenceBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqTwelveSMatchSubcommandTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("MIDORI.lungfish12sref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(">target\nACGT\n".utf8).write(to: bundleURL.appendingPathComponent("reference.fa"))
        try Data("target_id\tsequence_sha256\nref\tsha\n".utf8).write(to: bundleURL.appendingPathComponent("target-metadata.tsv"))
        try Data("""
        {
          "schemaVersion": 1,
          "kind": "12s-reference",
          "name": "MIDORI 12S",
          "referenceFastaPath": "reference.fa",
          "targetMetadataPath": "target-metadata.tsv",
          "sourceFiles": [],
          "metrics": {
            "referenceCount": 1,
            "metadataRowCount": 1,
            "taxidCount": 0,
            "taxonGroupCount": 0,
            "taxonomyCount": 0,
            "alternateMatchCount": 0
          },
          "provenancePath": ".lungfish-provenance.json",
          "createdAt": "2026-05-30T00:00:00Z"
        }
        """.utf8).write(to: bundleURL.appendingPathComponent("12s-reference.json"))

        let command = try FastqTwelveSMatchSubcommand.parse([
            "/tmp/sampleA.fastq",
            "--reference", bundleURL.path,
            "--output-dir", "/tmp/out",
            "--output-name", "wwtp-12s",
        ])

        let config = try command.configurationForTesting()

        XCTAssertEqual(config.referenceFASTA, bundleURL.appendingPathComponent("reference.fa").standardizedFileURL)
        XCTAssertEqual(config.referenceMetadata, bundleURL.appendingPathComponent("target-metadata.tsv").standardizedFileURL)
        XCTAssertEqual(config.referenceBundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(config.argv.filter { $0 == bundleURL.path }.count, 1)
    }

    func testFormatsProgressLinesForOperationsPanelParser() {
        XCTAssertEqual(
            FastqTwelveSMatchSubcommand.progressLine(fraction: 0.4, message: "Matching reads to 12S references."),
            "[ 40%] Matching reads to 12S references.\n"
        )
        XCTAssertEqual(
            FastqTwelveSMatchSubcommand.progressLine(fraction: 1.5, message: "Complete."),
            "[100%] Complete.\n"
        )
    }
}
