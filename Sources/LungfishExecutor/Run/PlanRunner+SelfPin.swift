// PlanRunner+SelfPin.swift - A `tool` step that runs the executor's own UMI layout check, pinned to the plan's
// executor build (Phase 5.3 lane EX-UMI, ARCH-UMI-CHECKER items 4 to 6)
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

/// A `tools` pin with id `lungfish-executor` names the plan's own executor build, which the self-check of `run --plan`
/// checked by the `executor` entry's SHA-256 and size before any tool starts. Such a step is never looked up in the
/// manifest. It runs the binary already checked, `/proc/self/exe` on Linux and the real path of `argv[0]` in a replay on
/// the Mac, through `runStep` as every `tool` step runs, and runs only `umi-layout-check`.
extension PlanRunner {
    static let executorToolID = "lungfish-executor"

    /// Whether `step` runs the executor itself.
    static func runsExecutor(_ step: PlanStep) -> Bool {
        step.kind == .tool && step.tool?.id == executorToolID
    }

    /// The program the executor runs itself by, or nil when `argv[0]` holds no path.
    static func runningExecutorProgram() -> String? {
        #if os(Linux)
        return runningExecutorPath
        #else
        guard let launched = CommandLine.arguments.first, launched.contains("/"), let resolved = realpath(launched, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
        #endif
    }

    /// The tool a self-pinned step runs. A pin that is not the plan's executor build, an argv that is not a whole
    /// `umi-layout-check` argv, and a decompressor the plan does not pin are refused with the step's field.
    static func selfPinnedTool(_ step: PlanStep, plan: ExecutionPlan, field: String) throws(RunRefusal) -> ImageTool {
        let build = plan.executor
        guard let pin = step.tool, pin.version == build.lgeVersion, pin.build == build.lgeCommit else {
            let named = step.tool.map { "\($0.version) build \($0.build)" } ?? "no build"
            throw RunRefusal(
                field: "\(field).tool",
                reason: "Step \(step.id) runs lungfish-executor \(named), and the plan's executor is \(build.lgeVersion) build "
                    + "\(build.lgeCommit). A step runs only the executor build the plan pins. No tool ran."
            )
        }
        let check: UMILayoutCheck.Arguments
        do {
            guard step.arguments.first == UMILayoutCheck.subcommand else {
                throw UMILayoutCheck.UsageError("the executor runs only \(UMILayoutCheck.subcommand) as a step")
            }
            check = try UMILayoutCheck.Arguments(argv: step.arguments)
        } catch {
            let message = (error as? UMILayoutCheck.UsageError)?.message ?? String(describing: error)
            throw RunRefusal(field: "\(field).arguments", reason: "Step \(step.id) cannot run: \(message). No tool ran.")
        }
        guard ["gzip", "pigz", "bgzip"].contains(check.decompressor), plan.tools.contains(where: { $0.id == check.decompressor }) else {
            throw RunRefusal(
                field: "\(field).arguments",
                reason: "Step \(step.id) reads its reads through \(check.decompressor), which the plan does not pin as its gzip, "
                    + "pigz or bgzip. No tool ran."
            )
        }
        guard let program = runningExecutorProgram() else {
            throw RunRefusal(field: "\(field).tool", reason: "The executor could not find its own binary to run step \(step.id). No tool ran.")
        }
        return ImageTool(id: executorToolID, version: pin.version, build: pin.build, path: program, condaPackage: executorToolID)
    }

    /// A self-pinned step's record names LGE's build with `planPin` and the running binary's SHA-256, never an image tool
    /// (ARCH-UMI-CHECKER item 6). A check that exits non-zero adds the words it wrote to standard error to its reason, so
    /// the run record's `reason` says why the sample has no counts (executor-plan.md, The UMI layout check).
    static func selfPinned(_ step: ExecutorStepRecord, build: PlanExecutorBuild, sha256: String?) -> ExecutorStepRecord {
        var step = step
        step.tool = ExecutorToolRecord(
            id: executorToolID, version: build.lgeVersion, build: build.lgeCommit, path: runningExecutorPath,
            versionSource: .planPin, sha256: sha256
        )
        let words = step.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if step.outcome == .failed, step.toolExitCode != nil, !words.isEmpty {
            step.reason = [step.reason, words].compactMap { $0 }.joined(separator: " ")
        }
        return step
    }
}
