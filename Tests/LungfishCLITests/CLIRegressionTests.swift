// CLIRegressionTests.swift - Regression tests for LungfishCLI commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Tests command parsing, subcommand structure, option validation, and help
// text generation for all top-level CLI commands. Uses ArgumentParser's
// parse() method -- NEVER creates GlobalOptions() directly (see MEMORY.md).
//
// NOTE: AssembleCommand, ClassifyCommand, MapCommand, and OrientCommand each
// define a local --threads option AND include GlobalOptions (which also has
// --threads). This is a pre-existing duplicate-option bug. Calling
// helpMessage() or parse() on those commands triggers a fatalError from
// ArgumentParser validation. Tests for those commands avoid helpMessage()
// and parse(), testing only static configuration properties.

import ArgumentParser
import XCTest
@testable import LungfishCLI

// MARK: - Top-Level CLI Structure

final class CLITopLevelRegressionTests: XCTestCase {

    func testLungfishCLICommandName() {
        XCTAssertEqual(LungfishCLI.configuration.commandName, "lungfish")
    }

    func testLungfishCLIVersion() {
        XCTAssertEqual(LungfishCLI.configuration.version, "1.0.0")
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
        XCTAssertEqual(subs.count, 4)
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
// NOTE: Has duplicate --threads option (own + GlobalOptions). helpMessage()/parse()
// triggers fatalError in ArgumentParser validation. Test configuration only.

final class AssembleCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(AssembleCommand.configuration.commandName, "assemble")
    }

    func testAbstractIsNonEmpty() {
        XCTAssertFalse(AssembleCommand.configuration.abstract.isEmpty)
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

// MARK: - MapCommand
// NOTE: Has duplicate --threads option (own + GlobalOptions).

final class MapCommandRegressionTests: XCTestCase {

    func testCommandName() {
        XCTAssertEqual(MapCommand.configuration.commandName, "map")
    }

    func testAbstractIsNonEmpty() {
        XCTAssertFalse(MapCommand.configuration.abstract.isEmpty)
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

    func testHelpTextIsNonEmpty() {
        let help = ProvisionToolsCommand.helpMessage()
        XCTAssertFalse(help.isEmpty)
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
