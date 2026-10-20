// ProvenanceExporter+NoOutputSteps.swift - The comment an export writes for a tool step it does not run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The shell, Python, Nextflow and Snakemake exports leave out a tool step whose standard output
// LGE read in the app and that recorded no output file (`ProvenanceExportPlan+NoOutputSteps.swift`).
// Each such step stays in the script as one comment line with its tool, version and the argv that
// ran, as the exports write a comment line for a path they cannot resolve.

import Foundation

extension ProvenanceExporter {
    /// One comment line for each tool step the plan leaves out because LGE read its output in the
    /// app and it recorded no output file, each ending in a newline, or nothing. `prefix` is the
    /// comment leader of the format.
    func noOutputStepNote(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        plan.noOutputSteps.map { step in
            let argv = plan.commandLine(for: step, spell: Self.noOutputStepSpelling, escape: Self.oneLine)
            return "\(prefix)Step \(stepNumbers(step)) (\(step.identity.displayLabel)) wrote no file, "
                + "since LGE read its output in the app, so this script does not run it. It ran \(argv)\n"
        }.joined()
    }

    private static func noOutputStepSpelling(_ path: ProvenanceExportPlan.MappedPath) -> String {
        switch path {
        case .project(let tail): return tail.isEmpty ? "$PROJECT" : "$PROJECT/\(tail)"
        case .result(let relative): return relative
        case .external(let recorded), .verbatim(let recorded): return recorded
        }
    }

    /// A token kept on the comment's one line.
    private static func oneLine(_ token: String) -> String {
        token.replacingOccurrences(of: "\n", with: " ")
    }
}
