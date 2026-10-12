// TaxTriageParityKnownDifferences.swift - Every declared difference between the sides of a TaxTriage parity case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q1a, 2.7 T2. Side A (today's GUI route) and side B (its recorded command, or the
// pooled command of a request it records none for) differ at the base, and each difference is
// declared here with its reason, the lane or phase whose change removes it, and how many found
// differences it matches in each case. TaxTriageCLIGUIParityReplayTests fails on a difference no
// entry declares and on an entry that matches more or fewer differences in a case than its count,
// so the list only shrinks, one difference at a time, and a new difference cannot hide under an old
// pattern. A lane that closes a difference lowers the count, or deletes the case or the entry, in
// the same commit.

import Foundation

/// Where a declared difference applies.
enum TaxTriageParityScope: Hashable, Sendable, CustomStringConvertible {
    /// How the second side differs from the first, the reference side.
    case pair(TaxTriageParitySide, TaxTriageParitySide)
    /// A fixed fact one side does not hold.
    case side(TaxTriageParitySide)

    var description: String {
        switch self {
        case .pair(let reference, let candidate): return "\(reference) against \(candidate)"
        case .side(let side): return "side \(side)"
        }
    }
}

/// One declared difference.
struct TaxTriageParityKnownDifference: Sendable {
    /// The cases the entry applies to, each with the number of found differences it matches there.
    let counts: [TaxTriageParityCase: Int]
    let scope: TaxTriageParityScope
    /// The id of the difference, where `*` stands for any run of characters.
    let id: String
    let reason: String
    /// The lane whose change removes the difference, or the phase that retires the route.
    let closedBy: String

    func matches(_ difference: TaxTriageParityDifference) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: id).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return difference.id.range(of: pattern, options: .regularExpression) != nil
    }
}

enum TaxTriageParityKnownDifferences {
    static let all: [TaxTriageParityKnownDifference] = layout + pooledLayout + records + pooledRecords + facts

    /// The legacy GUI route stays in process through 2.9 (2.8 T1), so a difference that comes from
    /// it closes when the route runs through lungfish-cli.
    static let guiRoute = "2.10, the GUI route through lungfish-cli (A3 and U8, Moved out of 2.8)"
    /// `taxtriage run` on the executor runs build-db taxtriage, with its cleanup as a recorded
    /// removal step (2.8 T5).
    static let executorIndex = "A2, taxtriage run on the executor builds taxtriage.sqlite (2.8 T5)"
    /// A row of several samples records no command, so side B runs the pooled command.
    static let perSample = "2.10, a recorded command for several samples (cli-parity-gap taxtriage-multi-sample, A3 and U8)"
    /// The GUI claims its folder before the pipeline lists its outputs, `taxtriage run` after.
    static let folderClaim = "A2 or the 2.10 GUI route, once both routes claim the folder before the pipeline lists its outputs"

    private static func pair(
        _ counts: [TaxTriageParityCase: Int], _ id: String, _ reason: String, closedBy: String
    ) -> TaxTriageParityKnownDifference {
        TaxTriageParityKnownDifference(counts: counts, scope: .pair(.a, .b), id: id, reason: reason, closedBy: closedBy)
    }

    /// A fact of the result's root record, `Analyses/<folder>/.lungfish-provenance.json`.
    private static func record(
        _ counts: [TaxTriageParityCase: Int], _ fact: String, _ reason: String, closedBy: String
    ) -> TaxTriageParityKnownDifference {
        pair(counts, "record Project.lungfish/Analyses/*/.lungfish-provenance.json: \(fact)", reason, closedBy: closedBy)
    }

    // MARK: Folders

    private static let layout: [TaxTriageParityKnownDifference] = [
        pair([.x1: 1, .x2: 1, .x3: 1], "analysis: only in A: batch-run-history.json",
             "The GUI records the run in the folder's batch history (BatchRunHistory.recordRun in completeTaxTriageRun). taxtriage run keeps none",
             closedBy: guiRoute),
        pair([.x1: 2, .x2: 2, .x3: 2], "analysis: only in A: taxtriage.sqlite*",
             "The GUI runs build-db taxtriage once the pipeline ends, which writes taxtriage.sqlite and its record. taxtriage run builds no database (TaxTriageStandInEngineReplayTests pins it)",
             closedBy: executorIndex),
        pair([.x1: 1, .x2: 1], "analysis: only in B: top/*.top_report.tsv",
             "The GUI's build-db step deletes top/ with the other intermediate folders (performCleanupForSingleResult in BuildDbCommand.swift). The legacy route keeps that cleanup until it goes, and the executor path keeps top/ (2.8 T5)",
             closedBy: guiRoute),
        pair([.x1: 1, .x2: 1, .x3: 1], "analysis: differs: taxtriage-result.json",
             "allOutputFiles. The GUI's list starts with analysis-metadata.json, which the GUI writes when it claims the folder before the run, and its batch result lists each sample's files in the sample's folder. taxtriage run marks its folder after the pipeline lists its files (markAsProjectAnalysisIfNeeded) and a pooled run lists every file at its root",
             closedBy: folderClaim),
        pair([.x1: 1, .x2: 1, .x3: 2], "source manifest: only in A: *",
             "Only the GUI records the run in each source bundle's analyses-manifest.json (completeTaxTriageRun)",
             closedBy: guiRoute),
    ]

    /// X3. Side A runs one Nextflow per sample in its own folder below the batch root (2.8 T2), and
    /// side B's frozen tree is the pooled run of the same two samples (QA inventory 2.2).
    private static let pooledLayout: [TaxTriageParityKnownDifference] = [
        pair([.x3: 20], "analysis: only in A: */*",
             "Each sample folder of the GUI's batch holds its own samplesheet, config, launch command, log, trace, accession map, organism report, record and result. The GUI's cleanup deleted each folder's top/",
             closedBy: perSample),
        pair([.x3: 12], "analysis: only in B: *",
             "The pooled run writes one samplesheet, config, launch command, log and trace for both samples and every sample's accession map, organism report and top report at the root of its folder",
             closedBy: perSample),
    ]

    // MARK: Records

    private static let records: [TaxTriageParityKnownDifference] = [
        record([.x1: 3, .x2: 3, .x3: 3], "*teps[Lungfish TaxTriage Index#1]",
               "The GUI's build-db step adds its index step to the result's record, in steps, canonicalRunSteps and legacyRunSteps (O1, ARCH 5 of 2.8)",
               closedBy: executorIndex),
        record([.x1: 2, .x2: 2], "files[*|log]",
               "The index step reads nextflow.log and trace.txt as logs, and the record lists its inputs with that role beside the pipeline's outputs",
               closedBy: executorIndex),
        record([.x1: 2, .x2: 2], "outputs[*|log]", "As files", closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 2], "files[*|report]",
               "The index step reads each organism report as a report, and the record lists it with that role",
               closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 2], "outputs[*|report]", "As files", closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 1], "files[*taxtriage.sqlite|output]",
               "The index step's output, the database", closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 1], "outputs[*taxtriage.sqlite|output]", "As files", closedBy: executorIndex),
        record([.x1: 1, .x2: 1], "files[*analysis-metadata.json|output]",
               "The GUI writes analysis-metadata.json when it claims the folder before the run, so the pipeline lists it among its outputs. taxtriage run marks its folder after (markAsProjectAnalysisIfNeeded)",
               closedBy: folderClaim),
        record([.x1: 2, .x2: 2], "outputs[*analysis-metadata.json|output]",
               "As files, once from the taxtriage step and once from the index step's inputs", closedBy: folderClaim),
        record([.x1: 1, .x2: 1], "steps[taxtriage#1].outputs[*analysis-metadata.json|output]",
               "As files, in the taxtriage step", closedBy: folderClaim),
        record([.x1: 1, .x2: 1, .x3: 1], "output.format",
               "The run's output is its first output. In the GUI record it is analysis-metadata.json, or taxtriage-result.json in a batch record, and in the record of taxtriage run the first accession map",
               closedBy: folderClaim),
        record([.x1: 1, .x2: 1, .x3: 1], "output.path", "As output.format", closedBy: folderClaim),
    ]

    /// X3. The GUI's batch record against the record of the pooled run.
    private static let pooledRecords: [TaxTriageParityKnownDifference] = [
        record([.x3: 1], "workflowName", "TaxTriage Serial Batch against TaxTriage", closedBy: perSample),
        record([.x3: 1], "explicitOptions.workflow.value", "taxtriage-serial-batch against taxtriage", closedBy: perSample),
        record([.x3: 1], "legacyRunParameters.workflow.value", "As explicitOptions", closedBy: perSample),
        record([.x3: 1], "argv",
               "The batch record's run level names the first sample's reproducible Nextflow command, the pooled record the launch of both samples",
               closedBy: perSample),
        record([.x3: 1], "reproducibleCommand", "As argv", closedBy: perSample),
        record([.x3: 3], "*teps[lungfish-app-taxtriage-serial-batch#1]",
               "The batch record's step for the serial batch itself", closedBy: perSample),
        record([.x3: 3], "*teps[taxtriage#2]",
               "The batch record holds one taxtriage step per sample, the pooled record one for both", closedBy: perSample),
        record([.x3: 13], "*teps[taxtriage#1].*",
               "The batch record's first taxtriage step is the first sample's launch, with its own samplesheet, folder and nine outputs",
               closedBy: perSample),
        record([.x3: 18], "files[<project>/Analyses/*/*/*|output]",
               "The batch record lists the nine files of each sample folder, the pooled record the files at its root",
               closedBy: perSample),
        record([.x3: 32], "outputs[<project>/Analyses/*/*/*|output]",
               "As files, the nine of each sample folder from its taxtriage step and seven again from the index step's inputs",
               closedBy: perSample),
    ]

    // MARK: Fixed facts

    private static let facts: [TaxTriageParityKnownDifference] = [
        TaxTriageParityKnownDifference(
            counts: [.x1: 2, .x2: 2, .x3: 6],
            scope: .side(.a),
            id: "fact: record * names *top/*.top_report.tsv that does not exist",
            reason: "2.8 T5. The GUI's build-db step deletes top/, and the result's record, each sample's record and the database's record still name the top reports (missingRecordFiles in TaxTriageStandInEngineReplayTests). The legacy route keeps this cleanup until it goes",
            closedBy: guiRoute
        ),
    ]

    /// One line per found difference that no entry declares, and per entry that matches another
    /// number of found differences than its count for `parityCase` in `scope`, listing the
    /// differences it matches.
    static func failures(
        found: [TaxTriageParityDifference],
        parityCase: TaxTriageParityCase,
        scope: TaxTriageParityScope
    ) -> [String] {
        let declared = all.filter { $0.counts[parityCase] != nil && $0.scope == scope }
        var lines: [String] = []
        for difference in found where !declared.contains(where: { $0.matches(difference) }) {
            lines.append("not declared: \(difference)")
        }
        for entry in declared {
            let matched = found.filter(entry.matches)
            let count = entry.counts[parityCase] ?? 0
            if matched.isEmpty {
                lines.append("declared but gone, delete \(parityCase.rawValue) from the entry (closed by \(entry.closedBy)): \(entry.id)")
            } else if matched.count != count {
                lines.append(
                    "\(matched.count) differences match, \(count) declared for \(parityCase.rawValue) (closed by \(entry.closedBy)): \(entry.id)"
                        + matched.map { "\n        \($0.id)" }.joined()
                )
            }
        }
        return lines
    }
}
