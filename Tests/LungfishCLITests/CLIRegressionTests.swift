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
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

// MARK: - Top-Level CLI Structure

final class CLITopLevelRegressionTests: XCTestCase {

    func testLungfishCLICommandName() {
        XCTAssertEqual(LungfishCLI.configuration.commandName, "lungfish")
    }

    func testLungfishCLIVersion() {
        XCTAssertEqual(LungfishCLI.configuration.version, "0.4.0-alpha.16")
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

    func testRunHeadlessIsRegisteredAsDiscoverableTopLevelSubcommand() throws {
        let names = LungfishCLI.configuration.subcommands.map { $0.configuration.commandName }

        XCTAssertTrue(names.contains("run-headless"))
        XCTAssertTrue(LungfishCLI.helpMessage().contains("run-headless"))
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

final class ClassifyCommandMaterializationRegressionTests: XCTestCase {

    func testClassifyMaterializesVirtualDerivedBundleInsteadOfRootPayload() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-materialize-derived-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@selected\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)

        let materializer = RecordingCLISequenceMaterializer(materializedURL: materializedURL)
        let resolved = try await ClassifyCommand.resolveExecutionInputs(
            for: [fixture.derivedBundleURL],
            tempDirectory: materializedURL.deletingLastPathComponent(),
            materializer: materializer
        )

        XCTAssertEqual(resolved.inputURLs.map(\.standardizedFileURL), [materializedURL.standardizedFileURL])
        XCTAssertEqual(materializer.bundleURLs, [fixture.derivedBundleURL.standardizedFileURL])
        XCTAssertFalse(resolved.inputURLs.map(\.standardizedFileURL).contains(fixture.rootFASTQURL.standardizedFileURL))
    }

    func testClassifyMaterializationPreflightsAllInputsBeforeWritingOutputs() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-materialize-preflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        let materializer = RecordingCLISequenceMaterializer(materializedURL: materializedURL)

        do {
            _ = try await ClassifyCommand.resolveExecutionInputs(
                for: [fixture.derivedBundleURL, tempDir.appendingPathComponent("missing.txt")],
                tempDirectory: materializedURL.deletingLastPathComponent(),
                materializer: materializer
            )
            XCTFail("Expected unreadable second input to fail before materialization starts")
        } catch {
            XCTAssertTrue(materializer.bundleURLs.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: materializedURL.path))
        }
    }

    func testMaterializationCleanupRemovesOutputsWhenLaterMaterializationFails() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-materialize-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let first = try makeVirtualDerivedFASTQFixture(under: tempDir.appendingPathComponent("first", isDirectory: true))
        let second = try makeVirtualDerivedFASTQFixture(under: tempDir.appendingPathComponent("second", isDirectory: true))
        let materializationDirectory = tempDir.appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
        let materializer = FailingSecondCLISequenceMaterializer()

        do {
            _ = try await ClassifyCommand.resolveExecutionInputs(
                for: [first.derivedBundleURL, second.derivedBundleURL],
                tempDirectory: materializationDirectory,
                materializer: materializer
            )
            XCTFail("Expected second materialization to fail")
        } catch {
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: materializationDirectory.path)) ?? []
            XCTAssertTrue(remaining.isEmpty, "Failed materialization should not leave unprovenanced FASTQ outputs: \(remaining)")
        }
    }

    func testMaterializationCleanupPreservesPreexistingNonDirectoryPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-materialize-file-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let blockingURL = tempDir.appendingPathComponent(".lungfish-classify-inputs")
        try "preexisting".write(to: blockingURL, atomically: true, encoding: .utf8)

        do {
            _ = try await ClassifyCommand.resolveExecutionInputs(
                for: [fixture.derivedBundleURL],
                tempDirectory: blockingURL,
                materializer: RecordingCLISequenceMaterializer(
                    materializedURL: blockingURL.appendingPathComponent("materialized.fastq")
                )
            )
            XCTFail("Expected directory creation to fail when materialization path is a file")
        } catch {
            XCTAssertEqual(try String(contentsOf: blockingURL, encoding: .utf8), "preexisting")
        }
    }

    func testDurableReplayArgvRewritesRelativeVirtualInputArgument() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-relative-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        let replayArgv = CLISequenceInputMaterialization.durableReplayArgv(
            argv: ["lungfish", "classify", "derived.lungfishfastq", "--db", "FixtureDB"],
            originalInputArguments: ["derived.lungfishfastq"],
            originalInputURLs: [fixture.derivedBundleURL],
            executionInputURLs: [materializedURL]
        )

        XCTAssertEqual(replayArgv, ["lungfish", "classify", materializedURL.path, "--db", "FixtureDB"])
    }

    func testMaterializationOnlyProvenanceUsesReplayableTopLevelCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-materialize-provenance-command-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@selected\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)

        let sidecarURL = try XCTUnwrap(CLISequenceInputMaterialization.writeMaterializationProvenance(
            workflowName: "lungfish.classify.input-materialization",
            workflowVersion: "test-version",
            parentArgv: ["lungfish", "classify", "derived.lungfishfastq", "--db", "FixtureDB"],
            parentDurableReplayArgv: ["lungfish", "classify", materializedURL.path, "--db", "FixtureDB"],
            originalInputURLs: [fixture.derivedBundleURL],
            executionInputURLs: [materializedURL],
            outputDirectory: tempDir,
            operationName: "classification",
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            writer: ProvenanceWriter(signingProvider: nil)
        ))
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: sidecarURL)
        )
        let expected = ["lungfish", "fastq", "materialize", fixture.derivedBundleURL.path, "--output", materializedURL.path]
        XCTAssertEqual(envelope.argv, expected)
        XCTAssertEqual(envelope.durableReplayArgv, expected)
        XCTAssertEqual(envelope.steps.first?.argv, expected)
        XCTAssertEqual(envelope.options.explicit["parentArgv"], .array([
            .string("lungfish"), .string("classify"), .string("derived.lungfishfastq"), .string("--db"), .string("FixtureDB")
        ]))
    }

    func testMaterializationProvenanceWriteFailureCleansMaterializedPayload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-materialize-provenance-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        let blockedOutputDirectory = tempDir.appendingPathComponent("blocked-output")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@selected\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)
        try "not a directory".write(to: blockedOutputDirectory, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CLISequenceInputMaterialization.writeMaterializationProvenanceOrCleanup(
            workflowName: "lungfish.classify.input-materialization",
            workflowVersion: "test-version",
            parentArgv: ["lungfish", "classify", fixture.derivedBundleURL.path, "--db", "FixtureDB"],
            parentDurableReplayArgv: ["lungfish", "classify", materializedURL.path, "--db", "FixtureDB"],
            originalInputURLs: [fixture.derivedBundleURL],
            executionInputURLs: [materializedURL],
            outputDirectory: blockedOutputDirectory,
            operationName: "classification",
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            writer: ProvenanceWriter(signingProvider: nil)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: materializedURL.path))
    }

    func testClassifyProvenanceRecordsOriginalVirtualBundleAndMaterializedExecutionInput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-virtual-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@selected\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)

        let reportURL = tempDir.appendingPathComponent("classification.kreport")
        let outputURL = tempDir.appendingPathComponent("classification.kraken")
        try """
          0.00\t0\t0\tU\t0\tunclassified
        100.00\t1\t1\tR\t1\troot
        """.write(to: reportURL, atomically: true, encoding: .utf8)
        try "C\tselected\t1\t4\t1:4\n".write(to: outputURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("kraken-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)

        let config = ClassificationConfig.fromPreset(
            .balanced,
            inputFiles: [materializedURL],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databasePath: dbURL,
            threads: 2,
            outputDirectory: tempDir
        )
        let result = ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: reportURL),
            reportURL: reportURL,
            outputURL: outputURL,
            brackenURL: nil,
            runtime: 4.0,
            toolVersion: "2.1.3",
            provenanceId: nil
        )

        let sidecarURL = try ClassifyCommand.writeProvenance(
            result: result,
            originalInputURLs: [fixture.derivedBundleURL],
            executionInputURLs: [materializedURL],
            argv: ["lungfish", "classify", fixture.derivedBundleURL.path, "--db", "FixtureDB"],
            durableReplayArgv: ["lungfish", "classify", materializedURL.path, "--db", "FixtureDB"],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 104),
            materializationStartedAt: Date(timeIntervalSince1970: 100),
            materializationEndedAt: Date(timeIntervalSince1970: 101),
            writer: ProvenanceWriter(signingProvider: nil)
        )

        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(envelope.workflowName, "lungfish.classify")
        XCTAssertEqual(envelope.argv, ["lungfish", "classify", fixture.derivedBundleURL.path, "--db", "FixtureDB"])
        XCTAssertEqual(envelope.durableReplayArgv, ["lungfish", "classify", materializedURL.path, "--db", "FixtureDB"])
        XCTAssertTrue(envelope.files.contains {
            $0.path == fixture.derivedBundleURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == fixture.rootFASTQURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == materializedURL.path
                && $0.originPath == fixture.derivedBundleURL.path
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        let materializationStep = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "lungfish fastq materialize" }
        )
        XCTAssertEqual(
            materializationStep.argv,
            ["lungfish", "fastq", "materialize", fixture.derivedBundleURL.path, "--output", materializedURL.path]
        )
        XCTAssertTrue(materializationStep.inputs.contains { $0.path == fixture.derivedBundleURL.path })
        XCTAssertTrue(materializationStep.outputs.contains { $0.path == materializedURL.path })
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
        let subcommands = WorkflowCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertEqual(subcommands, ["run", "builder-run", "list", "validate", "diff"])
    }

    func testDefaultSubcommand() {
        XCTAssertNotNil(WorkflowCommand.configuration.defaultSubcommand)
    }

    func testRunHeadlessHelpPointsToWorkflowRunQuietSemantics() {
        let help = RunHeadlessSubcommand.helpMessage()

        XCTAssertTrue(help.contains("workflow run"))
        XCTAssertTrue(help.contains("--quiet"))
    }

    func testRunHeadlessParsesWorkflowPathWithoutDisplayRequirements() throws {
        let command = try RunHeadlessSubcommand.parse(["/tmp/workflow.nf"])

        XCTAssertEqual(command.workflow, "/tmp/workflow.nf")
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

    func testViralReconPrepareOnlyWritesRunManifestStatusAndProvenance() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let samplesheet = tempDirectory.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,/tmp/S1_R1.fastq.gz,/tmp/S1_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        let workDirectory = tempDirectory.appendingPathComponent("nextflow-work", isDirectory: true)
        let bundleURL = tempDirectory.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let command = try RunSubcommand.parse([
            "viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", tempDirectory.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", bundleURL.path,
            "--resume",
            "--workdir", workDirectory.path,
            "--prepare-only",
            "--quiet",
        ])

        try await command.run()

        let manifest = try NFCoreRunBundleStore.read(from: bundleURL)
        XCTAssertEqual(manifest.executionStatus, .prepared)
        XCTAssertTrue(manifest.resume)
        XCTAssertEqual(manifest.workDirectoryPath, workDirectory.path)
        XCTAssertNil(manifest.exitCode)

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: provenanceURL))
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.steps.first?.toolName, "lungfish-cli workflow run")
        XCTAssertEqual(provenance.steps.first?.exitCode, 0)
        XCTAssertTrue(provenance.steps.first?.command.contains("--prepare-only") == true)
        XCTAssertTrue(provenance.steps.first?.inputs.contains { input in
            input.path == samplesheet.path && input.sha256 != nil && input.sizeBytes != nil
        } == true)
        XCTAssertTrue(provenance.steps.first?.outputs.contains { output in
            output.path == bundleURL.path
        } == true)
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

    func testLocalNextflowPrepareOnlyWritesRunBundleManifestInputsStatusAndProvenance() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-nextflow-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let workflowURL = tempDirectory.appendingPathComponent("demo.nf")
        try "nextflow.enable.dsl=2\nworkflow { }\n"
            .write(to: workflowURL, atomically: true, encoding: .utf8)
        let readsURL = tempDirectory.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(to: readsURL, atomically: true, encoding: .utf8)
        let resultsURL = tempDirectory.appendingPathComponent("results", isDirectory: true)
        let bundleURL = tempDirectory.appendingPathComponent("demo.lungfishrun", isDirectory: true)

        let command = try RunSubcommand.parse([
            workflowURL.path,
            "--input", readsURL.path,
            "--results-dir", resultsURL.path,
            "--bundle-path", bundleURL.path,
            "--param", "sample=S1",
            "--prepare-only",
            "--quiet",
        ])

        try await command.run()

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(manifest["workflowName"] as? String, "demo")
        XCTAssertEqual(manifest["workflowPath"] as? String, workflowURL.standardizedFileURL.path)
        XCTAssertEqual(manifest["engine"] as? String, "nextflow")
        XCTAssertEqual(manifest["executionStatus"] as? String, "prepared")
        XCTAssertEqual(manifest["outputDirectoryName"] as? String, "results")
        XCTAssertEqual(manifest["stdoutLogPath"] as? String, "logs/stdout.log")
        XCTAssertEqual(manifest["stderrLogPath"] as? String, "logs/stderr.log")
        XCTAssertTrue((manifest["commandPreview"] as? String)?.contains("nextflow run \(workflowURL.path)") == true)
        XCTAssertTrue((manifest["commandPreview"] as? String)?.contains("--input \(readsURL.path)") == true)
        XCTAssertTrue((manifest["commandPreview"] as? String)?.contains("--sample S1") == true)

        let params = try XCTUnwrap(manifest["params"] as? [String: String])
        XCTAssertEqual(params["sample"], "S1")
        XCTAssertEqual(params["input"], readsURL.path)
        XCTAssertEqual(params["outdir"], resultsURL.standardizedFileURL.path)

        let inputBindings = try XCTUnwrap(manifest["inputBindings"] as? [[String: Any]])
        XCTAssertEqual(inputBindings.count, 1)
        XCTAssertEqual(inputBindings.first?["path"] as? String, readsURL.standardizedFileURL.path)
        XCTAssertNotNil(inputBindings.first?["sha256"])
        XCTAssertNotNil(inputBindings.first?["sizeBytes"])

        let statusHistory = try XCTUnwrap(manifest["statusHistory"] as? [[String: Any]])
        XCTAssertEqual(statusHistory.compactMap { $0["status"] as? String }, ["prepared"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("logs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("reports").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("outputs").path))

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: provenanceURL))
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.steps.first?.toolName, "lungfish-cli workflow run")
        XCTAssertEqual(provenance.steps.first?.exitCode, 0)
        XCTAssertTrue(provenance.steps.first?.command.contains(workflowURL.path) == true)
        XCTAssertTrue(provenance.steps.first?.command.contains("--prepare-only") == true)
        XCTAssertTrue(provenance.steps.first?.inputs.contains { input in
            input.path == workflowURL.standardizedFileURL.path && input.sha256 != nil && input.sizeBytes != nil
        } == true)
        XCTAssertTrue(provenance.steps.first?.inputs.contains { input in
            input.path == readsURL.standardizedFileURL.path && input.sha256 != nil && input.sizeBytes != nil
        } == true)
        XCTAssertTrue(provenance.steps.first?.outputs.contains { output in
            output.path == bundleURL.standardizedFileURL.path
        } == true)
    }

    func testLocalSnakemakeExecutionUsesInjectedRunnerAndUpdatesBundleStatusLogsAndProvenance() async throws {
        let originalRunner = RunSubcommand.localWorkflowProcessRunner
        let runner = StubLocalWorkflowProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "building all\ncomplete\n",
            standardError: "snakemake warning\n"
        ))
        RunSubcommand.localWorkflowProcessRunner = runner
        defer { RunSubcommand.localWorkflowProcessRunner = originalRunner }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-snakemake-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let snakefileURL = tempDirectory.appendingPathComponent("Snakefile")
        try "rule all:\n    shell: \"true\"\n".write(to: snakefileURL, atomically: true, encoding: .utf8)
        let readsURL = tempDirectory.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(to: readsURL, atomically: true, encoding: .utf8)
        let resultsURL = tempDirectory.appendingPathComponent("results", isDirectory: true)
        let bundleURL = tempDirectory.appendingPathComponent("snake.lungfishrun", isDirectory: true)

        let command = try RunSubcommand.parse([
            snakefileURL.path,
            "--input", readsURL.path,
            "--results-dir", resultsURL.path,
            "--bundle-path", bundleURL.path,
            "--param", "sample=S1",
            "--quiet",
        ])

        try await command.run()

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executableName, "snakemake")
        XCTAssertEqual(invocation.workingDirectory.path, resultsURL.standardizedFileURL.path)
        XCTAssertTrue(invocation.arguments.starts(with: [
            "--snakefile", snakefileURL.standardizedFileURL.path,
            "--directory", resultsURL.standardizedFileURL.path,
            "--cores", "all",
        ]))
        XCTAssertTrue(invocation.arguments.contains("--config"))
        XCTAssertTrue(invocation.arguments.contains("input=\(readsURL.standardizedFileURL.path)"))
        XCTAssertTrue(invocation.arguments.contains("outdir=\(resultsURL.standardizedFileURL.path)"))
        XCTAssertTrue(invocation.arguments.contains("sample=S1"))

        let manifest = try LocalWorkflowRunBundleStore.read(from: bundleURL)
        XCTAssertEqual(manifest.workflowName, "Snakefile")
        XCTAssertEqual(manifest.engine, .snakemake)
        XCTAssertEqual(manifest.executionStatus, .completed)
        XCTAssertEqual(manifest.exitCode, 0)
        XCTAssertEqual(manifest.params["sample"], "S1")
        XCTAssertEqual(manifest.params["cores"], "all")
        XCTAssertEqual(manifest.statusHistory.map(\.status), [.prepared, .running, .completed])
        XCTAssertEqual(manifest.stdoutLogPath, "logs/stdout.log")
        XCTAssertEqual(manifest.stderrLogPath, "logs/stderr.log")
        XCTAssertEqual(
            try String(contentsOf: bundleURL.appendingPathComponent("logs/stdout.log"), encoding: .utf8),
            "building all\ncomplete\n"
        )
        XCTAssertEqual(
            try String(contentsOf: bundleURL.appendingPathComponent("logs/stderr.log"), encoding: .utf8),
            "snakemake warning\n"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(
            WorkflowRun.self,
            from: Data(contentsOf: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.steps.first?.exitCode, 0)
        XCTAssertEqual(provenance.steps.first?.stderr, "snakemake warning\n")
        XCTAssertEqual(provenance.parameters["cores"], .string("all"))
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

private final class StubLocalWorkflowProcessRunner: LocalWorkflowProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executableName: String
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: LocalWorkflowProcessResult

    init(result: LocalWorkflowProcessResult) {
        self.result = result
    }

    func runWorkflow(
        executableName: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> LocalWorkflowProcessResult {
        invocations.append(Invocation(
            executableName: executableName,
            arguments: arguments,
            workingDirectory: workingDirectory
        ))
        return result
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
        XCTAssertEqual(subs.count, 6)
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
        XCTAssertTrue(help.contains("--extra-args"))
        XCTAssertFalse(help.contains("--advanced-options"))
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
            "--extra-args", #"--meta --rg-id "sample 1""#,
            "--extra-arg", "--meta",
        ])

        XCTAssertEqual(command.assembler, "flye")
        XCTAssertEqual(command.readType, "ont-reads")
        XCTAssertEqual(command.projectName, "demo")
        XCTAssertEqual(command.globalOptions.threads, 12)
        XCTAssertEqual(command.memoryGB, 32)
        XCTAssertEqual(command.profile, "nano-hq")
        XCTAssertEqual(command.extraArgs, #"--meta --rg-id "sample 1""#)
        XCTAssertEqual(command.extraArg, ["--meta"])
    }

    func testDeprecatedAdvancedOptionsAliasStillParsesForAssembly() throws {
        let command = try AssembleCommand.parse([
            "reads.fastq.gz",
            "--assembler", "flye",
            "--read-type", "ont-reads",
            "--advanced-options", #"--meta --tag "sample 1""#,
        ])

        XCTAssertEqual(command.advancedOptions, #"--meta --tag "sample 1""#)
    }

    func testDeprecatedAdvancedOptionsAliasWarnsForAssembly() async throws {
        let command = try AssembleCommand.parse([
            "/tmp/definitely-missing-reads.fastq.gz",
            "--advanced-options", "--meta",
        ])

        let stderr = await captureStandardError {
            do {
                try await command.run()
            } catch {
                // The test only needs the parse-time compatibility path; the
                // missing input file stops execution before any tool runs.
            }
        }

        XCTAssertTrue(stderr.contains("warning: --advanced-options is deprecated, use --extra-args"))
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

    func testVirtualDerivedBundleIsMaterializedForAssemblyExecution() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-virtual-bundle-input-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try "@root\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        try "root\n".write(
            to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "@root\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)

        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "root"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let materializer = RecordingAssemblyMaterializer(materializedURL: materializedURL)
        let resolved = try await AssembleCommand.resolveExecutionInputURLs(
            for: [derivedBundleURL],
            tempDirectory: tempDir,
            materializer: materializer
        )

        XCTAssertEqual(resolved.map(\.standardizedFileURL), [materializedURL.standardizedFileURL])
        XCTAssertEqual(materializer.bundleURLs, [derivedBundleURL.standardizedFileURL])
        XCTAssertFalse(resolved.map(\.standardizedFileURL).contains(rootFASTQURL.standardizedFileURL))
    }

    func testLongReadAssemblerTopologyValidationDoesNotMaterializeVirtualDerivedInputs() async throws {
        let cases = [
            (assembler: "flye", readType: "ont-reads"),
            (assembler: "hifiasm", readType: "pacbio-hifi"),
        ]

        for testCase in cases {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("assemble-\(testCase.assembler)-topology-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
            let rootFASTAURL = rootBundleURL.appendingPathComponent("root.fasta")
            let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
            let secondInputURL = tempDir.appendingPathComponent("second.fasta")
            try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
            try ">read1\nACGT\n".write(to: rootFASTAURL, atomically: true, encoding: .utf8)
            try ">read2\nTGCA\n".write(to: secondInputURL, atomically: true, encoding: .utf8)
            try "read1\n".write(
                to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
                atomically: true,
                encoding: .utf8
            )
            let manifest = FASTQDerivedBundleManifest(
                name: "derived",
                parentBundleRelativePath: "../root.lungfishfastq",
                rootBundleRelativePath: "../root.lungfishfastq",
                rootFASTQFilename: "root.fasta",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [],
                operation: FASTQDerivativeOperation(kind: .searchText, query: "read1"),
                cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
                pairingMode: nil,
                sequenceFormat: .fasta
            )
            try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

            let outputDir = tempDir.appendingPathComponent("assembly-out", isDirectory: true)
            let command = try AssembleCommand.parse([
                derivedBundleURL.path,
                secondInputURL.path,
                "--assembler", testCase.assembler,
                "--read-type", testCase.readType,
                "--output", outputDir.path,
            ])

            do {
                try await command.run()
                XCTFail("Expected \(testCase.assembler) topology validation to fail before materialization")
            } catch {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true).path
                    ),
                    "\(testCase.assembler) should reject invalid topology before materializing derived inputs"
                )
            }
        }
    }

    func testDemuxGroupInputIsRejectedBeforeMaterialization() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-demux-group-no-materialize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let groupBundleURL = tempDir.appendingPathComponent("group.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: groupBundleURL, withIntermediateDirectories: true)
        try """
        @ont-read runid=0123456789abcdef0123456789abcdef01234567 flow_cell_id=FLO-MIN106 start_time=2026-05-15T00:00:00Z
        ACGT
        +
        IIII

        """.write(to: rootFASTQURL, atomically: true, encoding: .utf8)

        let manifest = FASTQDerivedBundleManifest(
            name: "group",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .demuxGroup(barcodeCount: 2),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .demultiplex),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: groupBundleURL)

        let outputDir = tempDir.appendingPathComponent("assembly-out", isDirectory: true)
        let command = try AssembleCommand.parse([
            groupBundleURL.path,
            "--assembler", "flye",
            "--output", outputDir.path,
        ])

        let output = await captureStandardOutputForRegression {
            do {
                try await command.run()
                XCTFail("Expected demux-group topology to fail before materialization")
            } catch {
                // Expected: demux groups are containers, not single assembly inputs.
            }
        }

        XCTAssertTrue(output.contains("Demultiplexed group bundles are container-only"))
        XCTAssertFalse(output.contains("Materializing pointer dataset"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true).path
            )
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

    func testAssembleCommandWritesCanonicalOutputProvenance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let inputURL = tempDir.appendingPathComponent("reads.fastq")
        let contigsURL = tempDir.appendingPathComponent("contigs.fasta")
        let logURL = tempDir.appendingPathComponent("assembly.log")
        try "@r1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try ">contig1\nACGTACGT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
        try "assembler log\n".write(to: logURL, atomically: true, encoding: .utf8)

        let result = AssemblyResult(
            tool: .megahit,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: logURL,
            assemblerVersion: "1.2.9",
            commandLine: "megahit -r reads.fastq -o out --min-contig-len 500",
            outputDirectory: tempDir,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 6.0
        )
        try result.save(to: tempDir)

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [inputURL],
            projectName: "demo",
            outputDirectory: tempDir,
            pairedEnd: false,
            threads: 4,
            memoryGB: nil,
            minContigLength: 500,
            selectedProfileID: "meta-sensitive",
            extraArguments: ["--k-min", "21"]
        )
        let argv = [
            "lungfish", "assemble", inputURL.path,
            "--assembler", "megahit",
            "--threads", "4",
        ]

        let sidecarURL = try AssembleCommand.writeProvenance(
            request: request,
            result: result,
            originalInputURLs: [inputURL],
            executionInputURLs: [inputURL],
            argv: argv,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 106),
            stderr: "assembler stderr summary",
            writer: ProvenanceWriter(signingProvider: nil)
        )

        XCTAssertEqual(sidecarURL, tempDir.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let data = try Data(contentsOf: sidecarURL)
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)

        XCTAssertEqual(envelope.workflowName, "lungfish.assemble")
        XCTAssertEqual(envelope.workflowVersion, LungfishCLI.configuration.version)
        XCTAssertEqual(envelope.toolName, "megahit")
        XCTAssertEqual(envelope.toolVersion, "1.2.9")
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.options.resolvedDefaults["assembler"], .string("megahit"))
        XCTAssertEqual(envelope.options.resolvedDefaults["threads"], .integer(4))
        XCTAssertEqual(envelope.options.resolvedDefaults["minContigLength"], .integer(500))
        XCTAssertEqual(envelope.runtimeIdentity.condaEnvironment, "megahit")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.wallTimeSeconds, 6.0)
        XCTAssertEqual(envelope.stderr, "assembler stderr summary")
        XCTAssertEqual(envelope.output?.path, contigsURL.path)
        XCTAssertTrue(envelope.files.contains { $0.path == inputURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.outputs.contains { $0.path == contigsURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.outputs.contains { $0.path == tempDir.appendingPathComponent("assembly-result.json").path })
    }

    func testAssembleProvenanceRecordsOriginalVirtualBundleAndMaterializationStep() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-virtual-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try "@read1\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        try "read1\n".write(
            to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "read1"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@read1\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)
        let contigsURL = tempDir.appendingPathComponent("contigs.fasta")
        try ">contig1\nACGT\n".write(to: contigsURL, atomically: true, encoding: .utf8)

        let result = AssemblyResult(
            tool: .megahit,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "1.2.9",
            commandLine: "megahit -r \(materializedURL.path) -o \(tempDir.path)",
            outputDirectory: tempDir,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 3.0
        )
        try result.save(to: tempDir)

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [materializedURL],
            projectName: "demo",
            outputDirectory: tempDir,
            threads: 2
        )

        let sidecarURL = try AssembleCommand.writeProvenance(
            request: request,
            result: result,
            originalInputURLs: [derivedBundleURL],
            executionInputURLs: [materializedURL],
            argv: ["lungfish", "assemble", derivedBundleURL.path],
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 203),
            materializationStartedAt: Date(timeIntervalSince1970: 200),
            materializationEndedAt: Date(timeIntervalSince1970: 201),
            writer: ProvenanceWriter(signingProvider: nil)
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: sidecarURL)
        )

        XCTAssertTrue(envelope.files.contains {
            $0.path == derivedBundleURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == rootFASTQURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == materializedURL.path
                && $0.originPath == derivedBundleURL.path
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        let materializationStep = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "lungfish.assemble.input-materialization" }
        )
        XCTAssertTrue(materializationStep.inputs.contains { $0.path == derivedBundleURL.path })
        XCTAssertTrue(materializationStep.outputs.contains { $0.path == materializedURL.path })
        XCTAssertEqual(materializationStep.startedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(materializationStep.completedAt, Date(timeIntervalSince1970: 201))
        XCTAssertEqual(materializationStep.wallTimeSeconds, 1.0)
    }

    func testInvalidExplicitReadTypeDoesNotMaterializeVirtualDerivedInput() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-invalid-no-materialize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTAURL = rootBundleURL.appendingPathComponent("root.fasta")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try ">read1\nACGT\n".write(to: rootFASTAURL, atomically: true, encoding: .utf8)
        try "read1\n".write(
            to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fasta",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "read1"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fasta
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let outputDir = tempDir.appendingPathComponent("assembly-out", isDirectory: true)
        let command = try AssembleCommand.parse([
            derivedBundleURL.path,
            "--assembler", "flye",
            "--read-type", "not-a-read-type",
            "--output", outputDir.path,
        ])

        do {
            try await command.run()
            XCTFail("Expected invalid read type to fail before materialization")
        } catch {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true).path
                )
            )
        }
    }

    func testInferredUnsupportedReadTypeMetadataDoesNotMaterializeVirtualDerivedInput() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-inferred-no-materialize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try "@unknown-read\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .illuminaShortReads),
            for: rootFASTQURL
        )
        try "".write(
            to: derivedBundleURL.appendingPathComponent("trim-positions.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .trim(trimPositionFilename: "trim-positions.tsv"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let outputDir = tempDir.appendingPathComponent("assembly-out", isDirectory: true)
        let command = try AssembleCommand.parse([
            derivedBundleURL.path,
            "--assembler", "flye",
            "--output", outputDir.path,
        ])

        let output = await captureStandardOutputForRegression {
            do {
                try await command.run()
                XCTFail("Expected inferred unsupported read type to fail before materialization")
            } catch {
                // Expected: the CLI should reject from root metadata before
                // invoking the derived-bundle materializer.
            }
        }

        XCTAssertTrue(output.contains("Flye is not available for Illumina short reads"))
        XCTAssertFalse(output.contains("Materializing pointer dataset"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true).path
            )
        )
    }

    func testExplicitReadTypeTakesPrecedenceOverPreMaterializationMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-explicit-read-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try """
        @ont-read runid=0123456789abcdef0123456789abcdef01234567 flow_cell_id=FLO-MIN106 start_time=2026-05-15T00:00:00Z
        ACGT
        +
        IIII

        """.write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .ontReads),
            for: rootFASTQURL
        )
        try "".write(
            to: derivedBundleURL.appendingPathComponent("trim-positions.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .trim(trimPositionFilename: "trim-positions.tsv"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let resolvedReadType = try AssembleCommand.resolvePreMaterializationReadType(
            for: .hifiasm,
            explicitReadType: .pacBioHiFi,
            inputURLs: [derivedBundleURL]
        )
        let request = AssemblyRunRequest(
            tool: .hifiasm,
            readType: try XCTUnwrap(resolvedReadType),
            inputURLs: [rootFASTQURL],
            projectName: "explicit",
            outputDirectory: tempDir.appendingPathComponent("assembly-out", isDirectory: true),
            threads: 2
        )
        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(resolvedReadType, .pacBioHiFi)
        XCTAssertFalse(command.arguments.contains("--ont"))
    }

    func testReadTypeInferenceUsesMaterializedDerivedExecutionInput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-read-type-materialized-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try """
        @read1 runid=0123456789abcdef0123456789abcdef01234567 flow_cell_id=FLO-MIN106 start_time=2026-05-15T00:00:00Z
        ACGTACGT
        +
        IIIIIIII

        """.write(to: materializedURL, atomically: true, encoding: .utf8)

        let readType = try AssembleCommand.resolveReadType(
            for: .flye,
            explicitReadType: nil,
            originalInputURLs: [derivedBundleURL],
            executionInputURLs: [materializedURL]
        )

        XCTAssertEqual(readType, .ontReads)
    }

    func testReadTypeInferenceRejectsMixedKnownAndUnknownPerInputMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-read-type-mixed-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let knownBundleURL = tempDir.appendingPathComponent("known.lungfishfastq", isDirectory: true)
        let unknownBundleURL = tempDir.appendingPathComponent("unknown.lungfishfastq", isDirectory: true)
        let knownOriginalFASTQ = knownBundleURL.appendingPathComponent("known.fastq")
        let unknownOriginalFASTQ = unknownBundleURL.appendingPathComponent("unknown.fastq")
        let knownExecutionFASTQ = tempDir.appendingPathComponent("known-materialized.fastq")
        let unknownExecutionFASTQ = tempDir.appendingPathComponent("unknown-materialized.fastq")
        try FileManager.default.createDirectory(at: knownBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknownBundleURL, withIntermediateDirectories: true)
        try "@unknown-known-original\nACGT\n+\n!!!!\n".write(to: knownOriginalFASTQ, atomically: true, encoding: .utf8)
        try "@unknown-original\nTGCA\n+\n!!!!\n".write(to: unknownOriginalFASTQ, atomically: true, encoding: .utf8)
        try "@unknown-known-execution\nACGT\n+\n!!!!\n".write(to: knownExecutionFASTQ, atomically: true, encoding: .utf8)
        try "@unknown-execution\nTGCA\n+\n!!!!\n".write(to: unknownExecutionFASTQ, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .illuminaShortReads),
            for: knownOriginalFASTQ
        )

        XCTAssertThrowsError(
            try AssembleCommand.resolveReadType(
                for: .spades,
                explicitReadType: nil,
                originalInputURLs: [knownBundleURL, unknownBundleURL],
                executionInputURLs: [knownExecutionFASTQ, unknownExecutionFASTQ]
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                AssembleReadTypeResolutionError.mixedDetectedAndUnknown.localizedDescription
            )
        }
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

    func testManagedAssemblyLaunchAliasesParseToCommandOptions() throws {
        let command = try AssembleCommand.parse([
            "reads.fastq.gz",
            "--assembler", "megahit",
            "--read-type", "illumina-short-reads",
            "--name", "alias-demo",
            "--output", "/tmp/alias-demo-output",
            "--profile", "meta-sensitive",
        ])

        XCTAssertEqual(command.assembler, "megahit")
        XCTAssertEqual(command.readType, "illumina-short-reads")
        XCTAssertEqual(command.projectName, "alias-demo")
        XCTAssertEqual(command.outputDir, "/tmp/alias-demo-output")
        XCTAssertEqual(command.profile, "meta-sensitive")
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

private struct VirtualDerivedFASTQFixture {
    let rootBundleURL: URL
    let rootFASTQURL: URL
    let derivedBundleURL: URL
}

private func makeVirtualDerivedFASTQFixture(under tempDir: URL) throws -> VirtualDerivedFASTQFixture {
    let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
    let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
    let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
    try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
    try """
    @selected
    ACGT
    +
    IIII
    @excluded
    TGCA
    +
    IIII

    """.write(to: rootFASTQURL, atomically: true, encoding: .utf8)
    try "selected\n".write(
        to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
        atomically: true,
        encoding: .utf8
    )

    let manifest = FASTQDerivedBundleManifest(
        name: "derived",
        parentBundleRelativePath: "../root.lungfishfastq",
        rootBundleRelativePath: "../root.lungfishfastq",
        rootFASTQFilename: "root.fastq",
        payload: .subset(readIDListFilename: "read-ids.txt"),
        lineage: [],
        operation: FASTQDerivativeOperation(kind: .searchText, query: "selected"),
        cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
        pairingMode: nil,
        sequenceFormat: .fastq
    )
    try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

    return VirtualDerivedFASTQFixture(
        rootBundleURL: rootBundleURL,
        rootFASTQURL: rootFASTQURL,
        derivedBundleURL: derivedBundleURL
    )
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
        XCTAssertTrue(help.contains("--extra-args"))
        XCTAssertFalse(help.contains("--advanced-options"))
        XCTAssertFalse(help.contains("--match-score"))
        XCTAssertTrue(help.contains("read-mapping"))
    }

    func testParsingAdvancedMappingOptions() throws {
        let command = try MapCommand.parse([
            "reads.fastq.gz",
            "--reference", "reference.fa",
            "--mapper", "bbmap",
            "--extra-args", #"minid=0.97 local=t idtag="sample 1""#,
        ])

        XCTAssertEqual(command.extraArgs, #"minid=0.97 local=t idtag="sample 1""#)
    }

    func testDeprecatedAdvancedOptionsAliasStillParsesForMap() throws {
        let command = try MapCommand.parse([
            "reads.fastq.gz",
            "--reference", "reference.fa",
            "--advanced-options", #"minid=0.97 local=t idtag="sample 1""#,
        ])

        XCTAssertEqual(command.advancedOptions, #"minid=0.97 local=t idtag="sample 1""#)
    }

    func testDeprecatedAdvancedOptionsAliasWarnsForMap() async throws {
        let command = try MapCommand.parse([
            "/tmp/definitely-missing-reads.fastq.gz",
            "--reference", "/tmp/definitely-missing-reference.fa",
            "--advanced-options", "--eqx",
        ])

        let stderr = await captureStandardError {
            do {
                try await command.run()
            } catch {
                // Missing inputs keep the test isolated from the mapping backend.
            }
        }

        XCTAssertTrue(stderr.contains("warning: --advanced-options is deprecated, use --extra-args"))
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

    func testMapMaterializesVirtualDerivedBundleInsteadOfRootPayload() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-materialize-derived-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-map-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@selected\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)

        let materializer = RecordingCLISequenceMaterializer(materializedURL: materializedURL)
        let resolved = try await MapCommand.resolveExecutionInputs(
            for: [fixture.derivedBundleURL],
            tempDirectory: materializedURL.deletingLastPathComponent(),
            materializer: materializer
        )

        XCTAssertEqual(resolved.inputURLs.map(\.standardizedFileURL), [materializedURL.standardizedFileURL])
        XCTAssertEqual(materializer.bundleURLs, [fixture.derivedBundleURL.standardizedFileURL])
        XCTAssertFalse(resolved.inputURLs.map(\.standardizedFileURL).contains(fixture.rootFASTQURL.standardizedFileURL))
    }

    func testMapProvenanceRecordsOriginalVirtualBundleAndMaterializedExecutionInput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-virtual-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-map-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@selected\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)
        try ">chr1\nACGTACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
        try CLISequenceInputMaterialization.writeMaterializationProvenance(
            workflowName: "lungfish.map.input-materialization",
            workflowVersion: "test-version",
            parentArgv: ["lungfish", "map", fixture.derivedBundleURL.path, "--reference", referenceURL.path],
            parentDurableReplayArgv: ["lungfish", "map", materializedURL.path, "--reference", referenceURL.path],
            originalInputURLs: [fixture.derivedBundleURL],
            executionInputURLs: [materializedURL],
            outputDirectory: tempDir,
            operationName: "mapping",
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            writer: ProvenanceWriter(signingProvider: nil)
        )

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [materializedURL],
            originalInputFASTQURLs: [fixture.derivedBundleURL],
            referenceFASTAURL: referenceURL,
            outputDirectory: tempDir,
            sampleName: "sample",
            pairedEnd: false,
            threads: 2
        )
        let bamURL = tempDir.appendingPathComponent("sample.sorted.bam")
        let baiURL = tempDir.appendingPathComponent("sample.sorted.bam.bai")
        try Data("bam".utf8).write(to: bamURL)
        try Data("bai".utf8).write(to: baiURL)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 2.0,
            contigs: []
        )

        let inputRecords = try CLISequenceInputMaterialization.inputRecordsPreservingLineage(
            originalInputURLs: [fixture.derivedBundleURL],
            executionInputURLs: [materializedURL]
        ) + [
            ProvenanceRecorder.fileRecord(url: referenceURL, format: .fasta, role: .reference)
        ]
        let mapperInvocation = MappingCommandInvocation(
            label: "minimap2",
            argv: ["minimap2", "-x", "sr", referenceURL.path, materializedURL.path],
            durableReplayArgv: ["minimap2", "-x", "sr", referenceURL.path, materializedURL.path]
        )
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapperInvocation,
            normalizationInvocations: [],
            mapperVersion: "2.28",
            samtoolsVersion: "1.21",
            inputFiles: inputRecords,
            outputFiles: [
                ProvenanceRecorder.fileRecord(url: bamURL, format: .bam, role: .output),
                ProvenanceRecorder.fileRecord(url: baiURL, role: .index)
            ],
            exitStatus: 0
        )
        try provenance.save(to: tempDir)
        try provenance.saveCanonicalEnvelope(to: tempDir, writer: ProvenanceWriter(signingProvider: nil))

        let loaded = try XCTUnwrap(MappingProvenance.load(from: tempDir))
        XCTAssertTrue(loaded.inputFiles.contains {
            $0.path == fixture.derivedBundleURL.path && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertTrue(loaded.inputFiles.contains {
            $0.path == fixture.rootFASTQURL.path && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertTrue(loaded.inputFiles.contains {
            $0.path == materializedURL.path && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertEqual(loaded.mapperInvocation.durableReplayArgv, mapperInvocation.durableReplayArgv)
        XCTAssertFalse(loaded.mapperInvocation.durableReplayArgv?.contains { $0.contains("TemporaryItems") } ?? true)

        let envelope = loaded.canonicalEnvelope(sourceDirectory: tempDir)
        XCTAssertTrue(envelope.files.contains { $0.path == fixture.derivedBundleURL.path })
        XCTAssertTrue(envelope.files.contains { $0.path == materializedURL.path })
        XCTAssertEqual(envelope.durableReplayArgv, mapperInvocation.durableReplayArgv)
        let resolved = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: tempDir))
        XCTAssertEqual(resolved.sidecarURL.lastPathComponent, ProvenanceWriter.provenanceFilename)
        XCTAssertEqual(resolved.envelope.workflowName, "lungfish map")
        XCTAssertTrue(resolved.envelope.outputs.contains { $0.path == bamURL.path })
        XCTAssertFalse(resolved.envelope.outputs.contains { $0.path == materializedURL.path })
    }

    func testManagedMappingMaterializationProvenanceUsesRealFastqMaterializeCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-materialization-step-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fixture = try makeVirtualDerivedFASTQFixture(under: tempDir)
        let materializedURL = tempDir
            .appendingPathComponent(".lungfish-map-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@selected\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)
        try ">chr1\nACGTACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [materializedURL],
            originalInputFASTQURLs: [fixture.derivedBundleURL],
            inputMaterializationStartedAt: Date(timeIntervalSince1970: 10),
            inputMaterializationEndedAt: Date(timeIntervalSince1970: 13),
            referenceFASTAURL: referenceURL,
            outputDirectory: tempDir,
            sampleName: "sample",
            pairedEnd: false,
            threads: 2
        )
        let pipeline = ManagedMappingPipeline()

        let steps = try pipeline.mappingInputMaterializationStepsForTesting(request: request)

        let step = try XCTUnwrap(steps.first)
        let expectedCommand = CLISequenceInputMaterialization.materializationCommand(
            originalURL: fixture.derivedBundleURL,
            executionURL: materializedURL
        )
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(step.toolName, "lungfish fastq materialize")
        XCTAssertEqual(step.command, expectedCommand)
        XCTAssertEqual(step.durableReplayArgv, expectedCommand)
        XCTAssertFalse(step.command.contains("materialize-inputs"))
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertEqual(step.wallTime, 3)
        XCTAssertTrue(step.inputs.contains { $0.path == fixture.derivedBundleURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(step.outputs.contains { $0.path == materializedURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
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
        XCTAssertEqual(subs.count, 5)
        XCTAssertTrue(subs.contains { $0 == DbCommand.DbInfoSubcommand.self })
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

private func captureStandardOutputForRegression(_ operation: () async throws -> Void) async rethrows -> String {
    let pipe = Pipe()
    let originalStdout = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

    do {
        try await operation()
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } catch {
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        throw error
    }
}

private func captureStandardError(_ operation: () async throws -> Void) async rethrows -> String {
    let pipe = Pipe()
    let originalStderr = dup(STDERR_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    do {
        try await operation()
        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)
        pipe.fileHandleForWriting.closeFile()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } catch {
        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)
        pipe.fileHandleForWriting.closeFile()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        throw error
    }
}

private final class RecordingAssemblyMaterializer: AssemblyInputMaterializing {
    let materializedURL: URL
    private(set) var bundleURLs: [URL] = []

    init(materializedURL: URL) {
        self.materializedURL = materializedURL
    }

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        bundleURLs.append(bundleURL.standardizedFileURL)
        return materializedURL
    }
}

private final class RecordingCLISequenceMaterializer: CLISequenceInputMaterializing {
    let materializedURL: URL
    private(set) var bundleURLs: [URL] = []

    init(materializedURL: URL) {
        self.materializedURL = materializedURL
    }

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        bundleURLs.append(bundleURL.standardizedFileURL)
        return materializedURL
    }
}

private final class FailingSecondCLISequenceMaterializer: CLISequenceInputMaterializing {
    private var invocationCount = 0

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        invocationCount += 1
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let outputURL = tempDirectory.appendingPathComponent("materialized-\(invocationCount).fastq")
        try "@read\(invocationCount)\nACGT\n+\nIIII\n".write(to: outputURL, atomically: true, encoding: .utf8)
        if invocationCount == 2 {
            throw CLISequenceInputMaterializationError.unsupportedSequenceInput("fixture failure")
        }
        return outputURL
    }
}
