// ViralReconRunRecordTests.swift - What a launched Viral Recon run records against what its engine ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B31. Each run goes through `workflow run nf-core/viralrecon` in process on
// `ViralReconLaunchedRun.Runner`, which records the launch the engine got and writes Nextflow's own debug log in
// the launch folder, so every record fact can be checked against the launch it describes.

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ViralReconRunRecordTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-run-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Q33 fix 8 (BIO 4, ARCH 2). The run bundle's manifest records the command the engine launched, the resource-limit
    /// `-c` file and the work folder among it, and not the `--max_cpus` and `--max_memory` that the launch turns into
    /// `process.resourceLimits` and never passes.
    func testTheManifestRecordsTheCommandTheEngineLaunched() async throws {
        let run = try await ViralReconLaunchedRun.run(in: root)
        let launch = try XCTUnwrap(run.runner.launches.first, "the run launched nothing")
        let manifest = try NFCoreRunBundleStore.read(from: run.bundle)
        XCTAssertEqual(manifest.commandPreview, (["nextflow"] + launch.arguments).map(shellEscape).joined(separator: " "))
        XCTAssertFalse(manifest.commandPreview.contains("--max_cpus"), manifest.commandPreview)
        XCTAssertTrue(manifest.commandPreview.contains("lungfish-resource-limits.config"), manifest.commandPreview)
        XCTAssertEqual(manifest.params["max_cpus"], "2", "the limits the user chose stay among the parameters")
    }

    /// 2.9 R1 and R2. The step names a release tag only for a revision that tag names, the lock's tag for the pin's own
    /// commit or tag, and a release a user names with `--version` as itself. A branch or another commit names none.
    func testTheStepNamesATagOnlyForARevisionThatTagNames() throws {
        let pin = NextflowPipelinePin(
            pipelineID: "nf-core-viralrecon", repository: "nf-core/viralrecon",
            revision: "395079f1d24dce731ac22e03d7a5e71f110103fc", releaseVersion: "3.0.0")
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon"))
        func tag(_ version: String, _ pin: NextflowPipelinePin?) -> String? {
            NFCoreRunRequest(
                workflow: workflow, version: version, executor: .docker, inputURLs: [],
                outputDirectory: URL(fileURLWithPath: "/tmp/results")
            ).viralReconReleaseVersion(pin: pin)
        }
        XCTAssertEqual(tag(pin.revision, pin), "3.0.0")
        XCTAssertEqual(tag("3.0.0", pin), "3.0.0")
        XCTAssertEqual(tag("3.1.0", pin), "3.1.0")
        XCTAssertEqual(tag("3.1.0", nil), "3.1.0")
        XCTAssertNil(tag("dev", pin))
        XCTAssertNil(tag("0123456789abcdef0123456789abcdef01234567", pin))
    }

    /// Phase 2.10 N2. A run that names no `--version` launches the commit the lock pins with the legacy syntax parser
    /// its tag 3.0.0 needs, and its record and manifest name that commit as the revision and the tag as the release.
    func testABareRunLaunchesThePinnedCommitWithItsTagsEnvironment() async throws {
        let pin = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        let run = try await ViralReconLaunchedRun.run(in: root, debugLog: nil, version: nil)
        let launch = try XCTUnwrap(run.runner.launches.first, "the run launched nothing")
        let revision = try XCTUnwrap(launch.arguments.firstIndex(of: "-r")).advanced(by: 1)
        XCTAssertEqual(launch.arguments[revision], pin.revision, "-r takes the commit")
        XCTAssertEqual(launch.environment["NXF_SYNTAX_PARSER"], "v1", "the commit of tag 3.0.0 keeps the tag's parser")
        let step = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle)?.steps.first)
        XCTAssertEqual(step.toolVersion, pin.revision)
        XCTAssertEqual(step.githubReleaseVersion, "3.0.0")
        XCTAssertNil(step.resolvedOptions["resolvedCommit"], "the revision is the full commit already")
        let manifest = try NFCoreRunBundleStore.read(from: run.bundle)
        XCTAssertEqual([manifest.version, manifest.workflowPinnedVersion], [pin.revision, pin.revision])
        XCTAssertEqual(manifest.workflowGithubReleaseVersion, "3.0.0", "the release is the tag, never the commit")
    }

    /// N3, absent beats a guess. A debug log that names no version, with no probe to ask, leaves the version out, and a
    /// log with no `Launching` line leaves the commit out.
    func testALogNamingNoVersionLeavesTheVersionAbsent() async throws {
        let run = try await ViralReconLaunchedRun.run(in: root, debugLog: [ViralReconLaunchedRun.debugLogLines[0]])
        let step = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle)?.steps.first)
        XCTAssertNil(step.resolvedOptions["nextflowVersion"])
        XCTAssertNil(step.resolvedOptions["resolvedCommit"])
        XCTAssertEqual(step.resolvedOptions["pipelineSource"], .string("remote"))
    }

    /// The lines N3 reads, as Nextflow 26.04.6 wrote them in Q35's V1 and as its `-version` and `-v` print them on this
    /// Mac's managed engine. The launcher's argv line names no version.
    func testTheVersionAndCommitAreReadFromNextflowsOwnLines() {
        let lines = ViralReconLaunchedRun.debugLogLines
        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inDebugLog: lines.joined(separator: "\n")), "26.04.6")
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inDebugLog: lines[0] + " N E X T F L O W  ~  version 1.0.0"))
        XCTAssertEqual(NextflowRecordFacts.launchedCommit(inLog: lines.joined(separator: "\n")), "395079f1d2")
        let banner = "\n      N E X T F L O W\n      version 26.04.6 build 12646\n      created 09-07-2026 18:49 UTC (13:49 CDT)\n"
        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inVersionOutput: banner), "26.04.6")
        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inVersionOutput: "nextflow version 26.04.6.12646\n"), "26.04.6")
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inVersionOutput: "N E X T F L O W  ~  version 26.04.6\n"))
    }

    /// N3 with QA's check. A stand-in engine that writes no debug log answers `-version` as 25.04.6 and prints another
    /// version on its console. The probe runs the very command the launch ran, and the record names the probe's version.
    func testTheProbeAsksThePathTheEngineLaunched() async throws {
        let script = root.appendingPathComponent("stand-in nextflow.sh")
        try """
        #!/bin/sh
        if [ "$1" = "-version" ]; then printf '\\n      N E X T F L O W\\n      version 25.04.6 build 5954\\n'; exit 0; fi
        while [ $# -gt 0 ]; do [ "$1" = "--outdir" ] && mkdir -p "$2"; shift; done
        echo 'N E X T F L O W  ~  version 99.99.99'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let launch = WorkflowEngineLaunch(
            executableURL: URL(fileURLWithPath: "/bin/sh"), argumentPrefix: [script.path],
            environment: ["PATH": "/usr/bin:/bin"])
        let runner = ProbingRunner(inner: ProcessNFCoreWorkflowProcessRunner(homeDirectory: root, resolveLaunch: { _, _ in launch }))

        let run = try await ViralReconLaunchedRun.run(in: root.appendingPathComponent("run"), using: runner)

        let probe = try XCTUnwrap(runner.probes.first, "the run asked no version")
        XCTAssertEqual(runner.probes.count, 1)
        XCTAssertEqual(probe.command, ["/bin/sh", script.path])
        let log = try String(contentsOf: run.bundle.appendingPathComponent("logs/nextflow.log"), encoding: .utf8)
        let launched = try XCTUnwrap(log.split(separator: "\n").first { $0.hasPrefix("nextflow_command: ") })
        XCTAssertTrue(launched.hasPrefix("nextflow_command: " + probe.command.map(shellEscape).joined(separator: " ") + " "), String(launched))
        let step = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle)?.steps.first)
        XCTAssertEqual(step.resolvedOptions["nextflowVersion"], .string("25.04.6"), "the probe's, never the console's")
    }

    /// B31 review fix 2, BIO 8. The reference files a caller names with `fasta`, `gff` and `primer_fasta` are inputs of
    /// the step, as Q35's V1 launch passed them. They follow the samplesheet and the reads in the order the record lists
    /// its parameters, the FASTA, the GFF, the primer BED, then the primer FASTA, and each carries its file's SHA-256.
    func testTheReferenceFilesAreInputsWithTheirDigests() async throws {
        let references = root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let fasta = references.appendingPathComponent("MN908947.3.fasta")
        let gff = references.appendingPathComponent("MN908947.3.gff")
        let primerFASTA = references.appendingPathComponent("primers.fasta")
        try ">MN908947.3\nACGTACGTACGT\n".write(to: fasta, atomically: true, encoding: .utf8)
        try "##gff-version 3\nMN908947.3\tstand-in\tgene\t1\t12\t.\t+\t.\tID=gene1\n".write(to: gff, atomically: true, encoding: .utf8)
        try ">nCoV-2019_1_LEFT\nACGTACGTAC\n".write(to: primerFASTA, atomically: true, encoding: .utf8)

        let run = try await ViralReconLaunchedRun.run(in: root, extraArguments: [
            "--param", "fasta=\(fasta.path)", "--param", "gff=\(gff.path)", "--param", "primer_fasta=\(primerFASTA.path)",
        ])

        let step = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle)?.steps.first)
        XCTAssertEqual(
            step.inputs.map(\.path),
            ([run.samplesheet] + run.reads + [fasta, gff, run.primerBED, primerFASTA]).map(\.path)
        )
        for input in step.inputs {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: input.path))
            XCTAssertEqual(input.checksumSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), input.path)
        }
    }

    /// Q35 V3, BIO 2.2. A reference bundle that `fetch genome` wrote keeps its annotation only in
    /// `annotations/annotations.db`, and the run exports it as `inputs/reference/annotations.gff` for `--gff`. The engine
    /// reads those bytes, and they set SnpEff's gene names, so the export is an input of the step in the `gff` slot, after
    /// the FASTA and before the primer BED, with the digest that `stagedAnnotation.sha256` holds. Nothing else about the
    /// step's inputs moves, and the caller's `params` still hold no `gff`.
    func testAnExportedAnnotationIsAnInputWithItsDigest() async throws {
        let reference = root.appendingPathComponent("Downloads/MN908947.3.lungfishref", isDirectory: true)
        let fasta = try await writeFetchedReferenceBundle(at: reference)

        let run = try await ViralReconLaunchedRun.run(in: root, extraArguments: ["--param", "fasta=\(fasta.path)"])

        let exported = run.bundle.appendingPathComponent("inputs/reference/annotations.gff")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path), "the run exported no GFF")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle))
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(
            step.inputs.map(\.path),
            ([run.samplesheet] + run.reads + [fasta, exported, run.primerBED]).map(\.path),
            "the samplesheet, the reads, the FASTA, the exported GFF and the primer BED, in that order"
        )
        let staged = try XCTUnwrap(
            record.options.explicit[ViralReconAnnotationStaging.provenanceKey]?.dictionaryValue, "no staged annotation in the record")
        let stagedDigest = try XCTUnwrap(staged["sha256"]?.stringValue)
        let gff = try XCTUnwrap(step.inputs.first { $0.path == exported.path })
        XCTAssertEqual(gff.checksumSHA256, stagedDigest, "the input carries stagedAnnotation.sha256")
        XCTAssertEqual(gff.checksumSHA256, SHA256.hash(data: try Data(contentsOf: exported)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(gff.format, .gff3)
        XCTAssertEqual(gff.role, .input)
        XCTAssertEqual(gff.fileSize, UInt64(try Data(contentsOf: exported).count))
        let launch = try XCTUnwrap(run.runner.launches.first, "the run launched nothing")
        let flag = try XCTUnwrap(launch.arguments.firstIndex(of: "--gff"), "the engine got no --gff")
        XCTAssertEqual(launch.arguments[flag + 1], exported.path, "the engine read the bytes the record names")
        XCTAssertNil(try NFCoreRunBundleStore.read(from: run.bundle).params["gff"], "the records keep the caller's parameters")
    }

    /// The other half of BIO 2.2, unchanged. A GFF3 the caller names stays listed as the caller gave it, and its staged
    /// `.gff` copy, which the run bundle holds only to satisfy the schema's file name, is not a second input.
    func testACallersGFF3IsListedAsTheCallerGaveIt() async throws {
        let gff3 = root.appendingPathComponent("references/genes.gff3")
        try FileManager.default.createDirectory(at: gff3.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "##gff-version 3\nMN908947.3\tGenbank\tgene\t5\t40\t.\t+\t.\tID=gene-S;Name=S\n".write(to: gff3, atomically: true, encoding: .utf8)

        let run = try await ViralReconLaunchedRun.run(in: root, extraArguments: ["--param", "gff=\(gff3.path)"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: run.bundle.appendingPathComponent("inputs/reference/genes.gff").path))
        let step = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle)?.steps.first)
        XCTAssertEqual(step.inputs.map(\.path), ([run.samplesheet] + run.reads + [gff3, run.primerBED]).map(\.path))
    }

    /// A `.lungfishref` as `fetch genome` leaves it, its FASTA at `genome/sequence.fa` and its annotation only in
    /// `annotations/annotations.db`, imported from a GFF3 that is then deleted. Returns the FASTA.
    private func writeFetchedReferenceBundle(at bundleURL: URL) async throws -> URL {
        let fasta = bundleURL.appendingPathComponent("genome/sequence.fa")
        try FileManager.default.createDirectory(at: fasta.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ">MN908947.3\n\(String(repeating: "ACGT", count: 20))\n".write(to: fasta, atomically: true, encoding: .utf8)
        let gff3 = root.appendingPathComponent("fetch-temp/annotations.gff3")
        try FileManager.default.createDirectory(at: gff3.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("##gff-version 3\nMN908947.3\tGenbank\tgene\t5\t40\t.\t+\t.\tID=gene-S;Name=S\n"
            + "MN908947.3\tGenbank\tCDS\t5\t40\t.\t+\t0\tID=cds-S;Parent=gene-S;Name=S\n")
            .write(to: gff3, atomically: true, encoding: .utf8)
        let database = bundleURL.appendingPathComponent("annotations/annotations.db")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await AnnotationDatabase.createFromGFF3(gffURL: gff3, outputURL: database, chromosomeSizes: [("MN908947.3", 80)])
        try FileManager.default.removeItem(at: gff3)
        try BundleManifest(
            name: "MN908947.3",
            identifier: "org.lungfish.MN908947.3",
            source: SourceInfo(organism: "SARS-CoV-2", assembly: "MN908947.3"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 80, chromosomes: []),
            annotations: [AnnotationTrackInfo(
                id: "annotations", name: "genes", path: "annotations/annotations.db",
                databasePath: "annotations/annotations.db", annotationType: .custom, featureCount: 2)]
        ).save(to: bundleURL)
        return fasta
    }

    /// The A30 seam ruling, deviation 1. Once the engine launched, the manifest names the engine's own log beside its
    /// tails, and each log it names holds what its key says: `nextflowLogPath` the command that ran and the engine's
    /// output as the engine streamed it, `stdoutLogPath` the tail of that output and `stderrLogPath` of its errors.
    func testTheManifestNamesTheEnginesOwnLogOnceTheEngineLaunched() async throws {
        let script = root.appendingPathComponent("stand-in nextflow.sh")
        try """
        #!/bin/sh
        while [ $# -gt 0 ]; do [ "$1" = "--outdir" ] && mkdir -p "$2"; shift; done
        echo 'stand-in engine output'
        echo 'stand-in engine warning' >&2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let launch = WorkflowEngineLaunch(
            executableURL: URL(fileURLWithPath: "/bin/sh"), argumentPrefix: [script.path],
            environment: ["PATH": "/usr/bin:/bin"])
        let runner = ProbingRunner(inner: ProcessNFCoreWorkflowProcessRunner(homeDirectory: root, resolveLaunch: { _, _ in launch }))

        let run = try await ViralReconLaunchedRun.run(in: root.appendingPathComponent("run"), using: runner)

        let manifest = try Self.manifestObject(in: run.bundle)
        func log(_ key: String) throws -> String {
            let path = try XCTUnwrap(manifest[key] as? String, "the manifest names no \(key)")
            return try String(contentsOf: run.bundle.appendingPathComponent(path), encoding: .utf8)
        }
        XCTAssertEqual(manifest["nextflowLogPath"] as? String, "logs/nextflow.log")
        let engineLog = try log("nextflowLogPath")
        XCTAssertTrue(engineLog.contains("nextflow_command: "), engineLog)
        XCTAssertTrue(engineLog.contains("stand-in engine output"), engineLog)
        let (output, errors) = (try log("stdoutLogPath"), try log("stderrLogPath"))
        XCTAssertTrue(output.contains("stand-in engine output") && !output.contains("warning"), output)
        XCTAssertTrue(errors.contains("stand-in engine warning") && !errors.contains("output"), errors)
    }

    /// Only a run whose engine wrote `logs/nextflow.log` names it (B31 review fix 1). A cancel that comes before the
    /// engine's first line, as one during the version probe does, leaves no log and `stderrLogPath` holds the cancel's
    /// message, so the manifest names none. A cancel after the engine wrote its log names it, and a run that never
    /// launched has none to name.
    func testOnlyALaunchedRunNamesTheEnginesOwnLog() async throws {
        let cancelled = root.appendingPathComponent("cancelled")
        do {
            _ = try await ViralReconLaunchedRun.run(in: cancelled, using: CancellingRunner())
            XCTFail("the cancel did not reach the command")
        } catch {}
        let manifest = try Self.manifestObject(in: cancelled.appendingPathComponent("viralrecon.lungfishrun"))
        XCTAssertEqual(manifest["executionStatus"] as? String, "cancelled")
        XCTAssertNil(manifest["nextflowLogPath"], "the engine wrote no log before the cancel")

        let interrupted = root.appendingPathComponent("interrupted")
        do {
            _ = try await ViralReconLaunchedRun.run(in: interrupted, using: LogWritingCancellingRunner())
            XCTFail("the cancel did not reach the command")
        } catch {}
        let interruptedBundle = interrupted.appendingPathComponent("viralrecon.lungfishrun")
        let interruptedManifest = try Self.manifestObject(in: interruptedBundle)
        XCTAssertEqual(interruptedManifest["executionStatus"] as? String, "cancelled")
        XCTAssertEqual(interruptedManifest["nextflowLogPath"] as? String, "logs/nextflow.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: interruptedBundle.appendingPathComponent("logs/nextflow.log").path))

        let prepared = try await ViralReconLaunchedRun.run(
            in: root.appendingPathComponent("prepared"), extraArguments: ["--prepare-only"])
        XCTAssertNil(try Self.manifestObject(in: prepared.bundle)["nextflowLogPath"], "no engine ran")
    }

    /// The run bundle's `manifest.json` as JSON, so a key the manifest type does not know yet still reads.
    private static func manifestObject(in bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A runner whose launch is cancelled as soon as it starts.
    private final class CancellingRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            throw CancellationError()
        }
    }

    /// A runner that writes the engine's log as its launch does, then is cancelled while the engine runs.
    private final class LogWritingCancellingRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            try FileManager.default.createDirectory(at: launch.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "nextflow_command: stand-in\n".write(to: launch.logFile, atomically: true, encoding: .utf8)
            throw CancellationError()
        }
    }

    /// The real runner for the launch and the probe, without its Docker wait, recording each probe.
    private final class ProbingRunner: NFCoreWorkflowProcessRunning, NFCoreEngineVersionProbing, @unchecked Sendable {
        let inner: ProcessNFCoreWorkflowProcessRunner
        private(set) var probes: [NextflowVersionProbe] = []

        init(inner: ProcessNFCoreWorkflowProcessRunner) { self.inner = inner }

        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            try await inner.runNextflow(launch)
        }

        func probeEngineVersion() async -> NextflowVersionProbe? {
            let probe = await inner.probeEngineVersion()
            if let probe { probes.append(probe) }
            return probe
        }
    }
}
