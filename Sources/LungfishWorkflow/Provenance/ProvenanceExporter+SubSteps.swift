// ProvenanceExporter+SubSteps.swift - The comment an export writes for the steps a CLI step ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The shell, Python, Nextflow and Snakemake exports run a CLI step once and leave out the steps it
// ran inside (`ProvenanceExportPlan+SubSteps.swift`). Each of those steps stays in the script as a
// comment beside its CLI step, with its tool and version, so a reader can see what the import ran
// and which version of each tool did it.

import Foundation

extension ProvenanceExporter {
    /// One comment line for each sub-step of `step`, each ending in a newline, or nothing when
    /// `step` ran no other step. `prefix` is the comment leader of the format.
    func subStepNote(of step: ProvenanceExportPlan.Step, in plan: ProvenanceExportPlan, prefix: String) -> String {
        plan.subSteps(of: step).map { sub in
            "\(prefix)Step \(stepNumbers(sub)) (\(sub.identity.displayLabel)) ran inside step "
                + "\(stepNumbers(step)), so this script does not run it again.\n"
        }.joined()
    }
}
