// ProvenanceInspectorViewModel+StepTools.swift - The Tool and Step Tools rows of the Run Summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension ProvenanceInspectorViewModel {
    /// The run-level tool of a record written by the command line. It runs other tools and records them
    /// as steps, so its own name says little about the science.
    private static let commandLineToolName = CLICommandIdentity.executableName

    /// The Tool row of the Run Summary, for the view and the Copy text alike.
    var toolText: String {
        summary.toolVersion.isEmpty ? summary.toolName : "\(summary.toolName) \(summary.toolVersion)"
    }

    /// The Step Tools row of the Run Summary, or nil when the row does not show (Phase 2.8 decision P3).
    ///
    /// A classifier that runs through `lungfish-cli` records that program as its tool, so the Tool row never
    /// names Kraken2 or EsViritu. The row lists the tool and version of each step of the selected record that
    /// ran a program other than LGE, in step order, once each, spelt as the Lineage spells them. A step LGE ran
    /// itself, such as `lungfish-cli fastq materialize` or `Lungfish EsViritu Result Sidecar`, is left out, and
    /// the Lineage still lists it. Both come from the step's own record and never from the managed tool lock,
    /// so the row says what ran and not what LGE pins today. A step that names no tool adds nothing, and a step
    /// with no known version adds its tool alone. The row shows only when the run-level tool is `lungfish-cli`,
    /// because any other run-level tool already names itself.
    var stepToolsText: String? {
        guard summary.toolName.trimmingCharacters(in: .whitespacesAndNewlines) == Self.commandLineToolName,
              let steps = lineageRuns.last?.steps else { return nil }
        var seen: Set<String> = []
        let tools = steps.compactMap { step -> String? in
            let name = step.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = step.toolVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Self.namesNothing(name), !Self.isLGEsOwnStep(name) else { return nil }
            let tool = Self.namesNothing(version) ? name : "\(name) \(version)"
            return seen.insert(tool).inserted ? tool : nil
        }
        return tools.isEmpty ? nil : tools.joined(separator: ", ")
    }

    /// True for a blank text or the word a record uses when it does not know.
    private static func namesNothing(_ text: String) -> Bool {
        text.isEmpty || text.lowercased() == "unknown"
    }

    /// True for a step LGE ran itself, such as `lungfish-cli fastq materialize`, `lungfish-kraken2-index`,
    /// `Lungfish Classification Result Sidecar` or `LGE primer ordering`. Lineage lists such a step, and the
    /// row keeps to the programs LGE ran.
    private static func isLGEsOwnStep(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("lungfish") || lowered.hasPrefix("lge ")
    }
}
