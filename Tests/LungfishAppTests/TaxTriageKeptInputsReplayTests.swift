// TaxTriageKeptInputsReplayTests.swift - The joined input a TaxTriage record names stays where the record says
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane B2, decision O1 (docs/plans/2026-10-11-phase-2-8.md). A bundle of several files of single reads
// runs as one file that the planner joins with `cat`. The record names that file twice, as the output of the `cat`
// step and as the input of the TaxTriage step, so under O1 the file stays in the result's
// `.lungfish-taxtriage-inputs` folder after the run, unchanged. One case runs the GUI launch, `runTaxTriage`
// through `AppDelegate.TaxTriageLaunchSeam.makeRunner`, and one runs `taxtriage run` through
// `TaxTriageCommand.RunSubcommand.makePipeline`, both on `TaxTriageStandInEngine`.
//
// The GUI case runs on `OperationCenter.shared`, with `LUNGFISH_CLI_PATH` naming the built CLI for its `build-db`
// step, and the engine starts processes, so the class runs serially. Its name ends in ReplayTests, which sends it
// to the integration tier (`REPLAY_SUITES` in scripts/full-suite-gate.sh).

import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageKeptInputsReplayTests: XCTestCase {
    private var scratch: URL!

    enum StandInError: Error {
        case missingCLI
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "taxtriage-kept-inputs")
    }

    override func tearDown() async throws {
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - GUI

    func testTheGUIKeepsTheJoinedInputItsRecordNamesInTheResult() async throws {
        try requireBuiltCLI()
        let engine = try makeEngine()
        let fixtures = try ReadSetFixtures(in: scratch.appendingPathComponent("fixtures", isDirectory: true))
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "J1", fastq1: fixtures.chunkedRoot)],
            outputDirectory: scratch.appendingPathComponent("replaced-by-the-launch", isDirectory: true),
            kraken2DatabasePath: try makeDatabaseFolder(),
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile
        )

        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = OverlayRecordingViewer()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }

        let existing = Set(OperationCenter.shared.items.map(\.id))
        AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({ engine.makeRunner() }) {
            delegate.runTaxTriage(
                config: config,
                viewerController: viewer,
                routeContext: OperationRouteContext(projectURL: fixtures.projectURL, windowStateScopeID: nil)
            )
        }
        let rowID = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) }?.id, "runTaxTriage started no row")
        let finished = await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(100)) {
            OperationCenter.shared.items.first { $0.id == rowID }.map { !$0.state.isActive } ?? true
        }
        XCTAssertTrue(finished, "the TaxTriage row did not finish in 120 seconds")

        let analyses = fixtures.projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let analysis = try XCTUnwrap(
            Self.visibleFolders(in: analyses).filter { $0.lastPathComponent.hasPrefix("taxtriage-") }.onlyElement,
            "the launch must make one TaxTriage folder"
        )
        XCTAssertEqual(try TaxTriageResult.load(from: analysis).exitCode, 0)
        try assertKeptJoinedInput(in: analysis, bundle: fixtures.chunkedRoot)
    }

    // MARK: - CLI

    func testTheCLIKeepsTheJoinedInputItsRecordNamesInTheOutput() async throws {
        let engine = try makeEngine()
        let fixtures = try ReadSetFixtures(in: scratch.appendingPathComponent("fixtures", isDirectory: true))
        let output = scratch.appendingPathComponent("cli-output", isDirectory: true)

        try await Self.runCLI(
            [
                "run",
                "--input", fixtures.chunkedRoot.path,
                "--sample", "J1",
                "--output", output.path,
                "--db", try makeDatabaseFolder().path,
                "--nf-profile", TaxTriageStandInEngine.profile,
                "--max-cpus", "2",
                "--quiet",
            ],
            engine: engine
        )

        XCTAssertEqual(try TaxTriageResult.load(from: output).exitCode, 0)
        try assertKeptJoinedInput(in: output, bundle: fixtures.chunkedRoot)
    }

    // MARK: - Checks

    /// The record in `result` names one joined file, the output of its `cat` step and the input of its TaxTriage
    /// step. The file sits in the result's inputs folder, the folder `taxtriage run` names, and holds the bytes the
    /// record's digest names, and no input of the two steps is missing after the run (O1). The kept file is never an
    /// output of the TaxTriage step. The GUI's record also holds the index step of its `taxtriage.sqlite`, which
    /// names the result's outputs and not the inputs.
    private func assertKeptJoinedInput(
        in result: URL,
        bundle: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let record = try XCTUnwrap(
            try ProvenanceEnvelopeReader.loadCanonical(from: result),
            "no record in \(result.path)",
            file: file,
            line: line
        )
        let cat = try XCTUnwrap(
            record.steps.first { $0.toolName == SequenceInputConcatenation.toolName },
            "the record names the join",
            file: file,
            line: line
        )
        let taxTriage = try XCTUnwrap(record.steps.first { $0.toolName == "taxtriage" }, file: file, line: line)
        let joined = try XCTUnwrap(taxTriage.inputs.onlyElement, "one joined file", file: file, line: line)
        XCTAssertEqual(cat.outputs.map(\.path), [joined.path], "the cat step wrote the file TaxTriage read", file: file, line: line)
        let members = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: bundle), file: file, line: line)
        XCTAssertEqual(
            Set(cat.inputs.map { Self.resolved($0.path) }),
            Set(members.map { Self.resolved($0.path) }),
            "the cat step read the bundle's files",
            file: file,
            line: line
        )

        let inputs = result.appendingPathComponent(TaxTriageCommand.RunSubcommand.materializationDirectoryName, isDirectory: true)
        XCTAssertEqual(
            Self.resolved(URL(fileURLWithPath: joined.path).deletingLastPathComponent().path),
            Self.resolved(inputs.path),
            "the joined file is in the result's inputs folder",
            file: file,
            line: line
        )
        let missing = (cat.inputs + taxTriage.inputs).map(\.path).filter { !FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(missing, [], "every input of the join and of the run exists after the run", file: file, line: line)
        if FileManager.default.fileExists(atPath: joined.path) {
            XCTAssertEqual(try Self.sha256(of: joined.path), joined.checksumSHA256, "the kept file is the one the record names", file: file, line: line)
        }
        XCTAssertEqual(
            taxTriage.outputs.filter { Self.resolved($0.path).hasPrefix(Self.resolved(inputs.path) + "/") }.map(\.path),
            [],
            "a kept input is never an output of the TaxTriage step",
            file: file,
            line: line
        )
    }

    // MARK: - Helpers

    /// The engine for one case, stopped in teardown so no stand-in outlives the case.
    private func makeEngine() throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: scratch.appendingPathComponent("engine", isDirectory: true),
            behaviour: .completes
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// Points `LUNGFISH_CLI_PATH` at the built CLI, which the GUI's `build-db` step runs.
    private func requireBuiltCLI() throws {
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail(
                "No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH. "
                    + "Without it the GUI path builds no taxtriage.sqlite."
            )
            throw StandInError.missingCLI
        }
        let saved = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        addTeardownBlock {
            if let saved {
                setenv("LUNGFISH_CLI_PATH", saved, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }
    }

    /// Runs `taxtriage run` in this process with the pipeline factory bound to the engine.
    nonisolated private static func runCLI(_ arguments: [String], engine: TaxTriageStandInEngine) async throws {
        let command = try TaxTriageCommand.RunSubcommand.parse(arguments)
        try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
            try await command.run()
        }
    }

    /// A Kraken2 database folder. The stand-in never reads it, but the pipeline checks it exists.
    private func makeDatabaseFolder() throws -> URL {
        let folder = scratch.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func visibleFolders(in folder: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `path` with its symbolic links resolved, so `/var` and `/private/var` compare equal.
    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func sha256(of path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension Array {
    /// The element of a one-element array, else nil.
    var onlyElement: Element? { count == 1 ? first : nil }
}
