// ProvenanceNodeRuntime.swift - What the executor observed where an adopted run's steps ran, and each node step's tool (CHTC C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The run-level facts an adopted record keeps of the Linux machine and the executor that ran its steps, once per run as
/// the run record keeps them (UX ruling OQ-1). The adopt copies them from the run record's `runtimeIdentity` and
/// `executor` blocks. What the executor observed stays apart from what the launcher passed, which the record keeps in
/// `siteFacts` (ARCH-r2:91-98). A Mac import and a record written before C4 hold none, so their tab is unchanged.
public struct ProvenanceNodeRuntime: Codable, Sendable, Equatable {
    /// The kernel release the executor read on the machine (`runtimeIdentity.kernelRelease`).
    public let kernelRelease: String?
    /// The machine hardware name the executor read (`runtimeIdentity.machine`), such as `x86_64`.
    public let machine: String?
    /// The executor build's commit from the plan's build pin (`executor.buildPin.lgeCommit`), the `build` of the executor's own tool record.
    public let executorBuild: String?
    /// The SHA-256 of the executor binary that ran (`executor.sha256`).
    public let executorSHA256: String?
    /// How the executor found the processes a tool left behind, `subreaper` or `parentWalkOnly`, as the run record's
    /// `runtimeIdentity.orphanSweep` states it.
    public let orphanSweep: String?

    public init(
        kernelRelease: String? = nil, machine: String? = nil, executorBuild: String? = nil,
        executorSHA256: String? = nil, orphanSweep: String? = nil
    ) {
        self.kernelRelease = kernelRelease
        self.machine = machine
        self.executorBuild = executorBuild
        self.executorSHA256 = executorSHA256
        self.orphanSweep = orphanSweep
    }
}

/// The keys of a node step's `resolvedOptions` that state the step's tool as the run record states it (UX ruling
/// OQ-1). A Mac step holds neither key with a node source, so it shows no node row.
public enum ProvenanceNodeStepOptions {
    /// The step's tool, a dictionary of `id`, `version`, `build` and `versionSource` in the run record's tool shape.
    public static let toolKey = "tool"
    /// The plan step's title, for a step the row names by its title, such as "Count Q20 and Q30 bases".
    public static let titleKey = "stepTitle"
    /// The version sources a node's run record states (`ExecutorToolVersionSource`).
    public static let nodeVersionSources: Set<String> = ["imageManifest", "planPin"]

    /// The options of one node step: its tool under `tool` and, when given, the plan step's title under `stepTitle`.
    public static func options(
        toolID: String, version: String, build: String, versionSource: String, title: String? = nil
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            toolKey: .dictionary([
                "id": .string(toolID), "version": .string(version), "build": .string(build),
                "versionSource": .string(versionSource),
            ]),
        ]
        if let title { options[titleKey] = .string(title) }
        return options
    }
}
