// ManagedMappingPipeline+ReadSets.swift - Mapping a sample of pairs and single reads (READ-PAIRING.md)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// What the mapper run left for normalization.
struct MappedAlignment: Sendable {
    /// The mapper calls, and for BBMap on a sample of pairs and single reads
    /// the sort of each run and the merge, as provenance steps.
    let steps: [StepExecution]
    /// The SAM or BAM the normalization reads.
    let alignmentURL: URL
    let normalized: NormalizedMappingAlignment
}

extension ManagedMappingPipeline {

    /// Runs the mapper and normalizes its output into the sorted, indexed BAM.
    ///
    /// BBMap takes one kind of read per run, so a sample of pairs and single
    /// reads (``MappingRunRequest/readSetLayout``) maps in one run per read
    /// set. Each run is sorted, `samtools merge -c -p` joins them, and the
    /// merge is normalized like any run, so flagstat and every summary read
    /// the merged BAM. The per-run files and the merge are removed.
    ///
    /// Each mapper step of a sample of pairs and single reads records the
    /// read-set plan (``ReadSetPlan/provenanceParameters``) as options. A
    /// plan that records nothing new adds nothing.
    func mapAndNormalize(
        prepared: PreparedMappingExecution,
        command: ManagedMappingCommand,
        readSetPlan: ReadSetPlan?,
        mapperVersion: String,
        samtoolsVersion: String,
        progress: ProgressHandler?
    ) async throws -> MappedAlignment {
        let planOptions = readSetPlan?.provenanceParameters ?? [:]
        let request = prepared.request
        let referenceURL = prepared.referenceLocator.referenceURL
        let readLayoutPlan = request.readLayoutPlan
        progress?(0.08, "Read layout: \(readLayoutPlan.layout.displayName), mapped \(readLayoutPlan.handling.displayName).")
        progress?(0.1, "Running \(request.tool.displayName)...")

        let bbmapRuns = try MappingCommandBuilder.buildBBMapReadSetRuns(
            for: request,
            referenceLocator: prepared.referenceLocator
        )
        var steps: [StepExecution] = []
        let alignmentURL: URL
        var intermediates: [URL] = []
        if bbmapRuns.isEmpty {
            alignmentURL = MappingCommandBuilder.rawAlignmentURL(for: request)
            steps.append(Self.recording(planOptions, in: try await executeMappingCommand(
                command,
                outputURL: alignmentURL,
                inputRecords: mapperExecutionInputRecords(for: request, referenceURL: referenceURL),
                mapperVersion: mapperVersion,
                progress: progress
            )))
        } else {
            var sortedRuns: [URL] = []
            for (index, run) in bbmapRuns.enumerated() {
                progress?(0.1 + 0.5 * Double(index) / Double(bbmapRuns.count), "Running BBMap on read set \(index + 1) of \(bbmapRuns.count)...")
                let inputRecords = run.inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) }
                    + [ProvenanceRecorder.fileRecord(url: referenceURL, format: .fasta, role: .reference)]
                steps.append(Self.recording(planOptions, in: try await executeMappingCommand(
                    run.command,
                    outputURL: run.rawAlignmentURL,
                    inputRecords: inputRecords,
                    mapperVersion: mapperVersion,
                    progress: progress
                )))
                let sortedURL = run.rawAlignmentURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("bam")
                steps.append(try await samtoolsSort(
                    inputURL: run.rawAlignmentURL,
                    outputBAMURL: sortedURL,
                    threads: max(1, request.threads / 2),
                    samtoolsVersion: samtoolsVersion
                ))
                try? FileManager.default.removeItem(at: run.rawAlignmentURL)
                sortedRuns.append(sortedURL)
            }
            alignmentURL = request.outputDirectory.appendingPathComponent("\(request.sampleName).merged.bam")
            progress?(0.65, "Merging the BBMap runs...")
            steps.append(try await samtoolsMerge(
                sortedRuns,
                into: alignmentURL,
                threads: request.threads,
                samtoolsVersion: samtoolsVersion
            ))
            for url in sortedRuns { try? FileManager.default.removeItem(at: url) }
            intermediates.append(alignmentURL)
        }

        progress?(0.7, "Normalizing sorted BAM...")
        let normalized = try await normalizeAlignment(
            rawAlignmentURL: alignmentURL,
            outputDirectory: request.outputDirectory,
            sampleName: request.sampleName,
            threads: request.threads,
            minimumMappingQuality: request.minimumMappingQuality,
            includeSecondary: request.includeSecondary,
            includeSupplementary: request.includeSupplementary,
            removeIntermediateRawSAMOnSuccess: true,
            samtoolsVersion: samtoolsVersion
        )
        for url in intermediates { try? FileManager.default.removeItem(at: url) }
        return MappedAlignment(steps: steps, alignmentURL: alignmentURL, normalized: normalized)
    }

    /// The steps that wrote the mapper's input files: a materialization of a
    /// virtual bundle or a concatenation, then the read-set plan's split or
    /// interleave. A split of a virtual bundle records its materialization
    /// as the step that wrote the split's input.
    func readSetInputSteps(for request: MappingRunRequest, plan: ReadSetPlan?) throws -> [StepExecution] {
        guard let plan, !plan.steps.isEmpty else {
            return try mappingInputMaterializationSteps(for: request)
        }
        var steps: [StepExecution] = []
        if plan.wasMaterialized, let materializedURL = plan.steps.first?.inputURLs.first {
            steps += try mappingInputMaterializationSteps(for: request.withInputFASTQURLs([materializedURL]))
        }
        steps += try plan.steps.map { try $0.stepExecution(toolVersion: WorkflowRun.currentAppVersion) }
        return steps
    }

    /// `step` with `options` added to its resolved options, or unchanged when
    /// `options` is empty.
    static func recording(_ options: [String: ParameterValue], in step: StepExecution) -> StepExecution {
        guard !options.isEmpty else { return step }
        return StepExecution(
            id: step.id,
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            githubReleaseVersion: step.githubReleaseVersion,
            containerImage: step.containerImage,
            containerDigest: step.containerDigest,
            command: step.command,
            durableReplayArgv: step.durableReplayArgv,
            resolvedOptions: (step.resolvedOptions ?? [:]).merging(options) { _, planValue in planValue },
            runtimeIdentity: step.runtimeIdentity,
            inputs: step.inputs,
            outputs: step.outputs,
            exitCode: step.exitCode,
            wallTime: step.wallTime,
            peakMemoryBytes: step.peakMemoryBytes,
            stderr: step.stderr,
            dependsOn: step.dependsOn,
            startTime: step.startTime,
            endTime: step.endTime
        )
    }

    /// `samtools merge -c -p` of sorted BAMs that share one read group, so
    /// the merge keeps one `@RG` and one `@PG` line per program.
    private func samtoolsMerge(
        _ inputURLs: [URL],
        into outputURL: URL,
        threads: Int,
        samtoolsVersion: String
    ) async throws -> StepExecution {
        let execution = try await runNativeToolStep(
            tool: .samtools,
            arguments: ["merge", "-c", "-p", "-f", "-@", String(max(1, threads)), "-o", outputURL.path] + inputURLs.map(\.path),
            workingDirectory: outputURL.deletingLastPathComponent(),
            timeout: 3_600,
            toolVersion: samtoolsVersion,
            inputs: inputURLs.map { ($0, .bam, .input) },
            outputs: [(outputURL, .bam, .output)]
        )
        guard execution.result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(execution.result.stderr)
        }
        return execution.step
    }
}
