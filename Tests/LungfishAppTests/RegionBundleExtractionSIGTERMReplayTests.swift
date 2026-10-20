// RegionBundleExtractionSIGTERMReplayTests.swift - The region extraction cancels through the app's transport, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A48, review A48-M2 Fix 3 (SWIFT SC4, ARCH 8). The viewer's region extraction runs
// `extract sequence --bundle` on `CLIBundleBuildRunner`, whose cancel goes through `CLISubprocessTransport`.
// ToolProcess signals the leaf's process group and tree at once, and the leaf gets
// `CLIBundleBuildRunner.terminationGracePeriod` before SIGKILL. `ExtractSequenceBundleSIGTERMTests` signals
// the leaf alone. Here the leaf runs against a stand-in bgzip that writes its process ID and sleeps, with
// one busy thread for every active processor, five times. Side C is the runner the site uses, cancelled
// once bgzip runs. Side C' is the harness's replay of the command side C recorded, cancelled at the same
// point. Each ends cancelled inside the grace, publishes nothing, leaves no stage in the project's `.tmp`,
// leaves a record that reads `cancelled` with exit status 125, and leaves no process of its tree.
//
// Phase 2.12 lane 12.12 (A48-GAP). A viewer whose document has no reference bundle stages the sequence it
// shows with `StagedSequenceInput` and runs `extract sequence <staged FASTA> <region> -o <name>.lungfishref`
// on the same runner. The second test cancels that route the same way. Its staged input stays in both
// roots, since the cancelled record names it, and side C copies it to root C' before the replay.
//
// The in-process route has no cancelled record, so side A is not run. The class launches the built
// lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier. It needs no real tool.

import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class RegionBundleExtractionSIGTERMReplayTests: XCTestCase {
    /// 60 bases of `chr1`.
    nonisolated private static let sequence = "ACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT"
    nonisolated private static let projectPath = "Project.lungfish"
    nonisolated private static let sourcePath = "Project.lungfish/Source.lungfishref"
    nonisolated private static let extractionsPath = "Project.lungfish/Extractions"
    /// The FASTA document a viewer with no reference bundle shows.
    nonisolated private static let documentPath = "Project.lungfish/Downloads/test virus.fasta"
    nonisolated private static let stagedInputPrefix = "extract-sequence-input-"
    /// How many times the extraction cancels in one busy window. Whether the leaf's handler runs before
    /// its tool's death is noticed is a race a busy machine decides, so one run proves little.
    private static let repetitions = 5

    /// What side C's own watch saw when it cancelled the runner.
    private struct TransportCancel {
        /// The time from the cancel to the runner's return, nil when the cancel was never sent.
        let elapsed: Duration?
        /// Every process the test process had started since the run began, read just before the cancel.
        let tree: [Int32]
    }

    /// Whether side C's run has ended, set once by the side.
    private final class RunEnded: Sendable {
        private let state = Mutex(false)
        func set() { state.withLock { $0 = true } }
        var isSet: Bool { state.withLock { $0 } }
    }

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!
    private var transportCancel: TransportCancel?

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "region-extraction-sigterm")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        // Each side reads its bgzip from its own root, so side C' stops the same stand-in as side C.
        harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120), environment: { Self.environment(for: $0) }
        )
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    /// Which command side C runs.
    private enum Route {
        /// A viewer with a reference bundle, `extract sequence <bundle> <region> --bundle`.
        case bundle
        /// A viewer with no reference bundle, `extract sequence <staged FASTA> <region> -o <name>.lungfishref`.
        case document
    }

    func testRegionExtractionCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        try await assertCancelsWithEveryCoreBusy(.bundle)
    }

    /// Phase 2.12 lane 12.12 (A48-GAP), the route of a viewer with no reference bundle.
    func testRegionExtractionWithoutABundleCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        try await assertCancelsWithEveryCoreBusy(.document)
    }

    private func assertCancelsWithEveryCoreBusy(_ route: Route) async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        let cancel = RouteParityCancel(
            when: { FileManager.default.fileExists(atPath: Self.bgzipPIDFile(in: $0).path) },
            record: { Self.record(in: $0)?.status.rawValue }
        )
        for repetition in 1...Self.repetitions {
            transportCancel = nil
            let runs = try await harness.run(
                in: scratch.appendingPathComponent("run-\(repetition)", isDirectory: true),
                cancel: cancel,
                fixture: { try Self.makeFixture(in: $0) },
                sideA: { _ in
                    RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process route has no cancelled record to compare")
                },
                sideC: { root in await self.sideC(root, route) }
            )

            XCTAssertEqual(
                runs.cPrime.replayedArguments.first?.contains("--bundle"), route == .bundle,
                "run \(repetition), side C': the replay runs the command of the route side C took"
            )
            let observed = try XCTUnwrap(transportCancel, "run \(repetition): side C did not run")
            let elapsed = try XCTUnwrap(observed.elapsed, "run \(repetition), side C: bgzip never ran, so nothing was cancelled")
            XCTAssertLessThanOrEqual(
                elapsed, CLIBundleBuildRunner.terminationGracePeriod,
                "run \(repetition), side C: the leaf ends inside the grace the runner gives it before SIGKILL"
            )
            await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
            await RouteParityHarness.assertCancelled(runs.cPrime, cancel)

            for run in [runs.c, runs.cPrime] {
                let label = "run \(repetition), side \(run.side)"
                XCTAssertEqual(run.outcome.end, .cancelled, "\(label): \(run.outcome.detail)")
                let record = Self.record(in: run.root)
                XCTAssertEqual(record?.status.rawValue, "cancelled", "\(label): the record beside the bundle")
                XCTAssertEqual(record?.exitStatus, 125, "\(label): the leaf exits 125")
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: Self.outputURL(in: run.root).path),
                    "\(label): a cancelled extraction publishes no bundle"
                )
                let temp = run.root.appendingPathComponent("\(Self.projectPath)/.tmp", isDirectory: true)
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
                XCTAssertEqual(entries.filter { $0.hasPrefix("extract-bundle-") }, [], "\(label): the stage is removed")
                let inputs = entries.filter { $0.hasPrefix(Self.stagedInputPrefix) }
                XCTAssertEqual(inputs.count, route == .document ? 1 : 0, "\(label): the staged inputs, \(inputs)")
                for input in inputs {
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: temp.appendingPathComponent("\(input)/sequence.fa").path),
                        "\(label): the staged FASTA the record names stays after the cancel"
                    )
                }
                let pidText = try String(contentsOf: Self.bgzipPIDFile(in: run.root), encoding: .utf8)
                let bgzip = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), label)
                await CLISIGTERMHarness.assertNoProcessLeft([bgzip])
            }
        }
    }

    // MARK: - Side C

    /// The begin helper the site calls and the runner it launches, cancelled through the runner once the
    /// stand-in bgzip runs. It keeps what its watch saw in `transportCancel`. The document route stages
    /// its FASTA before the row begins, as the site does, and copies the stage to root C' once the run ends.
    private func sideC(_ root: URL, _ route: Route) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleBuildRunner(cliURLOverride: cli)
        let source = ExtractionRequest.Source.region(chromosome: "chr1", start: 10, end: 40)
        let arguments: [String]
        var stage: URL?
        switch route {
        case .bundle:
            arguments = SequenceExtractionPipeline.cliArguments(
                source: source,
                flank5Prime: 0,
                flank3Prime: 0,
                reverseComplement: false,
                concatenateExons: false,
                sourceBundleURL: root.appendingPathComponent(Self.sourcePath, isDirectory: true),
                bundleName: "Region",
                sampleFilter: nil,
                outputBundleURL: Self.outputURL(in: root)
            )
        case .document:
            let staged: URL
            do {
                staged = try await StagedSequenceInput.writeFASTA(
                    [.init(name: "chr1", bases: Self.sequence)], fileName: "sequence.fa", prefix: Self.stagedInputPrefix,
                    projectURL: root.appendingPathComponent(Self.projectPath, isDirectory: true)
                )
            } catch {
                return RouteParitySideOutcome(end: .failed, detail: "the input was not staged: \(error)")
            }
            stage = staged.deletingLastPathComponent()
            arguments = SequenceExtractionPipeline.cliFASTAArguments(
                source: source, flank5Prime: 0, flank3Prime: 0, reverseComplement: false, concatenateExons: false,
                inputURL: staged, sequenceName: "chr1",
                sourceDocumentURL: root.appendingPathComponent(Self.documentPath), bundleName: "Region",
                outputBundleURL: Self.outputURL(in: root)
            )
        }
        var operationID: UUID?
        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "chr1:11-40", arguments: arguments, routeContext: nil, reporter: reporter
        ) { operationID = $0 }
        guard let id = operationID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let pidFile = Self.bgzipPIDFile(in: root)
        let ended = RunEnded()
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let watch = Task.detached { () -> (tree: [Int32], sent: ContinuousClock.Instant)? in
            let reached = await LungfishTestSupport.waitUntil(
                timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)
            ) {
                ended.isSet || FileManager.default.fileExists(atPath: pidFile.path)
            }
            guard reached, !ended.isSet else { return nil }
            let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
            let sent = ContinuousClock.now
            runner.cancel()
            return (tree, sent)
        }
        let end: RouteParityEnd
        let detail: String
        do {
            let result = try await runner.run(
                arguments: arguments, operationID: id, environmentAdditions: Self.environment(for: root)
            )
            end = .completed
            detail = "the runner returned \(result.message ?? "")"
        } catch is CancellationError {
            end = .cancelled
            detail = "the runner threw CancellationError"
        } catch {
            end = .failed
            detail = "\(error)"
        }
        let endedAt = ContinuousClock.now
        ended.set()
        let sent = await watch.value
        transportCancel = TransportCancel(elapsed: sent.map { endedAt - $0.sent }, tree: sent?.tree ?? [])
        let recordedCommand = reporter.items.first?.cliCommand
        if let stage {
            do {
                try RegionExtractionWithoutBundleParityReplayTests.copyStage(stage, from: root)
            } catch {
                return RouteParitySideOutcome(
                    end: .failed, detail: "the stage was not copied to root C': \(error)", recordedCommand: recordedCommand
                )
            }
        }
        return RouteParitySideOutcome(end: end, detail: detail, recordedCommand: recordedCommand)
    }

    // MARK: - Fixture

    nonisolated private static func environment(for root: URL) -> [String: String] {
        ["LUNGFISH_CONDA_ROOT": root.appendingPathComponent("conda", isDirectory: true).path]
    }

    nonisolated private static func bgzipPIDFile(in root: URL) -> URL {
        root.appendingPathComponent("conda/envs/htslib/bin/bgzip.pid")
    }

    nonisolated private static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("\(extractionsPath)/Region.lungfishref", isDirectory: true)
    }

    /// The record the leaf writes beside the bundle it would have published.
    nonisolated private static func record(in root: URL) -> ProvenanceEnvelope? {
        ProvenanceRecorder.loadEnvelope(from: root.appendingPathComponent(extractionsPath, isDirectory: true))
    }

    /// A project with a source bundle that holds a plain FASTA with its index, so reading it needs no
    /// tool, a FASTA document of the same sequence for the route with no reference bundle, and a conda root whose bgzip and samtools answer a version probe and whose bgzip sleeps on
    /// any other call after it wrote `$$` beside itself. The leaf reads the root from
    /// `LUNGFISH_CONDA_ROOT`, so the stand-ins win over a real tool.
    nonisolated private static func makeFixture(in root: URL) throws {
        let fileManager = FileManager.default
        let bundle = root.appendingPathComponent(sourcePath, isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genome, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: root.appendingPathComponent(extractionsPath, isDirectory: true), withIntermediateDirectories: true
        )
        try ">chr1\n\(sequence)\n".write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        let document = root.appendingPathComponent(documentPath)
        try fileManager.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ">chr1\n\(sequence)\n".write(to: document, atomically: true, encoding: .utf8)
        try "chr1\t\(sequence.count)\t6\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            formatVersion: "1.0",
            name: "Source",
            identifier: "org.lungfish.tests.region-extraction-sigterm",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [ChromosomeInfo(
                    name: "chr1", length: Int64(sequence.count), offset: 6,
                    lineBases: sequence.count, lineWidth: sequence.count + 1
                )]
            )
        ).save(to: bundle)

        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        echo $$ > "$(dirname "$0")/bgzip.pid"
        exec sleep 120
        """
        let samtools = """
        #!/bin/sh
        echo "samtools 1.20"
        exit 0
        """
        for (path, script) in [("conda/envs/htslib/bin/bgzip", bgzip), ("conda/envs/samtools/bin/samtools", samtools)] {
            let binary = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }
}
