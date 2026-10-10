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

    // MARK: Walk F7, the last line goes to standard output

    /// The app logs every standard error line that is not a progress line as a
    /// warning, and a row with a warning reads Completed with Warnings. A clean
    /// run therefore prints only progress lines on standard error, and its last
    /// line, the path it wrote, on standard output.

    private struct CapturedStreams {
        let standardOutput: String
        let standardError: String
    }

    /// Runs `body` in this process with the process's standard output and
    /// standard error sent to files, and returns what `body` wrote to each.
    private func capturingStandardStreams(_ body: () async throws -> Void) async throws -> CapturedStreams {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqTwelveSMatchSubcommandTests-streams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout.txt")
        let errorURL = directory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        fflush(stdout)
        fflush(stderr)
        let savedOutput = dup(STDOUT_FILENO)
        let savedError = dup(STDERR_FILENO)
        guard savedOutput >= 0, savedError >= 0 else { throw POSIXError(.EBADF) }
        dup2(outputHandle.fileDescriptor, STDOUT_FILENO)
        dup2(errorHandle.fileDescriptor, STDERR_FILENO)
        var thrown: Error?
        do {
            try await body()
        } catch {
            thrown = error
        }
        fflush(stdout)
        fflush(stderr)
        dup2(savedOutput, STDOUT_FILENO)
        dup2(savedError, STDERR_FILENO)
        close(savedOutput)
        close(savedError)
        try outputHandle.close()
        try errorHandle.close()
        if let thrown { throw thrown }
        return CapturedStreams(
            standardOutput: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }

    /// Fails for any standard error line that the app would log as a warning.
    private func assertOnlyProgressLines(_ standardError: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in standardError.split(separator: "\n") {
            XCTAssertNotNil(
                text.range(of: #"^\[ *[0-9]+%\] .+"#, options: .regularExpression),
                "standard error holds a line that is not progress: \(text)",
                file: file,
                line: line
            )
        }
    }

    private struct TwelveSFixtures {
        let root: URL
        let reference: URL
        let reads: URL
        let outputDirectory: URL
        let midori: URL

        var matchArguments: [String] {
            [
                reads.path,
                "--reference", reference.path,
                "--output-dir", outputDirectory.path,
                "--output-name", "sampleA-12s",
                "--min-soft-clip", "2",
                "--threads", "1",
                "--no-chimera-review",
            ]
        }

        var resultBundle: URL {
            outputDirectory.appendingPathComponent("sampleA-12s.lungfish12s", isDirectory: true)
        }
    }

    private func makeTwelveSFixtures() throws -> TwelveSFixtures {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqTwelveSMatchSubcommandTests-run-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reference = root.appendingPathComponent("reference.fa")
        try """
        >human (Homo sapiens)|locus=12S|len=8|n_refs=3|n_species=2|also_matches=Heidelberg man (Homo heidelbergensis)|n_primer_pairs=1|primer_pairs=12S_vert
        ACGTACGT
        >rainbow trout (Oncorhynchus mykiss)|locus=12S|len=8|n_refs=2|n_species=1|also_matches=|n_primer_pairs=1|primer_pairs=12S_vert
        TTTTCCCC

        """.write(to: reference, atomically: true, encoding: .utf8)
        let midori = root.appendingPathComponent("midori.tsv")
        try """
        seq_id\tcommon_name\tlatin_name\tgroup\ttaxid\tname_source\ttaxonomy
        AB1\thuman\tHomo sapiens\tMammal\t9606\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo sapiens
        AB2\tHeidelberg man\tHomo heidelbergensis\tMammal\t1425170\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo heidelbergensis
        AB3\trainbow trout\tOncorhynchus mykiss\tFish\t8022\tfishbase\troot; Eukaryota; Chordata; Actinopteri; Salmoniformes; Salmonidae; Oncorhynchus; Oncorhynchus mykiss

        """.write(to: midori, atomically: true, encoding: .utf8)
        let reads = root.appendingPathComponent("sampleA.fastq")
        try "@read1\nTTACGTACGTGG\n+\nIIIIIIIIIIII\n@read2\nGGGGGGGGGGGG\n+\nIIIIIIIIIIII\n"
            .write(to: reads, atomically: true, encoding: .utf8)
        return TwelveSFixtures(
            root: root,
            reference: reference,
            reads: reads,
            outputDirectory: root.appendingPathComponent("results", isDirectory: true),
            midori: midori
        )
    }

    /// The wording is what a user reads in a terminal and what the Operations
    /// panel logs, so a change to it is a deliberate one.
    func testTheSuccessLinesReadAsTheyAlwaysDid() {
        let url = URL(fileURLWithPath: "/tmp/out/result")
        XCTAssertEqual(TwelveSCLISuccessLine.matchResult(url).text, "12S amplicon result bundle written to /tmp/out/result")
        XCTAssertEqual(TwelveSCLISuccessLine.referenceBundle(url).text, "12S reference bundle written to /tmp/out/result")
        XCTAssertEqual(TwelveSCLISuccessLine.targetMetadata(url).text, "12S target metadata written to /tmp/out/result")
        XCTAssertEqual(TwelveSCLISuccessLine.export(url).text, "12S export written to /tmp/out/result")
        XCTAssertEqual(TwelveSCLISuccessLine.unresolvedFASTA(url).text, "12S unresolved FASTA written to /tmp/out/result")
    }

    func testAMatchRunPrintsItsLastLineOnStandardOutputAndOnlyProgressOnStandardError() async throws {
        let fixtures = try makeTwelveSFixtures()

        let streams = try await capturingStandardStreams {
            try await FastqTwelveSMatchSubcommand.parse(fixtures.matchArguments).run()
        }

        XCTAssertEqual(
            streams.standardOutput,
            TwelveSCLISuccessLine.matchResult(fixtures.resultBundle.standardizedFileURL).text + "\n"
        )
        XCTAssertFalse(streams.standardError.isEmpty, "the run reports its progress")
        assertOnlyProgressLines(streams.standardError)
        XCTAssertFalse(streams.standardError.contains("written to"), streams.standardError)
    }

    func testAReferenceBundleRunPrintsItsLastLineOnStandardOutputAndOnlyProgressOnStandardError() async throws {
        let fixtures = try makeTwelveSFixtures()
        let bundle = fixtures.root.appendingPathComponent("MIDORI-12S.lungfish12sref", isDirectory: true)

        let streams = try await capturingStandardStreams {
            try await FastqTwelveSReferenceBundleSubcommand.parse([
                "--dedup-fasta", fixtures.reference.path,
                "--midori-metadata", fixtures.midori.path,
                "--output", bundle.path,
                "--name", "MIDORI 12S",
            ]).run()
        }

        XCTAssertEqual(
            streams.standardOutput,
            TwelveSCLISuccessLine.referenceBundle(bundle.standardizedFileURL).text + "\n"
        )
        XCTAssertFalse(streams.standardError.isEmpty, "the run reports its progress")
        assertOnlyProgressLines(streams.standardError)
        XCTAssertFalse(streams.standardError.contains("written to"), streams.standardError)
    }

    func testAMetadataRunPrintsItsLastLineOnStandardOutputAndNothingOnStandardError() async throws {
        let fixtures = try makeTwelveSFixtures()
        let table = fixtures.root.appendingPathComponent("12s-target-metadata.tsv")

        let streams = try await capturingStandardStreams {
            try await FastqTwelveSReferenceMetadataSubcommand.parse([
                "--dedup-fasta", fixtures.reference.path,
                "--midori-metadata", fixtures.midori.path,
                "--output", table.path,
            ]).run()
        }

        XCTAssertEqual(streams.standardOutput, TwelveSCLISuccessLine.targetMetadata(table.standardizedFileURL).text + "\n")
        XCTAssertEqual(streams.standardError, "")
    }

    func testAnExportRunPrintsItsLastLineOnStandardOutputAndNothingOnStandardError() async throws {
        let fixtures = try makeTwelveSFixtures()
        try await FastqTwelveSMatchSubcommand.parse(fixtures.matchArguments).run()
        let report = fixtures.root.appendingPathComponent("report.csv")

        let streams = try await capturingStandardStreams {
            try await FastqTwelveSExportSubcommand.parse([
                "--bundle", fixtures.resultBundle.path,
                "--export-format", "csv",
                "--output", report.path,
            ]).run()
        }

        XCTAssertEqual(streams.standardOutput, TwelveSCLISuccessLine.export(report.standardizedFileURL).text + "\n")
        XCTAssertEqual(streams.standardError, "")
    }

    func testAnUnresolvedExportRunPrintsItsLastLineOnStandardOutputAndNothingOnStandardError() async throws {
        let fixtures = try makeTwelveSFixtures()
        try await FastqTwelveSMatchSubcommand.parse(fixtures.matchArguments).run()
        let fasta = fixtures.root.appendingPathComponent("unresolved.fasta")

        let streams = try await capturingStandardStreams {
            try await FastqTwelveSExportUnresolvedSubcommand.parse([
                "--bundle", fixtures.resultBundle.path,
                "--min-reads", "1",
                "--output", fasta.path,
            ]).run()
        }

        XCTAssertEqual(streams.standardOutput, TwelveSCLISuccessLine.unresolvedFASTA(fasta.standardizedFileURL).text + "\n")
        XCTAssertEqual(streams.standardError, "")
    }
}
