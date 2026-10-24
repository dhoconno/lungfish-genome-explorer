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
    /// `interleave` step with no argv through `PortableMixedLayout` (M2 decision 3). The record keeps every launch, the
    /// largest peak memory of its launches and the orphans the run reaped since `adoptedSoFar`, and a step that fails
    /// keeps no output digest.
    func runOwnStep(
        _ step: PlanStep, tool: ImageTool, environment: [String: String], record: ExecutorStepRecord,
        adoptedSoFar: inout Int
    ) -> ExecutorStepRecord {
        var record = record
        record.argv = []
        let root = URL(fileURLWithPath: resolver.workRoot)
        let started = ContinuousClock.now
        let readerLog = ReaderChildLog()
        let childLauncher = ExecutorChildLauncher(
            controller: controller, decompressor: prepared.decompressor ?? (tool.id == "gzip" ? tool.path : nil),
            allowedPrograms: Set(prepared.manifest.tools.map(\.path)), graceSeconds: prepared.plan.graceSeconds,
            log: readerLog
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
                return OwnStepCounts(
                    input: nil, output: Int64(counts.writtenRecords),
                    mixed: ExecutorMixedLayoutCounts(mergedReads: counts.mergedRecords, pairs: counts.pairs, unpairedReads: 0)
                )
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
        let size = { (path: String) -> Int64 in
            (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path))?[.size] as? Int64 ?? 0
        }
        // The merged-to-mixed step records each decompressor child its reader started, in the storage step's launch
        // form, so the record names every program the step ran, and the child that failed the step states its end
        // (C4-3 C-3). The children of a storage step's count passes reach no record on either route yet (CHTC-c4v3).
        let readerLaunches = step.kind == .interleave
            ? Self.readerLaunches(readerLog.all, inputs: step.inputs, root: root, tools: prepared.manifest.tools) : []
        if !readerLaunches.isEmpty {
            record.storage = ExecutorStorageDetails(
                clumpingRan: false, qualityBinning: .none, inputBytes: step.inputs.reduce(0) { $0 + size($1) },
                outputBytes: 0, launches: readerLaunches
            )
            if let ended = readerLaunches.first(where: { $0.outcome != .succeeded }) ?? readerLaunches.last {
                record.toolExitCode = ended.toolExitCode
                record.toolSignal = ended.toolSignal
            }
        }
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
        // The step states what its launches state: the largest peak memory, any SIGKILL, every process stopped, and the
        // orphans the run reaped since the step before it, as an argv step does (tally K4.2, BIO fix 4 of the K4 part B
        // review).
        record.peakResidentBytes = launches.compactMap(\.peakResidentBytes).max()
        record.escalatedToSIGKILL = (launches + readerLaunches).contains { $0.escalatedToSIGKILL == true }
        record.stoppedProcesses = launches.flatMap { $0.stoppedProcesses ?? [] }
        if let reaped = launcher.adoptedOrphansReaped {
            record.adoptedOrphansReaped = reaped - adoptedSoFar
            adoptedSoFar = reaped
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
            if let mixed = counts.mixed {
                // The merged-to-mixed step states the mixed file's counts by kind, as the recipe engine counts them
                // (tally K4.1, BIO fix 2 of the K4 part B review).
                record.storage = ExecutorStorageDetails(
                    clumpingRan: false, qualityBinning: .none, inputBytes: step.inputs.reduce(0) { $0 + size($1) },
                    outputBytes: step.outputs.first.map(size) ?? 0, mixedLayout: mixed,
                    launches: readerLaunches.isEmpty ? nil : readerLaunches
                )
            }
        case .failure(let error):
            record.outcome = .failed
            // The controller's words for a launch the executor ended come first, so a deadline is never lost behind a
            // tool that printed nothing, and no path of the work root stays in the reason (SWIFT fix 3 of the K4 part B
            // review, ruling N8).
            let sentence = Self.sentence(for: error, heapGB: plan.storage.clumpifyHeapGB)
            record.reason = [launcher.lastStopReason, sentence].compactMap { $0 }.joined(separator: " ")
                .replacingOccurrences(of: resolver.workRoot + "/", with: "")
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
        /// The merged, pair and unpaired counts of the file a merged-to-mixed step wrote.
        var mixed: ExecutorMixedLayoutCounts?
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
            // The probe BBTools runs before it writes, so the record names the writer (K4-14), and a node whose bgzip
            // does not answer fails the step before clumpify starts (UX N3-2).
            let probe = try await storage.probeBBToolsWriter(environment: environment, compressionLevel: 4, threads: plan.storage.threads)
            try requireAnsweringBgzip(probe, step: step, environment: environment, plan: plan)
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
            try await storeWithoutClumping(
                plan: plan, step: step, inputs: inputs, output: output, root: root, environment: environment,
                storage: storage, launcher: launcher, compressor: compressor
            )
        }
    }

    /// UX's N3-2 words. BBTools writes through the first bgzip on its PATH that answers `bgzip -h`, else through its own
    /// writer, and the plan pins bgzip, so a step whose probe finds no answering bgzip fails before BBTools writes a byte,
    /// and no node stores bytes from a writer the plan does not name (tally-r2 N3-2 and N3-3b, fix 1 of the K4 part C UX
    /// review). The record names the writer's environment by the route that ran it (C4-3 C-4), so the version is the one
    /// check left that the answering bgzip is the one the plan pins: a probe whose bgzip states another version on its
    /// `Version:` line, or none, fails the step the same way (QA Q-4d).
    static func requireAnsweringBgzip(
        _ probe: PortableBBToolsWriterProbe, step: PlanStep, environment: [String: String], plan: ExecutionPlan
    ) throws {
        let tool = step.tool?.id ?? "BBTools"
        guard case .bgzip(let executable, _) = probe.writer else {
            throw ExecutorSpawn.Failure(
                reason: "Step \(step.id) did not run. \(tool) compresses its output with bgzip, and no bgzip "
                    + "answered `bgzip -h` on the step's PATH (\(environment["PATH"] ?? "")). The tool image must hold bgzip "
                    + "beside the BBTools scripts."
            )
        }
        guard let pinned = plan.tools.first(where: { $0.id == "bgzip" })?.version else {
            throw ExecutorSpawn.Failure(
                reason: "Step \(step.id) did not run. \(tool) compresses its output with bgzip, and the plan pins no bgzip."
            )
        }
        guard probe.version != pinned else { return }
        let states = probe.version.map { "states version \($0), not the version \(pinned) the plan pins" }
            ?? "states no version, so the executor cannot tell it is the version \(pinned) the plan pins"
        throw ExecutorSpawn.Failure(
            reason: "Step \(step.id) did not run. \(tool) compresses its output with bgzip, and the bgzip that answered "
                + "`bgzip -h` on the step's PATH, \(executable.path), \(states). The tool image must hold the pinned bgzip "
                + "beside the BBTools scripts."
        )
    }

    /// The decompressor children of a merged-to-mixed step as launches, in the order of the step's inputs and not the
    /// order they were reaped, since the R1 and R2 readers run together (SWIFT, CHTC CH-C3-1). Each states the absolute
    /// program that ran, never the `/usr/bin/gzip` the reader asked for, `-dc` and the work-relative input, its end, and
    /// that input with its SHA-256 (QA Q-3a). The child's stderr is `/dev/null`, so the launch keeps no stderr.
    /// Each argument under the work root loses the root's prefix in the one inline form the launcher and the runner use
    /// (`ExecutorToolLauncher`, `PlanRunner`), since the executor cannot import LungfishCore's `CanonicalFilePath` and keeps
    /// no helper of its own (`scripts/ratchets/path-helpers.sh`).
    static func readerLaunches(
        _ ends: [ReaderChildEnd], inputs: [String], root: URL, tools: [ImageTool]
    ) -> [ExecutorStorageLaunch] {
        let prefix = root.path + "/"
        let relativeArguments = ends.map { end in
            end.arguments.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
        }
        func position(_ index: Int) -> Int { inputs.firstIndex(of: relativeArguments[index].last ?? "") ?? inputs.count }
        let ordered = ends.indices.sorted { (position($0), $0) < (position($1), $1) }
        return ordered.map { index in
            let end = ends[index]
            let listed = tools.first { $0.path == end.executable }
            let id = listed?.id ?? URL(fileURLWithPath: end.executable).lastPathComponent
            let arguments = relativeArguments[index]
            let input = arguments.last ?? ""
            return ExecutorStorageLaunch(
                tool: ExecutorToolRecord(id: id, version: listed?.version ?? "", build: listed?.build ?? "", path: end.executable),
                argv: [end.executable] + arguments, environmentNames: end.environmentNames ?? [],
                outcome: end.isSuccess ? .succeeded : .failed, toolExitCode: end.exitCode, toolSignal: end.signal,
                wallSeconds: end.wallSeconds ?? 0, stderrPath: "/dev/null",
                reason: end.isSuccess ? nil : readerReason(end, tool: id, input: input),
                escalatedToSIGKILL: end.escalatedToSIGKILL,
                inputs: ExecutorFileDigest.hashing(input, under: root).map { [$0] }
            )
        }
    }

    /// The record's sentence for a decompressor child that did not succeed.
    static func readerReason(_ end: ReaderChildEnd, tool: String, input: String) -> String {
        if end.stopped { return "The executor stopped the decompressor \(tool) while it read \(input)." }
        if end.drainExpired {
            return "The decompressor \(tool) exited while it read \(input), and its output stayed open past the drain grace, "
                + "so the executor stopped its group."
        }
        if let signal = end.signal {
            return "The decompressor \(tool) ended by \(ExecutorSignals.name(signal)) while it read \(input)."
        }
        if let code = end.exitCode, code != 0 {
            return "The decompressor \(tool) stopped with status \(code) while it read \(input)."
        }
        return "The decompressor \(tool) ended before the reader read all of \(input)."
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
            // The Trim Galore route bins nothing, as on the Mac, so the record states the binning that ran (BIO fix 1 (b)
            // of the K4 part C review).
            qualityBinning: prepared.plan.storage.clumpingTool == .trimGalore
                ? QualityBinningScheme.none : prepared.plan.storage.qualityBinning,
            inputBytes: step.inputs.reduce(0) { $0 + size($1) }, outputBytes: step.outputs.first.map(size) ?? 0,
            launches: launches
        )
        // The launch that wrote the payload is the last one. A compressor writes at its own default level, which the
        // record does not state. BBTools writes through the bgzip that answered the probe, and a step whose probe found
        // none failed before BBTools ran (UX N3-2). A route that ran no probe, such as the Trim Galore route's
        // reformat.sh, states no writer, since no launch showed which one BBTools took (BIO fix 1 (a) of the K4 part C
        // review).
        guard let last = launches.last(where: { $0.argv.count > 1 && $0.argv.last != "-h" }) else { return details }
        if last.tool.id == "bgzip" || last.tool.id == "pigz" {
            details.writer = ExecutorStorageWriter(name: last.tool.id, tool: last.tool)
        } else if last.tool.id == "clumpify.sh" || last.tool.id == "reformat.sh" {
            if let answered = launches.first(where: { $0.argv.last == "-h" && $0.outcome == .succeeded }) {
                details.writer = ExecutorStorageWriter(name: "bgzip", tool: answered.tool)
            }
            details.effectiveCompressionLevel = last.argv.compactMap { $0.hasPrefix("zl=") ? Int($0.dropFirst(3)) : nil }.last
        }
        return details
    }

    /// The record's sentence for a storage failure. An out-of-memory clumpify never falls back to another route (K4-09).
    /// The sentence states what the record keeps, since a partial output may stay in the work root (UX fix 4 and BIO
    /// fix 1 (c) of the K4 part C review).
    static func sentence(for error: any Error, heapGB: Int) -> String {
        switch error {
        case PortableStorageError.outOfMemory(let tool, _):
            return "\(tool) ran out of memory in its \(heapGB) GB Java heap and stopped with status \(BBToolsOutOfMemory.exitStatus). "
                + "The plan's clumpifyHeapGB sets that heap. The record keeps no payload."
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
