// ProvenanceExportPlan+SubSteps.swift - Which recorded steps ran inside a CLI step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli import fastq` clumps the reads and counts them itself, and `import fasta`
// compresses and indexes the sequence itself. The writers record each of those tools as a step
// beside the CLI step. A script that ran every recorded step would run the import once through the
// CLI and then run its tools again, some of them on a hidden staging folder that no longer exists
// once the bundle is published (plan decision S6, finding F4).
//
// The plan keeps such a step in `steps` as a sub-step. It leaves the step out of
// `replayableSteps`, so no script runs it, and the scripts name it in a comment with its tool and
// version. The methods text still lists its tool, because the tool did run.
//
// A step is a sub-step of a CLI step when
// - it records a `parentStepID` that names that step, which the FASTQ importer and the native
//   bundle builder do from Phase 2.6 on, or
// - it records no parent, it lies in a hidden staging folder, and a CLI step lists one of its
//   outputs as its own. That is the rule for the released records, which have no such field.
//
// A parent the record holds decides alone. A step whose parent is not a CLI step stays in the script,
// and so does a step whose chain of parents loops. A parent the record does not hold counts as none,
// so the second rule reads the step. A CLI step that ran under another one keeps its own sub-steps
// under the outermost step, which is the one the script prints.
//
// A hidden staging folder is the `.<name>.building-<id>` folder an import fills before it
// publishes its bundle, or the `.tmp/fastq-import-<id>` workspace of a FASTQ import. Both are gone
// when the import ends, so no command that names one can be replayed. Released FASTQ imports
// record clumpify in the workspace and seqkit in the staging bundle, and released FASTA imports
// record bgzip and samtools in the staging bundle.
//
// An independent step is never a sub-step. A step in a staging folder that no CLI step claims
// stays, so does a record with no CLI step at all, and so does every step recorded around a CLI
// step with no staging folder in it.

import Foundation
import LungfishCore

extension ProvenanceExportPlan {
    /// The recorded number of the CLI step each sub-step ran inside, keyed by the sub-step's own
    /// number. `numbered` holds the recorded steps that survived the staging collapse, and
    /// `replayArguments` gives the argv a step replays, as the plan uses it.
    static func subStepParents(
        in numbered: [(number: Int, step: StepExecution)],
        replayArguments: (StepExecution) -> [String]?
    ) -> [Int: Int] {
        func isCLIStep(_ step: StepExecution) -> Bool {
            guard !isInternal(step), let argv = replayArguments(step), !argv.isEmpty else { return false }
            return isCLI(argv)
        }
        let cliSteps = numbered.filter { isCLIStep($0.step) }
        guard !cliSteps.isEmpty else { return [:] }
        let cliNumberByID = Dictionary(cliSteps.map { ($0.step.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        let recordedIDs = Set(numbered.map(\.step.id))

        var direct: [Int: Int] = [:]
        for (number, step) in numbered {
            if let parentID = step.parentStepID, recordedIDs.contains(parentID) {
                // A parent the record holds decides. A CLI step makes this a sub-step, and any other
                // step leaves it in the script, so the staging folder is never read for it.
                if let parent = cliNumberByID[parentID], parent != number { direct[number] = parent }
                continue
            }
            // No parent, or one the record does not hold, as when a command took the tool steps of a
            // builder over into a CLI step of its own. The staging folder decides.
            guard !isCLIStep(step), isInsideStagingFolder(step) else { continue }
            let written = Set(step.outputs.map(\.path).filter { !$0.hasPrefix("pipe:") })
            guard !written.isEmpty else { continue }
            // The CLI step that lists one of this step's outputs, the nearest one when a chain of
            // records holds several imports.
            let claimants = cliSteps.filter { cli in cli.step.outputs.contains { written.contains($0.path) } }
            if let parent = claimants.min(by: { abs($0.number - number) < abs($1.number - number) }) {
                direct[number] = parent.number
            }
        }

        // A CLI step that ran another keeps its own sub-steps under the outermost one, which is the
        // step the script prints. A chain that loops names no outermost step, so its steps stay.
        var parents: [Int: Int] = [:]
        for number in direct.keys {
            var outermost = number
            var seen: Set<Int> = [number]
            while let next = direct[outermost] {
                guard seen.insert(next).inserted else { outermost = number; break }
                outermost = next
            }
            if outermost != number { parents[number] = outermost }
        }
        return parents
    }

    /// Whether `step` was recorded inside a hidden staging folder: in its command, its durable
    /// replay command or one of its files.
    static func isInsideStagingFolder(_ step: StepExecution) -> Bool {
        let recorded = step.command + (step.durableReplayArgv ?? [])
            + step.inputs.map(\.path) + step.outputs.map(\.path)
        return recorded.contains { $0.range(of: stagingFolderPattern, options: .regularExpression) != nil }
    }

    /// A path component that starts with a dot and holds `.building-`, or the `.tmp/fastq-import-`
    /// workspace of a FASTQ import, after a slash or at the start of the text.
    private static let stagingFolderPattern = #"(^|/)(\.[^/]*\.building-|\.tmp/fastq-import-)"#

    /// The steps the export leaves out of the commands it runs because a CLI step ran them, in
    /// recorded order.
    var subSteps: [Step] { steps.filter(\.isSubStep) }

    /// The sub-steps of `step`, in recorded order.
    func subSteps(of step: Step) -> [Step] {
        steps.filter { sub in sub.ranUnder.map { step.numbers.contains($0) } ?? false }
    }
}

extension ProvenanceExportPlan.Step {
    /// Whether a CLI step ran this step, so the scripts name it and do not run it again.
    var isSubStep: Bool { ranUnder != nil }
}
