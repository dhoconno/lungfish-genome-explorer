// GATKVariantCallingCLIGUIParityReplayTests.swift - The GATK row's run against the replay of its recorded command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M3, decisions C4, C5, C14 and G1 of Phase 2.10 and S7 of Phase 2.11, on lane Q30's
// harness. The Call Variants dialog's GATK row runs `lungfish-cli variants call --caller gatk`. Its in-process
// route and its hidden key left in Phase 2.12 (lane 12.02, K3), so the class has no side A. The two sides
// start as copies of one bundle (the SARS-CoV-2 fixture reference and BAM).
//
// - Side C is the row's begin helper and `CLIVariantCallingRunner` on the argv `buildGATKCLIArguments` builds,
//   which launches the built `lungfish-cli variants call --caller gatk`. Its GATK is a stand-in micromamba that
//   answers `gatk --version` with its own version and copies the fixture's bgzip VCF and `.tbi` to `-O`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// C against C' declares nothing. The VCF compare is `MaskPolicy.gatk`. The cancel case runs with every core
// busy (SWIFT 3, SC4). It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier.

import CryptoKit
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
final class GATKVariantCallingCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case haplotypeCaller
    }

    /// What the stand-in GATK answers to `--version`, and what the dialog's request records (the lock's pin).
    nonisolated static let standInVersion = "4.6.1.0"
    nonisolated static let dialogVersion = "4.6.2.0"
    nonisolated static let trackName = "Sample BAM \u{2022} GATK HaplotypeCaller"
    nonisolated static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sarscov2", isDirectory: true)

    private var scratch: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "gatk-call-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - The stand-in GATK

    enum StandIn: String {
        /// Copies the fixture's VCF and index to `-O`.
        case writes
        /// Writes its process ID beside `-O` and sleeps with a child, so a cancel finds GATK at work.
        case holds
    }

    /// A storage root outside every side root whose micromamba answers the version probes and runs the
    /// GATK command as `mode` says, and the variables that point the CLI at it.
    private func standInEnvironment(_ mode: StandIn) throws -> [String: String] {
        let storage = scratch.appendingPathComponent("storage-\(mode.rawValue)", isDirectory: true)
        let conda = storage.appendingPathComponent("conda", isDirectory: true)
        let home = storage.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let lockVersion = ManagedToolLock.bundled.bootstrap?.micromamba.version ?? "2.9.0-0"
        let micromambaVersion = lockVersion.split(separator: "-").first.map(String.init) ?? lockVersion
        let work = mode == .writes
            ? "cp '\(Self.fixtures.appendingPathComponent("test.vcf.gz").path)' \"$out\"\n"
                + "cp '\(Self.fixtures.appendingPathComponent("test.vcf.gz.tbi").path)' \"$out.tbi\"\n"
            : "echo $$ > \"$(dirname \"$out\")/gatk-stand-in.pid\"\n/bin/sleep 300 &\nwait\n"
        try Self.writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "\(micromambaVersion)"; exit 0; fi
            case "$*" in
              *"gatk --version"*) echo "\(Self.standInVersion)"; exit 0 ;;
            esac
            out=""
            prev=""
            for arg in "$@"; do
              if [ "$prev" = "-O" ]; then out="$arg"; fi
              prev="$arg"
            done
            [ -n "$out" ] || exit 2
            \(work)
            """,
            to: conda.appendingPathComponent("bin/micromamba")
        )
        try Self.writeExecutable("#!/bin/sh\nexit 0\n", to: conda.appendingPathComponent("envs/gatk-core/bin/gatk"))
        return [
            "LUNGFISH_STORAGE_ROOT": storage.path,
            "LUNGFISH_CONDA_ROOT": conda.path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "CFFIXED_USER_HOME": home.path,
        ]
    }

    /// The built CLI with `environment`, since `CLIVariantCallingRunner` passes the CLI none. `exec`
    /// keeps the process, so the transport's signals reach the CLI itself.
    private func wrappedCLI(_ environment: [String: String], name: String) throws -> URL {
        let exports = environment.keys.sorted().map { "export \($0)='\(environment[$0]!)'" }.joined(separator: "\n")
        let wrapper = scratch.appendingPathComponent(name)
        try Self.writeExecutable("#!/bin/sh\n\(exports)\nexec '\(cli.path)' \"$@\"\n", to: wrapper)
        return wrapper
    }

    // MARK: - The fixture and the sides

    nonisolated static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
    }

    /// The track ID a first run's record is named for, shared by the cancel case's fixture and its assertion.
    nonisolated static let firstRunTrackID = "vc-first-run"

    /// The execution record a first run left in `variants/gatk`, named as a call into a bundle names its record.
    nonisolated static func firstRunRecordURL(in bundle: URL) -> URL {
        GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: firstRunTrackID, inBundle: bundle)
    }

    /// One bundle with the fixture's reference and BAM, or with the files of the same names in `inputs` and
    /// their sequence dictionary `genome.dict` (the live class's). The cancel case adds the record a first run
    /// left in `variants/gatk` (review A50 amendment 6).
    nonisolated static func writeFixture(_ root: URL, firstRunRecord: Data? = nil, from inputs: URL = fixtures) throws {
        let bundle = bundleURL(in: root)
        for folder in ["genome", "alignments", "variants/gatk"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        var copies = [
            ("genome.fasta", "genome/reference.fa"), ("genome.fasta.fai", "genome/reference.fa.fai"),
            ("test.paired_end.sorted.bam", "alignments/sample.bam"), ("test.paired_end.sorted.bam.bai", "alignments/sample.bam.bai"),
        ]
        if FileManager.default.fileExists(atPath: inputs.appendingPathComponent("genome.dict").path) {
            copies.append(("genome.dict", "genome/reference.dict"))
        }
        for (source, target) in copies {
            try FileManager.default.copyItem(at: inputs.appendingPathComponent(source), to: bundle.appendingPathComponent(target))
        }
        let fai = try String(contentsOf: inputs.appendingPathComponent("genome.fasta.fai"), encoding: .utf8)
        let fields = fai.split(separator: "\n").first?.split(separator: "\t").map(String.init) ?? []
        guard fields.count >= 5, let length = Int64(fields[1]), let offset = Int64(fields[2]),
              let lineBases = Int(fields[3]), let lineWidth = Int(fields[4]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try BundleManifest(
            name: "Sample",
            identifier: "sample-bundle",
            source: SourceInfo(organism: "Severe acute respiratory syndrome coronavirus 2", assembly: fields[0]),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: length,
                chromosomes: [ChromosomeInfo(name: fields[0], length: length, offset: offset, lineBases: lineBases, lineWidth: lineWidth)]
            ),
            alignments: [
                AlignmentTrackInfo(id: "aln-1", name: "Sample BAM", sourcePath: "alignments/sample.bam", indexPath: "alignments/sample.bam.bai"),
            ]
        ).save(to: bundle)
        if let firstRunRecord {
            try firstRunRecord.write(to: Self.firstRunRecordURL(in: bundle))
        }
    }

    /// The request the dialog builds for the bundle in `root` (`BAMVariantCallingDialogState.makeGATKRequest`),
    /// reference confidence NONE, the configuration's defaults, the free text of the Extra arguments field and
    /// the lock's pinned version.
    nonisolated static func dialogRequest(in root: URL, trackID: String) -> GATKPipelineExecutionRequest {
        let bundle = bundleURL(in: root)
        return .haplotypeCaller(
            configuration: GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: bundle.appendingPathComponent("genome/reference.fa"),
                inputBAMURL: bundle.appendingPathComponent("alignments/sample.bam"),
                outputVCFURL: bundle.appendingPathComponent("variants/gatk/\(trackID).vcf.gz"),
                emitReferenceConfidence: .none,
                extraArguments: ["--min-base-quality-score", "20"]
            ),
            toolVersion: dialogVersion,
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: standInCondaEnvironment)
        )
    }

    nonisolated static let standInCondaEnvironment = "/opt/lungfish/conda/envs/gatk-core"

    /// The row's argv for the bundle in `root`, which side C runs and its row records.
    nonisolated static func rowArguments(in root: URL) -> [String] {
        CLIVariantCallingRunner.buildGATKCLIArguments(
            request: dialogRequest(in: root, trackID: "vc-unused"),
            bundleURL: bundleURL(in: root),
            alignmentTrackID: "aln-1",
            outputTrackName: trackName
        )
    }

    /// Side C. The row's begin helper on the argv `buildGATKCLIArguments` builds, then `CLIVariantCallingRunner`
    /// on the built CLI. It returns the row's command, which side C' replays.
    static func sideC(_ root: URL, cli wrapper: URL) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        let arguments = Self.rowArguments(in: root)
        InspectorViewController.beginVariantCallingOperation(
            title: "Calling variants with GATK HaplotypeCaller",
            detail: "Running GATK HaplotypeCaller...",
            bundleURL: Self.bundleURL(in: root),
            cliArguments: arguments,
            routeContext: nil,
            reporter: reporter
        ) { _ in }
        let command = reporter.items.first?.cliCommand
        do {
            let result = try await CLIVariantCallingRunner(cliURLOverride: wrapper).run(arguments: arguments)
            let detail = InspectorViewController.variantCallingCompletionDetail(for: result)
            return RouteParitySideOutcome(end: .completed, detail: detail, recordedCommand: command)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
    }

    // MARK: - Cases

    /// The row's run and the replay of the command it recorded write one track and the same records. C against C'
    /// declares nothing.
    func testTheRecordedCommandReplaysToTheSameTrackAndRecords() async throws {
        let environment = try standInEnvironment(.writes)
        let wrapper = try wrappedCLI(environment, name: "lungfish-cli-writes")
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .gatk, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("call", isDirectory: true),
            fixture: { try Self.writeFixture($0) },
            sideC: { await Self.sideC($0, cli: wrapper) }
        )
        let result = try harness.evaluate(Case.haplotypeCaller, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(Case.haplotypeCaller)")
        XCTAssertEqual(runs.c.outcome.end, .completed, runs.c.outcome.detail)
        XCTAssertEqual(runs.c.outcome.detail, "Created variant track \(Self.trackName)", "the row ends on the words it ended on before")
        XCTAssertEqual(runs.cPrime.outcome.end, .completed, runs.cPrime.outcome.detail)

        // The stand-in GATK's answer to --version reaches side C's records, database and track (BIO 3,
        // review A50 R1 and amendment 5).
        let bundleC = Self.bundleURL(in: runs.c.root)
        let track = try XCTUnwrap(BundleManifest.load(from: bundleC).variants.first)
        XCTAssertEqual(track.version, Self.standInVersion)
        // The run's own record, named by the builder the CLI and the attach service use (lane 13.16). The runs of
        // a bundle no longer share `variants/gatk/.lungfish-provenance.json`.
        let executionURL = GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: track.id, inBundle: bundleC)
        let execution = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: executionURL)).legacyWorkflowRun()
        XCTAssertEqual(execution.steps.first?.toolVersion, Self.standInVersion)
        let databasePath = try XCTUnwrap(track.databasePath)
        let attachURL = bundleC.appendingPathComponent(
            databasePath.replacingOccurrences(of: ".db", with: ProvenanceRecorder.provenanceFilename.hasPrefix(".") ? ProvenanceRecorder.provenanceFilename : ".\(ProvenanceRecorder.provenanceFilename)")
        )
        let attach = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: attachURL)).legacyWorkflowRun()
        XCTAssertEqual(attach.parameters["variantCallerVersion"]?.stringValue, Self.standInVersion)
        XCTAssertEqual(
            VariantDatabase.metadataValue(at: bundleC.appendingPathComponent(databasePath), key: "variant_caller_version"),
            Self.standInVersion
        )
        // ARCH check 3. Every input of the record the completion event names still has the digest it
        // recorded, the half of `provenance verify` an unsigned record can pass. The signature half needs a
        // signing key, which the signing replay classes set up.
        let inputs = try XCTUnwrap(attach.steps.first).inputs
        XCTAssertEqual(inputs.count, 3, "the VCF, its index and the execution record")
        for input in inputs {
            let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: input.path)))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, input.sha256, "the recorded digest of \(input.path)")
        }
    }

    /// The limit of review A50 R1 and Notes 1 was declared and pinned here, and lane 13.16 closed it. Every GATK
    /// run in a bundle used to write `variants/gatk/.lungfish-provenance.json`, so a second run replaced the
    /// execution record the first track's attach record names as an input, and `provenance verify` of the first
    /// track found one changed input. Each run now writes `variants/gatk/<track>.gatk-run.lungfish-provenance.json`
    /// (`GATKPipelineExecutionRequest.bundleRunRecordURL`), which turns the last assertion around. A second run
    /// writes a record of its own name, the first track keeps its record byte for byte, and every input digest
    /// its attach record holds still matches.
    func testASecondRunLeavesTheExecutionRecordTheFirstTrackNamesAsItWas() async throws {
        let wrapper = try wrappedCLI(try standInEnvironment(.writes), name: "lungfish-cli-twice")
        let root = scratch.appendingPathComponent("twice", isDirectory: true)
        try Self.writeFixture(root)
        let bundle = Self.bundleURL(in: root)
        let firstOutcome = await Self.sideC(root, cli: wrapper)
        XCTAssertEqual(firstOutcome.end, .completed, "run 1: \(firstOutcome.detail)")
        let firstTrack = try XCTUnwrap(BundleManifest.load(from: bundle).variants.first, "the first run's track")
        let firstRecordURL = GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: firstTrack.id, inBundle: bundle)
        let firstRecord = try Data(contentsOf: firstRecordURL)
        let secondOutcome = await Self.sideC(root, cli: wrapper)
        XCTAssertEqual(secondOutcome.end, .completed, "run 2: \(secondOutcome.detail)")
        let tracks = try BundleManifest.load(from: bundle).variants
        XCTAssertEqual(tracks.count, 2, "each run attaches its own track")
        let secondTrack = try XCTUnwrap(tracks.first { $0.id != firstTrack.id }, "the second run's track")
        let secondRecordURL = GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: secondTrack.id, inBundle: bundle)
        XCTAssertNotEqual(secondRecordURL, firstRecordURL, "each run names a record of its own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRecordURL.path), "the second run wrote its own execution record")
        XCTAssertEqual(try Data(contentsOf: firstRecordURL), firstRecord, "the first track's execution record is as run 1 left it")
        let databasePath = try XCTUnwrap(firstTrack.databasePath, "the first run's track database")
        let attachURL = bundle.appendingPathComponent(
            databasePath.replacingOccurrences(of: ".db", with: ProvenanceRecorder.provenanceFilename)
        )
        let attach = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: attachURL)).legacyWorkflowRun()
        let inputs = try XCTUnwrap(attach.steps.first).inputs
        XCTAssertEqual(inputs.count, 3, "the VCF, its index and the execution record")
        XCTAssertTrue(
            inputs.contains { URL(fileURLWithPath: $0.path).lastPathComponent == firstRecordURL.lastPathComponent },
            "the first track's attach record names the first run's own execution record"
        )
        let changed = try inputs.filter { input in
            let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: input.path)))
                .map { String(format: "%02x", $0) }.joined()
            return digest != input.sha256
        }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(changed, [], "no input of the first track's attach record changed under the second run")
    }

    /// SWIFT 3 and SC4, review A50 R3 and amendment 6. The row's Cancel reaches the leaf through the
    /// transport with every core busy, three times. Sides C and C' each exit 125 inside the grace, leave a
    /// cancelled record and no process of their tree, attach no track, and leave the execution record a
    /// first run wrote in `variants/gatk` as it was.
    func testTheCLIRouteCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        let environment = try standInEnvironment(.holds)
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .gatk, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        let firstRun = Data("{\"first-run\":true}\n".utf8)
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        let cancel = RouteParityCancel(
            when: { FileManager.default.fileExists(atPath: Self.bundleURL(in: $0).appendingPathComponent("variants/gatk/gatk-stand-in.pid").path) },
            record: { try Self.cancelledRecordStatus(in: $0) }
        )
        let cli = cli!
        for repetition in 1...3 {
            let runs = try await runCancelled(
                harness,
                in: scratch.appendingPathComponent("cancel-\(repetition)", isDirectory: true),
                cancel: cancel,
                firstRun: firstRun,
                sideC: { root in
                    let reporter = RecordingOperationReporter()
                    let arguments = Self.rowArguments(in: root)
                    InspectorViewController.beginVariantCallingOperation(
                        title: "Calling variants with GATK HaplotypeCaller",
                        detail: "Running GATK HaplotypeCaller...",
                        bundleURL: Self.bundleURL(in: root),
                        cliArguments: arguments,
                        routeContext: nil,
                        reporter: reporter
                    ) { _ in }
                    let run = await RouteParityHarness.runCLI(
                        cli, arguments: arguments, timeout: .seconds(120), environment: environment, cancelWhen: { cancel.isReached(root) }
                    )
                    return RouteParitySideOutcome(
                        end: run.end, detail: run.detail, recordedCommand: reporter.items.first?.cliCommand, cancel: run.cancel
                    )
                }
            )
            for run in [runs.c, runs.cPrime] {
                XCTAssertEqual(run.outcome.end, .cancelled, "run \(repetition), side \(run.side): \(run.outcome.detail)")
                await RouteParityHarness.assertCancelled(run, cancel)
                let bundle = Self.bundleURL(in: run.root)
                XCTAssertEqual(try BundleManifest.load(from: bundle).variants.count, 0, "run \(repetition), side \(run.side) attaches no track")
                XCTAssertEqual(
                    try Data(contentsOf: Self.firstRunRecordURL(in: bundle)), firstRun,
                    "run \(repetition), side \(run.side): the first run's execution record is as it was"
                )
            }
        }
    }

    /// The status of the one record under the bundle's `provenance/cancelled`, or nil when there is none.
    nonisolated static func cancelledRecordStatus(in root: URL) throws -> String? {
        let folder = bundleURL(in: root).appendingPathComponent("provenance/cancelled", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }
        guard names.count == 1, let name = names.first else { return nil }
        return try ProvenanceEnvelopeReader.load(fromSidecar: folder.appendingPathComponent(name))?.status.rawValue
    }

    /// The two sides of a cancelled case, with no side A. Root C holds the fixture and the record a first run left,
    /// root C' starts as a copy of it, `sideC` runs on root C, and the harness replays the command side C recorded
    /// on root C', cancelled at the same point.
    private func runCancelled(
        _ harness: RouteParityHarness,
        in caseRoot: URL,
        cancel: RouteParityCancel,
        firstRun: Data,
        sideC: (URL) async throws -> RouteParitySideOutcome
    ) async throws -> (c: RouteParitySideRun, cPrime: RouteParitySideRun) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: caseRoot)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: caseRoot)
        try fileManager.createDirectory(at: rootC, withIntermediateDirectories: true)
        try Self.writeFixture(rootC, firstRunRecord: firstRun)
        try fileManager.copyItem(at: rootC, to: rootCPrime)
        let runC = RouteParitySideRun(side: .c, root: rootC, outcome: try await sideC(rootC))
        return (runC, await harness.replay(of: runC, in: rootCPrime, cancel: cancel))
    }

    nonisolated static func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
