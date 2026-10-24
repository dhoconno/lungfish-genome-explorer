// ExecutorToolLauncher.swift - The storage step's tool launcher on the node, over the run's StepController (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import Synchronization

/// Runs each launch of a `PortableStorageStep` through the run's one `StepController`, in the work root, within what is
/// left of the plan's deadline for the step (K2 review O-1, tally-r2 K4-06), and keeps a record of every launch.
///
/// Each argv path is made relative to the work root before the spawn (SWIFT N8). The child's environment is the step's,
/// with `_JAVA_OPTIONS` only for clumpify (tally-r2 K4-07). Stdout goes to the launch's output file or
/// `logs/<step>.<n>.stdout`, and stderr to `logs/<step>.<n>.stderr`. Each launch keeps the controller's sentence when it
/// did not succeed, what the controller signalled to stop it and its peak resident memory (SWIFT fix 3 and BIO fix 4 of
/// the K4 part B review).
final class ExecutorToolLauncher: PortableToolLauncher, Sendable {
    typealias Record = ExecutorStorageLaunch

    let stepID: String
    /// The manifest's tool for each storage tool the plan pins.
    let tools: [PortableStorageTool: ImageTool]
    /// Every tool of the manifest, to name a tool the writer probe found on the step's `PATH`.
    let manifestTools: [ImageTool]
    let controller: StepController
    let resolver: PlanResourceResolver
    let environment: [String: String]
    let graceSeconds: Double
    let deadline: ContinuousClock.Instant
    private let made = Mutex<[ExecutorStorageLaunch]>([])
    private let tail = Mutex<(text: String, bytes: UInt64, truncated: Bool)?>(nil)
    private let stop = Mutex<String?>(nil)
    private let adopted = Mutex<Int?>(nil)

    init(
        stepID: String, tools: [PortableStorageTool: ImageTool], manifestTools: [ImageTool], controller: StepController,
        resolver: PlanResourceResolver, environment: [String: String], graceSeconds: Double, deadlineSeconds: Double
    ) {
        self.stepID = stepID
        self.tools = tools
        self.manifestTools = manifestTools
        self.controller = controller
        self.resolver = resolver
        self.environment = environment
        self.graceSeconds = graceSeconds
        deadline = ContinuousClock.now + .milliseconds(Int64(deadlineSeconds * 1000))
    }

    /// Every launch so far, in order.
    var launches: [ExecutorStorageLaunch] { made.withLock { $0 } }

    /// The stderr tail of the last launch, the one that ended the step (tally K4.2).
    var lastStderrTail: (text: String, bytes: UInt64, truncated: Bool)? { tail.withLock { $0 } }

    /// The controller's sentence for the last launch the executor itself ended, at the step's deadline, for a
    /// termination signal or for a process left running, with each path relative to the work root. Nil when the
    /// executor ended no launch, so a tool's own exit is stated by the storage step's sentence alone.
    var lastStopReason: String? { stop.withLock { $0 } }

    /// The run's count of adopted orphans reaped, as the controller stated it after the last launch.
    var adoptedOrphansReaped: Int? { adopted.withLock { $0 } }

    /// The plan's tool id for each storage tool.
    static let toolIDs: [PortableStorageTool: String] = [
        .clumpify: "clumpify.sh", .reformat: "reformat.sh", .trimGalore: "trim_galore", .bgzip: "bgzip", .pigz: "pigz",
    ]

    func executableURL(for tool: PortableStorageTool) async throws -> URL {
        guard let image = tools[tool] else {
            throw ExecutorSpawn.Failure(reason: "The plan pins no \(Self.toolIDs[tool] ?? tool.rawValue) for step \(stepID).")
        }
        return URL(fileURLWithPath: image.path)
    }

    /// The launch's environment, the step's with the launch's own variables over it and `_JAVA_OPTIONS` only for
    /// clumpify (tally-r2 K4-07).
    func environment(for launch: PortableToolLaunch) -> [String: String] {
        var merged = environment.merging(launch.environment ?? [:]) { _, new in new }
        if launch.tool != .clumpify { merged["_JAVA_OPTIONS"] = nil }
        return merged
    }

    func run(_ launch: PortableToolLaunch) async throws -> PortableToolOutcome {
        let tool: ImageTool
        if let executable = launch.executable {
            guard let listed = manifestTools.first(where: { $0.path == executable.path }) else {
                throw ExecutorSpawn.Failure(reason: "The program \(executable.path) is not in the tool manifest.")
            }
            tool = listed
        } else {
            tool = try await image(for: launch.tool)
        }
        let workRoot = resolver.workRoot
        let prefix = workRoot + "/"
        if let folder = launch.workingDirectory, folder.path != workRoot {
            throw ExecutorSpawn.Failure(reason: "A storage launch asked for the folder \(folder.path), not the work root.")
        }
        let number = made.withLock { $0.count } + 1
        let stderrPath = "logs/\(stepID).\(number).stderr"
        let stdoutPath = launch.standardOutput.map { $0.path.hasPrefix(prefix) ? String($0.path.dropFirst(prefix.count)) : $0.path }
            ?? "logs/\(stepID).\(number).stdout"
        let stdout = try resolver.openOutput(stdoutPath)
        defer { stdout.closeDescriptor() }
        let stderr = try resolver.openOutput(stderrPath)
        defer { stderr.closeDescriptor() }

        let arguments = launch.arguments.map { $0.replacingOccurrences(of: prefix, with: "") }
        let launchEnvironment = environment(for: launch)
        let left = deadline - ContinuousClock.now
        let leftSeconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        let spec = StepSpec(
            executable: tool.path, arguments: arguments, environment: launchEnvironment,
            stdoutPath: stdout.relativePath, stderrPath: stderr.relativePath, outputs: [],
            graceSeconds: graceSeconds, deadlineSeconds: max(0.001, min(launch.timeout, leftSeconds)),
            sweepIntervalSeconds: 1, workingDirectory: workRoot,
            ownedStdout: stdout.fileDescriptor, ownedStderr: stderr.fileDescriptor
        )
        let started = Date()
        let controller = self.controller
        let result: StepResult = await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: controller.run(spec)) }.start()
        }
        let stderrTail = PlanRunner.stderrTail(stderr, workRoot: workRoot)
        tail.withLock { $0 = stderrTail }
        let tail = stderrTail.text
        let stdoutText = launch.standardOutput == nil ? PlanRunner.stderrTail(stdout, workRoot: workRoot).text : ""
        // A path in a reason is stated relative to the work root (SWIFT ruling N8).
        let reason = result.outcome == .succeeded ? nil : result.reason?.replacingOccurrences(of: prefix, with: "")
        if result.stoppedByExecutor, let reason {
            stop.withLock { $0 = reason }
        }
        adopted.withLock { $0 = result.adoptedOrphansReaped }

        var exitCode: Int32 = -1
        var entry = ExecutorStorageLaunch(
            tool: ExecutorToolRecord(id: tool.id, version: tool.version, build: tool.build, path: tool.path),
            argv: [tool.path] + arguments, environmentNames: launchEnvironment.keys.sorted(),
            outcome: ExecutorRunOutcome(rawValue: result.outcome.rawValue) ?? .failed,
            wallSeconds: result.wallSeconds, stderrPath: stderrPath, reason: reason,
            escalatedToSIGKILL: result.escalatedToSIGKILL, stoppedProcesses: result.stoppedProcesses,
            peakResidentBytes: result.exit?.peakResidentBytes
        )
        switch result.exit?.termination {
        case .exited(let code)?:
            entry.toolExitCode = code
            exitCode = code
        case .signaled(let signal)?:
            entry.toolSignal = signal
            exitCode = 128 + signal
        default:
            break
        }
        if launch.tool == .clumpify && launch.executable == nil {
            let lines = PortableClumpifyLog(tail)
            entry.clumpifyGroups = lines.groups
            entry.clumpifyMemoryEstimateLine = lines.memoryEstimate
            entry.clumpifyMemoryAvailableLine = lines.memoryAvailable
        }
        let recorded = entry
        made.withLock { $0.append(recorded) }
        return PortableToolOutcome(
            exitCode: exitCode, isSuccess: result.outcome == .succeeded, stdout: stdoutText, stderr: tail,
            startTime: started, endTime: Date()
        )
    }

    /// The record of a launch the step accepted, with the files it read and wrote hashed now, while they still exist,
    /// since the step deletes each scratch half once it is processed (QV-23). A path outside the work root, or a folder
    /// such as the one a Trim Galore call writes into, is not hashed.
    func record(_ run: PortableToolRun) async -> ExecutorStorageLaunch {
        let prefix = resolver.workRoot + "/"
        let root = URL(fileURLWithPath: resolver.workRoot)
        let argv = run.launch.arguments.map { $0.replacingOccurrences(of: prefix, with: "") }
        let digests = { (urls: [URL]) -> [ExecutorFileDigest]? in
            let found = urls.compactMap { url -> ExecutorFileDigest? in
                guard url.path.hasPrefix(prefix) else { return nil }
                return ExecutorFileDigest.hashing(String(url.path.dropFirst(prefix.count)), under: root)
            }
            return found.isEmpty ? nil : found
        }
        let inputs = digests(run.inputs)
        let outputs = digests(run.outputs)
        let recorded: ExecutorStorageLaunch? = made.withLock { all in
            guard let index = all.lastIndex(where: { Array($0.argv.dropFirst()) == argv }) else { return nil }
            all[index].inputs = inputs
            all[index].outputs = outputs
            return all[index]
        }
        return recorded ?? ExecutorStorageLaunch(
            tool: ExecutorToolRecord(id: run.executableURL.lastPathComponent, version: "", build: "", path: run.executableURL.path),
            argv: [run.executableURL.path] + argv, environmentNames: [], outcome: .succeeded, wallSeconds: 0, stderrPath: "",
            inputs: inputs, outputs: outputs
        )
    }

    private func image(for tool: PortableStorageTool) async throws -> ImageTool {
        guard let image = tools[tool] else {
            throw ExecutorSpawn.Failure(reason: "The plan pins no \(Self.toolIDs[tool] ?? tool.rawValue) for step \(stepID).")
        }
        return image
    }
}

extension ExecutorFileDigest {
    /// The digest of the regular file at `relativePath` under `root`, nil for a folder or a file that cannot be read.
    static func hashing(_ relativePath: String, under root: URL) -> ExecutorFileDigest? {
        let url = root.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              let digest = try? PortableDigest.sha256Hex(ofFileAt: url) else { return nil }
        return ExecutorFileDigest(relativePath: relativePath, sha256: digest, size: size)
    }
}
