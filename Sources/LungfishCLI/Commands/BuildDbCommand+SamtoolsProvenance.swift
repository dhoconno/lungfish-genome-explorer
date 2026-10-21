// BuildDbCommand+SamtoolsProvenance.swift - Samtools substep provenance for build-db
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

enum BuildDbSamtoolsProvenanceError: Error, LocalizedError {
    case descriptorUnavailable(String, String)

    var errorDescription: String? {
        switch self {
        case .descriptorUnavailable(let path, let reason):
            return "Could not record build-db samtools provenance for \(path): \(reason)"
        }
    }
}

/// The samtools steps of one `build-db` run, in the order they ran. Each step is handed over as it is
/// recorded, once it ended whole, through `handOver`, the run's ``BuildDbEventSink/step`` (lane S33).
final class BuildDbSamtoolsProvenanceCollector {
    fileprivate var recordedSteps: [ProvenanceStep] = []
    private let handOver: @Sendable (ProvenanceStep) -> Void

    init(handOver: @escaping @Sendable (ProvenanceStep) -> Void = { _ in }) {
        self.handOver = handOver
    }

    var steps: [ProvenanceStep] {
        recordedSteps
    }

    /// Records `step`, which ended whole, and hands it over.
    fileprivate func record(_ step: ProvenanceStep) {
        recordedSteps.append(step)
        handOver(step)
    }
}

private struct BuildDbSamtoolsInvocation: Sendable {
    let startedAt: Date
    let completedAt: Date
    let result: NativeToolResult

    var wallTimeSeconds: TimeInterval {
        completedAt.timeIntervalSince(startedAt)
    }
}

private actor BuildDbTrackingSamtoolsRunner: AlignmentSamtoolsRunning {
    private let samtoolsURL: URL
    private var invocations: [BuildDbSamtoolsInvocation] = []

    init(samtoolsPath: String) {
        self.samtoolsURL = URL(fileURLWithPath: samtoolsPath)
    }

    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        let samtoolsClock = ProvenanceRunClock()
        let result = try await NativeToolRunner.shared.runProcess(
            executableURL: samtoolsURL,
            arguments: arguments,
            timeout: timeout,
            toolName: "samtools"
        )
        let completedAt = samtoolsClock.now
        invocations.append(
            BuildDbSamtoolsInvocation(
                startedAt: samtoolsClock.startedAt,
                completedAt: completedAt,
                result: result
            )
        )
        return result
    }

    func snapshot() -> [BuildDbSamtoolsInvocation] {
        invocations
    }
}

final class BuildDbSamtoolsProvenanceTracker {
    private let samtoolsPath: String
    private let samtoolsURL: URL
    private let samtoolsVersion: String
    private let collector: BuildDbSamtoolsProvenanceCollector

    init(samtoolsPath: String, collector: BuildDbSamtoolsProvenanceCollector) {
        self.samtoolsPath = samtoolsPath
        self.samtoolsURL = URL(fileURLWithPath: samtoolsPath)
        self.samtoolsVersion = BuildDbCommand.detectSamtoolsVersion(at: samtoolsPath)
        self.collector = collector
    }

    func markdup(
        bamURL: URL,
        threads: Int = 4,
        force: Bool = false
    ) async throws -> MarkdupResult {
        // The read count pass catches the failure of each samtools call and goes on to the next BAM, but it
        // ends on `CancellationError`. A markdup after a cancel stops here, before the header probe and the
        // hash of the BAM below (2.7 E5), and the pass logs no warning for it (lane S33 M2).
        try Task.checkCancellation()
        let markdupClock = ProvenanceRunClock()
        let fm = FileManager.default

        guard fm.fileExists(atPath: bamURL.path) else {
            throw MarkdupError.fileNotFound(bamURL)
        }

        if !force, await isAlreadyMarkduped(bamURL: bamURL) {
            try await ensureFreshIndex(bamURL: bamURL)
            let total = (try? await countReads(bamURL: bamURL, accession: nil, flagFilter: 0x004)) ?? 0
            let nonDuplicate = (try? await countReads(bamURL: bamURL, accession: nil, flagFilter: 0x404)) ?? 0
            return MarkdupResult(
                bamURL: bamURL,
                wasAlreadyMarkduped: true,
                totalReads: total,
                duplicateReads: max(0, total - nonDuplicate),
                durationSeconds: markdupClock.elapsed
            )
        }

        let originalInput = try descriptor(url: bamURL, format: .bam, role: .input)
        let tempBamURL = URL(fileURLWithPath: bamURL.path + ".markdup.tmp")
        let tempBaiURL = URL(fileURLWithPath: tempBamURL.path + ".bai")
        let finalBaiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        let finalCsiURL = URL(fileURLWithPath: bamURL.path + ".csi")

        try? fm.removeItem(at: tempBamURL)
        try? fm.removeItem(at: tempBaiURL)

        let runner = BuildDbTrackingSamtoolsRunner(samtoolsPath: samtoolsPath)
        let pipeline = AlignmentMarkdupPipeline(samtoolsRunner: runner)

        do {
            let pipelineResult = try await pipeline.run(
                inputURL: bamURL,
                outputURL: tempBamURL,
                removeDuplicates: false,
                referenceFastaPath: nil,
                sortThreads: threads,
                progressHandler: nil
            )

            guard fm.fileExists(atPath: tempBamURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: tempBamURL.path),
                  let size = attrs[.size] as? Int,
                  size > 0 else {
                throw MarkdupError.corruptOutput(reason: "output BAM missing or empty at \(tempBamURL.path)")
            }

            // The markdup output replaces the BAM in place and its old index goes, so a step names
            // them, since earlier steps name their earlier bytes (P1 of Phase 2.8, row 422).
            let replaced = [originalInput] + [finalBaiURL, finalCsiURL].compactMap { url in
                fm.fileExists(atPath: url.path) ? try? descriptor(url: url, format: nil, role: .index) : nil
            }
            let replacementClock = ProvenanceRunClock()
            try? fm.removeItem(at: finalBaiURL)
            try? fm.removeItem(at: finalCsiURL)
            _ = try fm.replaceItemAt(bamURL, withItemAt: tempBamURL)
            if fm.fileExists(atPath: tempBaiURL.path) {
                try fm.moveItem(at: tempBaiURL, to: finalBaiURL)
            }

            guard fm.fileExists(atPath: finalBaiURL.path) else {
                throw MarkdupError.indexFailed(stderr: "samtools index did not produce \(finalBaiURL.path)")
            }

            let invocations = await runner.snapshot()
            try recordMarkdupPipelineSteps(
                originalInput: originalInput,
                finalBAMURL: bamURL,
                finalIndexURL: finalBaiURL,
                pipelineResult: pipelineResult,
                invocations: invocations
            )
            if let removal = RecordedRemovalStep.step(
                toolName: "Lungfish Markdup Replacement", api: "FileManager.replaceItemAt(_:withItemAt:)",
                removing: replaced, clock: replacementClock
            ) {
                collector.record(removal)
            }

            let total = try await countReads(bamURL: bamURL, accession: nil, flagFilter: 0x004)
            let nonDuplicate = try await countReads(bamURL: bamURL, accession: nil, flagFilter: 0x404)

            return MarkdupResult(
                bamURL: bamURL,
                wasAlreadyMarkduped: false,
                totalReads: total,
                duplicateReads: max(0, total - nonDuplicate),
                durationSeconds: markdupClock.elapsed
            )
        } catch {
            try? fm.removeItem(at: tempBamURL)
            try? fm.removeItem(at: tempBaiURL)
            throw error
        }
    }

    func idxstats(bamURL: URL) async throws -> String? {
        let invocation = try await executeSamtools(arguments: ["idxstats", bamURL.path])
        try appendStep(
            invocation,
            inputs: [descriptor(url: bamURL, format: .bam, role: .input)],
            outputs: []
        )
        guard invocation.result.isSuccess else {
            return nil
        }
        return invocation.result.stdout
    }

    func countReads(
        bamURL: URL,
        accession: String?,
        flagFilter: Int
    ) async throws -> Int {
        var arguments = ["view", "-c", "-F", String(flagFilter), bamURL.path]
        if let accession, !accession.isEmpty {
            arguments.append(accession)
        }
        let invocation = try await executeSamtools(arguments: arguments)
        try appendStep(
            invocation,
            inputs: [descriptor(url: bamURL, format: .bam, role: .input)],
            outputs: []
        )
        guard invocation.result.isSuccess else {
            throw MarkdupError.pipelineFailed(stage: "count", stderr: invocation.result.stderr)
        }
        // Output that is not a count is a failed count, never 0 (BIO's Q-A3 item 6).
        let output = invocation.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(output) else {
            throw MarkdupError.pipelineFailed(stage: "count", stderr: "samtools view -c printed no count: \(output)")
        }
        return count
    }

    private func isAlreadyMarkduped(bamURL: URL) async -> Bool {
        guard let invocation = try? await executeSamtools(arguments: ["view", "-H", bamURL.path]) else {
            return false
        }
        try? appendStep(
            invocation,
            inputs: [descriptor(url: bamURL, format: .bam, role: .input)],
            outputs: []
        )
        guard invocation.result.isSuccess else {
            return false
        }
        return invocation.result.stdout.contains("samtools markdup")
    }

    private func ensureFreshIndex(bamURL: URL) async throws {
        let fm = FileManager.default
        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")

        let baiHealthy: Bool = {
            guard fm.fileExists(atPath: baiURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: baiURL.path),
                  let size = attrs[.size] as? Int else {
                return false
            }
            return size > 0
        }()

        if !baiHealthy {
            try? fm.removeItem(at: baiURL)
            try? fm.removeItem(at: csiURL)
            let invocation = try await executeSamtools(arguments: ["index", bamURL.path])
            try appendStep(
                invocation,
                inputs: [descriptor(url: bamURL, format: .bam, role: .input)],
                outputs: invocation.result.isSuccess
                    ? [descriptor(url: baiURL, format: nil, role: .index)]
                    : []
            )
            guard invocation.result.isSuccess else {
                throw MarkdupError.indexFailed(stderr: invocation.result.stderr)
            }
            return
        }

        if fm.fileExists(atPath: csiURL.path) {
            try? fm.removeItem(at: csiURL)
        }
    }

    private func recordMarkdupPipelineSteps(
        originalInput: ProvenanceFileDescriptor,
        finalBAMURL: URL,
        finalIndexURL: URL,
        pipelineResult: AlignmentMarkdupPipelineResult,
        invocations: [BuildDbSamtoolsInvocation]
    ) throws {
        // Each stage after the first depends on the stage before it, so the record of the BAM keeps the stages
        // that name no file, `fixmate` and the coordinate `sort`, through its markdup, and the record of every
        // other BAM drops them (BIO's Q-A3 item 5).
        var previous: ProvenanceStep?
        for (index, pair) in zip(pipelineResult.commandHistory, invocations).enumerated() {
            let inputs: [ProvenanceFileDescriptor]
            let outputs: [ProvenanceFileDescriptor]
            switch pair.0.subcommand {
            case "sort" where index == 0:
                inputs = [originalInput]
                outputs = []
            case "markdup":
                inputs = []
                outputs = [try descriptor(url: finalBAMURL, format: .bam, role: .output)]
            case "index":
                inputs = [try descriptor(url: finalBAMURL, format: .bam, role: .output)]
                outputs = [try descriptor(url: finalIndexURL, format: nil, role: .index)]
            default:
                inputs = []
                outputs = []
            }
            previous = try appendStep(pair.1, inputs: inputs, outputs: outputs, dependsOn: previous.map { [$0.id] } ?? [])
        }
    }

    private func executeSamtools(arguments: [String]) async throws -> BuildDbSamtoolsInvocation {
        let samtoolsClock = ProvenanceRunClock()
        let result = try await NativeToolRunner.shared.runProcess(
            executableURL: samtoolsURL,
            arguments: arguments,
            timeout: 3600,
            toolName: "samtools"
        )
        return BuildDbSamtoolsInvocation(
            startedAt: samtoolsClock.startedAt,
            completedAt: samtoolsClock.now,
            result: result
        )
    }

    /// Records the step of `invocation` and returns it.
    @discardableResult
    private func appendStep(
        _ invocation: BuildDbSamtoolsInvocation,
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        dependsOn: [UUID] = []
    ) throws -> ProvenanceStep {
        let step = ProvenanceStep(
            toolName: "samtools",
            toolVersion: samtoolsVersion,
            argv: invocation.result.arguments,
            inputs: inputs,
            outputs: outputs,
            exitStatus: Int(invocation.result.exitCode),
            wallTimeSeconds: invocation.wallTimeSeconds,
            stderr: invocation.result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : invocation.result.stderr,
            dependsOn: dependsOn,
            startedAt: invocation.startedAt,
            completedAt: invocation.completedAt
        )
        collector.record(step)
        return step
    }

    private func descriptor(
        url: URL,
        format: FileFormat?,
        role: FileRole
    ) throws -> ProvenanceFileDescriptor {
        do {
            return try ProvenanceFileDescriptor.file(url: url, format: format, role: role)
        } catch {
            throw BuildDbSamtoolsProvenanceError.descriptorUnavailable(url.path, error.localizedDescription)
        }
    }
}
