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

final class BuildDbSamtoolsProvenanceCollector {
    fileprivate var recordedSteps: [ProvenanceStep] = []

    var steps: [ProvenanceStep] {
        recordedSteps
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
        let startedAt = Date()
        let result = try await NativeToolRunner.shared.runProcess(
            executableURL: samtoolsURL,
            arguments: arguments,
            timeout: timeout,
            toolName: "samtools"
        )
        let completedAt = Date()
        invocations.append(
            BuildDbSamtoolsInvocation(
                startedAt: startedAt,
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
        let startedAt = Date()
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
                durationSeconds: Date().timeIntervalSince(startedAt)
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

            let total = try await countReads(bamURL: bamURL, accession: nil, flagFilter: 0x004)
            let nonDuplicate = try await countReads(bamURL: bamURL, accession: nil, flagFilter: 0x404)

            return MarkdupResult(
                bamURL: bamURL,
                wasAlreadyMarkduped: false,
                totalReads: total,
                duplicateReads: max(0, total - nonDuplicate),
                durationSeconds: Date().timeIntervalSince(startedAt)
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
        let output = invocation.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
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
            try appendStep(pair.1, inputs: inputs, outputs: outputs)
        }
    }

    private func executeSamtools(arguments: [String]) async throws -> BuildDbSamtoolsInvocation {
        let startedAt = Date()
        let result = try await NativeToolRunner.shared.runProcess(
            executableURL: samtoolsURL,
            arguments: arguments,
            timeout: 3600,
            toolName: "samtools"
        )
        return BuildDbSamtoolsInvocation(
            startedAt: startedAt,
            completedAt: Date(),
            result: result
        )
    }

    private func appendStep(
        _ invocation: BuildDbSamtoolsInvocation,
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor]
    ) throws {
        collector.recordedSteps.append(
            ProvenanceStep(
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
                startedAt: invocation.startedAt,
                completedAt: invocation.completedAt
            )
        )
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
