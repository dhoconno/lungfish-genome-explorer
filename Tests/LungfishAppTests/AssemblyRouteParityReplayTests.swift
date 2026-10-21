// AssemblyRouteParityReplayTests.swift - The Reassemble routes and the recorded command, on a stand-in SPAdes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M3 (panel G1, C4 and C13, ARCH 2 and 3, BIO 1 to 3, UX 1, 3 and 4, QA 1, 4
// and 5). Phase 2.11 (K3) deleted the in-process route and its hidden key, so
// Reassemble runs on the CLI route only. The parity case runs one Reassemble on the two sides of
// RouteParityHarness that are left.
//
// - Side C, the CLI route, `AssemblyRunner.startManagedAssembly` on the built CLI.
// - Side C', the command side C's row recorded, rebased and run by the built CLI.
//
// It holds C against C' to nothing declared, the bar of side C's row to rising only, and the
// record of side C to the command its row recorded. `testTheRecordedCommandRebuildsTheBundle`
// replays the command the record
// names, moved here from AssembleCommandReferenceBundleTests because it needs bgzip
// (ruling-A46-masks section 2). The SIGTERM case cancels `assemble` through the real transport
// once its assembler runs.
//
// A stand-in SPAdes answers both sides (ruling-A46-bundle section 5, G2). Its micromamba sits in
// a conda root of the test's own, which also links the storage root's htslib and samtools envs,
// so each case states bgzip and samtools with ToolAvailability. Side C gets that conda root from
// LUNGFISH_CONDA_ROOT, which the test sets for its run, through the app's subprocess environment,
// and side C' gets it through the harness.
//
// The CLI route has one state the in-process route never reached, "row cancelled, result listed",
// a cancel that comes after the command finished (fix 8 of lane A46, its ruling section 5).
// ReadsLaunchCommandTests.testACancelThatComesAfterMapFinishedKeepsItsResult holds it.
//
// It launches the built lungfish-cli and needs bgzip, so its name ends in ReplayTests, which sends
// it to the integration tier (docs/contracts/CLI-EQUIVALENCE.md).

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class AssemblyRouteParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var cliBinary: URL!
    private var savedEnvironment: [String: String?] = [:]

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "assembly-route-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cliBinary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so sides C and C' cannot run"
        )
    }

    override func tearDown() async throws {
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        if !savedEnvironment.isEmpty {
            // The shared runner keeps the bgzip and samtools paths it found under the stand-in
            // root, which goes with the scratch folder, so the next test looks them up again.
            await NativeToolRunner.shared.clearCache()
        }
        savedEnvironment = [:]
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - C against C'

    func testTheReassembleRouteRecordsTheCommandItRunsAndTheRecordedCommandReproducesIt() async throws {
        let tools = try await installStandInTools()
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120),
            environment: { _ in tools.environment }
        )
        var rowC: MappingRouteRow?
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            fixture: Self.writeFixture,
            sideC: { root in
                let request = Self.request(in: root).normalizedForExecution()
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (row, item) = try await ReadsRouteParity.record(title: Self.title) {
                    AssemblyRunner.startManagedAssembly(request: request, routeContext: nil, runner: runner)
                }
                rowC = row
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        let ends = [runs.c, runs.cPrime]
        XCTAssertEqual(ends.map(\.outcome.end), [.completed, .completed], ends.map(\.outcome.detail).joined(separator: "\n"))
        // C against C' declares nothing. The command the row recorded rebuilds the same folder and bundle.
        let found = try harness.differences(runs.c, runs.cPrime)
        RouteParityHarness.assertNoFailures(found.map { "\($0.id): \($0.detail)" }, in: "spadesReassemble, C against C'")
        // The bar and the log change at a move on every route (ADDING-AN-OPERATION.md, What a CLI
        // route's row shows), and the CLI route's bar only rises.
        XCTAssertEqual(rowC?.bar, rowC?.bar.sorted(), "the CLI route's bar only rises")

        // The record names the command the row recorded (CLI-EQUIVALENCE, provenance names the command).
        let folder = Self.assemblyFolder(in: runs.c.root)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "side C wrote no record in \(folder.path)")
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        XCTAssertEqual(Array(record.argv.dropFirst()), try RecordedCLICommand.arguments(of: command))
    }

    // MARK: - The recorded command rebuilds the bundle (moved from AssembleCommandReferenceBundleTests)

    /// `assemble --reference-bundle` on root A, then the argv its record names, rebased onto a fresh
    /// root B, builds the same folder and the same bundle under the contract's masks.
    func testTheRecordedCommandRebuildsTheBundle() async throws {
        let tools = try await installStandInTools()
        let rootA = scratch.appendingPathComponent("A", isDirectory: true)
        let rootB = scratch.appendingPathComponent("B", isDirectory: true)
        for root in [rootA, rootB] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.writeFixture(root)
        }
        let first = await RouteParityHarness.runCLI(
            cliBinary, arguments: Self.arguments(in: rootA), timeout: .seconds(120), environment: tools.environment
        )
        XCTAssertEqual(first.end, .completed, first.detail)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: Self.assemblyFolder(in: rootA)))

        let command = OperationCenter.buildCLICommand(subcommand: "", args: Array(record.argv.dropFirst()))
        let replay = try RouteParityHarness.arguments(ofLine: RouteParityHarness.rebased(command, from: rootA, to: rootB))
        let second = await RouteParityHarness.runCLI(cliBinary, arguments: replay, timeout: .seconds(120), environment: tools.environment)
        XCTAssertEqual(second.end, .completed, second.detail)

        OutputEquivalence.assertSame(rootA, rootB, kind: .bundle)
    }

    // MARK: - SIGTERM through the transport (P2, SWIFT 3 and 7)

    /// The Reassemble row's cancel reaches `assemble` as SIGTERM through the transport every CLI
    /// route uses, once the assembler runs. The command exits 125 inside the grace with its failed
    /// line, no process of its tree is left, and no bundle is published.
    func testSIGTERMThroughTheTransportCancelsAssemble() async throws {
        let condaRoot = scratch.appendingPathComponent("cancel-tools/conda", isDirectory: true)
        let assemblerPID = scratch.appendingPathComponent("assembler.pid")
        try ReadsRouteParity.write(
            ReadsRouteParity.sleepingMicromamba(tool: "spades.py", pidFile: assemblerPID),
            executableAt: condaRoot.appendingPathComponent("bin/micromamba")
        )
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.writeFixture(root)

        let run = await RouteParityHarness.runCLI(
            cliBinary, arguments: Self.arguments(in: root), timeout: .seconds(60),
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path, "LUNGFISH_CONDA_SHARED_PKGS": "0"],
            cancelWhen: { FileManager.default.fileExists(atPath: assemblerPID.path) }
        )

        let observed = try XCTUnwrap(run.cancel, "the assembler never ran, so nothing was cancelled: \(run.detail)\n\(run.stderr)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)\n\(run.stderr)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        let lastEvent = run.stdout.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(lastEvent.contains(#""event":"failed""#) && lastEvent.contains("Assembly cancelled"), run.stdout)
        let bundle = Self.assemblyFolder(in: root).deletingLastPathComponent().appendingPathComponent("\(Self.projectName).lungfishref")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), "a cancelled run publishes no bundle")
    }
}

// MARK: - The fixture, the sides and the stand-in

extension AssemblyRouteParityReplayTests {
    nonisolated static let projectName = "demo"

    /// The title of the Reassemble row of the request of any root.
    static var title: String {
        "\(AssemblyTool.spades.displayName) Assembly: \(projectName)"
    }

    /// A project holding two reads and the folder Reassemble writes into.
    nonisolated static func writeFixture(_ root: URL) throws {
        let inputs = root.appendingPathComponent("Project.lungfish/inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputFolder(in: root), withIntermediateDirectories: true)
        try "@r1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n@r2\nTTGCATTGCATTGCATTGCA\n+\nIIIIIIIIIIIIIIIIIIII\n"
            .write(to: inputs.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
    }

    nonisolated static func outputFolder(in root: URL) -> URL {
        root.appendingPathComponent("Project.lungfish/Assemblies", isDirectory: true)
    }

    /// The folder the pipeline writes, `<output>/<project name>`.
    nonisolated static func assemblyFolder(in root: URL) -> URL {
        outputFolder(in: root).appendingPathComponent(projectName, isDirectory: true)
    }

    /// The Reassemble request of `root`, SPAdes on one read file with one thread and 4 GB.
    nonisolated static func request(in root: URL) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [root.appendingPathComponent("Project.lungfish/inputs/reads.fastq")],
            projectName: projectName,
            outputDirectory: outputFolder(in: root),
            threads: 1,
            memoryGB: 4
        )
    }

    /// The argv after the binary that the CLI route runs for the request of `root`.
    nonisolated static func arguments(in root: URL) -> [String] {
        let request = request(in: root).normalizedForExecution()
        return AssemblyRunner.managedAssemblyCLIArguments(
            for: request, outputDirectory: AssemblyRunner.executionRequest(for: request).outputDirectory
        )
    }

    /// A conda root of the test's own: a stand-in micromamba whose SPAdes writes one contig, and
    /// the storage root's htslib and samtools envs, linked. Side A reads it from
    /// LUNGFISH_CONDA_ROOT, set until tearDown, and every CLI run gets `environment`.
    func installStandInTools() async throws -> StandInTools {
        let bgzip = try await ToolAvailability.require("bgzip", environment: "htslib")
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let condaRoot = scratch.appendingPathComponent("tools/conda", isDirectory: true)
        let envs = condaRoot.appendingPathComponent("envs", isDirectory: true)
        // The test process's CondaManager puts the bundled micromamba in place of a stand-in whose
        // version differs, so SPAdes is an env of its own that either micromamba runs.
        try ReadsRouteParity.write(Self.micromamba(envs: envs), executableAt: condaRoot.appendingPathComponent("bin/micromamba"))
        try ReadsRouteParity.write(Self.spades, executableAt: envs.appendingPathComponent("spades/bin/spades.py"))
        try FileManager.default.createDirectory(at: envs.appendingPathComponent("spades/conda-meta"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: envs.appendingPathComponent("spades/conda-meta/history").path, contents: Data())
        for (name, executable) in [("htslib", bgzip), ("samtools", samtools)] {
            let environment = executable.deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(at: envs.appendingPathComponent(name), withDestinationURL: environment)
        }
        let tools = StandInTools(environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path, "LUNGFISH_CONDA_SHARED_PKGS": "0"])
        for (key, value) in tools.environment {
            if savedEnvironment[key] == nil { savedEnvironment[key] = .some(ProcessInfo.processInfo.environment[key]) }
            setenv(key, value, 1)
        }
        await NativeToolRunner.shared.clearCache()
        return tools
    }

    struct StandInTools: Sendable {
        let environment: [String: String]
    }

    /// A stand-in micromamba that answers its version probe and runs `run -n <env> <tool> ...` from
    /// the env's own `bin` folder under `envs`.
    nonisolated static func micromamba(envs: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "2.0.0"; exit 0; fi
        if [ "$1" != "run" ] || [ "$2" != "-n" ]; then echo "unexpected micromamba invocation: $*" >&2; exit 64; fi
        environment="$3"
        tool="$4"
        shift 4
        exec '\(envs.path)'/"$environment"/bin/"$tool" "$@"
        """
    }

    /// The stand-in SPAdes of `StandInSPAdesConda` in LungfishCLITests. It answers its version
    /// probe and writes one contig and its log.
    nonisolated static let spades = """
        #!/bin/sh
        if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then echo "SPAdes 4.2.0"; exit 0; fi
        outdir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then shift; outdir="$1"; fi
          shift
        done
        if [ -z "$outdir" ]; then echo "missing -o argument" >&2; exit 66; fi
        mkdir -p "$outdir"
        printf '>contig1\\nACGTACGTACGTACGTACGT\\n' > "$outdir/contigs.fasta"
        echo "SPAdes pipeline finished" > "$outdir/spades.log"
        exit 0
        """
}
