// PrimerDesignOperationOperationTests.swift - The primer design row's lock, command and refusal
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The primer design row locks the analysis bundle it writes (R4) and records the
// `lungfish-cli primers design <engine>` command that PrimerDesignOperation.cliCommand builds from
// the dialog's settings (Phase 2.11 lane A67, row primer-design, which closed the CLI parity gap).
// A held lock must refuse the row and launch no worker. The recorded command parses with the
// command of its engine and names the run's inputs and destination. The native tool argv goes to the
// row's log, since it is not a lungfish-cli command.

import XCTest
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class PrimerDesignOperationOperationTests: XCTestCase {
    private let destination = URL(
        fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Analyses/Primer3 Test.lungfishprimeranalysis",
        isDirectory: true
    )

    /// The command of a PrimalScheme run of an untouched dialog into `destination`.
    private func recordedCommand() throws -> String {
        let state = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
        state.engine = .primalScheme
        state.addInputs([URL(fileURLWithPath: "/input/mhc 1.fasta")])
        return try XCTUnwrap(PrimerDesignOperation.cliCommand(state: state, destination: destination))
    }

    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Existing writer",
            detail: "Running",
            operationType: .workflow,
            targetBundleURL: destination,
            cliCommand: "lungfish-cli primers design primer3"
        ).startedID)
        return center
    }

    // MARK: - begin helper

    func testRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = PrimerDesignOperation.beginPrimerDesignOperation(
            title: "Primer3 · Test",
            destination: destination,
            routeContext: nil,
            cliCommand: try recordedCommand(),
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held destination lock must refuse the primer design row")
        }
        XCTAssertFalse(launched, "a refused row must launch no worker")
        XCTAssertEqual(refusal.blockingOperationTitle, "Existing writer")
    }

    func testRecordsItsTypeLockAndACommandThatParsesWithTheRunsInputsAndDestination() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())
        var launchedID: UUID?

        PrimerDesignOperation.beginPrimerDesignOperation(
            title: "PrimalScheme · Test",
            destination: destination,
            routeContext: routeContext,
            cliCommand: try recordedCommand(),
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "PrimalScheme · Test")
        XCTAssertEqual(item.initialDetail, "Preparing primer design…")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, destination)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: PrimerDesignCommand.PrimalScheme3Subcommand.self)
        XCTAssertEqual(command.msaPaths, ["/input/mhc 1.fasta"])
        // A result in a project takes --project, so a replay writes a new bundle (lane 13.43, row PRIMER-PROJECT).
        XCTAssertNil(command.outputPath)
        XCTAssertEqual(command.projectPath, "/tmp/lane 1a2/Project.lungfish")
        XCTAssertEqual(command.analysisName, "Primer3 Test")
    }

    // MARK: - argv (2.12 lane 12.17, A67-ARGV)

    /// The argv a design run records as its provenance is the row's command word for word, so the Provenance tab and
    /// Copy CLI Command name one command. A dialog with no command has no argv either, and since lane 12.17 M2 the
    /// presenter then runs nothing and says so in the dialog. The live class shows the Primer3 run's record
    /// (`PrimerDesignCLIGUIParityReplayTests.testTheDesignRunRecordsTheRecordedCommandAsItsProvenanceArgv`).
    func testTheArgvIsTheRowsCommandWordForWordForEachEngine() throws {
        for engine in [PrimerDesignEngine.primalScheme, .olivar, .varVAMP] {
            let state = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
            state.engine = engine
            state.addInputs([URL(fileURLWithPath: "/input/mhc 1.fasta")])
            let argv = try XCTUnwrap(PrimerDesignOperation.cliArgv(state: state, destination: destination), "\(engine)")
            let command = PrimerDesignOperation.cliCommand(state: state, destination: destination)
            XCTAssertEqual(
                argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: command)), "\(engine)"
            )
            XCTAssertEqual(Array(argv.prefix(3)), [CLICommandIdentity.executableName, "primers", "design"], "\(engine)")
        }
        // A Primer3 dialog that has read no template selects no record, so it has no command.
        let unread = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
        unread.engine = .primer3
        unread.addInputs([URL(fileURLWithPath: "/input/mhc 1.fasta")])
        XCTAssertNil(PrimerDesignOperation.cliArgv(state: unread, destination: destination))
        XCTAssertNil(PrimerDesignOperation.cliCommand(state: unread, destination: destination))
    }

    // MARK: - the form of a result in a project (2.13 lane 13.43, row PRIMER-PROJECT)

    /// The recorded command of every engine names `--project` and `--name` in place of `--output`, so a replay in Terminal
    /// writes a new bundle and leaves the one the app wrote alone, and each leaf parses it back to the dialog's project and
    /// name.
    func testEveryEngineRecordsProjectAndNameInPlaceOfOutput() throws {
        for engine in [PrimerDesignEngine.primalScheme, .olivar, .varVAMP] {
            let state = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
            state.engine = engine
            state.addInputs([URL(fileURLWithPath: "/input/mhc 1.fasta")])
            let argv = try XCTUnwrap(PrimerDesignOperation.cliArgv(state: state, destination: destination), "\(engine)")
            XCTAssertFalse(argv.contains("--output"), "\(engine): \(argv)")
            let index = try XCTUnwrap(argv.firstIndex(of: "--project"), "\(engine)")
            XCTAssertEqual(Array(argv[index...].prefix(3)), ["--project", "/tmp/lane 1a2/Project.lungfish", "--name=Primer3 Test"])
        }
    }

    /// Words with no `--output` pair for the destination stay as they are, and a name that starts with a hyphen joins its
    /// option so the leaf reads it as a value.
    func testTheProjectFormReplacesOnlyTheOutputPairOfTheDestination() throws {
        let hyphen = URL(fileURLWithPath: "/tmp/p.lungfish/Analyses/-odd name.lungfishprimeranalysis", isDirectory: true)
        XCTAssertEqual(
            PrimerDesignOperation.inProjectForm(["--msa", "a.fasta", "--output", hyphen.path, "--grouping=independent"], destination: hyphen),
            ["--msa", "a.fasta", "--project", "/tmp/p.lungfish", "--name=-odd name", "--grouping=independent"])
        let other = ["--msa", "a.fasta", "--output", "/elsewhere/x.lungfishprimeranalysis"]
        XCTAssertEqual(PrimerDesignOperation.inProjectForm(other, destination: hyphen), other)
        XCTAssertEqual(PrimerDesignOperation.inProjectForm(["--msa", "a.fasta"], destination: hyphen), ["--msa", "a.fasta"])
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse(
            PrimerDesignOperation.inProjectForm(["--msa", "a.fasta", "--output", hyphen.path], destination: hyphen))
        XCTAssertEqual(command.analysisName, "-odd name")
        XCTAssertEqual(command.projectPath, "/tmp/p.lungfish")
    }

    // MARK: - dialog words (2.12 lane 12.17, UX ruling)

    /// The text of a dialog whose settings have no command (nothing ran) and the alert of a name taken between the check
    /// and the launch are the UX ruling's words, so a rewording of either is a decision and not a drift. No test reaches
    /// the presenter's branch for a missing command, since no dialog state lacks one
    /// (`PrimerDesignCommandRoundTripTests.testEveryDialogAssayAndSchemeEngineHasACommand`), so this pin holds the words
    /// themselves.
    func testTheDialogWordsForNothingRanAndATakenNameAreTheRulingsWords() {
        XCTAssertEqual(
            PrimerDesignOperation.noCommandMessage,
            "Lungfish could not build the lungfish-cli command for these settings, so nothing ran. Check the settings and try again."
        )
        XCTAssertEqual(
            PrimerDesignOperation.existingDestinationMessage,
            "An analysis with this name already exists in the project. Run the design again with a different name."
        )
    }

    // MARK: - start

    func testTheNativeToolArgvGoesToTheLogAndTheRowKeepsTheCommand() async throws {
        let reporter = RecordingOperationReporter()
        let gate = AsyncStream<Void>.makeStream()
        let argv = ["/path with spaces/primer3_core", "--format_output", "/tmp/lane 1a2/primer3 input.txt"]
        let output = destination
        let recorded = try recordedCommand()
        let handle = PrimerDesignOperation.start(
            center: reporter,
            title: "Primer3 · Test",
            destination: output,
            routeContext: nil,
            cliCommand: recorded,
            operation: { _ in
                NativeProcessObservation.onEvent?(.started(argv: argv))
                for await _ in gate.stream { break }
                return output
            },
            onResultSaved: { _ in }
        )

        let expectedLog = "Native command: " + argv.map(shellEscape).joined(separator: " ")
        await waitUntil { reporter.item(handle.id)?.logs.contains { $0.message == expectedLog } == true }
        // The native argv is not a lungfish-cli command, so it goes to the row's log
        // and the row keeps the command the dialog's settings build.
        XCTAssertEqual(reporter.item(handle.id)?.cliCommand, recorded)
        gate.continuation.finish()
        await handle.task.value
        XCTAssertEqual(reporter.item(handle.id)?.state, .completed)
        XCTAssertEqual(reporter.item(handle.id)?.outputURLs, [destination])
    }

    func testARefusedStartRunsNoWorkerAndHandsBackTheRefusedRow() async throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Existing writer")
        let output = destination
        let handle = PrimerDesignOperation.start(
            center: reporter,
            title: "Primer3 · Test",
            destination: output,
            routeContext: nil,
            cliCommand: try recordedCommand(),
            operation: { _ in
                XCTFail("a refused row must not run the design")
                return output
            },
            onResultSaved: { _ in XCTFail("a refused row must not publish a result") }
        )

        await handle.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(handle.id, item.id)
        XCTAssertEqual(item.state, .refused)
        XCTAssertFalse(item.hasCancelCallback)
        XCTAssertTrue(item.logs.isEmpty)
    }
}
