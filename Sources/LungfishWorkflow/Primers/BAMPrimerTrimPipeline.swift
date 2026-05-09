// BAMPrimerTrimPipeline.swift - Run ivar trim + samtools sort/index with provenance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Runs the primer-trim workflow against a BAM file.
///
/// Resolves the primer scheme's BED to the BAM's reference name, runs `ivar trim`,
/// sorts and indexes the output, and writes a provenance sidecar JSON documenting
/// the primer scheme and iVar arguments used.
public struct BAMPrimerTrimPipeline {
    /// Builds the argument list passed to `ivar trim`.
    ///
    /// This pure, synchronous helper exists so callers (and tests) can reason
    /// about the exact iVar invocation without running a process. The returned
    /// array begins with `"trim"` (iVar's subcommand) and ends with `"-e"` so
    /// reads without a matching primer are kept rather than discarded.
    /// - Parameters:
    ///   - bedPath: Path to the primer BED (already resolved to the BAM's reference name).
    ///   - inputBAMPath: Path to the source BAM.
    ///   - outputPrefix: Prefix for iVar's output; `.bam` is appended by iVar.
    ///   - minReadLength: Minimum read length (bp) to retain; passed via `-m`.
    ///   - minQuality: Minimum Phred quality for the sliding-window trim; passed via `-q`.
    ///   - slidingWindow: Sliding-window width (bp); passed via `-s`.
    ///   - primerOffset: Primer coordinate offset (bp); passed via `-x`.
    /// - Returns: The argv (without the program name) suitable for `NativeToolRunner.run(.ivar, arguments:)`.
    public static func buildIvarTrimArgv(
        bedPath: String,
        inputBAMPath: String,
        outputPrefix: String,
        minReadLength: Int,
        minQuality: Int,
        slidingWindow: Int,
        primerOffset: Int
    ) -> [String] {
        [
            "trim",
            "-b", bedPath,
            "-i", inputBAMPath,
            "-p", outputPrefix,
            "-q", "\(minQuality)",
            "-m", "\(minReadLength)",
            "-s", "\(slidingWindow)",
            "-x", "\(primerOffset)",
            "-e"
        ]
    }
}

extension BAMPrimerTrimPipeline {
    /// Errors reported by the primer-trim pipeline when an external stage fails.
    ///
    /// Each case carries the captured stderr from the corresponding tool, which
    /// is surfaced verbatim in the user-facing error description (or
    /// `"no stderr"` when the tool produced none).
    public enum PipelineError: Error, LocalizedError, Sendable {
        /// `ivar trim` exited non-zero.
        case ivarTrimFailed(stderr: String)

        /// `samtools sort` exited non-zero.
        case samtoolsSortFailed(stderr: String)

        /// `samtools index` exited non-zero.
        case samtoolsIndexFailed(stderr: String)

        public var errorDescription: String? {
            switch self {
            case .ivarTrimFailed(let s):
                return "ivar trim failed: \(s.isEmpty ? "no stderr" : s)"
            case .samtoolsSortFailed(let s):
                return "samtools sort failed: \(s.isEmpty ? "no stderr" : s)"
            case .samtoolsIndexFailed(let s):
                return "samtools index failed: \(s.isEmpty ? "no stderr" : s)"
            }
        }
    }

    /// Runs the full primer-trim pipeline: `ivar trim` → `samtools sort` → `samtools index`,
    /// then writes a JSON provenance sidecar next to the output BAM.
    ///
    /// The primer bundle's BED is resolved against `targetReferenceName` before
    /// iVar is invoked; if the match is on an equivalent (rather than canonical)
    /// accession, a rewritten BED is produced in the system temp directory and
    /// cleaned up after the run. Intermediate unsorted BAMs are also removed.
    /// Progress is reported through `progress(fraction, description)` at five
    /// coarse checkpoints.
    ///
    /// - Parameters:
    ///   - request: Inputs (source BAM, primer bundle, output BAM URL, iVar parameters).
    ///   - targetReferenceName: The `@SQ` `SN` name of the source BAM; used to resolve the primer BED.
    ///   - runner: The `NativeToolRunner` that locates `ivar` and `samtools`.
    ///   - progress: Optional progress callback receiving `(fraction, description)`.
    /// - Returns: A `BAMPrimerTrimResult` describing the sorted BAM, its BAI,
    ///   the provenance sidecar URL, and the provenance struct written to it.
    /// - Throws: `PrimerSchemeResolver.ResolveError` if the primer scheme does
    ///   not cover `targetReferenceName`, or `PipelineError.*` when a tool fails.
    public static func run(
        _ request: BAMPrimerTrimRequest,
        targetReferenceName: String,
        runner: NativeToolRunner,
        progress: @Sendable @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> BAMPrimerTrimResult {
        let workflowStart = Date()
        progress(0.0, "Resolving primer scheme")
        let resolved = try PrimerSchemeResolver.resolve(
            bundle: request.primerSchemeBundle,
            targetReferenceName: targetReferenceName
        )

        let workDir = request.outputBAMURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let trimmedPrefix = workDir.appendingPathComponent("trimmed.unsorted")
        let trimmedUnsortedBAM = trimmedPrefix.appendingPathExtension("bam")

        // Single cleanup for intermediates; runs on every exit path (success or throw).
        defer {
            try? FileManager.default.removeItem(at: trimmedUnsortedBAM)
            if resolved.isRewritten {
                try? FileManager.default.removeItem(at: resolved.bedURL)
            }
        }

        progress(0.1, "Running ivar trim")
        let ivarArgs = buildIvarTrimArgv(
            bedPath: resolved.bedURL.path,
            inputBAMPath: request.sourceBAMURL.path,
            outputPrefix: trimmedPrefix.path,
            minReadLength: request.minReadLength,
            minQuality: request.minQuality,
            slidingWindow: request.slidingWindow,
            primerOffset: request.primerOffset
        )

        let ivarCommand = await nativeCommand(for: .ivar, arguments: ivarArgs, runner: runner)
        let ivarTimedResult = try await runTimed(
            .ivar,
            arguments: ivarArgs,
            workingDirectory: workDir,
            timeout: 3_600,
            runner: runner
        )
        let ivarResult = ivarTimedResult.result
        guard ivarResult.isSuccess else {
            throw PipelineError.ivarTrimFailed(stderr: ivarResult.stderr)
        }
        let ivarVersion = await runner.getToolVersion(.ivar) ?? "unknown"
        let sourceInputs = inputFileRecords(
            sourceBAMURL: request.sourceBAMURL,
            primerBEDURL: resolved.bedURL
        )
        let ivarStep = StepExecution(
            toolName: "ivar",
            toolVersion: toolVersion(version: ivarVersion, tool: .ivar),
            command: ivarCommand,
            inputs: sourceInputs,
            outputs: [ProvenanceRecorder.fileRecord(url: trimmedUnsortedBAM, format: .bam, role: .output)],
            exitCode: ivarResult.exitCode,
            wallTime: ivarTimedResult.wallTime,
            stderr: nonEmpty(ivarResult.stderr),
            startTime: ivarTimedResult.startTime,
            endTime: ivarTimedResult.endTime
        )

        progress(0.55, "Sorting BAM")
        let sortArgs = ["sort", "-o", request.outputBAMURL.path, trimmedUnsortedBAM.path]
        let sortCommand = await nativeCommand(for: .samtools, arguments: sortArgs, runner: runner)
        let sortTimedResult = try await runTimed(
            .samtools,
            arguments: sortArgs,
            workingDirectory: workDir,
            timeout: 3_600,
            runner: runner
        )
        let sortResult = sortTimedResult.result
        guard sortResult.isSuccess else {
            // samtools sort may have written a truncated BAM; remove it to uphold
            // the pipeline's all-or-nothing output contract.
            try? FileManager.default.removeItem(at: request.outputBAMURL)
            throw PipelineError.samtoolsSortFailed(stderr: sortResult.stderr)
        }
        let samtoolsVersion = await runner.getToolVersion(.samtools) ?? "unknown"
        let sortStep = StepExecution(
            toolName: "samtools",
            toolVersion: toolVersion(version: samtoolsVersion, tool: .samtools),
            command: sortCommand,
            inputs: [ProvenanceRecorder.fileRecord(url: trimmedUnsortedBAM, format: .bam, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: request.outputBAMURL, format: .bam, role: .output)],
            exitCode: sortResult.exitCode,
            wallTime: sortTimedResult.wallTime,
            stderr: nonEmpty(sortResult.stderr),
            dependsOn: [ivarStep.id],
            startTime: sortTimedResult.startTime,
            endTime: sortTimedResult.endTime
        )

        progress(0.85, "Indexing BAM")
        let indexArgs = ["index", request.outputBAMURL.path]
        let indexCommand = await nativeCommand(for: .samtools, arguments: indexArgs, runner: runner)
        let indexTimedResult = try await runTimed(
            .samtools,
            arguments: indexArgs,
            workingDirectory: workDir,
            timeout: 600,
            runner: runner
        )
        let indexResult = indexTimedResult.result
        guard indexResult.isSuccess else {
            // Remove the sorted BAM and any partial BAI so the caller cannot
            // observe an un-indexed or half-indexed output.
            try? FileManager.default.removeItem(at: request.outputBAMURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: request.outputBAMURL.path + ".bai"))
            throw PipelineError.samtoolsIndexFailed(stderr: indexResult.stderr)
        }

        let bamIndexURL = URL(fileURLWithPath: request.outputBAMURL.path + ".bai")
        let indexStep = StepExecution(
            toolName: "samtools",
            toolVersion: toolVersion(version: samtoolsVersion, tool: .samtools),
            command: indexCommand,
            inputs: [ProvenanceRecorder.fileRecord(url: request.outputBAMURL, format: .bam, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: bamIndexURL, role: .index)],
            exitCode: indexResult.exitCode,
            wallTime: indexTimedResult.wallTime,
            stderr: nonEmpty(indexResult.stderr),
            dependsOn: [sortStep.id],
            startTime: indexTimedResult.startTime,
            endTime: indexTimedResult.endTime
        )
        let outputRecords = [
            ProvenanceRecorder.fileRecord(url: request.outputBAMURL, format: .bam, role: .output),
            ProvenanceRecorder.fileRecord(url: bamIndexURL, role: .index)
        ]
        let workflowEnd = Date()
        let provenance = BAMPrimerTrimProvenance(
            operation: "primer-trim",
            primerScheme: .init(
                bundleName: request.primerSchemeBundle.manifest.name,
                bundleSource: request.primerSchemeBundle.manifest.source ?? "project-local",
                bundleVersion: request.primerSchemeBundle.manifest.version,
                canonicalAccession: request.primerSchemeBundle.manifest.canonicalAccession
            ),
            sourceBAMRelativePath: request.sourceBAMURL.lastPathComponent,
            ivarVersion: ivarVersion,
            ivarTrimArgs: ivarArgs,
            timestamp: workflowEnd,
            schemaVersion: 2,
            workflowName: "lungfish bam primer-trim",
            workflowVersion: WorkflowRun.currentAppVersion,
            command: workflowCommand(for: request, targetReferenceName: targetReferenceName),
            resolvedOptions: resolvedOptions(for: request, targetReferenceName: targetReferenceName),
            inputFiles: sourceInputs,
            outputFiles: outputRecords,
            runtimeIdentity: [
                "ivar": runtimeIdentity(for: .ivar),
                "samtools": runtimeIdentity(for: .samtools)
            ],
            steps: [ivarStep, sortStep, indexStep],
            wallTimeSeconds: workflowEnd.timeIntervalSince(workflowStart),
            exitStatus: 0,
            stderr: combinedStderr([ivarResult.stderr, sortResult.stderr, indexResult.stderr])
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let provenanceData = try encoder.encode(provenance)
        let provenanceURL = PrimerTrimProvenanceLoader.sidecarURL(forBAMAt: request.outputBAMURL)
        do {
            try provenanceData.write(to: provenanceURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: request.outputBAMURL)
            try? FileManager.default.removeItem(at: bamIndexURL)
            try? FileManager.default.removeItem(at: provenanceURL)
            throw error
        }

        progress(1.0, "Primer trim complete")

        return BAMPrimerTrimResult(
            outputBAMURL: request.outputBAMURL,
            outputBAMIndexURL: bamIndexURL,
            provenanceURL: provenanceURL,
            provenance: provenance
        )
    }

    private static func runTimed(
        _ tool: NativeTool,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        runner: NativeToolRunner
    ) async throws -> TimedNativeToolResult {
        let start = Date()
        let result = try await runner.run(
            tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        let end = Date()
        return TimedNativeToolResult(
            result: result,
            startTime: start,
            endTime: end,
            wallTime: end.timeIntervalSince(start)
        )
    }

    private static func nativeCommand(
        for tool: NativeTool,
        arguments: [String],
        runner: NativeToolRunner
    ) async -> [String] {
        if let toolURL = try? await runner.findTool(tool) {
            return [toolURL.path] + arguments
        }
        return [tool.executableName] + arguments
    }

    private static func inputFileRecords(sourceBAMURL: URL, primerBEDURL: URL) -> [FileRecord] {
        var records = [
            ProvenanceRecorder.fileRecord(url: sourceBAMURL, format: .bam, role: .input),
            ProvenanceRecorder.fileRecord(url: primerBEDURL, format: .bed, role: .reference)
        ]
        let indexURL = URL(fileURLWithPath: sourceBAMURL.path + ".bai")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            records.insert(ProvenanceRecorder.fileRecord(url: indexURL, role: .index), at: 1)
        }
        return records
    }

    private static func workflowCommand(
        for request: BAMPrimerTrimRequest,
        targetReferenceName: String
    ) -> [String] {
        if !request.workflowCommand.isEmpty {
            return request.workflowCommand
        }
        return [
            "BAMPrimerTrimPipeline.run",
            "--source-bam", request.sourceBAMURL.path,
            "--scheme", request.primerSchemeBundle.url.path,
            "--output-bam", request.outputBAMURL.path,
            "--target-reference", targetReferenceName,
            "--ivar-min-quality", String(request.minQuality),
            "--ivar-min-length", String(request.minReadLength),
            "--ivar-sliding-window", String(request.slidingWindow),
            "--ivar-primer-offset", String(request.primerOffset)
        ]
    }

    private static func resolvedOptions(
        for request: BAMPrimerTrimRequest,
        targetReferenceName: String
    ) -> [String: String] {
        [
            "source_bam": request.sourceBAMURL.path,
            "primer_scheme": request.primerSchemeBundle.url.path,
            "output_bam": request.outputBAMURL.path,
            "target_reference": targetReferenceName,
            "ivar_min_quality": String(request.minQuality),
            "ivar_min_length": String(request.minReadLength),
            "ivar_sliding_window": String(request.slidingWindow),
            "ivar_primer_offset": String(request.primerOffset)
        ]
    }

    private static func toolVersion(version: String, tool: NativeTool) -> String {
        "\(version) (\(runtimeIdentity(for: tool)))"
    }

    private static func runtimeIdentity(for tool: NativeTool) -> String {
        switch tool.location {
        case .managed(let environment, let executableName):
            let packageSpec = (try? ManagedToolLock.loadFromBundle().tool(named: environment)?.packageSpec)
                ?? tool.sourcePackage
            return "managed conda environment \(environment); executable \(executableName); package \(packageSpec)"
        case .bundled(let relativePath):
            return "bundled executable \(relativePath)"
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func combinedStderr(_ values: [String]) -> String? {
        let combined = values
            .compactMap(nonEmpty)
            .joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }
}

private struct TimedNativeToolResult {
    let result: NativeToolResult
    let startTime: Date
    let endTime: Date
    let wallTime: TimeInterval
}
