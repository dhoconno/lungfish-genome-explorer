// PlanRunner.swift - Runs a checked plan's steps through StepController and fills the run record (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs each step of a plan that `RunCommand.prepare` checked, in order, through one `StepController`, with the plan's
/// deadline, grace and environment, in the work root. The first step that does not succeed ends the run, and the record
/// names it.
struct PlanRunner {
    let prepared: PreparedRun
    let resolver: PlanResourceResolver
    let controller: StepController
    /// The two folders after the manifest's on the child's `PATH`, fixed (SWIFT Q-K4-3). BBTools' wrapper scripts call
    /// `dirname`, `basename` and `readlink`, and no conda environment of the slice holds them. They come last, so a tool
    /// the manifest lists always wins, and nothing is inherited. A Java is never taken from them.
    static let systemFolders = ["/usr/bin", "/bin"]
    /// Each folder of the manifest's tools once, in the manifest's order, then `systemFolders` unless the manifest named one.
    let searchFolders: [String]
    /// The child's whole `PATH`.
    var searchPath: String { searchFolders.joined(separator: ":") }

    init(_ prepared: PreparedRun, resolver: PlanResourceResolver, controller: StepController) {
        self.prepared = prepared
        self.resolver = resolver
        self.controller = controller
        var folders: [String] = []
        for tool in prepared.manifest.tools {
            let slash = tool.path.lastIndex(of: "/") ?? tool.path.startIndex
            let folder = slash == tool.path.startIndex ? "/" : String(tool.path[..<slash])
            if !folders.contains(folder) { folders.append(folder) }
        }
        for folder in Self.systemFolders where !folders.contains(folder) { folders.append(folder) }
        searchFolders = folders
    }

    /// The manifest's first `java` as a tool record when the plan pins a BBTools wrapper, else none (SWIFT Q-K4-3).
    static func runtimes(of prepared: PreparedRun) -> [ExecutorToolRecord] {
        let pinned = Array(prepared.tools.values) + Array(prepared.storageTools.values)
        guard pinned.contains(where: { $0.id.hasSuffix(".sh") }),
              let java = prepared.manifest.tools.first(where: { $0.id == "java" }) else { return [] }
        return [ExecutorToolRecord(id: java.id, version: java.version, build: java.build, path: java.path)]
    }

    /// Whether the executor runs `step` by the plan's argv. An `interleave` step with an argv (paired to interleaved)
    /// runs by it.
    static func runsArgv(_ step: PlanStep) -> Bool {
        switch step.kind {
        case .recipe, .compress, .statistics: return true
        case .interleave: return !step.arguments.isEmpty
        case .storage, .qualityCount: return false
        }
    }

    /// Whether the executor builds `step` itself: the storage step and the merged-to-mixed `interleave` step, which
    /// carry no argv (`runOwnStep`). The Q20 and Q30 count runs no tool (`runQualityCount`).
    static func runsOwnStep(_ step: PlanStep) -> Bool {
        step.kind == .storage || (step.kind == .interleave && step.arguments.isEmpty)
    }

    /// Nil when the manifest's path is a regular file the executor may run, else the reason, naming the tool id.
    static func toolPathRefusal(_ tool: ImageTool) -> String? {
        var info = stat()
        guard stat(tool.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(tool.path, X_OK) == 0 else {
            return "The tool \(tool.id) at \(tool.path) is not a regular file the executor may run."
        }
        return nil
    }

    /// Runs the steps and sets the record's steps, outcome, reason, signal and the step the run stopped at.
    func run(into record: inout ExecutorRunRecord) {
        do {
            for folder in ["tmp", "home", "logs"] { try resolver.makeDirectory(folder) }
        } catch {
            record.outcome = .failed
            record.reason = "The executor could not make its folders in the work root. \(error.localizedDescription)"
            return
        }
        record.searchPath = searchFolders
        record.runtimes = Self.runtimes(of: prepared)
        var adoptedSoFar = 0
        var readCounts: [String: Int64] = [:]
        for step in prepared.plan.steps {
            if let signal = controller.interruptSignal {
                record.outcome = .interrupted
                record.signal = signal
                record.signalName = ExecutorSignals.name(signal)
                record.failedStepID = step.id
                record.reason = "The executor received \(ExecutorSignals.name(signal)) before step \(step.id) started."
                return
            }
            var stepRecord: ExecutorStepRecord
            if step.kind == .qualityCount {
                stepRecord = runQualityCount(step, run: record)
            } else if let tool = prepared.tools[step.id] {
                stepRecord = runStep(step, tool: tool, adoptedSoFar: &adoptedSoFar)
            } else {
                record.outcome = .failed
                record.failedStepID = step.id
                record.reason = "Step \(step.id) has no tool from the manifest."
                return
            }
            if step.kind == .recipe, stepRecord.outcome == .succeeded {
                countReads(of: step, into: &stepRecord, counted: &readCounts)
            }
            record.steps.append(stepRecord)
            record.payloads += Self.payloads(of: stepRecord)
            guard stepRecord.outcome == .succeeded else {
                record.outcome = stepRecord.outcome == .interrupted ? .interrupted : .failed
                record.failedStepID = step.id
                record.signal = stepRecord.signal
                record.signalName = stepRecord.signalName
                record.reason = "Step \(step.id) (\(step.title)) did not succeed. \(stepRecord.reason ?? "")"
                return
            }
        }
        record.outcome = .succeeded
    }

    /// Runs one step. Its stdout goes to the plan's `standardOutput` or `logs/<id>.stdout`, and its stderr to
    /// `logs/<id>.stderr`, each a descriptor `PlanResourceResolver.openOutput` made with no link followed.
    private func runStep(_ step: PlanStep, tool: ImageTool, adoptedSoFar: inout Int) -> ExecutorStepRecord {
        let workRoot = resolver.workRoot
        var environment = ["PATH": searchPath, "TMPDIR": workRoot + "/tmp", "HOME": workRoot + "/home"]
        for variable in step.environment {
            environment[variable.name] = variable.value
        }
        var record = ExecutorStepRecord(
            id: step.id, kind: step.kind,
            tool: ExecutorToolRecord(id: tool.id, version: tool.version, build: tool.build, path: tool.path),
            outcome: .refused, argv: [tool.path] + step.arguments, environmentNames: environment.keys.sorted(),
            graceSeconds: prepared.plan.graceSeconds, deadlineSeconds: step.deadlineSeconds,
            startedAt: ExecutorRunRecord.timestamp(Date()), endedAt: "", wallSeconds: 0
        )
        if let reason = Self.toolPathRefusal(tool) {
            record.reason = reason
            record.endedAt = ExecutorRunRecord.timestamp(Date())
            return record
        }
        if Self.runsOwnStep(step) {
            return runOwnStep(step, tool: tool, environment: environment, record: record, adoptedSoFar: &adoptedSoFar)
        }
        let streams: (stdout: PlanOutputFile, stderr: PlanOutputFile)
        do {
            for output in step.outputs {
                if let slash = output.lastIndex(of: "/") { try resolver.makeDirectory(String(output[..<slash])) }
            }
            let stdout = try resolver.openOutput(step.standardOutput ?? "logs/\(step.id).stdout")
            do {
                streams = (stdout, try resolver.openOutput("logs/\(step.id).stderr"))
            } catch {
                stdout.closeDescriptor()
                throw error
            }
        } catch {
            record.reason = "The executor could not make the step's files. \(error.localizedDescription)"
            record.endedAt = ExecutorRunRecord.timestamp(Date())
            return record
        }
        defer {
            streams.stdout.closeDescriptor()
            streams.stderr.closeDescriptor()
        }

        let prefix = workRoot + "/"
        let spec = StepSpec(
            executable: tool.path, arguments: step.arguments, environment: environment,
            stdoutPath: streams.stdout.relativePath, stderrPath: streams.stderr.relativePath,
            outputs: step.outputs.map { prefix + $0 },
            graceSeconds: prepared.plan.graceSeconds, deadlineSeconds: step.deadlineSeconds, sweepIntervalSeconds: 1,
            workingDirectory: workRoot, ownedStdout: streams.stdout.fileDescriptor, ownedStderr: streams.stderr.fileDescriptor
        )
        var result = controller.run(spec)
        if result.outcome != .interrupted, let signal = controller.interruptSignal {
            // A signal that arrived after the tool's end still ends the run as interrupted, with nothing left running.
            result.outcome = .interrupted
            result.signal = signal
            result.outputs = []
            result.reason = "The executor received \(ExecutorSignals.name(signal)) and stopped the step."
        }
        record.outcome = ExecutorRunOutcome(rawValue: result.outcome.rawValue) ?? .failed
        // A path in a reason is stated relative to the work root (SWIFT ruling N8).
        record.reason = result.reason?.replacingOccurrences(of: prefix, with: "")
        record.signal = result.signal
        record.signalName = result.signal.map(ExecutorSignals.name)
        record.toolPID = result.toolPID
        if case .exited(let code)? = result.exit?.termination { record.toolExitCode = code }
        if case .signaled(let signal)? = result.exit?.termination { record.toolSignal = signal }
        record.peakResidentBytes = result.exit?.peakResidentBytes
        record.escalatedToSIGKILL = result.escalatedToSIGKILL
        record.stoppedProcesses = result.stoppedProcesses
        record.adoptedOrphansReaped = result.adoptedOrphansReaped - adoptedSoFar
        adoptedSoFar = result.adoptedOrphansReaped
        record.outputs = result.outputs.map { output in
            let path = output.path.hasPrefix(prefix) ? String(output.path.dropFirst(prefix.count)) : output.path
            return ExecutorStepRecord.Output(path: path, bytes: output.bytes, sha256: output.sha256)
        }
        let tail = Self.stderrTail(streams.stderr, workRoot: workRoot)
        record.stderrTail = tail.text
        record.stderrBytes = tail.bytes
        record.stderrTruncated = tail.truncated
        if step.kind == .statistics { captureStatistics(step, standardOutput: streams.stdout, into: &record) }
        record.wallSeconds = result.wallSeconds
        record.endedAt = ExecutorRunRecord.timestamp(Date())
        return record
    }

    /// The last `limit` bytes of a step's stderr, decoded as UTF-8 with replacement, every byte the step wrote, and
    /// whether the tail is cut (tally K4.2). It reads through a new descriptor and only when that names the file the
    /// step wrote, by device and inode, since the step's own descriptor is open for writing only.
    static func stderrTail(
        _ file: PlanOutputFile,
        workRoot: String,
        limit: Int = ExecutorStepRecord.stderrTailLimit
    ) -> (text: String, bytes: UInt64, truncated: Bool) {
        let fd = open(workRoot + "/" + file.relativePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return ("", 0, false) }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, UInt64(truncatingIfNeeded: status.st_dev) == file.device,
              UInt64(truncatingIfNeeded: status.st_ino) == file.inode else { return ("", 0, false) }
        let size = Int64(status.st_size)
        let start = max(0, size - Int64(limit))
        var buffer = [UInt8](repeating: 0, count: Int(size - start))
        var filled = 0
        while filled < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, raw.count - filled, off_t(start) + off_t(filled))
            }
            if count > 0 {
                filled += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return (String(decoding: buffer[..<filled], as: UTF8.self), UInt64(size), size > Int64(limit))
    }
}
