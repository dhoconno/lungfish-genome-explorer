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
    static let all: [TaxTriageParityKnownDifference] =
        layout + pooledLayout + records + pooledRecords + facts + faultLayout + faultRecords + faultFacts
            + executorLayout + executorRecords + routeC

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
    /// build-db's cleanup deletes `top/`, which the records it leaves still name.
    static let keptTop = "A2 with B12, a cleanup that keeps top/ and records what it removes (2.8 T5, row 258)"
    /// A one-sample row records a plain `--output` into the GUI's own batch folder (2.8 T17).
    static let rowSpelling = "2.10, a one-sample row that records --project, so its replay lays the result out as the app does (2.8 T17)"
    /// The reader re-roots a span of free text that holds several paths (PortablePath.rerootFreeText).
    static let readerReroot = "2.10, a re-root that leaves a whole command alone (PortablePath.rerootFreeText, Moved out row)"

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
        pair([.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1, .x7: 1], "analysis: only in A: batch-run-history.json",
             "The GUI records the run in the folder's batch history (BatchRunHistory.recordRun in completeTaxTriageRun). taxtriage run keeps none",
             closedBy: guiRoute),
        pair([.x1: 2, .x2: 2, .x3: 2, .x4: 2, .x5: 2], "analysis: only in A: taxtriage.sqlite*",
             "The GUI runs build-db taxtriage once the pipeline ends, which writes taxtriage.sqlite and its record. taxtriage run builds no database (TaxTriageStandInEngineReplayTests pins it). X7 runs build-db on side B too",
             closedBy: executorIndex),
        pair([.x1: 1, .x2: 1, .x5: 1], "analysis: only in B: top/*.top_report.tsv",
             "The GUI's build-db step deletes top/ with the other intermediate folders (performCleanupForSingleResult in BuildDbCommand.swift). The legacy route keeps that cleanup until it goes, and the executor path keeps top/ (2.8 T5)",
             closedBy: guiRoute),
        pair([.x1: 1, .x2: 1, .x3: 1, .x5: 1, .x7: 1], "analysis: differs: taxtriage-result.json",
             "allOutputFiles. The GUI's list starts with analysis-metadata.json, which the GUI writes when it claims the folder before the run, and its batch result lists each sample's files in the sample's folder. taxtriage run marks its folder after the pipeline lists its files (markAsProjectAnalysisIfNeeded) and a pooled run lists every file at its root",
             closedBy: folderClaim),
        pair([.x1: 1, .x2: 1, .x3: 2, .x4: 2, .x5: 1, .x7: 1], "source manifest: only in A: *",
             "Only the GUI records the run in each source bundle's analyses-manifest.json (completeTaxTriageRun), for every sample of the request, a failed one too (X4)",
             closedBy: guiRoute),
    ]

    /// X3 and X4. Side A runs one Nextflow per sample in its own folder below the batch root
    /// (2.8 T2), and side B's frozen tree is the pooled run of the same two samples (QA inventory
    /// 2.2), which fails as a whole in X4.
    private static let pooledLayout: [TaxTriageParityKnownDifference] = [
        pair([.x3: 20, .x4: 17], "analysis: only in A: */*",
             "Each sample folder of the GUI's batch holds its own samplesheet, config, launch command, log, trace, accession map, organism report, record and result. The GUI's cleanup deleted each folder's top/. X4's failed sample keeps its samplesheet, config, launch command, log, trace and record",
             closedBy: perSample),
        pair([.x3: 12, .x4: 7], "analysis: only in B: *",
             "The pooled run writes one samplesheet, config, launch command, log and trace for both samples and every sample's accession map, organism report and top report at the root of its folder. X4's failed pooled run writes only the first five, and the executor keeps its run record with the outcome failed (E5)",
             closedBy: perSample),
    ]

    // MARK: Records

    private static let records: [TaxTriageParityKnownDifference] = [
        record([.x1: 3, .x2: 3, .x3: 3, .x4: 3, .x5: 3, .x7: 3], "*teps[Lungfish TaxTriage Index#1]",
               "The GUI's build-db step adds its index step to the result's record, in steps, canonicalRunSteps and legacyRunSteps (O1, ARCH 5 of 2.8)",
               closedBy: executorIndex),
        record([.x1: 2, .x2: 2, .x5: 2, .x7: 2], "files[*|log]",
               "The index step reads nextflow.log and trace.txt as logs, and the record lists its inputs with that role beside the pipeline's outputs",
               closedBy: executorIndex),
        record([.x1: 2, .x2: 2, .x5: 2, .x7: 2], "outputs[*|log]", "As files", closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 2, .x4: 1, .x5: 1, .x7: 1], "files[*|report]",
               "The index step reads each organism report as a report, and the record lists it with that role",
               closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 2, .x4: 1, .x5: 1, .x7: 1], "outputs[*|report]", "As files", closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1, .x7: 1], "files[*taxtriage.sqlite|output]",
               "The index step's output, the database", closedBy: executorIndex),
        record([.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1, .x7: 1], "outputs[*taxtriage.sqlite|output]", "As files", closedBy: executorIndex),
        // A2 closed the analysis-metadata.json rows of X1, X2, X5 and X7. The executor writes the
        // file when it claims the folder in phase P1, before the pipeline lists its outputs.
        record([.x4: 1], "output.format",
               "The run's output is its first output. In the GUI's batch record it is taxtriage-result.json, and in the record of X4's failed pooled run nextflow.log",
               closedBy: perSample),
        record([.x3: 1, .x4: 1], "output.path",
               "As output.format. X3's two records name files of one format, the batch result against the pooled run's first output",
               closedBy: perSample),
    ]

    /// X3 and X4. The GUI's batch record against the record of the pooled run.
    private static let pooledRecords: [TaxTriageParityKnownDifference] = [
        record([.x3: 1, .x4: 1], "workflowName", "TaxTriage Serial Batch against TaxTriage", closedBy: perSample),
        record([.x3: 1, .x4: 1], "explicitOptions.workflow.value", "taxtriage-serial-batch against taxtriage", closedBy: perSample),
        record([.x3: 1, .x4: 1], "legacyRunParameters.workflow.value", "As explicitOptions", closedBy: perSample),
        record([.x3: 1, .x4: 1], "explicitOptions.classifiers",
               "B11 M2 (R5) files classifiers among the resolved defaults of the pipeline's record, which the pooled run writes. The GUI's batch record files every run parameter as an explicit option (TaxTriageSerialBatchRunner.provenanceParameters)",
               closedBy: guiRoute),
        record([.x3: 1, .x4: 1], "legacyRunParameters.classifiers", "As explicitOptions", closedBy: guiRoute),
        record([.x3: 1, .x4: 1], "explicitOptions.sample_count",
               "B12 ruling H1 files sample_count among the resolved defaults of the pipeline's record, which the pooled run writes. The GUI's batch record keeps every run parameter as an explicit option (TaxTriageSerialBatchRunner.provenanceParameters, kept by ruling H4)",
               closedBy: guiRoute),
        record([.x3: 1, .x4: 1], "legacyRunParameters.sample_count", "As explicitOptions", closedBy: guiRoute),
        record([.x3: 1, .x4: 1], "argv",
               "The batch record's run level names the first sample's reproducible Nextflow command, the pooled record the launch of both samples",
               closedBy: perSample),
        record([.x3: 1, .x4: 1], "reproducibleCommand", "As argv", closedBy: perSample),
        record([.x3: 3, .x4: 3], "*teps[lungfish-app-taxtriage-serial-batch#1]",
               "The batch record's step for the serial batch itself", closedBy: perSample),
        record([.x3: 3, .x4: 3], "*teps[taxtriage#2]",
               "The batch record holds one taxtriage step per sample, the pooled record one for both", closedBy: perSample),
        record([.x3: 13, .x4: 5], "*teps[taxtriage#1].*",
               "The batch record's first taxtriage step is the first sample's launch, with its own samplesheet, folder and nine outputs. In X4 it is the failed sample's, whose stderr the batch prefixes",
               closedBy: perSample),
        record([.x3: 18, .x4: 9], "files[<project>/Analyses/*/*/*|output]",
               "The batch record lists the nine files of each sample folder that completed, the pooled record the files at its root",
               closedBy: perSample),
        record([.x3: 32, .x4: 16], "outputs[<project>/Analyses/*/*/*|output]",
               "As files, the nine of each completed sample folder from its taxtriage step and seven again from the index step's inputs",
               closedBy: perSample),
    ]

    // MARK: Fixed facts

    private static let facts: [TaxTriageParityKnownDifference] = [
        TaxTriageParityKnownDifference(
            counts: [.x1: 2, .x2: 2, .x3: 6, .x4: 3, .x5: 2, .x7: 2],
            scope: .side(.a),
            id: "fact: record * names *top/*.top_report.tsv that does not exist",
            reason: "2.8 T5. The GUI's build-db step deletes top/, and the result's record, each sample's record and the database's record still name the top reports (missingRecordFiles in TaxTriageStandInEngineReplayTests). The legacy route keeps this cleanup until it goes",
            closedBy: guiRoute
        ),
    ]

    // MARK: Fault cases

    /// X4 and X6, a failed pooled run and a cancel, beside the folders of a completed GUI run.
    private static let faultLayout: [TaxTriageParityKnownDifference] = [
        pair([.x4: 1], "terminal: A and B end differently",
             "Side A's serial batch keeps the sample that completed and reads Completed with Warnings. Side B's pooled run, one Nextflow for both samples (2.8 T2), fails as a whole when one sample fails, and taxtriage run ends with the executor's workflow error, exit 64 (exit 1 in the shipped binary)",
             closedBy: perSample),
        // A2 closed X4's and X6's analysis-metadata.json and X6's run record. The executor claims
        // the folder with both before the run and keeps them for a failed or cancelled run (E5).
        pair([.x4: 1], "analysis: only in A: taxtriage-result.json",
             "Side A's batch writes its aggregate result for the sample that completed. The failed pooled run writes none",
             closedBy: perSample),
    ]

    /// X4. The GUI's batch record, which completes with one sample, against the record of the
    /// failed pooled run.
    private static let faultRecords: [TaxTriageParityKnownDifference] = [
        record([.x4: 1], "files[*taxtriage-result.json|output]",
               "The batch record lists the aggregate result, which the failed pooled run never writes", closedBy: perSample),
        record([.x4: 1], "outputs[*taxtriage-result.json|output]", "As files", closedBy: perSample),
        record([.x4: 1], "status", "The batch completes with the sample that completed, the pooled run fails", closedBy: perSample),
        record([.x4: 1], "readStatus", "As status", closedBy: perSample),
        record([.x4: 1], "exitStatus", "As status, 0 against the executor's workflow error 64", closedBy: perSample),
        record([.x4: 1], "opsStats.completedRunCount", "As status, one completed run against none", closedBy: perSample),
        record([.x4: 1], "output.sha256",
               "As output.path, the batch result against the failed run's nextflow.log, a file only one tree holds", closedBy: perSample),
        record([.x4: 1], "output.size", "As output.sha256", closedBy: perSample),
    ]

    /// X4 and X7, fixed facts that side A or side B does not hold today.
    private static let faultFacts: [TaxTriageParityKnownDifference] = [
        TaxTriageParityKnownDifference(
            counts: [.x4: 1],
            scope: .side(.a),
            id: "fact: nothing is written into negative-control's bundle: analyses-manifest.json",
            reason: "QA inventory 2.2 says a failed sample writes nothing into its bundle, but completeTaxTriageRun records the analysis in the manifest of every sample of the request, the failed one too (AppDelegate+TaxTriageCompletion.swift:90-105)",
            closedBy: "completeTaxTriageRun records only the samples that kept a report (AppDelegate+TaxTriageCompletion.swift:90), at the latest with the 2.10 GUI route through lungfish-cli (A3 and U8)"
        ),
        TaxTriageParityKnownDifference(
            counts: [.x4: 1],
            scope: .side(.b),
            id: "fact: the run ends Completed with Warnings, not exit 64",
            reason: "Side B's pooled run of both samples fails as a whole when one sample fails (2.8 T2), so it cannot keep the other sample and count 1 failed sample (1 report). Since A2 the executor ends the failed run with its workflow error code, 64 (AnalysisRunExitCode.workflowError), where the pipeline's error escaped the command before",
            closedBy: perSample
        ),
        TaxTriageParityKnownDifference(
            counts: [.x7: 2],
            scope: .side(.b),
            id: "fact: record * names *top/*.top_report.tsv that does not exist",
            reason: "2.8 T5 on side B. X7 runs the app's build-db on side B before the rebuild, whose cleanup deletes top/, which the result's record and the database's record still name, as on side A",
            closedBy: keptTop
        ),
    ]

    // MARK: Side B on the executor (A2 M2)

    /// The folders of side B since `taxtriage run` runs on the analysis run executor.
    private static let executorLayout: [TaxTriageParityKnownDifference] = [
        pair([.x1: 1, .x2: 1, .x5: 1, .x6: 1, .x7: 1], "analysis: differs: analysis-metadata.json",
             "isBatch. The GUI marks its taxtriage-batch folder as a batch. The executor claims the folder the one-sample row's plain --output names as a single result folder and marks it so",
             closedBy: rowSpelling),
        pair([.x3: 1, .x4: 1], "analysis: differs: analysis-metadata.json",
             "isBatch. The GUI's serial batch against the executor's single folder of the pooled run",
             closedBy: perSample),
        pair([.x6: 1], "analysis: differs: .lungfish-run-in-progress.json",
             "Both cancelled runs keep their run record with the outcome. The GUI's names the command its row records, the executor's the canonical taxtriage run argv, which a test process records in place of its own (recordedCommandLine)",
             closedBy: guiRoute),
        pair([.x6: 3], "project: only in B: .tmp/taxtriage-run-<UUID>/*",
             "N7 and A2 review fix 1. A cancelled executor launch leaves its launch scratch, the owner marker, the temp origin and Nextflow's -w folder, in the project's .tmp/ for the abandoned-scratch sweep, because its cancelled record is the root record, which the executor writes after the unit returns (N5). The GUI's in-process route writes its own cancelled record and then removes the scratch (T13)",
             closedBy: guiRoute),
    ]

    /// The result's root record, which the executor writes on side B in place of the pipeline's own.
    private static let executorRecords: [TaxTriageParityKnownDifference] = [
        record([.x1: 1, .x2: 1, .x5: 1, .x6: 1, .x7: 1], "workflowName",
               "TaxTriage against lungfish.taxtriage.run, the executor's root record (S2, A2)", closedBy: guiRoute),
        record([.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1, .x6: 1, .x7: 1], "toolName",
               "The pipeline's record names taxtriage as the run's tool, the executor's names lungfish-cli. The TaxTriage step names taxtriage on both",
               closedBy: guiRoute),
        record([.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1, .x6: 1, .x7: 1], "toolVersion",
               "As toolName, the pinned commit against LGE's version", closedBy: guiRoute),
        record([.x1: 1, .x2: 1, .x5: 1, .x6: 1, .x7: 1], "argv",
               "The run level of the executor's record names the taxtriage run command (R1, UX 6), the pipeline's record the launch of Nextflow, which the step keeps on both",
               closedBy: guiRoute),
        record([.x1: 1, .x2: 1, .x5: 1, .x6: 1, .x7: 1], "reproducibleCommand", "As argv", closedBy: guiRoute),
        record([.x1: 1, .x2: 1, .x5: 1, .x6: 1, .x7: 1], "stderr",
               "The pipeline's record keeps the run's stderr, empty, X5's warning lines or the pipeline's cancel words. The executor's keeps the run's warnings, none, X5's errored-task paragraph or its own cancel words. The step keeps the warning lines on both (B12)",
               closedBy: guiRoute),
        record([.x6: 1], "steps[taxtriage#1].reproducibleCommand",
               "Review fix 1 changed no recorded field. On reading, PortablePath.rerootFreeText writes the last path of a span that exists in the project in place of the whole span. Side A's cancel removed its scratch, so its command reads from the --outdir folder on, and side B keeps its scratch for the sweep (N7), so its command reads from the -w folder on",
               closedBy: readerReroot),
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
