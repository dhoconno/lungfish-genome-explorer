// PlanRunner+Storage.swift - The storage step and the merged-to-mixed step that run --plan runs itself (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import Synchronization

extension PlanRunner {
    /// The plan's storage tools as `PortableStorageStep` names them.
    static let storageTools: [String: PortableStorageTool] = [
        "clumpify.sh": .clumpify, "reformat.sh": .reformat, "trim_galore": .trimGalore, "bgzip": .bgzip, "pigz": .pigz,
    ]

    /// Runs a step the executor builds itself: a storage step through `PortableStorageStep` (M2 decision 2), or an
    /// `interleave` step with no argv through `PortableMixedLayout` (M2 decision 3). The record keeps every launch, and a
    /// step that fails keeps no output digest.
    func runOwnStep(_ step: PlanStep, tool: ImageTool, environment: [String: String], record: ExecutorStepRecord) -> ExecutorStepRecord {
        var record = record
        record.argv = []
        let root = URL(fileURLWithPath: resolver.workRoot)
        let started = ContinuousClock.now
        let childLauncher = ExecutorChildLauncher(
            controller: controller, decompressor: prepared.decompressor ?? (tool.id == "gzip" ? tool.path : nil),
            graceSeconds: prepared.plan.graceSeconds
        )
        let launcher = ExecutorToolLauncher(
            stepID: step.id, tools: prepared.storageTools, manifestTools: prepared.manifest.tools, controller: controller,
            resolver: resolver, environment: environment, graceSeconds: prepared.plan.graceSeconds,
            deadlineSeconds: step.deadlineSeconds
        )
        let plan = prepared.plan
        let outcome = Self.blocking { () async throws -> OwnStepCounts in
            for output in step.outputs {
                if let slash = output.lastIndex(of: "/") { try resolver.makeDirectory(String(output[..<slash])) }
            }
            let inputs = step.inputs.map { root.appendingPathComponent($0) }
            guard let first = step.outputs.first else {
                throw ExecutorSpawn.Failure(reason: "Step \(step.id) names no output.")
            }
            let output = root.appendingPathComponent(first)
            if step.kind == .interleave {
                guard inputs.count == 1 || inputs.count == 3 else {
                    throw ExecutorSpawn.Failure(reason: "Step \(step.id) needs the merged reads and, when present, both unmerged files.")
                }
                let counts = try await PortableMixedLayout.writeMixedLayout(
                    merged: inputs[0], unmergedR1: inputs.count == 3 ? inputs[1] : nil,
                    unmergedR2: inputs.count == 3 ? inputs[2] : nil, to: output, launcher: childLauncher
                )
                return OwnStepCounts(input: nil, output: Int64(counts.writtenRecords))
            }
            try await Self.store(plan: plan, step: step, inputs: inputs, output: output, root: root, environment: environment,
                                 launcher: launcher, childLauncher: childLauncher)
            let counted = try await PortableStorageChecks.detachedWork { () throws -> (Int, Int) in
                let input = try inputs.reduce(0) { $0 + (try FASTQPairInterleaver.countRecords(in: $1, launcher: childLauncher)) }
                return (input, try FASTQPairInterleaver.countRecords(in: output, launcher: childLauncher))
            }
            return OwnStepCounts(input: Int64(counted.0), output: Int64(counted.1))
        }

        let launches = launcher.launches
        if step.kind == .storage {
            record.storage = storageDetails(step: step, launches: launches, root: root)
            if let own = launches.first(where: { $0.tool.id == tool.id }) {
                record.argv = own.argv
                record.environmentNames = own.environmentNames
            }
        }
        if let last = launches.last {
            record.toolExitCode = last.toolExitCode
            record.toolSignal = last.toolSignal
            if let tail = launcher.lastStderrTail {
                record.stderrTail = tail.text
                record.stderrBytes = tail.bytes
                record.stderrTruncated = tail.truncated
            }
        }
        switch outcome {
        case .success(let counts):
            record.inputReadCount = counts.input
            record.outputReadCount = counts.output
            record.outputs = step.outputs.compactMap { path in
                let url = root.appendingPathComponent(path)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
                      let digest = try? PortableDigest.sha256Hex(ofFileAt: url) else { return nil }
                return ExecutorStepRecord.Output(path: path, bytes: UInt64(size), sha256: digest)
            }
            record.outcome = record.outputs.count == step.outputs.count ? .succeeded : .failed
            if record.outcome == .failed { record.reason = "Step \(step.id) left an output missing." }
        case .failure(let error):
            record.outcome = .failed
            record.reason = Self.sentence(for: error, heapGB: plan.storage.clumpifyHeapGB)
        }
        if let signal = controller.interruptSignal {
            record.outcome = .interrupted
            record.signal = signal
            record.signalName = ExecutorSignals.name(signal)
            record.outputs = []
            record.reason = "The executor received \(ExecutorSignals.name(signal)) and stopped the step."
        }
        record.wallSeconds = StepController.seconds(since: started)
        record.endedAt = ExecutorRunRecord.timestamp(Date())
        return record
    }

    private struct OwnStepCounts: Sendable {
        var input: Int64?
        var output: Int64
    }

    /// Runs the storage route the plan names, with the plan's heap, threads, binning, level, compressor and deadline.
    private static func store(
        plan: ExecutionPlan, step: PlanStep, inputs: [URL], output: URL, root: URL, environment: [String: String],
        launcher: ExecutorToolLauncher, childLauncher: ExecutorChildLauncher
    ) async throws {
        let storage = PortableStorageStep(launcher: launcher, childLauncher: childLauncher)
        let compressor = PortableCompressor(rawValue: plan.storage.compressor.rawValue)
        switch plan.storage.clumpingTool {
        case .bbtools:
            // The probe BBTools runs before it writes, so the record names the writer (K4-14).
            _ = try await storage.probeBBToolsWriter(environment: environment, compressionLevel: 4, threads: plan.storage.threads)
            _ = try await storage.clumpify(PortableStorageStep<ExecutorToolLauncher>.ClumpifyRun(
                inputs: inputs, output: output, workingDirectory: root, heapGB: plan.storage.clumpifyHeapGB,
                threads: plan.storage.threads, qualityBinning: plan.storage.qualityBinning, environment: environment,
                compressor: compressor, deadlineSeconds: step.deadlineSeconds
            ), progress: { _, _ in })
        case .trimGalore:
            _ = try await storage.trimGalore(PortableStorageStep<ExecutorToolLauncher>.TrimGaloreRun(
                inputs: inputs, pairing: inputs.count > 1 ? .pairs : .interleavedFile, output: output,
                workingDirectory: root, stem: "sample", threads: plan.storage.threads,
                compressionLevel: plan.storage.compressionLevel, memoryBytes: plan.clumping.heapBytes,
                compressor: compressor, deadlineSeconds: step.deadlineSeconds
            ), progress: { _, _ in })
        case .none:
            throw ExecutorSpawn.Failure(reason: "This executor build does not run the storage route none yet.")
        }
    }

    /// The storage fields of the record: the writer and level (K4-14), clumpify's group and memory lines from its launch
    /// with the most groups (K4-10), the sizes and every launch.
    private func storageDetails(step: PlanStep, launches: [ExecutorStorageLaunch], root: URL) -> ExecutorStorageDetails {
        func size(_ path: String) -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path))?[.size] as? Int64 ?? 0
        }
        let clumpify = launches.filter { $0.clumpifyGroups != nil || $0.clumpifyMemoryEstimateLine != nil }
        let chosen = clumpify.max { ($0.clumpifyGroups ?? 0) < ($1.clumpifyGroups ?? 0) }
        var details = ExecutorStorageDetails(
            clumpifyGroups: chosen?.clumpifyGroups, clumpifyMemoryEstimateLine: chosen?.clumpifyMemoryEstimateLine,
            clumpifyMemoryAvailableLine: chosen?.clumpifyMemoryAvailableLine,
            clumpingRan: launches.contains { $0.tool.id == "clumpify.sh" || $0.tool.id == "trim_galore" },
            qualityBinning: prepared.plan.storage.qualityBinning,
            inputBytes: step.inputs.reduce(0) { $0 + size($1) }, outputBytes: step.outputs.first.map(size) ?? 0,
            launches: launches
        )
        // The launch that wrote the payload is the last one. A compressor writes at its own default level, which the
        // record does not state. BBTools writes through the bgzip the probe found, else its own BGZF writer.
        guard let last = launches.last(where: { $0.argv.count > 1 && $0.argv.last != "-h" }) else { return details }
        if last.tool.id == "bgzip" || last.tool.id == "pigz" {
            details.writer = ExecutorStorageWriter(name: last.tool.id, tool: last.tool)
        } else if last.tool.id == "clumpify.sh" || last.tool.id == "reformat.sh" {
            let probe = launches.first { $0.argv.last == "-h" && $0.outcome == .succeeded }
            details.writer = ExecutorStorageWriter(name: probe == nil ? "BBTools native BGZF" : "bgzip", tool: probe?.tool)
            details.effectiveCompressionLevel = last.argv.compactMap { $0.hasPrefix("zl=") ? Int($0.dropFirst(3)) : nil }.last
        }
        return details
    }

    /// The record's sentence for a storage failure. An out-of-memory clumpify never falls back to another route (K4-09).
    static func sentence(for error: any Error, heapGB: Int) -> String {
        switch error {
        case PortableStorageError.outOfMemory(let tool, _):
            return "\(tool) ran out of memory in its \(heapGB) GB Java heap and stopped with status \(BBToolsOutOfMemory.exitStatus). "
                + "The plan's clumpifyHeapGB sets that heap. No output was kept."
        case PortableStorageError.storageFailed(let text): return "The storage step failed. \(text)"
        case PortableStorageError.compressionFailed(let text): return "The compressor failed. \(text)"
        case PortableStorageError.compressorNotFound: return "The storage step had to compress and the plan names no compressor."
        case PortableStorageError.pairedOutputVerificationFailed(let text): return "The stored pairs do not match. \(text)"
        case let failure as ExecutorSpawn.Failure: return failure.reason
        default: return "The step failed. \(error.localizedDescription)"
        }
    }

    /// Runs async work to its end from the runner's synchronous loop, off the cooperative pool's caller.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, any Error> {
        let box = Mutex<Result<T, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result: Result<T, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            box.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 } ?? .failure(CancellationError())
    }
}
