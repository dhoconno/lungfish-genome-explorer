// ViralReconRecordShapeGapTests.swift - What Viral Recon's record holds against the one Nextflow record shape
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B11, milestone M2, ruling N12. Decision R1 gives every Nextflow step one shape, the pipeline id at its
// revision with the release tag beside it, and `pipelineSource` and `nextflowVersion` among its resolved options
// (`NextflowRecordFacts`). In 2.9 only TaxTriage writes it. These tests state Viral Recon's gaps against that shape and
// the profile, parameter and input rows of the panel's BIO mapping, each as today's fact, and change nothing in it.
// Viral Recon's move onto the shape in Phase 2.10 flips them.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ViralReconRecordShapeGapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-record-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// N12, declared gaps. The record's one step is LGE's `lungfish-cli workflow run` at LGE's version, where the shape
    /// has the lock's pipeline id `nf-core-viralrecon` at the pinned revision. The release tag is the step's
    /// `githubReleaseVersion`, as the shape has it, and a run parameter, and the step's resolved options hold no
    /// `nextflowVersion` and no `pipelineSource`. A kept log gives a Nextflow 26 version only when the workflow's own
    /// code prints one, as TaxTriage's does, so Viral Recon's move needs a version source of its own.
    func testViralReconRecordsTheCommandWhereTheShapeHasThePipelineAtItsRevision() async throws {
        let pin = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        let shape = NextflowRecordFacts(pin: pin, pipelineSource: .remote)
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nP,/tmp/P_R1.fastq.gz,/tmp/P_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", root.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", runBundle.path,
            "--version", pin.releaseVersion,
            "--prepare-only",
            "--quiet",
        ]).run()

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: runBundle))
        XCTAssertEqual(record.steps.count, 1)
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(shape.toolName, "nf-core-viralrecon")
        // 2.10 B31 M1 flipped these. The step is the pipeline id at the revision -r takes, and LGE's command is the
        // run's argv.
        XCTAssertEqual(step.toolName, shape.toolName, "the step is the lock's pipeline id")
        XCTAssertEqual(step.toolVersion, shape.toolVersion, "at the pinned revision")
        XCTAssertEqual(record.argv.prefix(3), ["lungfish-cli", "workflow", "run"], "LGE's command is the run's argv")
        XCTAssertEqual(step.githubReleaseVersion, shape.githubReleaseVersion, "the tag, as the shape has it")
        XCTAssertEqual(record.options.explicit["github_release_version"], .string(pin.releaseVersion))
        XCTAssertNil(step.resolvedOptions["nextflowVersion"], "gap, no Nextflow version")
        XCTAssertEqual(step.resolvedOptions["pipelineSource"], .string("remote"), "the repository, launched with -r")
        XCTAssertEqual(record.options.explicit["executor"], .string("docker"))
        XCTAssertEqual(record.options.explicit["profile"], .string("docker"), "the profile -profile passes, an explicit option")
        // 2.7 E12. What LGE passes unasked, the forced Freyja skips and a flag left at its default, is a resolved default.
        XCTAssertEqual(record.options.resolvedDefaults["skip_freyja"], .string("true"))
        XCTAssertEqual(record.options.resolvedDefaults["skip_freyja_boot"], .string("true"))
        XCTAssertNil(record.options.explicit["skip_freyja"])
        XCTAssertEqual(record.options.resolvedDefaults["resume"], .boolean(false))
        XCTAssertEqual(record.options.explicit["prepareOnly"], .boolean(true))
        // M2 flipped this. The FASTQs the samplesheet names are inputs too, without a digest where no file exists.
        XCTAssertEqual(step.inputs.map(\.path), [samplesheet.path, "/tmp/P_R1.fastq.gz", "/tmp/P_R2.fastq.gz"])
        XCTAssertNotNil(step.inputs.first?.checksumSHA256)
    }

    /// Phase 2.10 lane B31 M1, the pin of a launched run's record before the writer moves. The engine's own debug log in
    /// the launch folder names Nextflow 26.04.6 and the commit of tag 3.0.0 in the lines of Q35's real run V1, and the
    /// record names neither. The step starts and ends at the moment the record is written, not when the engine started,
    /// and the samplesheet is its one input.
    func testALaunchedRunRecordsStartEqualToEndAndNothingFromTheEnginesOwnLog() async throws {
        let run = try await ViralReconLaunchedRun.run(in: root)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle))
        let step = try XCTUnwrap(record.steps.first)
        let manifest = try NFCoreRunBundleStore.read(from: run.bundle)
        XCTAssertEqual(manifest.executionStatus, .completed)
        XCTAssertNotNil(manifest.startedAt, "the engine's start is in the manifest")
        // M2 flipped these. The step and the run start when the engine started and end when it ended, as the manifest
        // records them, and each FASTQ and the primer BED is an input with its digest.
        XCTAssertEqual(step.startedAt, manifest.startedAt)
        XCTAssertEqual(step.completedAt, manifest.completedAt)
        XCTAssertEqual(record.createdAt, manifest.startedAt)
        // N3 and 2.9 R2. The engine's own debug log names the version that ran and the commit tag 3.0.0 resolved to.
        XCTAssertEqual(step.resolvedOptions["nextflowVersion"], .string("26.04.6"))
        XCTAssertEqual(step.resolvedOptions["resolvedCommit"], .string("395079f1d2"))
        XCTAssertEqual(step.inputs.map(\.path), [run.samplesheet.path] + run.reads.map(\.path) + [run.primerBED.path])
        for input in step.inputs {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: input.path))
            XCTAssertEqual(input.checksumSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), input.path)
        }
    }
}

/// One `workflow run nf-core/viralrecon` launched in process on a runner that writes no outputs but the results folder and,
/// in the launch folder, the first lines Nextflow 26.04.6 wrote to its own debug log `.nextflow.log` in Q35's real run V1
/// (`SCR/realrun/V1/warm-meta/nextflow.log` lines 1, 2 and 32, with its paths shortened).
struct ViralReconLaunchedRun {
    let bundle: URL
    let results: URL
    let samplesheet: URL
    let reads: [URL]
    let primerBED: URL
    let runner: Runner

    static let debugLogLines = [
        "Oct-13 19:21:52.275 [main] DEBUG nextflow.cli.Launcher - $> nextflow run nf-core/viralrecon -r 3.0.0 -profile docker",
        "Oct-13 19:21:52.335 [main] INFO  nextflow.cli.CmdRun - N E X T F L O W  ~  version 26.04.6",
        "Oct-13 19:21:55.928 [main] INFO  nextflow.cli.CmdRun - Launching `https://github.com/nf-core/viralrecon` [fervent_ochoa] - revision: 395079f1d2 [3.0.0]",
    ]

    /// Records each launch, writes `debugLog` as `.nextflow.log` in its launch folder and creates the results folder.
    final class Runner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        let debugLog: [String]?
        private(set) var launches: [NFCoreWorkflowLaunch] = []

        init(debugLog: [String]?) { self.debugLog = debugLog }

        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            launches.append(launch)
            if let debugLog {
                try FileManager.default.createDirectory(at: launch.workingDirectory, withIntermediateDirectories: true)
                try (debugLog.joined(separator: "\n") + "\n")
                    .write(to: launch.workingDirectory.appendingPathComponent(".nextflow.log"), atomically: true, encoding: .utf8)
            }
            if let index = launch.arguments.firstIndex(of: "--outdir"), index + 1 < launch.arguments.count {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: launch.arguments[index + 1]), withIntermediateDirectories: true)
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
        }
    }

    /// Runs one paired Illumina amplicon sample with two CPUs and 4 GB, as the app's wizard asks, in `root`.
    static func run(
        in root: URL, debugLog: [String]? = debugLogLines, extraArguments: [String] = [],
        using other: (any NFCoreWorkflowProcessRunning)? = nil
    ) async throws -> ViralReconLaunchedRun {
        let reads = ["S1_R1.fastq", "S1_R2.fastq"].map { root.appendingPathComponent("reads/\($0)") }
        try FileManager.default.createDirectory(at: reads[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        for (index, url) in reads.enumerated() {
            try "@r1/\(index + 1)\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let primerBED = root.appendingPathComponent("primers/primers.bed")
        try FileManager.default.createDirectory(at: primerBED.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "MN908947.3\t30\t54\tnCoV-2019_1_LEFT\t1\t+\n".write(to: primerBED, atomically: true, encoding: .utf8)
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,\(reads[0].path),\(reads[1].path)\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)
        let runner = Runner(debugLog: debugLog)
        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", bundle.path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--param", "protocol=amplicon",
            "--param", "genome=MN908947.3",
            "--param", "primer_bed=\(primerBED.path)",
            "--param", "max_cpus=2",
            "--param", "max_memory=4.GB",
            "--quiet",
        ] + extraArguments).run(nfCoreRunner: other ?? runner)
        return ViralReconLaunchedRun(
            bundle: bundle, results: results, samplesheet: samplesheet, reads: reads, primerBED: primerBED, runner: runner)
    }
}
