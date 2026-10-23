// RunCommand.swift - lungfish-executor run --plan: one plan's steps on this machine and its run record (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import LungfishPortable

/// Why a run may not start, with the plan field or argument it names. Every refusal comes before any tool runs.
struct RunRefusal: Error, Equatable {
    var field: String
    var reason: String
}

/// What the checks before the first tool hand the steps.
struct PreparedRun {
    var plan: ExecutionPlan
    var manifest: ImageToolManifest
    /// The manifest's tool for each step, by step id.
    var tools: [String: ImageTool]
    /// The manifest's tool for each storage tool the plan pins (`PlanRunner.storageTools`).
    var storageTools: [PortableStorageTool: ImageTool] = [:]
    /// The plan's pinned `gzip`, else `pigz`, which reads gzip input in place of `/usr/bin/gzip`.
    var decompressor: String?
}

/// `lungfish-executor run --plan <file> [--image-manifest <absolute file>] [--site-fact KEY=VALUE]...`
///
/// The run checks, in order, the site facts (tally-r2 3.1), the subreaper, the plan, the running binary against the
/// plan's executor entry before any other file is read (tally K4.4), the tool manifest (SWIFT ruling Q-K4-1), each step's
/// kind, tool pin and tool path, the plan's files, and the preflight (tally-r2 K4-16). A failed check refuses the run
/// before any tool starts. Then each step runs through one `StepController`, and the record is written last, by one
/// rename, as `run-record.json` at the work root (ARCH-r3 ruling 2). Exit codes are `ExecutorExitCode`.
enum RunCommand {
    static let usage = "usage: lungfish-executor run --plan <file> [--image-manifest <absolute file>] [--site-fact KEY=VALUE]...\n"
    static let maximumSiteFacts = 64
    static let maximumSiteFactValueBytes = 1024
    /// The largest plan file the executor reads.
    static let maximumPlanSize = 16 << 20

    struct Options: Equatable {
        var plan = ""
        var imageManifest: String?
        var siteFacts: [String] = []
    }

    /// Parses the arguments after `run`, or returns the usage error.
    static func parse(_ arguments: [String]) -> Result<Options, StepCommand.UsageError> {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--plan", "--image-manifest", "--site-fact"].contains(flag) else {
                return .failure("unknown option \(flag)")
            }
            guard index + 1 < arguments.count else { return .failure("\(flag) needs a value") }
            let value = arguments[index + 1]
            switch flag {
            case "--plan":
                guard options.plan.isEmpty, !value.isEmpty else { return .failure("--plan needs one file") }
                options.plan = value
            case "--image-manifest":
                guard options.imageManifest == nil else { return .failure("--image-manifest is given twice") }
                options.imageManifest = value
            default:
                options.siteFacts.append(value)
            }
            index += 2
        }
        guard !options.plan.isEmpty else { return .failure("--plan is required") }
        return .success(options)
    }

    /// The site facts in the order given, or the refusal that names the argument's position and the rule it broke, never
    /// its value (tally-r2 3.1). A fact is recorded and never interpreted, passed to a tool or used to find a file.
    static func siteFacts(_ arguments: [String]) -> Result<[PlanKeyValue], RunRefusal> {
        guard arguments.count <= maximumSiteFacts else {
            let position = maximumSiteFacts + 1
            return .failure(RunRefusal(
                field: "--site-fact \(position)",
                reason: "Site fact \(position) is over the limit of \(maximumSiteFacts) site facts. No tool ran."
            ))
        }
        var facts: [PlanKeyValue] = []
        var keys = Set<String>()
        for (offset, text) in arguments.enumerated() {
            let position = offset + 1
            let refusal = { (rule: String) in
                RunRefusal(field: "--site-fact \(position)", reason: "Site fact \(position) \(rule) No tool ran.")
            }
            guard let equals = text.firstIndex(of: "=") else { return .failure(refusal("is not KEY=VALUE.")) }
            let key = String(text[..<equals])
            let value = String(text[text.index(after: equals)...])
            guard isSiteFactKey(key) else {
                return .failure(refusal("has a key that is not a letter followed by at most 63 letters, digits or underscores."))
            }
            guard value.utf8.count <= maximumSiteFactValueBytes else {
                return .failure(refusal("has a value over \(maximumSiteFactValueBytes) bytes."))
            }
            guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                return .failure(refusal("has a value that holds a control character."))
            }
            guard keys.insert(key).inserted else { return .failure(refusal("repeats the key of an earlier site fact.")) }
            facts.append(PlanKeyValue(key: key, value: value))
        }
        return .success(facts)
    }

    /// `[A-Za-z][A-Za-z0-9_]{0,63}`.
    static func isSiteFactKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        func letter(_ scalar: Unicode.Scalar) -> Bool { ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) }
        guard (1...64).contains(scalars.count), letter(scalars[0]) else { return false }
        return scalars.allSatisfy { letter($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// The text the record states in place of the `--image-manifest` value.
    static let notRecorded = "(not recorded)"

    /// The argv the record states: `commandLine`, the executor's argv after its own path, with the `--plan` value cut
    /// to its file name and the `--image-manifest` value stated as `(not recorded)`, so the record holds no path of the
    /// machine that ran it (SWIFT rulings N8 and Q-K4-1). The `--site-fact` pairs stay verbatim (tally-r2 3.1).
    static func recordedArguments(_ commandLine: [String]) -> [String] {
        var recorded = commandLine
        var index = 0
        while index < recorded.count {
            let flag = recorded[index]
            guard ["--plan", "--image-manifest", "--site-fact"].contains(flag), index + 1 < recorded.count else {
                index += 1
                continue
            }
            if flag == "--plan" {
                recorded[index + 1] = URL(fileURLWithPath: recorded[index + 1]).lastPathComponent
            } else if flag == "--image-manifest" {
                recorded[index + 1] = notRecorded
            }
            index += 2
        }
        return recorded
    }

    /// Runs the mode. Called from `main` after the termination signals are blocked and before any thread exists.
    /// `commandLine` is the executor's argv after its own path, which the record states through `recordedArguments`.
    static func main(_ arguments: [String], commandLine: [String] = Array(CommandLine.arguments.dropFirst())) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            FileHandle.standardError.write(Data("lungfish-executor: \(error.message)\n\(usage)".utf8))
            return ExecutorExitCode.usage
        }
        // Before any thread or child exists (tally-r2 K3-1). Off Linux both calls return ENOSYS and change nothing.
        let subreaper = ChildSubreaper.setAndConfirm()
        let started = Date()
        let clock = ContinuousClock.now
        let resolver: PlanResourceResolver
        do {
            resolver = try PlanResourceResolver(planFile: URL(fileURLWithPath: options.plan))
        } catch {
            let message = "lungfish-executor: refused: The plan's folder cannot be resolved, so no run record can be written. "
                + "\(error.localizedDescription) No tool ran.\n"
            FileHandle.standardError.write(Data(message.utf8))
            return ExecutorExitCode.refused
        }
        ExecutorSignals.ignoreBrokenPipe()
        ExecutorSpawn.markInheritedDescriptorsCloseOnExec()
        let controller = StepController()
        let sources = ExecutorSignals.watch(queue: DispatchQueue(label: "lungfish-executor.signals")) { signal in
            controller.interrupt(signal)
        }
        var record = ExecutorRunRecord(
            outcome: .refused, executorArguments: recordedArguments(commandLine),
            executor: ExecutorBinaryIdentity(sha256: nil, size: nil, buildPin: nil), plan: nil, imageManifest: nil,
            runtimeIdentity: RuntimeObservation.identity(subreaper: subreaper),
            startedAt: ExecutorRunRecord.timestamp(started), endedAt: "", wallSeconds: 0
        )
        do throws(RunRefusal) {
            let prepared = try prepare(options, resolver: resolver, subreaper: subreaper, record: &record)
            PlanRunner(prepared, resolver: resolver, controller: controller).run(into: &record)
        } catch {
            record.outcome = .refused
            record.refusedField = error.field
            record.reason = error.reason
        }
        withExtendedLifetime(sources) {}
        record.exitCode = record.outcome.exitCode
        record.endedAt = ExecutorRunRecord.timestamp(Date())
        record.wallSeconds = StepController.seconds(since: clock)
        return finish(record, workRoot: resolver.workRoot)
    }

    /// The checks before any tool runs. Each fills the record with what it read, and a failed one throws the refusal.
    static func prepare(
        _ options: Options,
        resolver: PlanResourceResolver,
        subreaper: ChildSubreaper.Report,
        subreaperRequired: Bool = StepCommand.isLinux,
        record: inout ExecutorRunRecord
    ) throws(RunRefusal) -> PreparedRun {
        switch siteFacts(options.siteFacts) {
        case .success(let facts): record.siteFacts = facts
        case .failure(let refusal): throw refusal
        }
        if subreaperRequired && !subreaper.isSet {
            let code = subreaper.setterResult != 0 ? subreaper.setterResult : subreaper.getterResult
            let name = code != 0 ? ChildSubreaper.errnoName(code) : "a getter value of \(subreaper.getterValue ?? 0)"
            throw RunRefusal(field: "subreaper", reason: StepReason.subreaperRefused(errnoName: name))
        }

        let planName = URL(fileURLWithPath: options.plan).lastPathComponent
        let planBytes: Data
        do throws(RunFiles.ReadError) {
            planBytes = try RunFiles.readWhole(options.plan, limit: maximumPlanSize)
        } catch {
            throw RunRefusal(field: "--plan", reason: "The plan file \(planName) \(error.phrase) No tool ran.")
        }
        record.plan = ExecutorFileDigest(
            relativePath: planName, sha256: PortableDigest.sha256Hex(of: planBytes), size: Int64(planBytes.count)
        )
        let plan: ExecutionPlan
        do {
            plan = try ExecutionPlan.decode(planBytes)
        } catch let error as PlanDecodeError {
            throw RunRefusal(field: error.field, reason: "\(error.reason) No tool ran.")
        } catch {
            throw RunRefusal(field: "--plan", reason: "The plan file \(planName) cannot be read. No tool ran.")
        }
        record.executor.buildPin = plan.executor
        record.recipe = plan.recipe

        // The self-check, before any file past the plan is read (tally K4.4). The plan pins exactly one executor entry.
        let executorIndex = plan.entries.firstIndex { $0.role == .executor } ?? 0
        let pinned = plan.entries[executorIndex]
        guard let running = RunFiles.runningExecutorDigest() else {
            throw RunRefusal(
                field: "entries[\(executorIndex)]",
                reason: "The executor could not read its own binary to check it against the plan's executor entry. No tool ran."
            )
        }
        record.executor.sha256 = running.sha256
        record.executor.size = running.size
        guard running.sha256 == pinned.sha256, running.size == pinned.size else {
            throw RunRefusal(
                field: "entries[\(executorIndex)]",
                reason: "The running executor has SHA-256 \(running.sha256) and \(running.size) bytes, and the plan's executor "
                    + "entry pins \(pinned.sha256) and \(pinned.size) bytes. No tool ran."
            )
        }

        let manifest = try RunFiles.loadManifest(
            path: options.imageManifest ?? ImageToolManifest.imagePath,
            source: options.imageManifest == nil ? .image : .argument,
            pin: plan.imageManifest,
            record: &record
        )
        var tools: [String: ImageTool] = [:]
        for (index, step) in plan.steps.enumerated() {
            let field = "steps[\(index)]"
            if step.kind == .storage && plan.storage.clumpingTool == .none {
                throw RunRefusal(
                    field: "storage.clumpingTool",
                    reason: "Step \(step.id) stores with no clumping, a route this executor build does not run yet. No tool ran."
                )
            }
            guard PlanRunner.runsArgv(step) || PlanRunner.runsOwnStep(step) else {
                throw RunRefusal(
                    field: "\(field).kind",
                    reason: "Step \(step.id) is a \(step.kind.rawValue) step, which this executor build does not run yet. No tool ran."
                )
            }
            guard let pin = step.tool, let tool = manifest.tool(matching: pin) else {
                let named = step.tool.map { "\($0.id) \($0.version) build \($0.build)" } ?? "no tool"
                throw RunRefusal(
                    field: "\(field).tool",
                    reason: "Step \(step.id) runs \(named), which the tool manifest does not list with that version and build. No tool ran."
                )
            }
            if let reason = PlanRunner.toolPathRefusal(tool) {
                throw RunRefusal(field: "\(field).tool", reason: "\(reason) No tool ran.")
            }
            tools[step.id] = tool
        }

        // The executor entry was checked as the running binary above. The run never reads or runs the folder's copy.
        for (index, entry) in plan.entries.enumerated() where entry.role != .executor {
            do {
                _ = try resolver.verify(entry)
            } catch {
                throw RunRefusal(field: "entries[\(index)]", reason: "\(error.localizedDescription) No tool ran.")
            }
            record.inputs.append(entry)
        }
        if let refusal = RuntimeObservation.preflightRefusal(
            heapGB: plan.storage.clumpifyHeapGB, limits: record.runtimeIdentity.observedLimits
        ) {
            throw refusal
        }
        var prepared = PreparedRun(plan: plan, manifest: manifest, tools: tools)
        for pin in plan.tools {
            guard let storageTool = PlanRunner.storageTools[pin.id], let tool = manifest.tool(matching: pin) else { continue }
            prepared.storageTools[storageTool] = tool
        }
        prepared.decompressor = ["gzip", "pigz"].lazy.compactMap { id in
            plan.tools.first { $0.id == id }.flatMap { manifest.tool(matching: $0) }?.path
        }.first
        return prepared
    }

    /// Writes the record and returns the run's exit code, or `failed` for a run that succeeded but left no record.
    private static func finish(_ record: ExecutorRunRecord, workRoot: String) -> Int32 {
        do throws(ExecutorSpawn.Failure) {
            try RunRecordWriter.write(record, workRoot: workRoot)
        } catch {
            FileHandle.standardError.write(Data("lungfish-executor: \(error.reason)\n".utf8))
            return record.outcome == .succeeded ? ExecutorExitCode.failed : record.exitCode
        }
        if let reason = record.reason {
            FileHandle.standardError.write(Data("lungfish-executor: \(record.outcome.rawValue): \(reason)\n".utf8))
        }
        return record.exitCode
    }
}
