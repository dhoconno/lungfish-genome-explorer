// PrimerDesignCLIGUIParityReplayTests.swift - The Primer3 design in the app against primers design primer3, on real primer3_core
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A67 M1 (2) and BIO risk BR13, plan decisions C4 and C5 of 2.10 and G1, 2.9 O5 (live tests first), on
// lane Q30's harness. The PCR Primer Design dialog runs its engine in process, and its row records the
// `lungfish-cli primers design <engine>` command that reproduces the run (`PrimerDesignOperation.cliCommand`). One case
// runs on three sides that start as copies of one project folder, which holds a FASTA of one template, on the real
// `primer3_core` of the managed environment.
//
// - Side A is the in-process route, the request `PrimerDesignDialogPresenter.run` builds from the dialog (its `:72-147`)
//   and `Primer3DesignPipeline().run(request:)`, the call `PrimerDesignOperation.start` makes. It has no CLI.
// - Side C is the row, `PrimerDesignOperation.beginPrimerDesignOperation` with the command built from the same dialog,
//   and the built `lungfish-cli` run on the arguments of that recorded command.
// - Side C' is the harness's replay of that command.
//
// A against C and C against C' declare nothing (C4). The bundle needs a mask policy of its own, the family policy
// OutputEquivalence.MaskPolicy.primerAnalysis beside .gatk (Tests/Support/LungfishTestSupport/
// OutputEquivalence+PrimerAnalysisMasks.swift, named in the Masks row of docs/contracts/CLI-EQUIVALENCE.md, lane 12.16
// under ruling 2 of the A67 review). It hides what each host says about itself in the two provenance envelopes (the
// argument vector, the options it names and its tool name and version), and the class pins the CLI's vector against the
// recorded command apart.
//
// It launches the built lungfish-cli and the managed primer3_core, so its name ends in ReplayTests, which sends it to the
// integration tier, and it skips without primer3 unless `LUNGFISH_REQUIRE_TOOLS=1`, which fails it. The other engines
// (primalscheme3, olivar and varvamp) join as further cases of this class.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class PrimerDesignCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case primer3
        case primalScheme3
        case varvamp
    }

    /// The differences of A against C.
    static let declared: [RouteParityDeclaredDifference<Case>] = []

    private static let analysisName = "primer-parity"
    var scratch: URL!
    var cli: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "primer-design-parity").resolvingSymlinksInPath().standardizedFileURL
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testThePrimer3RowWritesWhatTheInProcessRunWroteOnRealPrimer3() async throws {
        let conda = CondaManager.shared
        do {
            _ = try await conda.toolPath(name: "primer3_core", environment: "primer3")
        } catch {
            try ToolAvailability.skipOrFail("primer3 is not installed in the managed environment: \(error)")
        }
        let environment = ["LUNGFISH_CONDA_ROOT": conda.rootPrefix.path]
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .primerAnalysis, replayTimeout: .seconds(300),
            environment: { _ in environment }
        )
        let result = try await harness.assertParity(
            Case.primer3,
            declared: Self.declared,
            in: scratch.appendingPathComponent(Case.primer3.rawValue, isDirectory: true),
            fixture: { root in try Self.writeFixture(root) },
            sideA: { root in await self.sideA(root) },
            sideC: { root in await self.sideC(root, harness: harness) }
        )
        let command = try XCTUnwrap(result.runs.c.outcome.recordedCommand, "side C records the row's command")
        XCTAssertTrue(command.hasPrefix("lungfish-cli primers design primer3 "), command)
        try Self.assertRecordedArgv(of: result.runs.c, is: RecordedCLICommand.arguments(of: command), cli: cli)
        try Self.assertRecordedArgv(
            of: result.runs.cPrime, is: try XCTUnwrap(result.runs.cPrime.replayedArguments.first), cli: cli
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            // Real Primer3 designed pairs for the template on every side.
            let normalized = Self.bundleURL(in: run.root).appendingPathComponent("results/primer3-normalized-v1.json")
            let data = try Data(contentsOf: normalized)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let templates = try XCTUnwrap(json["results"] as? [[String: Any]])
            XCTAssertEqual(templates.count, 1, "side \(run.side)")
            for template in templates {
                XCTAssertFalse((template["pairs"] as? [Any] ?? []).isEmpty, "side \(run.side): Primer3 designed no pair")
            }
        }
    }

    // MARK: - The fixture and the dialog

    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent("Analyses/\(analysisName).lungfishprimeranalysis", isDirectory: true)
    }

    /// One template of 600 bases from a fixed generator, about half G and C, so Primer3 finds pairs, and the project's
    /// `Analyses` folder, which the dialog creates before a run and the command expects to exist. One template, because
    /// the comparison numbers the UUIDs of files that tie on their blanked name and text (`annotations/<UUID>.bed` of two
    /// templates) in the order of their random raw names, so two runs of the same design would number them differently.
    private static func writeFixture(_ root: URL) throws {
        let text = ">template-one\n" + wrapped(sequence(seed: 11, length: 600)) + "\n"
        try text.write(to: root.appendingPathComponent("templates.fasta"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Analyses", isDirectory: true), withIntermediateDirectories: true
        )
    }

    static func sequence(seed: UInt64, length: Int) -> String {
        let bases = Array("ACGT")
        var state = seed
        var result = ""
        for _ in 0..<length {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result.append(bases[Int((state >> 33) & 3)])
        }
        return result
    }

    static func wrapped(_ sequence: String) -> String {
        let letters = Array(sequence)
        return stride(from: 0, to: letters.count, by: 70)
            .map { String(letters[$0..<min($0 + 70, letters.count)]) }
            .joined(separator: "\n")
    }

    /// The dialog of the side's project folder for `engine`, with its input read and, for a FASTA of templates, every
    /// record selected.
    static func dialog(
        in root: URL, engine: PrimerDesignEngine = .primer3, input: String = "templates.fasta"
    ) async -> PrimerDesignDialogState {
        let state = PrimerDesignDialogState(projectURL: root)
        state.engine = engine
        state.analysisName = analysisName
        state.addInputs([root.appendingPathComponent(input)])
        await state.inspectInputs()
        return state
    }

    // MARK: - The sides

    /// Side A. The request the presenter builds from the dialog, on the pipeline `PrimerDesignOperation.start` runs.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        do {
            let state = await Self.dialog(in: root)
            let destination = try state.validatedDestinationURL(createParent: true)
            let runtime = ProvenanceRuntimeIdentity()
            let options = try state.primer3Options()
            let fixed = options.fixedOligos
            let visibleOptions: [String: ParameterValue] = [
                "analysisName": .string(state.analysisName),
                "engine": .string(state.engine.rawValue),
                "interface": .string("Lungfish PCR Primer Design"),
                "projectPath": .string(root.path),
                "assay": .string(state.chemistry.rawValue),
                "assayMode": .string(state.chemistry.assayMode.rawValue),
                "assayDefaultsSource": .string("shared Primer3AssayDefaults preset, editable in the dialog"),
                "fixedLeftPrimer": fixed.leftPrimer.map(ParameterValue.string) ?? .null,
                "fixedRightPrimer": fixed.rightPrimer.map(ParameterValue.string) ?? .null,
                "fixedProbe": fixed.probe.map(ParameterValue.string) ?? .null,
                "forceLeftEnd": fixed.forceLeftEnd.map(ParameterValue.integer) ?? .null,
                "forceRightEnd": fixed.forceRightEnd.map(ParameterValue.integer) ?? .null,
                "probeMinTmOffsetOverPrimers": options.probeMinTmOffsetOverPrimers.map(ParameterValue.number) ?? .null,
            ]
            let invocation = PrimerAnalysisWrapperInvocation(
                argv: PrimerDesignOperation.cliArgv(state: state, destination: destination) ?? CommandLine.arguments,
                callerVersion: runtime.appVersion ?? WorkflowRun.currentAppVersion,
                explicitOptions: visibleOptions, runtimeIdentity: runtime
            )
            let request = Primer3DesignRequest(
                inputURLs: state.inputURLs, selections: try state.primer3Selections(), destinationURL: destination,
                options: options, invocation: invocation, executableURL: nil,
                expectedInputChecksums: state.inputSummaries.mapValues(\.checksumSHA256)
            )
            _ = try await Primer3DesignPipeline().run(request: request)
            return RouteParitySideOutcome(end: .completed, detail: "Primer analysis saved.")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The row the dialog begins, which records the command, and the built CLI on the recorded command's
    /// arguments with the same managed environment as side A. It returns the row's command, which side C' replays.
    func sideC(
        _ root: URL, harness: RouteParityHarness, engine: PrimerDesignEngine = .primer3, input: String = "templates.fasta"
    ) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        do {
            let state = await Self.dialog(in: root, engine: engine, input: input)
            let destination = try state.validatedDestinationURL(createParent: true)
            PrimerDesignOperation.beginPrimerDesignOperation(
                title: "\(state.engine.rawValue) · \(state.analysisName)", destination: destination, routeContext: nil,
                cliCommand: PrimerDesignOperation.cliCommand(state: state, destination: destination), reporter: reporter
            ) { _ in }
            let recorded = reporter.items.first?.cliCommand
            let arguments = try RecordedCLICommand.arguments(of: recorded)
            let run = await RouteParityHarness.runCLI(
                harness.cliBinary, arguments: arguments, timeout: harness.replayTimeout, environment: harness.environment(root)
            )
            return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: recorded)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: reporter.items.first?.cliCommand)
        }
    }
}

extension PrimerDesignCLIGUIParityReplayTests {
    /// The CLI's own record of its call, `provenance/wrapper.json`, holds the program that ran and the recorded command's
    /// arguments, on side C and on the replay. The policy hides the vector from the compare, so this pins it.
    static func assertRecordedArgv(
        of run: RouteParitySideRun, is arguments: [String], cli: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let wrapper = bundleURL(in: run.root).appendingPathComponent("provenance/wrapper.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: wrapper)) as? [String: Any], file: file, line: line
        )
        let argv = try XCTUnwrap(json["argv"] as? [String], "side \(run.side) records its argv", file: file, line: line)
        XCTAssertEqual(argv.first.map { URL(fileURLWithPath: $0).lastPathComponent }, cli.lastPathComponent, file: file, line: line)
        XCTAssertEqual(Array(argv.dropFirst()), arguments, "side \(run.side): the CLI ran the recorded command", file: file, line: line)
    }
}

extension PrimerDesignCLIGUIParityReplayTests {
    /// A67-ARGV (2.12 lane 12.17, `CLI-EQUIVALENCE.md` line 16). The in-process run records the row's command as its
    /// provenance argv, the words Copy CLI Command gives, and not the app's launch arguments. Side A builds its request
    /// as `PrimerDesignDialogPresenter.run` does, so this reads side A's `provenance/wrapper.json`.
    func testTheDesignRunRecordsTheRecordedCommandAsItsProvenanceArgv() async throws {
        do {
            _ = try await CondaManager.shared.toolPath(name: "primer3_core", environment: "primer3")
        } catch {
            try ToolAvailability.skipOrFail("primer3 is not installed in the managed environment: \(error)")
        }
        let root = scratch.appendingPathComponent("argv", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.writeFixture(root)
        let outcome = await sideA(root)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)
        let row = PrimerDesignOperation.cliCommand(state: await Self.dialog(in: root), destination: Self.bundleURL(in: root))
        let wrapper = Self.bundleURL(in: root).appendingPathComponent("provenance/wrapper.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: wrapper)) as? [String: Any])
        XCTAssertEqual(
            json["argv"] as? [String], [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: row))
        )
    }
}
