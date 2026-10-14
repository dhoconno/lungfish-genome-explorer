// RunSubcommand+ViralReconRecord.swift - The facts of a Viral Recon run's record on the one Nextflow record shape
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension RunSubcommand {
    /// The Nextflow facts of a Viral Recon step on the record shape of 2.9 R1 (Phase 2.10 lane B31).
    ///
    /// The step's tool is the lock's pipeline id, `nf-core-viralrecon`, at the revision `-r` takes, with the release tag
    /// that names that revision beside it (``NFCoreRunRequest/viralReconReleaseVersion(pin:)``). `workflow run` always
    /// launches the repository with `-r`, never a snapshot, so the code came from `remote`. LGE's own command stays the
    /// argv of the run.
    static func viralReconStepFacts(for request: NFCoreRunRequest) -> NextflowRecordFacts {
        NextflowRecordFacts(
            toolName: NextflowWorkflowDescriptor.viralRecon.lockPipelineID,
            toolVersion: request.version,
            githubReleaseVersion: request.viralReconReleaseVersion(
                pin: try? NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()),
            pipelineSource: .remote
        )
    }

    /// The step's resolved options: `pipelineSource`, the `nextflowVersion` the engine's own debug log or the probe of
    /// the launched executable named (N3, absent otherwise), and, for a revision that is not itself a full commit, the
    /// `resolvedCommit` Nextflow's `Launching` line names (2.9 R2, B20). A run that never launched has no engine facts.
    static func viralReconResolvedOptions(
        _ facts: NextflowRecordFacts,
        engine: ViralReconEngineFacts?
    ) -> [String: ParameterValue] {
        var options = facts.resolvedOptions(nextflowVersion: engine?.nextflowVersion)
        let namesFullCommit = facts.toolVersion.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
        if !namesFullCommit, let commit = engine?.launchedCommit {
            options["resolvedCommit"] = .string(commit)
        }
        return options
    }

    /// The run's options, split by 2.7 E12 into what the caller chose and what the command applied unasked.
    ///
    /// A pipeline parameter is explicit when the caller passed it with the value that ran, and `input` and `outdir`
    /// come from `--input` and `--results-dir`. A parameter LGE adds or overrides, such as the `skip_freyja` and
    /// `skip_freyja_boot` that no Apple Silicon run can do without, is a resolved default with the value that ran. The
    /// profile `-profile` passes is explicit beside the executor that names it. The release tag is explicit when
    /// `--version` named the revision and a resolved default when the lock's pin did, and `resume` and `prepareOnly` are
    /// explicit only when their flags were given.
    func viralReconRunOptions(
        request: NFCoreRunRequest,
        prepareOnly: Bool,
        releaseVersion: String?
    ) -> (explicit: [String: ParameterValue], resolvedDefaults: [String: ParameterValue]) {
        var explicit: [String: ParameterValue] = [:]
        var resolved: [String: ParameterValue] = [:]
        for (key, value) in request.effectiveParams {
            if key == "input" || key == "outdir" || request.params[key] == value {
                explicit[key] = .string(value)
            } else {
                resolved[key] = .string(value)
            }
        }
        explicit["executor"] = .string(request.executor.rawValue)
        explicit["profile"] = .string(request.executor.rawValue)
        if let releaseVersion {
            if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolved["github_release_version"] = .string(releaseVersion)
            } else {
                explicit["github_release_version"] = .string(releaseVersion)
            }
        }
        for (key, given) in [("resume", request.resume), ("prepareOnly", prepareOnly)] {
            if given { explicit[key] = .boolean(true) } else { resolved[key] = .boolean(false) }
        }
        return (explicit, resolved)
    }

    /// The parameters that name a file or folder the run reads, in the order a record lists them, with their formats.
    static let viralReconInputParameters: [(name: String, format: FileFormat)] = [
        ("fasta", .fasta), ("gff", .gff3), ("primer_bed", .bed), ("primer_fasta", .fasta),
        ("fastq_dir", .fastq), ("sequencing_summary", .text),
    ]

    /// The run's inputs (BIO B-8): the samplesheet LGE was given, each FASTQ file or FASTQ bundle a read pairing decision
    /// names as its sample's source, in sample order, and the reference FASTA, the GFF, the primer BED and FASTA, the
    /// Nanopore `fastq_pass` folder and sequencing summary the parameters name, each as the caller gave it. Each carries
    /// its digest, except that a cancelled run names the reads and references unhashed, so the cancel ends inside the
    /// grace the app gives it (SWIFT 3).
    static func viralReconInputRecords(
        request: NFCoreRunRequest,
        readPairing: [ViralReconReadPairingDecision],
        hashesReads: Bool
    ) -> [FileRecord] {
        func record(_ url: URL, _ format: FileFormat) -> FileRecord {
            hashesReads
                ? ProvenanceRecorder.fileOrDirectoryRecord(url: url, format: format, role: .input)
                : FileRecord(path: url.standardizedFileURL.path, format: format, role: .input)
        }
        let samplesheets = request.inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .text, role: .input) }
        let reads = readPairing.flatMap(\.sourceFASTQURLs).map { record($0, .fastq) }
        let references = viralReconInputParameters.compactMap { parameter in
            request.params[parameter.name].flatMap { $0.isEmpty ? nil : record(URL(fileURLWithPath: $0), parameter.format) }
        }
        var seen = Set<String>()
        return (samplesheets + reads + references).filter { seen.insert($0.path).inserted }
    }

    /// When the run started and ended, as its manifest records them: the engine's launch and end for a run that got that
    /// far, and the bundle's creation for one that did not, with `recordedAt` for an end the manifest does not hold.
    static func viralReconRunWindow(bundleURL: URL, recordedAt: Date) -> (start: Date, end: Date) {
        guard let manifest = try? NFCoreRunBundleStore.read(from: bundleURL) else { return (recordedAt, recordedAt) }
        let start = manifest.startedAt ?? manifest.createdAt
        return (start, max(start, manifest.completedAt ?? recordedAt))
    }
}
