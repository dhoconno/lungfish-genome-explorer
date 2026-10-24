// ProvenanceInspectorViewModel+NodeRuntime.swift - The rows an adopted record adds to the Provenance tab (CHTC C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import LungfishWorkflow

/// The rows that name where and with what binary an adopted run's steps ran, in UX's words (rulings OQ-1 and OQ-5,
/// C4-13).
///
/// - Run level, once, in the Runtime section after Dependency Set: "Steps ran on", "Steps ran with", "Leftover
///   processes", then "Reported by the launcher" with one row per site fact.
/// - Step level, on each node step after Command and Environment and before the storage lines and Inputs: "Version and
///   build", with the words for where the version came from.
///
/// Each row shows only when the record holds its field, so a Mac import and a record written before C4 show as they did,
/// and none is a warning. A node step with a recorded title, such as the counter step "Count Q20 and Q30 bases", shows
/// under its title.
enum ProvenanceNodeRuntimeDisplay {
    static let stepsRanOnLabel = "Steps ran on"
    static let stepsRanWithLabel = "Steps ran with"
    static let leftoverProcessesLabel = "Leftover processes"
    static let versionAndBuildLabel = "Version and build"
    /// The accessibility identifier of a step's "Version and build" value, beside `provenance-step-command`.
    static let versionAndBuildIdentifier = "provenance-step-version-and-build"

    /// The "Leftover processes" value for each `orphanSweep` value (tally-r2 section 3.5, UX-r2:115-116).
    static let orphanSweepWords = [
        "parentWalkOnly": "Found through each process's parent only. A process that a tool detached from its parent is "
            + "not found and may still be running after the step ended.",
        "subreaper": "Adopted and stopped. The executor takes in every process a tool leaves behind and stops it "
            + "before the step ends.",
    ]

    /// The run-level rows of `runtime`, in screen order, or none for a record that holds no node fact or site fact.
    static func runtimeRows(_ runtime: ProvenanceRuntimeIdentity) -> [ProvenanceRuntimeRow] {
        var rows: [ProvenanceRuntimeRow] = []
        if let node = runtime.nodeRuntime {
            if let kernel = recorded(node.kernelRelease) {
                let value = recorded(node.machine).map { "kernel \(kernel) (\($0))" } ?? "kernel \(kernel)"
                rows.append(ProvenanceRuntimeRow(label: stepsRanOnLabel, value: value))
            }
            let build = recorded(node.executorBuild).map { " build \($0) (from the plan's pin)" }
            let digest = recorded(node.executorSHA256).map { "SHA-256 \($0)" }
            if build != nil || digest != nil {
                let value = "lungfish-executor" + (build ?? "") + (digest.map { ", \($0)" } ?? "")
                rows.append(ProvenanceRuntimeRow(label: stepsRanWithLabel, value: value))
            }
            if let sweep = recorded(node.orphanSweep) {
                rows.append(ProvenanceRuntimeRow(label: leftoverProcessesLabel, value: orphanSweepWords[sweep] ?? sweep))
            }
        }
        rows += ProvenanceSiteFactRows.rows(runtime.siteFacts).map { ProvenanceRuntimeRow(label: $0.label, value: $0.value) }
        return rows
    }

    /// The "Version and build" value of a node step, "<version> (build <build>), from <source words>", or nil for a step
    /// whose record states no tool with a node's version source, as every Mac step and every record before C4.
    static func versionAndBuild(of step: ProvenanceStep) -> String? {
        guard case .dictionary(let tool)? = step.resolvedOptions[ProvenanceNodeStepOptions.toolKey],
              let source = string(tool["versionSource"]), ProvenanceNodeStepOptions.nodeVersionSources.contains(source),
              let version = recorded(string(tool["version"])),
              let words = ProvenanceStepStorageDisplay.sourceWords(source)
        else { return nil }
        let build = recorded(string(tool["build"])).map { " (build \($0))" } ?? ""
        return "\(version)\(build), \(words)"
    }

    /// The title a node step's record names it by, or nil.
    static func title(of step: ProvenanceStep) -> String? {
        recorded(string(step.resolvedOptions[ProvenanceNodeStepOptions.titleKey]))
    }

    private static func string(_ value: ParameterValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private static func recorded(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension ProvenanceSection {
    /// A node step's "Version and build" row, or nothing for a step whose record states no node tool. It follows the
    /// Environment row, in the order the Copy text lists it (`appendStepLines(of:to:)`).
    @ViewBuilder
    func stepVersionRow(of step: ProvenanceLineageStep) -> some View {
        if let text = step.versionAndBuild {
            summaryRow(
                ProvenanceNodeRuntimeDisplay.versionAndBuildLabel, value: text,
                accessibilityIdentifier: ProvenanceNodeRuntimeDisplay.versionAndBuildIdentifier
            )
        }
    }
}
