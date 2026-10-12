// RecordedRemovalStep.swift - The provenance step that names the files a run removed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The step that names each file a run removed (panel decision P1 of Phase 2.8).
///
/// Step facts stay as they were, so a record keeps naming a file that a later step of the run
/// compressed, moved or deleted. The removal step says why the file is gone. It names each
/// removed file once as an input, never a pattern, with the digest and size an earlier step
/// recorded for the bytes it removed, because a completed record holds both for every local
/// file (`ProvenanceRunBuilder`). It states `operation` `remove` in its resolved options. A file
/// that the run rewrote in place is named too, with the digest of the bytes that are gone.
public enum RecordedRemovalStep {
    /// The `operation` a removal step states in its resolved options.
    public static let operation = "remove"

    /// The resolved options of a removal step.
    public static var resolvedOptions: [String: ParameterValue] {
        ["invocationKind": .string("swift-api"), "operation": .string(operation)]
    }

    /// The step that removed `files` through `api`, the call that removed them, or nil when
    /// nothing was removed. Each path is named once, in order.
    public static func step(
        toolName: String,
        api: String,
        removing files: [ProvenanceFileDescriptor],
        clock: ProvenanceRunClock
    ) -> ProvenanceStep? {
        var seen: Set<String> = []
        let removed = files.filter { seen.insert($0.path).inserted }
        guard !removed.isEmpty else { return nil }
        return ProvenanceStep(
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [api] + removed.map(\.path),
            resolvedOptions: resolvedOptions,
            inputs: removed,
            outputs: [],
            exitStatus: 0,
            wallTimeSeconds: clock.elapsed,
            startedAt: clock.startedAt,
            completedAt: clock.now
        )
    }

    /// Records the removal of `files` through `api` in `runID`, or nothing when there are none.
    @discardableResult
    public static func record(
        in recorder: ProvenanceRecorder,
        runID: UUID,
        toolName: String,
        api: String,
        removing files: [FileRecord],
        dependsOn: [UUID]
    ) async -> UUID? {
        var seen: Set<String> = []
        let removed = files.filter { seen.insert($0.path).inserted }
        guard !removed.isEmpty else { return nil }
        return await recorder.recordStep(
            runID: runID,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: [api] + removed.map(\.path),
            resolvedOptions: resolvedOptions,
            inputs: removed,
            outputs: [],
            exitCode: 0,
            wallTime: 0,
            dependsOn: dependsOn
        )
    }
}
