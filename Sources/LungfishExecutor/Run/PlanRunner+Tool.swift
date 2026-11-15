// PlanRunner+Tool.swift - What a schema 2 `tool` step leaves in the run record (Phase 5.3 lane EX-TOOL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// A `tool` step runs by the plan's argv through `runStep`, as a `recipe` step does, and states no read count, since
/// counts come from the tool's own files (docs/formats/executor-plan.md, The `tool` step). Each output in its record
/// carries the policy its plan names.
extension PlanRunner {
    /// The payload entries of a `tool` step that succeeded: each `home` output, in the order of the step's outputs,
    /// with no record count. A `staged` or `stays` output is never a payload (executor-run-record.md, Payloads).
    static func homePayloads(of step: ExecutorStepRecord) -> [ExecutorPayloadRecord] {
        guard step.kind == .tool, step.outcome == .succeeded else { return [] }
        return step.outputs.filter { $0.policy == .home }.map { output in
            ExecutorPayloadRecord(relativePath: output.path, sha256: output.sha256, size: Int64(output.bytes))
        }
    }
}
