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
        try writeExecutable(
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
        try writeExecutable("#!/bin/sh\nexit 0\n", to: conda.appendingPathComponent("envs/gatk-core/bin/gatk"))
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
        try writeExecutable("#!/bin/sh\n\(exports)\nexec '\(cli.path)' \"$@\"\n", to: wrapper)
        return wrapper
    }

    // MARK: - The fixture and the sides

    nonisolated static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
    }

    /// One bundle with the fixture's reference and BAM. The cancel case adds the record a first run left in
    /// `variants/gatk` (review A50 amendment 6).
    nonisolated static func writeFixture(_ root: URL, firstRunRecord: Data? = nil) throws {
        let bundle = bundleURL(in: root)
        for folder in ["genome", "alignments", "variants/gatk"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let copies = [
            ("genome.fasta", "genome/reference.fa"), ("genome.fasta.fai", "genome/reference.fa.fai"),
            ("test.paired_end.sorted.bam", "alignments/sample.bam"), ("test.paired_end.sorted.bam.bai", "alignments/sample.bam.bai"),
        ]
        for (source, target) in copies {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(source), to: bundle.appendingPathComponent(target))
        }
        let fai = try String(contentsOf: fixtures.appendingPathComponent("genome.fasta.fai"), encoding: .utf8)
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
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/opt/lungfish/conda/envs/gatk-core")
        )
    }

    /// The row's argv for the bundle in `root`, which side C runs and its row records.
    nonisolated static func rowArguments(in root: URL) -> [String] {
        CLIVariantCallingRunner.buildGATKCLIArguments(
            request: dialogRequest(in: root, trackID: "vc-unused"),
            bundleURL: bundleURL(in: root),
            alignmentTrackID: "aln-1",
            outputTrackName: trackName
        )
    }

    /// Side A. The `legacy` route's in-process run on the dialog's request, its runner a stand-in that
    /// writes what the stand-in GATK of side C writes.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        let trackID = "vc-\(UUID().uuidString.lowercased())"
        do {
            let attachment = try await InspectorViewController.runGATKVariantCallingInProcess(
                request: Self.dialogRequest(in: root, trackID: trackID),
                runner: FixtureGATKRunner(vcf: Self.fixtures.appendingPathComponent("test.vcf.gz")),
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
    private func sideC(_ root: URL, cli wrapper: URL) async -> RouteParitySideOutcome {
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
            sideA: { await self.sideA($0) },
            sideC: { await self.sideC($0, cli: wrapper) }
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
    nonisolated static let declared: [RouteParityDeclaredDifference<Case>] = {
        let execution = "differs: Sample.lungfishref/variants/gatk/.lungfish-provenance.json at "
        let attach = "differs: Sample.lungfishref/variants/gatk/vc-<UUID-1>.lungfish-provenance.json at "
        let closedBy = "2.12, the in-process GATK route leaves with its key (K3)"
        let command = "The in-process route passes no command, so its execution record names the first GATK command. "
            + "The leaf names the lungfish-cli variants call --caller gatk command it ran, which replays the run."
        let attachCommand = "The in-process attach names lungfish-app gatk-attach, which no binary runs. "
            + "The leaf's attach record names the leaf's command (review A50 F1)."
        let version = "The dialog records the lock's pinned GATK version, the leaf the version the installed GATK "
            + "answers to --version (BIO 3). Here the pin is 4.6.2.0 and the stand-in answers 4.6.1.0."
        let environment = "Each route names the gatk-core environment of its own conda root, the app's for the dialog "
            + "and the one LUNGFISH_CONDA_ROOT names for the leaf, a stand-in here."
        func entry(_ count: Int, _ id: String, _ reason: String) -> RouteParityDeclaredDifference<Case> {
            RouteParityDeclaredDifference([.haplotypeCaller: count], id, reason: reason, closedBy: closedBy)
        }
        return [
            entry(28, execution + "argv[<ANY>]", command),
            entry(1, execution + "reproducibleCommand", command),
            entry(28, attach + "argv[<ANY>]", attachCommand),
            entry(28, attach + "steps[0].argv[<ANY>]", attachCommand),
            entry(1, attach + "reproducibleCommand", attachCommand),
            entry(1, attach + "steps[0].reproducibleCommand", attachCommand),
            entry(2, execution + "<ANY>toolVersion", version),
            entry(1, execution + "tool.version", version),
            entry(1, attach + "options.explicit.variantCallerVersion.value", version),
            entry(2, "differs: Sample.lungfishref/variants/gatk/vc-<UUID-1>.db: only in <ANY>: variant_caller_version<ANY>", version),
            entry(1, "differs: Sample.lungfishref/manifest.json at variants[0].version", version),
            entry(2, "differs: Sample.lungfishref/variants/gatk/<ANY>.lungfish-provenance.json at options.explicit.condaEnvironment.value", environment),
        ]
    }()

    private func writeExecutable(_ text: String, to url: URL) throws {
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
