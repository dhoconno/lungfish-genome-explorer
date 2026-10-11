// StepCopyFacts.swift - Which facts of a recorded step a step copy keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4b, scope rows B6 and B8. Eleven step copies carried the marker "keeping them comes with
// 2.7" and set a recorded step's release version, durable replay command, resolved options, runtime identity
// or peak memory to nothing. Two metagenomics import conversions made a new step with a new id. A pin sends
// `fullStep` through a site and states what the copy did to each fact with `changes(from:in:)`, so the
// commit that changes a site declares each fact it now keeps.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

public enum StepCopyFacts {
    /// What a copy did to one fact of the step it copied.
    public enum Change: String, Sendable, CustomStringConvertible {
        /// The source held the fact and the copy holds nothing for it.
        case lost
        /// Both hold the fact with different values, such as a path a site rewrote, or the copy has a new id.
        case changed

        public var description: String { rawValue }
    }

    /// A recorded step that holds every fact a copy can drop. Its argv, its durable replay command and its
    /// `input` option name `input`, so a site that rewrites the replay command through a path map shows
    /// whether it rewrote the option the same way.
    public static func fullStep(
        toolName: String = "samtools",
        input: URL,
        inputs: [ProvenanceFileDescriptor] = [],
        outputs: [ProvenanceFileDescriptor] = []
    ) -> ProvenanceStep {
        let argv = [toolName, "view", "-b", input.path]
        return ProvenanceStep(
            toolName: toolName,
            toolVersion: "1.22",
            githubReleaseVersion: "v2026.10.14",
            argv: argv,
            durableReplayArgv: argv,
            resolvedOptions: ["input": .file(input), "threads": .integer(4)],
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: "2026.10.14",
                executablePath: "<external>/\(toolName)",
                processIdentifier: nil,
                operatingSystemVersion: "macOS 26.0",
                architecture: "arm64",
                user: nil,
                condaEnvironment: "samtools",
                dependencySet: "copy-pin-dependencies"
            ),
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: 1,
            peakMemoryBytes: 1_048_576,
            dependsOn: [UUID()],
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            completedAt: Date(timeIntervalSince1970: 1_790_000_001),
            parentStepID: UUID(),
            managedToolID: ManagedToolID(rawValue: "samtools"),
            toolVersionEvidence: .classify(recorded: "1.22")
        )
    }

    /// What `copy` did to each fact of `source` that it did not keep as it was. A fact missing from the
    /// result was kept with the same value. The facts are the id and every field a step copy has dropped.
    public static func changes(from source: ProvenanceStep, in copy: ProvenanceStep) -> [String: Change] {
        var result: [String: Change] = [:]
        func note(_ name: String, _ sourceHolds: Bool, _ copyHolds: Bool, _ equal: Bool) {
            guard sourceHolds, !equal else { return }
            result[name] = copyHolds ? .changed : .lost
        }
        note("id", true, true, copy.id == source.id)
        note(
            "githubReleaseVersion", source.githubReleaseVersion != nil, copy.githubReleaseVersion != nil,
            copy.githubReleaseVersion == source.githubReleaseVersion
        )
        note(
            "durableReplayArgv", source.durableReplayArgv != nil, copy.durableReplayArgv != nil,
            copy.durableReplayArgv == source.durableReplayArgv
        )
        note(
            "resolvedOptions", !source.resolvedOptions.isEmpty, !copy.resolvedOptions.isEmpty,
            copy.resolvedOptions == source.resolvedOptions
        )
        note(
            "runtimeIdentity", source.runtimeIdentity != nil, copy.runtimeIdentity != nil,
            copy.runtimeIdentity == source.runtimeIdentity
        )
        note(
            "peakMemoryBytes", source.peakMemoryBytes != nil, copy.peakMemoryBytes != nil,
            copy.peakMemoryBytes == source.peakMemoryBytes
        )
        note("dependsOn", !source.dependsOn.isEmpty, !copy.dependsOn.isEmpty, copy.dependsOn == source.dependsOn)
        note("parentStepID", source.parentStepID != nil, copy.parentStepID != nil, copy.parentStepID == source.parentStepID)
        note(
            "managedToolID", source.managedToolID != nil, copy.managedToolID != nil,
            copy.managedToolID == source.managedToolID
        )
        note(
            "toolVersionEvidence", source.toolVersionEvidence != nil, copy.toolVersionEvidence != nil,
            copy.toolVersionEvidence == source.toolVersionEvidence
        )
        return result
    }

    /// The path a file option holds, or nil when the option is missing or holds no file.
    public static func filePath(of option: String, in step: ProvenanceStep) -> String? {
        step.resolvedOptions[option]?.fileValue?.path
    }
}
