// RecipeAppliedPresentation.swift - The words the Inspector shows for a recipe run record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// What the Inspector's Ingestion section shows for a ``RecipeAppliedInfo``, as strings, so that a test reads them
/// without a view (CHTC lane C2-MERGED, fix 1). A field an older record lacks reads "Not recorded". Nothing here
/// writes a record, so an older record's sidecar stays as it was.
enum RecipeAppliedPresentation {
    static let notRecorded = "Not recorded"

    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// The switches the merged recipe has, in the order the Inspector draws them.
    private static let knownSwitches: [(id: String, label: String)] = [
        (id: "removeDuplicates", label: "Remove duplicate reads"),
        (id: "removeRibosomalRNA", label: "Remove ribosomal RNA reads"),
    ]

    /// The recipes that have the two known switches and whose older records hold no settings: the merged recipe and
    /// the three names an older build wrote (the legacy VSP2 recipe, its recipe file and the wastewater file). A
    /// record without settings from any other recipe, such as `wgs`, `hifi` or the amplicon merge, comes from a
    /// recipe that has no such switch, so it gets no switch row.
    private static let recipeIDsWithKnownSwitches: Set<String> = [
        "illumina-paired-cleanup", "illuminaVSP2TargetEnrichment", "vsp2-target-enrichment", "wastewater-metagenomics",
    ]

    /// The rows after the recipe's name, in the order the Inspector draws them, which is also the order VoiceOver
    /// reads and Copy text takes them. Preset, one row for each switch the recipe has, then the recipe digest. A
    /// switch row reads Not recorded only for a recipe that has the switch and a record that lacks its setting.
    static func rows(for info: RecipeAppliedInfo) -> [Row] {
        var rows = [Row(label: "Preset", value: presetText(for: info))]
        let recipeHasKnownSwitches = recipeIDsWithKnownSwitches.contains(info.recipeID)
        for known in knownSwitches {
            let setting = info.switchSettings?.first { $0.id == known.id }
            guard setting != nil || recipeHasKnownSwitches else { continue }
            rows.append(Row(label: known.label, value: setting.map(switchText) ?? notRecorded))
        }
        for setting in info.switchSettings ?? [] where !knownSwitches.contains(where: { $0.id == setting.id }) {
            rows.append(Row(label: setting.label, value: switchText(setting)))
        }
        rows.append(Row(label: "Recipe digest", value: info.recipeSHA256 ?? notRecorded))
        return rows
    }

    /// The preset the name resolved to. A record that holds the name it was given but no preset ran the recipe's
    /// own defaults, which is a fact and not a missing field.
    private static func presetText(for info: RecipeAppliedInfo) -> String {
        if let name = info.presetName { return name }
        return info.requestedName == nil ? notRecorded : "None (recipe defaults)"
    }

    /// "On (preset)", "Off (recipe default)" or "On (your choice)". The CLI line says "option" for the last, and the
    /// Inspector says what the person did.
    static func switchText(_ setting: RecipeSwitchSetting) -> String {
        let source: String
        switch setting.source {
        case .recipeDefault: source = "recipe default"
        case .preset: source = "preset"
        case .option: source = "your choice"
        }
        return "\(setting.value ? "On" : "Off") (\(source))"
    }

    /// The reads removed across the steps that ran, with the share of the first step that ran, such as
    /// "100 (10.0%)". Nil when nothing was removed or the record holds no counts.
    static func netReadsRemoved(for info: RecipeAppliedInfo) -> String? {
        guard let removed = info.totalReadsRemoved, removed > 0 else { return nil }
        let count = LungfishFormatters.formatGroupedCount(removed)
        // A kept-duplicates record has the turned-off dedup result first, and it holds no count.
        guard let input = info.stepResults.first(where: \.didRun)?.inputReadCount, input > 0 else { return count }
        return count + String(format: " (%.1f%%)", Double(removed) / Double(input) * 100)
    }

    /// The one line a step that a switch turned off shows in place of its tool and time, such as "Not run, Remove
    /// ribosomal RNA reads is off". Nil for a step that ran.
    static func notRunLine(for step: RecipeStepResult) -> String? {
        guard let setting = step.turnedOffBy else { return nil }
        return "Not run, \(setting.label) is off"
    }

    /// The tool and its version, nil for a step that did not run.
    static func toolText(for step: RecipeStepResult) -> String? {
        guard step.didRun else { return nil }
        return step.toolVersion.map { "\(step.tool) \($0)" } ?? step.tool
    }

    /// The step's wall time, nil for a step that did not run.
    static func durationText(for step: RecipeStepResult) -> String? {
        step.didRun ? LungfishFormatters.formatDuration(step.durationSeconds) : nil
    }

    /// A shell script that reproduces the steps that ran. A step a switch turned off is named as not run, and the
    /// count in the header counts only the steps that ran.
    static func reproducibilityScript(for info: RecipeAppliedInfo, appliedDate: String) -> String {
        var lines: [String] = []
        lines.append("#!/bin/bash")
        lines.append("# Pipeline: \(info.recipeName)")
        lines.append("# Generated by Lungfish on \(appliedDate)")
        lines.append("# \(info.stepResults.filter(\.didRun).count) step(s)")
        lines.append("")
        lines.append("set -euo pipefail")
        lines.append("")

        for (idx, step) in info.stepResults.enumerated() {
            if let setting = step.turnedOffBy {
                lines.append("# Step \(idx + 1): \(step.stepName) was not run, \(setting.label) is off")
                lines.append("")
                continue
            }
            lines.append("# Step \(idx + 1): \(step.stepName)")
            if let ver = step.toolVersion {
                lines.append("# Tool: \(step.tool) \(ver)")
            }
            if let cmd = step.commandLine,
               !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(cmd)
            } else {
                lines.append("# (no command recorded for this step)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
