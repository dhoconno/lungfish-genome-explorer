// WorkflowOperationTwelveSCommandParityTests.swift - The 12S row's command parses to the run's configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
import XCTest

/// The Operations panel row for 12S matching records the `lungfish-cli`
/// command the app runs. Parsed by the real CLI, that command must give the
/// configuration the dialog built, resolution policy included, and the CLI's
/// replay argv (the provenance argv) must be that recorded command
/// (docs/contracts/CLI-EQUIVALENCE.md, Phase 2.1 lane L4).
@MainActor
final class WorkflowOperationTwelveSCommandParityTests: XCTestCase {

    private func makeService() -> WorkflowOperationExecutionService {
        WorkflowOperationExecutionService(operationCenter: OperationCenter(), processRunner: NeverRunCLI())
    }

    private let inputURL = URL(fileURLWithPath: "/tmp/parity/SampleA.lungfishfastq", isDirectory: true)
    private let referenceURL = URL(fileURLWithPath: "/tmp/parity/amplicons_12s.fa")
    private let outputDirectory = URL(fileURLWithPath: "/tmp/parity/results", isDirectory: true)

    private var defaultConfiguration: TwelveSAmpliconMatchingConfiguration {
        TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [inputURL],
            referenceFASTA: referenceURL,
            outputDirectory: outputDirectory,
            outputName: "SampleA-12s",
            threads: 1
        )
    }

    private var everyChoiceConfiguration: TwelveSAmpliconMatchingConfiguration {
        TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [inputURL, URL(fileURLWithPath: "/tmp/parity/SampleB.lungfishfastq", isDirectory: true)],
            referenceFASTA: referenceURL,
            referenceMetadata: URL(fileURLWithPath: "/tmp/parity/12s-target-metadata.tsv"),
            sampleMetadata: URL(fileURLWithPath: "/tmp/parity/samples.csv"),
            outputDirectory: outputDirectory,
            outputName: "wwtp-12s",
            minimumSoftClipBases: 2,
            maximumIndelBases: 4,
            matchingMode: .ontIndel,
            threads: 3,
            runChimeraReview: false,
            ambiguityResolution: .conservative(minFoldRatio: 2.0, absoluteFloor: 10)
        )
    }

    /// The mode and the thread count are always named. Every other default
    /// is left out, as the CLI's own replay leaves it out.
    func testRecordedCommandNamesTheModeAndThreadCountAndLeavesOtherDefaultsOut() {
        let arguments = makeService().twelveSAmpliconMatchingArguments(for: defaultConfiguration)

        XCTAssertEqual(arguments, [
            "fastq", "12s-match", inputURL.path,
            "--reference", referenceURL.path,
            "--output-dir", outputDirectory.path,
            "--output-name", "SampleA-12s",
            "--matching-mode", "illumina-exact",
            "--threads", "1",
        ])
    }

    func testRecordedCommandNamesTheConservativeResolution() {
        let arguments = makeService().twelveSAmpliconMatchingArguments(for: everyChoiceConfiguration)

        let index = try? XCTUnwrap(arguments.firstIndex(of: "--ambiguity-resolution"))
        XCTAssertEqual(index.map { arguments[$0 + 1] }, "conservative")
        XCTAssertEqual(arguments.filter { $0 == "--ambiguity-resolution" }.count, 1)
        XCTAssertEqual(arguments.filter { $0 == "--matching-mode" }.count, 1)
        XCTAssertTrue(arguments.contains("--no-chimera-review"))
    }

    /// The recorded command, parsed by the shipped CLI parser, is the run's
    /// configuration, and the CLI's replay argv is the recorded command.
    func testRecordedCommandParsesToTheSameConfigurationAndReplayArgv() throws {
        let service = makeService()
        for configuration in [defaultConfiguration, everyChoiceConfiguration] {
            let arguments = service.twelveSAmpliconMatchingArguments(for: configuration)
            let command = ViralReconWorkflowCommandPreview.build(
                executableName: CLICommandIdentity.executableName,
                arguments: arguments
            )

            let parsed = try RecordedCLICommand.parse(command, as: FastqTwelveSMatchSubcommand.self)
            let cli = try parsed.configurationForTesting()

            // Paths, not URL values, because a URL the dialog built carries a
            // directory flag the parsed path does not.
            XCTAssertEqual(cli.inputFASTQs.map(\.path), configuration.inputFASTQs.map(\.path), command)
            XCTAssertEqual(cli.referenceFASTA.path, configuration.referenceFASTA.path, command)
            XCTAssertEqual(cli.referenceMetadata?.path, configuration.referenceMetadata?.path, command)
            XCTAssertEqual(cli.referenceBundleURL?.path, configuration.referenceBundleURL?.path, command)
            XCTAssertEqual(cli.sampleMetadata?.path, configuration.sampleMetadata?.path, command)
            XCTAssertEqual(cli.outputDirectory.path, configuration.outputDirectory.path, command)
            XCTAssertEqual(cli.outputName, configuration.outputName, command)
            XCTAssertEqual(cli.minimumSoftClipBases, configuration.minimumSoftClipBases, command)
            XCTAssertEqual(cli.maximumIndelBases, configuration.maximumIndelBases, command)
            XCTAssertEqual(cli.matchingMode, configuration.matchingMode, command)
            XCTAssertEqual(cli.threads, configuration.threads, command)
            XCTAssertEqual(cli.runChimeraReview, configuration.runChimeraReview, command)
            XCTAssertEqual(cli.forceOverwrite, configuration.forceOverwrite, command)
            XCTAssertEqual(cli.ambiguityResolution, configuration.ambiguityResolution, command)
            XCTAssertEqual(cli.argv, [CLICommandIdentity.executableName] + arguments, command)
        }
    }
}

private final class NeverRunCLI: LocalWorkflowCLIProcessRunning {
    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        XCTFail("these tests build the command and never run it")
        throw CancellationError()
    }

    func cancel() {}
}
