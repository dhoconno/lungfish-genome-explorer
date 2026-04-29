// CLIRegressionTests.swift - Regression tests for LungfishCLI commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Tests command parsing, subcommand structure, option validation, and help
// text generation for all top-level CLI commands. Uses ArgumentParser's
// parse() method -- NEVER creates GlobalOptions() directly (see MEMORY.md).
//
// NOTE: ClassifyCommand, MapCommand, and OrientCommand still have a duplicate
// local/global --threads bug. AssembleCommand no longer does, so it can be
// exercised with real help/parse coverage.

import ArgumentParser
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Top-Level CLI Structure

final class CLITopLevelRegressionTests: XCTestCase {

    func testLungfishCLICommandName() {
        XCTAssertEqual(LungfishCLI.configuration.commandName, "lungfish")
    }

    func testLungfishCLIVersion() {
        XCTAssertEqual(LungfishCLI.configuration.version, "0.4.0-alpha.4")
    }

    func testLungfishCLIAbstractIsNonEmpty() {
        XCTAssertFalse(LungfishCLI.configuration.abstract.isEmpty)
    }

    func testLungfishCLIHasNoDefaultSubcommand() {
        XCTAssertNil(LungfishCLI.configuration.defaultSubcommand)
    }

    func testLungfishCLISubcommandCount() {
        // 21 subcommands registered at the time of writing.
        // If a subcommand is added or removed, update this count.
        let subcommands = LungfishCLI.configuration.subcommands
        XCTAssertGreaterThanOrEqual(subcommands.count, 20,
            "Expected at least 20 subcommands; found \(subcommands.count)")
    }

    func testHelpTextIsNonEmpty() throws {
        let helpText = LungfishCLI.helpMessage()
        XCTAssertFalse(helpText.isEmpty)
        XCTAssertTrue(helpText.contains("lungfish"))
    }
}

// MARK: - GlobalOptions Parsing

final class GlobalOptionsRegressionTests: XCTestCase {

    func testDefaultParsing() throws {
        let options = try GlobalOptions.parse([])
        XCTAssertEqual(options.verbosity, 0)
        XCTAssertFalse(options.quiet)
        XCTAssertFalse(options.showProgress)
        XCTAssertFalse(options.noProgress)
        XCTAssertFalse(options.debug)
        XCTAssertNil(options.logFile)
        XCTAssertFalse(options.noColor)
        XCTAssertNil(options.threads)
        XCTAssertEqual(options.outputFormat, .text)
    }

    func testDebugFlag() throws {
        let options = try GlobalOptions.parse(["--debug"])
        XCTAssertTrue(options.debug)
    }

    func testQuietFlag() throws {
        let options = try GlobalOptions.parse(["--quiet"])
        XCTAssertTrue(options.quiet)
        XCTAssertEqual(options.effectiveVerbosity, -1)
    }

    func testVerboseFlag() throws {
        let options = try GlobalOptions.parse(["-v"])
        XCTAssertEqual(options.verbosity, 1)
        XCTAssertEqual(options.effectiveVerbosity, 1)
    }

    func testDoubleVerbose() throws {
        let options = try GlobalOptions.parse(["-vv"])
        XCTAssertEqual(options.verbosity, 2)
    }

    func testNoColorFlag() throws {
        let options = try GlobalOptions.parse(["--no-color"])
        XCTAssertTrue(options.noColor)
        XCTAssertFalse(options.useColors)
    }

    func testThreadsOption() throws {
        let options = try GlobalOptions.parse(["--threads", "8"])
        XCTAssertEqual(options.threads, 8)
        XCTAssertEqual(options.effectiveThreads, 8)
    }

    func testDefaultEffectiveThreadsUsesProcessorCount() throws {
        let options = try GlobalOptions.parse([])
        XCTAssertEqual(options.effectiveThreads, ProcessInfo.processInfo.activeProcessorCount)
    }

    func testJsonOutputFormat() throws {
        let options = try GlobalOptions.parse(["--format", "json"])
        XCTAssertEqual(options.outputFormat, .json)
    }

    func testTsvOutputFormat() throws {
        let options = try GlobalOptions.parse(["--format", "tsv"])
        XCTAssertEqual(options.outputFormat, .tsv)
    }

    func testOutputModeDebug() throws {
        let options = try GlobalOptions.parse(["--debug"])
        XCTAssertEqual(options.outputMode, .debug)
    }

    func testOutputModeJson() throws {
        let options = try GlobalOptions.parse(["--format", "json"])
        XCTAssertEqual(options.outputMode, .json)
    }

    func testProgressFlags() throws {
        let withProgress = try GlobalOptions.parse(["--progress"])
        XCTAssertTrue(withProgress.showProgress)

        let noProgress = try GlobalOptions.parse(["--no-progress"])
        XCTAssertTrue(noProgress.noProgress)
        XCTAssertFalse(noProgress.shouldShowProgress)
    }

    func testLogFileOption() throws {
        let options = try GlobalOptions.parse(["--log-file", "/tmp/test.log"])
        XCTAssertEqual(options.logFile, "/tmp/test.log")
    }
}

// MARK: - OutputFormat

final class OutputFormatRegressionTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(OutputFormat.allCases.count, 3)
        XCTAssertTrue(OutputFormat.allCases.contains(.text))
        XCTAssertTrue(OutputFormat.allCases.contains(.json))
        XCTAssertTrue(OutputFormat.allCases.contains(.tsv))
    }

    func testRawValues() {
        XCTAssertEqual(OutputFormat.text.rawValue, "text")
        XCTAssertEqual(OutputFormat.json.rawValue, "json")
        XCTAssertEqual(OutputFormat.tsv.rawValue, "tsv")
    }
}

// MARK: - CLIExitCode

final class CLIExitCodeRegressionTests: XCTestCase {

    func testExitCodeValues() {
        XCTAssertEqual(CLIExitCode.success.rawValue, 0)
        XCTAssertEqual(CLIExitCode.failure.rawValue, 1)
        XCTAssertEqual(CLIExitCode.usage.rawValue, 2)
        XCTAssertEqual(CLIExitCode.inputError.rawValue, 3)
        XCTAssertEqual(CLIExitCode.outputError.rawValue, 4)
        XCTAssertEqual(CLIExitCode.formatError.rawValue, 5)
        XCTAssertEqual(CLIExitCode.workflowError.rawValue, 64)
        XCTAssertEqual(CLIExitCode.containerError.rawValue, 65)
        XCTAssertEqual(CLIExitCode.networkError.rawValue, 66)
        XCTAssertEqual(CLIExitCode.timeout.rawValue, 124)
        XCTAssertEqual(CLIExitCode.cancelled.rawValue, 125)
        XCTAssertEqual(CLIExitCode.dependency.rawValue, 126)
        XCTAssertEqual(CLIExitCode.notFound.rawValue, 127)
    }

    func testExitCodeConversion() {
        let code = CLIExitCode.success
        XCTAssertEqual(code.exitCode.rawValue, 0)
    }
}

// MARK: - ClassifyCommand Input Format

final class ClassifyCommandInputFormatRegressionTests: XCTestCase {

    func testInferInputFormatReturnsFASTAForHomogeneousFASTAInputs() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/input-a.fasta"),
            URL(fileURLWithPath: "/tmp/input-b.fa"),
        ]

        XCTAssertEqual(try ClassifyCommand.inferInputFormat(from: urls), .fasta)
    }

    func testInferInputFormatReturnsFASTAForReferenceBundleInputs() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-reference-input-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = try makeReferenceBundle(
            named: "classify-reference",
            under: tempDir,
            fastaFilename: "genome/sequence.fa.gz"
        )

        XCTAssertEqual(try ClassifyCommand.inferInputFormat(from: [bundleURL]), .fasta)
    }

    func testInferInputFormatRejectsMixedSequenceFormats() {
        let urls = [
            URL(fileURLWithPath: "/tmp/input-a.fastq"),
            URL(fileURLWithPath: "/tmp/input-b.fasta"),
        ]

        XCTAssertThrowsError(try ClassifyCommand.inferInputFormat(from: urls)) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(type(of: error))")
                return
            }
            switch cliError {
            case .validationFailed(let errors):
                XCTAssertTrue(errors.contains { $0.contains("same format") })
            default:
                XCTFail("Expected validationFailed, got \(cliError)")
            }
        }
    }
}

// MARK: - CLIError

final class CLIErrorRegressionTests: XCTestCase {

    func testErrorDescriptions() {
        let errors: [(CLIError, String)] = [
            (.inputFileNotFound(path: "/a/b"), "Input file not found: /a/b"),
            (.outputWriteFailed(path: "/x", reason: "disk full"), "Failed to write output file '/x': disk full"),
            (.formatDetectionFailed(path: "f.xyz"), "Could not detect format for file: f.xyz"),
            (.unsupportedFormat(format: "xyz"), "Unsupported format: xyz"),
            (.conversionFailed(reason: "bad"), "Conversion failed: bad"),
            (.containerUnavailable, "Apple Containerization is not available. Requires macOS 26 or later."),
            (.networkError(reason: "timeout"), "Network error: timeout"),
            (.cancelled, "Operation cancelled"),
        ]

        for (error, expected) in errors {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }

    func testExitCodeMapping() {
        XCTAssertEqual(CLIError.inputFileNotFound(path: "").exitCode, .inputError)
        XCTAssertEqual(CLIError.outputWriteFailed(path: "", reason: "").exitCode, .outputError)
        XCTAssertEqual(CLIError.formatDetectionFailed(path: "").exitCode, .formatError)
        XCTAssertEqual(CLIError.unsupportedFormat(format: "").exitCode, .formatError)
        XCTAssertEqual(CLIError.conversionFailed(reason: "").exitCode, .failure)
        XCTAssertEqual(CLIError.validationFailed(errors: []).exitCode, .failure)
        XCTAssertEqual(CLIError.workflowFailed(reason: "").exitCode, .workflowError)
        XCTAssertEqual(CLIError.containerUnavailable.exitCode, .containerError)
        XCTAssertEqual(CLIError.networkError(reason: "").exitCode, .networkError)
        XCTAssertEqual(CLIError.cancelled.exitCode, .cancelled)
    }

    func testValidationFailedDescription() {
        let error = CLIError.validationFailed(errors: ["bad field", "missing value"])
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("bad field"))
        XCTAssertTrue(desc.contains("missing value"))
    }
}

// MARK: - ConvertCommand

final class ConvertCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(ConvertCommand.configuration.commandName, "convert")
    }

    func testHelpTextIsNonEmpty() {
        let help = ConvertCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
        XCTAssertTrue(help.contains("convert"))
    }

    func testParsingWithRequiredArguments() throws {
        let cmd = try ConvertCommand.parse(["input.fa", "--to", "output.gb", "--to-format", "genbank"])
        XCTAssertEqual(cmd.input, "input.fa")
        XCTAssertEqual(cmd.outputFile, "output.gb")
        XCTAssertEqual(cmd.toFormat, "genbank")
        XCTAssertFalse(cmd.includeAnnotations)
        XCTAssertFalse(cmd.force)
    }

    func testParsingWithForceFlag() throws {
        let cmd = try ConvertCommand.parse(["in.fa", "--to", "out.fa", "--force"])
        XCTAssertTrue(cmd.force)
    }

    func testParsingMissingOutputThrows() {
        XCTAssertThrowsError(try ConvertCommand.parse(["input.fa"]))
    }
}

// MARK: - AnalyzeCommand

final class AnalyzeCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(AnalyzeCommand.configuration.commandName, "analyze")
    }

    func testSubcommands() {
        let subs = AnalyzeCommand.configuration.subcommands
        XCTAssertEqual(subs.count, 3)
    }

    func testDefaultSubcommand() {
        XCTAssertNotNil(AnalyzeCommand.configuration.defaultSubcommand)
    }

    func testHelpTextIsNonEmpty() {
        let help = AnalyzeCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testStatsSubcommandParsing() throws {
        let cmd = try StatsSubcommand.parse(["genome.fasta"])
        XCTAssertEqual(cmd.input, "genome.fasta")
        XCTAssertFalse(cmd.perSequence)
    }

    func testStatsSubcommandWithFlags() throws {
        let cmd = try StatsSubcommand.parse(["genome.fasta", "--per-sequence", "--length-distribution"])
        XCTAssertTrue(cmd.perSequence)
        XCTAssertTrue(cmd.lengthDistribution)
    }

    func testValidateSubcommandParsing() throws {
        let cmd = try FileValidateSubcommand.parse(["file1.fa", "file2.vcf"])
        XCTAssertEqual(cmd.files.count, 2)
    }

    func testValidateSubcommandStrictFlag() throws {
        let cmd = try FileValidateSubcommand.parse(["file.fa", "--strict"])
        XCTAssertTrue(cmd.strict)
    }
}

// MARK: - TranslateCommand

final class TranslateCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(TranslateCommand.configuration.commandName, "translate")
    }

    func testHelpTextIsNonEmpty() {
        let help = TranslateCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testParsingMinimalArguments() throws {
        let cmd = try TranslateCommand.parse(["input.fasta"])
        XCTAssertEqual(cmd.input, "input.fasta")
        XCTAssertNil(cmd.frame)
        XCTAssertEqual(cmd.table, 1)
        XCTAssertNil(cmd.output)
        XCTAssertFalse(cmd.trimToStop)
        XCTAssertFalse(cmd.noStopAsterisk)
        XCTAssertFalse(cmd.longestORF)
    }

    func testParsingWithFrame() throws {
        let cmd = try TranslateCommand.parse(["input.fasta", "--frame", "3"])
        XCTAssertEqual(cmd.frame, 3)
    }

    func testParsingWithCodonTable() throws {
        let cmd = try TranslateCommand.parse(["input.fasta", "--table", "11"])
        XCTAssertEqual(cmd.table, 11)
    }

    func testParsingWithOutputFile() throws {
        let cmd = try TranslateCommand.parse(["input.fasta", "-o", "proteins.fa"])
        XCTAssertEqual(cmd.output, "proteins.fa")
    }

    func testParsingWithAllFlags() throws {
        let cmd = try TranslateCommand.parse([
            "input.fasta", "--trim-to-stop", "--longest-orf"
        ])
        XCTAssertTrue(cmd.trimToStop)
        XCTAssertTrue(cmd.longestORF)
    }
}

// MARK: - SearchCommand

final class SearchCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(SearchCommand.configuration.commandName, "search")
    }

    func testHelpTextIsNonEmpty() {
        let help = SearchCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testParsingMinimalArguments() throws {
        let cmd = try SearchCommand.parse(["genome.fasta", "ATGCGATCG"])
        XCTAssertEqual(cmd.input, "genome.fasta")
        XCTAssertEqual(cmd.pattern, "ATGCGATCG")
        XCTAssertFalse(cmd.useRegex)
        XCTAssertFalse(cmd.useIUPAC)
        XCTAssertEqual(cmd.maxMismatches, 0)
        XCTAssertFalse(cmd.forwardOnly)
        XCTAssertFalse(cmd.caseSensitive)
    }

    func testParsingWithRegexFlag() throws {
        let cmd = try SearchCommand.parse(["genome.fasta", "ATG.+", "--regex"])
        XCTAssertTrue(cmd.useRegex)
    }

    func testParsingWithIUPACFlag() throws {
        let cmd = try SearchCommand.parse(["genome.fasta", "TATAWAWN", "--iupac"])
        XCTAssertTrue(cmd.useIUPAC)
    }

    func testParsingWithMismatches() throws {
        let cmd = try SearchCommand.parse(["genome.fasta", "GAATTC", "--max-mismatches", "2"])
        XCTAssertEqual(cmd.maxMismatches, 2)
    }
}

// MARK: - ExtractCommand

final class ExtractCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(ExtractCommand.configuration.commandName, "extract")
    }

    func testHelpTextIsNonEmpty() {
        let help = ExtractCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testParsingMinimalArguments() throws {
        let cmd = try ExtractSequenceSubcommand.parse(["genome.fasta", "chr1:1000-2000"])
        XCTAssertEqual(cmd.input, "genome.fasta")
        XCTAssertEqual(cmd.region, "chr1:1000-2000")
        XCTAssertFalse(cmd.reverseComplement)
        XCTAssertEqual(cmd.flank, 0)
        XCTAssertEqual(cmd.lineWidth, 70)
    }

    func testParsingWithReverseComplement() throws {
        let cmd = try ExtractSequenceSubcommand.parse(["g.fa", "chr1:1-100", "--reverse-complement"])
        XCTAssertTrue(cmd.reverseComplement)
    }

    func testParsingWithFlank() throws {
        let cmd = try ExtractSequenceSubcommand.parse(["g.fa", "chr1:1-100", "--flank", "50"])
        XCTAssertEqual(cmd.flank, 50)
    }

    func testParsingWithFlank5And3() throws {
        let cmd = try ExtractSequenceSubcommand.parse(["g.fa", "chr1:1-100", "--flank-5", "10", "--flank-3", "20"])
        XCTAssertEqual(cmd.flank5, 10)
        XCTAssertEqual(cmd.flank3, 20)
    }
}

// MARK: - FastqCommand

final class FastqCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(FastqCommand.configuration.commandName, "fastq")
    }

    func testHelpTextIsNonEmpty() {
        let help = FastqCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommandCount() {
        let subs = FastqCommand.configuration.subcommands
        XCTAssertGreaterThanOrEqual(subs.count, 14,
            "Expected at least 14 FASTQ subcommands; found \(subs.count)")
    }
}

// MARK: - WorkflowCommand

final class WorkflowCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(WorkflowCommand.configuration.commandName, "workflow")
    }

    func testHelpTextIsNonEmpty() {
        let help = WorkflowCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommands() {
        let subs = WorkflowCommand.configuration.subcommands
        XCTAssertEqual(subs.count, 3)
    }

    func testDefaultSubcommand() {
        XCTAssertNotNil(WorkflowCommand.configuration.defaultSubcommand)
    }

    func testRunSubcommandAllowsOnlyViralReconNFCoreWorkflow() throws {
        let command = try RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", "/tmp/samplesheet.csv",
            "--results-dir", "/tmp/results",
            "--bundle-path", "/tmp/viralrecon.lungfishrun",
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--prepare-only",
        ])

        XCTAssertEqual(command.workflow, "nf-core/viralrecon")
        XCTAssertEqual(command.input, ["/tmp/samplesheet.csv"])
        XCTAssertEqual(command.version, "3.0.0")
        XCTAssertTrue(command.prepareOnly)
    }

    func testUnsupportedNFCoreWorkflowIsRejected() throws {
        let command = try RunSubcommand.parse([
            "nf-core/fetchngs",
            "--input", "/tmp/accessions.csv",
            "--prepare-only",
        ])

        XCTAssertThrowsError(try command.validateViralReconWorkflowName())
    }

    func testBareViralReconPrepareOnlyWritesRunBundle() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let samplesheet = tempDirectory.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,/tmp/S1_R1.fastq.gz,/tmp/S1_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        let bundleURL = tempDirectory.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let command = try RunSubcommand.parse([
            "viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", tempDirectory.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", bundleURL.path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--param", "protocol=amplicon",
            "--prepare-only",
            "--quiet",
        ])

        try await command.run()

        let manifest = try NFCoreRunBundleStore.read(from: bundleURL)
        XCTAssertEqual(manifest.workflowName, "viralrecon")
        XCTAssertEqual(manifest.workflowDisplayName, "nf-core/viralrecon")
        XCTAssertEqual(manifest.version, "3.0.0")
        XCTAssertEqual(manifest.workflowPinnedVersion, "3.0.0")
        XCTAssertEqual(manifest.params["input"], samplesheet.path)
        XCTAssertEqual(manifest.params["platform"], "illumina")
        XCTAssertEqual(manifest.params["protocol"], "amplicon")
        XCTAssertTrue(manifest.commandPreview.contains("nextflow run nf-core/viralrecon -r 3.0.0 -profile docker"))
        XCTAssertTrue(manifest.commandPreview.contains("--input \(samplesheet.path)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("logs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("reports").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("outputs").path))
    }

    func testViralReconPrepareOnlyQuotesMetacharactersInPreparedCommand() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral&recon'\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let samplesheet = tempDirectory.appendingPathComponent("samples&ids.csv")
        try "sample,fastq_1,fastq_2\nS1,/tmp/S1_R1.fastq.gz,/tmp/S1_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        let bundleURL = tempDirectory.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let command = try RunSubcommand.parse([
            "viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", tempDirectory.appendingPathComponent("results;rm", isDirectory: true).path,
            "--bundle-path", bundleURL.path,
            "--version", "3.0.0",
            "--prepare-only",
            "--quiet",
        ])

        try await command.run()

        let manifest = try NFCoreRunBundleStore.read(from: bundleURL)
        let escapedSamplesheet = samplesheet.path.replacingOccurrences(of: "'", with: "'\\''")
        XCTAssertTrue(manifest.commandPreview.contains("--input '\(escapedSamplesheet)'"))
        XCTAssertFalse(manifest.commandPreview.contains("--input \(samplesheet.path)"))
    }

    func testViralReconRuntimeOptionsAreIncludedInPreparedNextflowCommand() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-options-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let samplesheet = tempDirectory.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,/tmp/S1_R1.fastq.gz,/tmp/S1_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        let workDirectory = tempDirectory.appendingPathComponent("nextflow-work", isDirectory: true)
        let bundleURL = tempDirectory.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let command = try RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", tempDirectory.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", bundleURL.path,
            "--resume",
            "--workdir", workDirectory.path,
            "--cpus", "8",
            "--memory", "16.GB",
            "--prepare-only",
            "--quiet",
        ])

        try await command.run()

        let manifest = try NFCoreRunBundleStore.read(from: bundleURL)
        XCTAssertEqual(manifest.params["max_cpus"], "8")
        XCTAssertEqual(manifest.params["max_memory"], "16.GB")
        XCTAssertTrue(manifest.commandPreview.contains("-resume"))
        XCTAssertTrue(manifest.commandPreview.contains("-work-dir \(workDirectory.path)"))
        XCTAssertTrue(manifest.commandPreview.contains("--max_cpus 8"))
        XCTAssertTrue(manifest.commandPreview.contains("--max_memory 16.GB"))
    }

    func testViralReconTimeoutIsRejectedUntilRunnerSupportsIt() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let samplesheet = tempDirectory.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,/tmp/S1_R1.fastq.gz,/tmp/S1_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)

        let command = try RunSubcommand.parse([
            "viralrecon",
            "--input", samplesheet.path,
            "--timeout", "30",
            "--prepare-only",
            "--quiet",
        ])

        do {
            try await command.run()
            XCTFail("Expected --timeout to be rejected for viralrecon runs")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .workflowError)
            XCTAssertTrue(error.localizedDescription.contains("--timeout"))
        }
    }

    func testRunHelpAdvertisesOnlyViralReconNFCoreWorkflow() {
        let help = RunSubcommand.helpMessage()

        XCTAssertTrue(help.contains("nf-core/viralrecon"))
        XCTAssertFalse(help.contains("nf-core/rnaseq"))
    }

    func testListNFCoreShowsOnlyViralRecon() async throws {
        let command = try ListSubcommand.parse(["--nf-core"])

        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("nf-core/viralrecon"))
        XCTAssertFalse(output.contains("nf-core/fetchngs"))
        XCTAssertFalse(output.contains("nf-core/seqinspector"))
    }

    func testNFCoreRequestUsesPinnedVersionWhenVersionOmitted() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "",
            executor: .docker,
            inputURLs: [URL(fileURLWithPath: "/tmp/samplesheet.csv")],
            outputDirectory: URL(fileURLWithPath: "/tmp/results")
        )

        XCTAssertEqual(request.version, workflow.pinnedVersion)
        XCTAssertEqual(request.manifest().workflowPinnedVersion, workflow.pinnedVersion)
        XCTAssertTrue(request.nextflowArguments.contains("-r"))
        XCTAssertTrue(request.nextflowArguments.contains(workflow.pinnedVersion))
        XCTAssertTrue(request.cliArguments(bundlePath: URL(fileURLWithPath: "/tmp/run.lungfishrun")).contains(workflow.pinnedVersion))
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try await operation()
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
    }
}

// MARK: - FetchCommand

final class FetchCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(FetchCommand.configuration.commandName, "fetch")
    }

    func testHelpTextIsNonEmpty() {
        let help = FetchCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommands() {
        let subs = FetchCommand.configuration.subcommands
        XCTAssertGreaterThanOrEqual(subs.count, 5)
    }

    func testDefaultSubcommand() {
        XCTAssertNotNil(FetchCommand.configuration.defaultSubcommand)
    }
}

// MARK: - BundleCommand

final class BundleCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(BundleCommand.configuration.commandName, "bundle")
    }

    func testHelpTextIsNonEmpty() {
        let help = BundleCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommands() {
        let subs = BundleCommand.configuration.subcommands
        XCTAssertEqual(subs.count, 5)
    }
}

// MARK: - BlastCommand

final class BlastCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(BlastCommand.configuration.commandName, "blast")
    }

    func testHelpTextIsNonEmpty() {
        let help = BlastCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommands() {
        let subs = BlastCommand.configuration.subcommands
        XCTAssertEqual(subs.count, 1)
    }

    func testDefaultSubcommand() {
        XCTAssertNotNil(BlastCommand.configuration.defaultSubcommand)
    }
}

// MARK: - EsVirituCommand

final class EsVirituCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(EsVirituCommand.configuration.commandName, "esviritu")
    }

    func testAbstractIsNonEmpty() {
        XCTAssertFalse(EsVirituCommand.configuration.abstract.isEmpty)
    }
}

// MARK: - TaxTriageCommand

final class TaxTriageCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(TaxTriageCommand.configuration.commandName, "taxtriage")
    }

    func testAbstractIsNonEmpty() {
        XCTAssertFalse(TaxTriageCommand.configuration.abstract.isEmpty)
    }
}

// MARK: - AssembleCommand

final class AssembleCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(AssembleCommand.configuration.commandName, "assemble")
    }

    func testAbstractIsNonEmpty() {
        XCTAssertFalse(AssembleCommand.configuration.abstract.isEmpty)
    }

    func testHelpMessageUsesManagedAssemblySurface() {
        let help = AssembleCommand.helpMessage()
        XCTAssertTrue(help.contains("--assembler"))
        XCTAssertTrue(help.contains("--read-type"))
        XCTAssertTrue(help.contains("--profile"))
        XCTAssertTrue(help.contains("--advanced-options"))
        XCTAssertFalse(help.localizedCaseInsensitiveContains("Apple Containers"))
    }

    func testParsingManagedAssemblyArguments() throws {
        let command = try AssembleCommand.parse([
            "reads.fastq.gz",
            "--assembler", "flye",
            "--read-type", "ont-reads",
            "--project-name", "demo",
            "--threads", "12",
            "--memory-gb", "32",
            "--profile", "nano-hq",
            "--advanced-options", #"--meta --rg-id "sample 1""#,
            "--extra-arg", "--meta",
        ])

        XCTAssertEqual(command.assembler, "flye")
        XCTAssertEqual(command.readType, "ont-reads")
        XCTAssertEqual(command.projectName, "demo")
        XCTAssertEqual(command.globalOptions.threads, 12)
        XCTAssertEqual(command.memoryGB, 32)
        XCTAssertEqual(command.profile, "nano-hq")
        XCTAssertEqual(command.advancedOptions, #"--meta --rg-id "sample 1""#)
        XCTAssertEqual(command.extraArg, ["--meta"])
    }

    func testBundleInputResolvesToContainedFASTQForExecution() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-bundle-input-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq.gz")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("fake-fastq".utf8).write(to: fastqURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolved = try AssembleCommand.resolveExecutionInputURLs(for: [bundleURL])

        XCTAssertEqual(
            resolved.map(\.standardizedFileURL),
            [fastqURL.standardizedFileURL]
        )
    }

    func testDerivedFASTAInputResolvesToContainedFASTAForExecution() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-fasta-bundle-input-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let fastaURL = bundleURL.appendingPathComponent("reads.fasta")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">read1\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let manifest = FASTQDerivedBundleManifest(
            name: "sample",
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: "reads.fasta",
            payload: .fullFASTA(fastaFilename: "reads.fasta"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "fixture"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fasta
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolved = try AssembleCommand.resolveExecutionInputURLs(for: [bundleURL])

        XCTAssertEqual(
            resolved.map(\.standardizedFileURL),
            [fastaURL.standardizedFileURL]
        )
    }

    func testReferenceBundleInputResolvesToContainedFASTAForExecution() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-reference-bundle-input-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = try makeReferenceBundle(
            named: "assemble-reference",
            under: tempDir,
            fastaFilename: "genome/sequence.fa.gz"
        )
        let fastaURL = bundleURL.appendingPathComponent("genome/sequence.fa.gz")

        let resolved = try AssembleCommand.resolveExecutionInputURLs(for: [bundleURL])

        XCTAssertEqual(
            resolved.map(\.standardizedFileURL),
            [fastaURL.standardizedFileURL]
        )
    }

    func testInvalidReadTypeIsRejectedBeforeFallbackInference() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-invalid-read-type-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastqURL = tempDir.appendingPathComponent("reads.fastq")
        try? "@read1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)

        let command = try? AssembleCommand.parse([
            fastqURL.path,
            "--assembler", "spades",
            "--read-type", "not-a-read-type",
        ])
        XCTAssertNotNil(command)

        do {
            try await command?.run()
            XCTFail("Expected invalid read type to fail")
        } catch is ExitCode {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSourceIncludesManagedAssemblyLaunchAliases() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishCLI/Commands/AssembleCommand.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#"customLong("assembler")"#))
        XCTAssertTrue(source.contains(#"customLong("read-type")"#))
        XCTAssertTrue(source.contains(#"customLong("project-name")"#))
        XCTAssertTrue(source.contains(#"customLong("output")"#))
        XCTAssertTrue(source.contains(#"customLong("profile")"#))
        XCTAssertTrue(source.contains("ManagedAssemblyPipeline"))
    }
}

// MARK: - OrientCommand
// NOTE: Has duplicate --threads option (own + GlobalOptions).

final class OrientCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(OrientCommand.configuration.commandName, "orient")
    }

    func testAbstractIsNonEmpty() {
        XCTAssertFalse(OrientCommand.configuration.abstract.isEmpty)
    }
}

private func makeReferenceBundle(
    named bundleName: String,
    under root: URL,
    fastaFilename: String
) throws -> URL {
    let bundleURL = root.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let fastaURL = bundleURL.appendingPathComponent(fastaFilename)
    try FileManager.default.createDirectory(
        at: fastaURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try ">contig1\nAACCGGTT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
    try "contig1\t8\t9\t8\t9\n".write(
        to: bundleURL.appendingPathComponent("\(fastaFilename).fai"),
        atomically: true,
        encoding: .utf8
    )

    let manifest = BundleManifest(
        name: bundleName,
        identifier: "org.lungfish.\(bundleName)",
        source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
        genome: GenomeInfo(
            path: fastaFilename,
            indexPath: "\(fastaFilename).fai",
            totalLength: 8,
            chromosomes: []
        )
    )
    try manifest.save(to: bundleURL)
    return bundleURL
}

// MARK: - MapCommand
// NOTE: Has duplicate --threads option (own + GlobalOptions).

final class MapCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(MapCommand.configuration.commandName, "map")
    }

    func testAbstractIsNonEmpty() {
        XCTAssertFalse(MapCommand.configuration.abstract.isEmpty)
    }

    func testHelpMentionsMapperAndReadMappingPack() {
        let help = MapCommand.helpMessage()

        XCTAssertTrue(help.contains("--mapper"))
        XCTAssertTrue(help.contains("--advanced-options"))
        XCTAssertFalse(help.contains("--match-score"))
        XCTAssertTrue(help.contains("read-mapping"))
    }

    func testParsingAdvancedMappingOptions() throws {
        let command = try MapCommand.parse([
            "reads.fastq.gz",
            "--reference", "reference.fa",
            "--mapper", "bbmap",
            "--advanced-options", #"minid=0.97 local=t idtag="sample 1""#,
        ])

        XCTAssertEqual(command.advancedOptions, #"minid=0.97 local=t idtag="sample 1""#)
    }

    func testReferenceBundleInputResolvesToContainedFASTAForExecution() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-reference-bundle-input-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = try makeReferenceBundle(
            named: "map-reference",
            under: tempDir,
            fastaFilename: "genome/sequence.fa.gz"
        )
        let fastaURL = bundleURL.appendingPathComponent("genome/sequence.fa.gz")

        let resolved = try MapCommand.resolveExecutionInputURLs(for: [bundleURL])

        XCTAssertEqual(
            resolved.map(\.standardizedFileURL),
            [fastaURL.standardizedFileURL]
        )
    }

    func testDerivedFASTAInputResolvesToContainedFASTAForExecution() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-fasta-bundle-input-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let fastaURL = bundleURL.appendingPathComponent("reads.fasta")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">read1\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let manifest = FASTQDerivedBundleManifest(
            name: "sample",
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: "reads.fasta",
            payload: .fullFASTA(fastaFilename: "reads.fasta"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "fixture"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fasta
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolved = try MapCommand.resolveExecutionInputURLs(for: [bundleURL])

        XCTAssertEqual(
            resolved.map(\.standardizedFileURL),
            [fastaURL.standardizedFileURL]
        )
    }
}

// MARK: - ImportCommand

final class ImportCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(ImportCommand.configuration.commandName, "import")
    }

    func testHelpTextIsNonEmpty() {
        let help = ImportCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
        XCTAssertTrue(help.contains("sample-metadata"))
    }
}

// MARK: - VariantsCommand

final class VariantsCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(VariantsCommand.configuration.commandName, "variants")
    }

    func testHelpTextIsNonEmpty() {
        let help = VariantsCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
        XCTAssertTrue(help.contains("call"))
    }

    func testRootCLIRegistersVariantsCommand() {
        let names = LungfishCLI.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("variants"))
    }
}

// MARK: - NaoMgsCommand

final class NaoMgsCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(NaoMgsCommand.configuration.commandName, "nao-mgs")
    }

    func testHelpTextIsNonEmpty() {
        let help = NaoMgsCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }
}

// MARK: - MetadataCommand

final class MetadataCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(MetadataCommand.configuration.commandName, "metadata")
    }

    func testHelpTextIsNonEmpty() {
        let help = MetadataCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommands() {
        let subs = MetadataCommand.configuration.subcommands
        XCTAssertEqual(subs.count, 5)
    }
}

// MARK: - DebugCommand

final class DebugCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(DebugCommand.configuration.commandName, "debug")
    }

    func testHelpTextIsNonEmpty() {
        let help = DebugCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommands() {
        let subs = DebugCommand.configuration.subcommands
        XCTAssertGreaterThanOrEqual(subs.count, 4)
    }

    func testDefaultSubcommand() {
        XCTAssertNotNil(DebugCommand.configuration.defaultSubcommand)
    }
}

// MARK: - ProvisionToolsCommand

final class ProvisionToolsCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(ProvisionToolsCommand.configuration.commandName, "provision-tools")
    }

    func testAbstractMentionsMicromambaBootstrap() {
        XCTAssertTrue(ProvisionToolsCommand.configuration.abstract.contains("micromamba"))
        XCTAssertTrue(ProvisionToolsCommand.configuration.abstract.contains("bootstrap"))
    }

    func testHelpTextIsNonEmpty() {
        let help = ProvisionToolsCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
        XCTAssertTrue(help.contains("micromamba"))
        XCTAssertFalse(help.contains("samtools (v1.21)"))
        XCTAssertFalse(help.contains("or universal"))
    }

    func testUniversalArchitectureIsRejected() {
        XCTAssertThrowsError(try ProvisionToolsCommand.parse(["--arch", "universal"]))
    }

    func testProvisioningSummaryJSONIsStable() throws {
        let summary = ProvisioningSummary(
            successful: ["zeta", "alpha"],
            failed: [
                "zeta": "failed zeta",
                "alpha": "failed alpha"
            ],
            skipped: ["omega", "beta"],
            duration: 1.5
        )

        let payload = try provisioningJSONObject(from: JSONEncoder().encode(summary))

        XCTAssertEqual(payload["successful"] as? [String], ["alpha", "zeta"])
        XCTAssertEqual(payload["failed"] as? [String: String], [
            "alpha": "failed alpha",
            "zeta": "failed zeta"
        ])
        XCTAssertEqual(payload["skipped"] as? [String], ["beta", "omega"])
        XCTAssertEqual(payload["duration"] as? Double, 1.5)
    }

    func testInstallationStatusSummaryJSONIsStable() throws {
        let status = InstallationStatusSummary(status: [
            "zeta": false,
            "alpha": true
        ])

        let payload = try provisioningJSONObject(from: JSONEncoder().encode(status))

        XCTAssertEqual(payload as? [String: Bool], [
            "alpha": true,
            "zeta": false
        ])
    }

    private func provisioningJSONObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - CondaCommand

final class CondaCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(CondaCommand.configuration.commandName, "conda")
    }

    func testHelpTextIsNonEmpty() {
        let help = CondaCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommandCount() {
        let subs = CondaCommand.configuration.subcommands
        XCTAssertGreaterThanOrEqual(subs.count, 10)
    }

}

// MARK: - DbCommand

final class DbCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(DbCommand.configuration.commandName, "db")
    }

    func testHelpTextIsNonEmpty() {
        let help = DbCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testSubcommands() {
        let subs = DbCommand.configuration.subcommands
        XCTAssertEqual(subs.count, 4)
    }
}

// MARK: - UniversalSearchCommand

final class UniversalSearchCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(UniversalSearchCommand.configuration.commandName, "universal-search")
    }

    func testHelpTextIsNonEmpty() {
        let help = UniversalSearchCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
    }

    func testParsingMinimalArguments() throws {
        let cmd = try UniversalSearchCommand.parse(["./Project.lungfish"])
        XCTAssertEqual(cmd.projectPath, "./Project.lungfish")
        XCTAssertEqual(cmd.query, "")
        XCTAssertEqual(cmd.limit, 200)
        XCTAssertFalse(cmd.reindex)
        XCTAssertFalse(cmd.stats)
    }

    func testParsingWithQueryAndFlags() throws {
        let cmd = try UniversalSearchCommand.parse([
            "./P.lungfish", "--query", "virus:HKU1", "--reindex", "--stats", "--limit", "50"
        ])
        XCTAssertEqual(cmd.query, "virus:HKU1")
        XCTAssertEqual(cmd.limit, 50)
        XCTAssertTrue(cmd.reindex)
        XCTAssertTrue(cmd.stats)
    }
}

// MARK: - Codable Result Types

final class ResultTypeCodableRegressionTests: XCTestCase {

    func testConvertResultCodable() throws {
        let result = ConvertResult(
            inputFile: "in.fa", outputFile: "out.gb",
            inputFormat: "fasta", outputFormat: "genbank",
            sequenceCount: 5, annotationCount: 10
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ConvertResult.self, from: data)
        XCTAssertEqual(decoded.sequenceCount, 5)
        XCTAssertEqual(decoded.annotationCount, 10)
    }

    func testSearchMatchCodable() throws {
        let match = SearchMatch(chromosome: "chr1", start: 100, end: 200, strand: "+", mismatches: 0)
        let data = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(SearchMatch.self, from: data)
        XCTAssertEqual(decoded.chromosome, "chr1")
        XCTAssertEqual(decoded.start, 100)
    }

    func testExtractResultCodable() throws {
        let result = ExtractResult(
            inputFile: "g.fa", outputFile: nil, region: "chr1:1-100",
            chromosome: "chr1", start: 0, end: 100, length: 100,
            reverseComplement: false
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ExtractResult.self, from: data)
        XCTAssertEqual(decoded.length, 100)
        XCTAssertNil(decoded.outputFile)
    }

    func testTranslateResultCodable() throws {
        let result = TranslateResult(
            inputFile: "in.fa", outputFile: nil, sequenceCount: 2,
            translationCount: 12, codonTable: "Standard", codonTableId: 1,
            frames: ["plus1", "plus2", "plus3"]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranslateResult.self, from: data)
        XCTAssertEqual(decoded.translationCount, 12)
        XCTAssertEqual(decoded.frames.count, 3)
    }

    func testValidationResultCodable() throws {
        let fileResult = ValidationFileResult(
            file: "test.fa", valid: true, format: "FASTA", errors: []
        )
        let result = ValidationResult(files: [fileResult], allValid: true)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ValidationResult.self, from: data)
        XCTAssertTrue(decoded.allValid)
        XCTAssertEqual(decoded.files.count, 1)
    }
}
