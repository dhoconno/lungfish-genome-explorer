// GATKVariantCallingCLIGUIParityReplayTests.swift - The GATK row in process against `variants call --caller gatk`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M3, decisions C4, C5, C14 and G1 of Phase 2.10 and S7 of Phase 2.11, on lane Q30's
// harness. The Call Variants dialog's GATK row runs one of two routes, which the hidden key
// `GATKVariantCallingRoute` picks. The three sides start as copies of one bundle (the SARS-CoV-2 fixture
// reference and BAM).
//
// - Side A is the `legacy` route, `InspectorViewController.runGATKVariantCallingInProcess` on the
//   dialog's request, with a stand-in runner that writes the fixture's bgzip VCF and `.tbi` at `-O`.
// - Side C is the `cli` route, the row's begin helper and `CLIVariantCallingRunner` on the argv
//   `buildGATKCLIArguments` builds, which launches the built `lungfish-cli variants call --caller gatk`.
//   Its GATK is a stand-in micromamba that answers `gatk --version` with its own version and copies the
//   same two files to `-O`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C declares each difference with `<ANY>` and BIO's reason (review A50 R1). C against C' declares
// none. The VCF compare is `MaskPolicy.gatk`. The cancel case runs with every core busy (SWIFT 3, SC4).
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier.

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
            try firstRunRecord.write(to: bundle.appendingPathComponent("variants/gatk/\(ProvenanceRecorder.provenanceFilename)"))
        }
    }

    /// The request the dialog builds for the bundle in `root` (`BAMVariantCallingDialogState.makeGATKRequest`),
    /// reference confidence NONE, the configuration's defaults, the free text of the Extra arguments field and
    /// the lock's pinned version.
    /// The live class passes the version the installed GATK answers and its conda root's environment.
    nonisolated static func dialogRequest(
        in root: URL, trackID: String, toolVersion: String = dialogVersion, condaEnvironment: String = standInCondaEnvironment
    ) -> GATKPipelineExecutionRequest {
        let bundle = bundleURL(in: root)
        return .haplotypeCaller(
            configuration: GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: bundle.appendingPathComponent("genome/reference.fa"),
                inputBAMURL: bundle.appendingPathComponent("alignments/sample.bam"),
                outputVCFURL: bundle.appendingPathComponent("variants/gatk/\(trackID).vcf.gz"),
                emitReferenceConfidence: .none,
                extraArguments: ["--min-base-quality-score", "20"]
            ),
            toolVersion: toolVersion,
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: condaEnvironment)
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

    /// Side A. The `legacy` route's in-process run on the dialog's request with `runner`, a stand-in that
    /// writes what the stand-in GATK of side C writes, or the managed GATK in the live class.
    static func sideA(
        _ root: URL,
        runner: some GATKCommandRunning,
        toolVersion: String = dialogVersion,
        condaEnvironment: String = standInCondaEnvironment
    ) async -> RouteParitySideOutcome {
        let trackID = "vc-\(UUID().uuidString.lowercased())"
        do {
            let attachment = try await InspectorViewController.runGATKVariantCallingInProcess(
                request: dialogRequest(in: root, trackID: trackID, toolVersion: toolVersion, condaEnvironment: condaEnvironment),
                runner: runner,
                bundleURL: Self.bundleURL(in: root),
                alignmentTrackID: "aln-1",
                outputTrackID: trackID,
                outputTrackName: Self.trackName
            )
            return RouteParitySideOutcome(end: .completed, detail: "Created variant track \(attachment.trackInfo.name)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The row's begin helper on the argv the `cli` route builds, then `CLIVariantCallingRunner`
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

    func testTheCLIRouteWritesWhatTheInProcessRouteWrote() async throws {
        let environment = try standInEnvironment(.writes)
        let wrapper = try wrappedCLI(environment, name: "lungfish-cli-writes")
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .gatk, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        let result = try await harness.assertParity(
            Case.haplotypeCaller,
            declared: Self.declared,
            in: scratch.appendingPathComponent("call", isDirectory: true),
            fixture: { try Self.writeFixture($0) },
            sideA: { await Self.sideA($0, runner: FixtureGATKRunner(vcf: Self.fixtures.appendingPathComponent("test.vcf.gz"))) },
            sideC: { await Self.sideC($0, cli: wrapper) }
        )
        XCTAssertEqual(result.runs.a.outcome.end, .completed, result.runs.a.outcome.detail)
        XCTAssertEqual(result.runs.c.outcome.end, .completed, result.runs.c.outcome.detail)
        XCTAssertEqual(result.runs.c.outcome.detail, "Created variant track \(Self.trackName)", "the row ends on the words it ended on before")
        XCTAssertEqual(result.runs.cPrime.outcome.end, .completed, result.runs.cPrime.outcome.detail)

        // The stand-in GATK's answer to --version reaches side C's records, database and track (BIO 3,
        // review A50 R1 and amendment 5).
        let bundleC = Self.bundleURL(in: result.runs.c.root)
        let track = try XCTUnwrap(BundleManifest.load(from: bundleC).variants.first)
        XCTAssertEqual(track.version, Self.standInVersion)
        let executionURL = bundleC.appendingPathComponent("variants/gatk/\(ProvenanceRecorder.provenanceFilename)")
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

    /// The limit of review A50 R1 and Notes 1, declared and pinned. Every GATK run in a bundle writes
    /// `variants/gatk/.lungfish-provenance.json`, so a second run replaces the execution record the first
    /// track's attach record names as an input. The first track's VCF and index keep the digests its attach
    /// record holds and the execution record does not, so `provenance verify` of the first track finds one
    /// changed input. ARCH objection 5 of 2.10 keeps the layout in 2.11. A per-run record name (2.12, after a
    /// BIO and ARCH ruling) turns the last assertion around, and the test then pins the fix.
    func testASecondRunReplacesTheExecutionRecordTheFirstTrackNames() async throws {
        let wrapper = try wrappedCLI(try standInEnvironment(.writes), name: "lungfish-cli-twice")
        let root = scratch.appendingPathComponent("twice", isDirectory: true)
        try Self.writeFixture(root)
        for run in 1...2 {
            let outcome = await Self.sideC(root, cli: wrapper)
            XCTAssertEqual(outcome.end, .completed, "run \(run): \(outcome.detail)")
        }
        let bundle = Self.bundleURL(in: root)
        let tracks = try BundleManifest.load(from: bundle).variants
        XCTAssertEqual(tracks.count, 2, "each run attaches its own track")
        let databasePath = try XCTUnwrap(tracks.first { $0.name == Self.trackName }?.databasePath, "the first run's track")
        let attachURL = bundle.appendingPathComponent(
            databasePath.replacingOccurrences(of: ".db", with: ProvenanceRecorder.provenanceFilename)
        )
        let attach = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: attachURL)).legacyWorkflowRun()
        let inputs = try XCTUnwrap(attach.steps.first).inputs
        XCTAssertEqual(inputs.count, 3, "the VCF, its index and the execution record")
        let changed = try inputs.filter { input in
            let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: input.path)))
                .map { String(format: "%02x", $0) }.joined()
            return digest != input.sha256
        }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(changed, [ProvenanceRecorder.provenanceFilename], "only the shared execution record changed under the first track")
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
            let runs = try await harness.run(
                in: scratch.appendingPathComponent("cancel-\(repetition)", isDirectory: true),
                cancel: cancel,
                fixture: { try Self.writeFixture($0, firstRunRecord: firstRun) },
                sideA: { _ in RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process route writes no cancelled record") },
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
                    try Data(contentsOf: bundle.appendingPathComponent("variants/gatk/\(ProvenanceRecorder.provenanceFilename)")), firstRun,
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

    /// Every A against C difference, with BIO's reason (review A50 R1). Each closes in 2.12, when the
    /// in-process route leaves with its key (K3).
    nonisolated static let declared: [RouteParityDeclaredDifference<Case>] = commandDifferences + {
        let version = "The dialog records the lock's pinned GATK version, the leaf the version the installed GATK "
            + "answers to --version (BIO 3). Here the pin is 4.6.2.0 and the stand-in answers 4.6.1.0."
        let environment = "Each route names the gatk-core environment of its own conda root, the app's for the dialog "
            + "and the one LUNGFISH_CONDA_ROOT names for the leaf, a stand-in here."
        return [
            declaredEntry(2, executionRecord + "<ANY>toolVersion", version),
            declaredEntry(1, executionRecord + "tool.version", version),
            declaredEntry(1, attachRecord + "options.explicit.variantCallerVersion.value", version),
            declaredEntry(2, "differs: Sample.lungfishref/variants/gatk/vc-<UUID-1>.db: only in <ANY>: variant_caller_version<ANY>", version),
            declaredEntry(1, "differs: Sample.lungfishref/manifest.json at variants[0].version", version),
            declaredEntry(2, "differs: Sample.lungfishref/variants/gatk/<ANY>.lungfish-provenance.json at options.explicit.condaEnvironment.value", environment),
        ]
    }()

    /// The differences of the two routes' commands. They hold on real GATK too, so the live class declares them.
    nonisolated static let commandDifferences: [RouteParityDeclaredDifference<Case>] = {
        let command = "The in-process route passes no command, so its execution record names the first GATK command. "
            + "The leaf names the lungfish-cli variants call --caller gatk command it ran, which replays the run."
        let attachCommand = "The in-process attach names lungfish-app gatk-attach, which no binary runs. "
            + "The leaf's attach record names the leaf's command (review A50 F1)."
        return [
            declaredEntry(28, executionRecord + "argv[<ANY>]", command),
            declaredEntry(1, executionRecord + "reproducibleCommand", command),
            declaredEntry(28, attachRecord + "argv[<ANY>]", attachCommand),
            declaredEntry(28, attachRecord + "steps[0].argv[<ANY>]", attachCommand),
            declaredEntry(1, attachRecord + "reproducibleCommand", attachCommand),
            declaredEntry(1, attachRecord + "steps[0].reproducibleCommand", attachCommand),
        ]
    }()

    nonisolated static let executionRecord = "differs: Sample.lungfishref/variants/gatk/.lungfish-provenance.json at "
    nonisolated static let attachRecord = "differs: Sample.lungfishref/variants/gatk/vc-<UUID-1>.lungfish-provenance.json at "

    nonisolated static func declaredEntry(_ count: Int, _ id: String, _ reason: String) -> RouteParityDeclaredDifference<Case> {
        RouteParityDeclaredDifference(
            [.haplotypeCaller: count], id, reason: reason, closedBy: "2.12, the in-process GATK route leaves with its key (K3)"
        )
    }

    nonisolated static func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// Answers the GATK command as the stand-in GATK of side C does. It copies the fixture's bgzip VCF and its
/// `.tbi` to `-O`.
private struct FixtureGATKRunner: GATKCommandRunning {
    let vcf: URL

    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        guard let flag = command.arguments.firstIndex(of: "-O"), command.arguments.indices.contains(flag + 1) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let output = URL(fileURLWithPath: command.arguments[flag + 1])
        try FileManager.default.copyItem(at: vcf, to: output)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: vcf.path + ".tbi"), to: URL(fileURLWithPath: output.path + ".tbi")
        )
        return GATKCommandExecutionResult(exitCode: 0, stdout: "", stderr: "", wallTime: 0)
    }
}
