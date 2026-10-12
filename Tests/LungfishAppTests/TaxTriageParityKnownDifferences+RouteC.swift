// TaxTriageParityKnownDifferences+RouteC.swift - The declared differences of sides C and C' of a TaxTriage parity case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q1b, 2.7 T2. Side C runs the routed `taxtriage run --project` through the built
// lungfish-cli and side C' the argv side C's root record names (TaxTriageCLIGUIParityReplayTests+RouteC.swift).
// A against C lists what the switch of the GUI route to lungfish-cli changes, frozen when Q1b
// landed and only to shrink. C against C' and C' against C declare nothing, the acceptance. The
// fixed facts sides C and C' do not hold are declared here too, each for both sides.

import Foundation

extension TaxTriageParityKnownDifferences {
    static let routeC: [TaxTriageParityKnownDifference] = routeCLayout + routeCRecords + routeCBatchRecords + routeCFacts

    /// The comparison numbers a side's UUIDs in the order it meets them across its whole tree.
    static let uuidNumbering = "a comparison that numbers the UUIDs of each file alone, a part of Q1b moved out of the A2 M3b continuation"
    /// build-db taxtriage itself keeps the legacy cleanup.
    static let buildDbForce = "build-db taxtriage --force with the executor's recorded cleanup that keeps top/ (2.8 row 247 and T5)"

    private static func pairAC(
        _ counts: [TaxTriageParityCase: Int], _ id: String, _ reason: String, closedBy: String
    ) -> TaxTriageParityKnownDifference {
        TaxTriageParityKnownDifference(counts: counts, scope: .pair(.a, .c), id: id, reason: reason, closedBy: closedBy)
    }

    /// A fact of the result's root record, `Analyses/<folder>/.lungfish-provenance.json`.
    private static func recordC(
        _ counts: [TaxTriageParityCase: Int], _ fact: String, _ reason: String, closedBy: String = guiRoute
    ) -> TaxTriageParityKnownDifference {
        pairAC(counts, "record Project.lungfish/Analyses/*/.lungfish-provenance.json: \(fact)", reason, closedBy: closedBy)
    }

    /// The same fixed fact on sides C and C'.
    private static func factC(
        _ counts: [TaxTriageParityCase: Int], _ fact: String, _ reason: String, closedBy: String
    ) -> [TaxTriageParityKnownDifference] {
        [TaxTriageParitySide.c, .cPrime].map {
            TaxTriageParityKnownDifference(counts: counts, scope: .side($0), id: "fact: \(fact)", reason: reason, closedBy: closedBy)
        }
    }

    private static let everyCase: [TaxTriageParityCase: Int] = [.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1, .x6: 1, .x7: 1]
    private static let completedCases: [TaxTriageParityCase: Int] = [.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1, .x7: 1]

    // MARK: Folders

    private static let routeCLayout: [TaxTriageParityKnownDifference] = [
        pairAC(completedCases, "analysis: only in A: batch-run-history.json",
               "The GUI records the run in the folder's batch history (BatchRunHistory.recordRun in completeTaxTriageRun). taxtriage run keeps none",
               closedBy: guiRoute),
        pairAC([.x1: 1, .x2: 1, .x3: 2, .x4: 1, .x5: 1], "analysis: only in C: *top/*.top_report.tsv",
               "The GUI's build-db step deletes top/ with the other intermediate folders, and the executor's finalize keeps it and records what it removes (2.8 T5, row 258). X4's failed sample writes no top report, and X7's rebuild deletes top/ on both sides",
               closedBy: guiRoute),
        pairAC([.x1: 1, .x2: 1, .x3: 2, .x4: 2, .x5: 1, .x6: 1, .x7: 1], "analysis: differs: *nextflow.log",
               "The same lines on both sides but the launch scratch, which each names by its UUID. The comparison numbers a side's UUIDs in the order it meets them in its tree, and side C's tree holds more of them before this file, as on side B",
               closedBy: uuidNumbering),
        pairAC([.x1: 2, .x2: 2, .x3: 4, .x4: 4, .x5: 2, .x6: 2, .x7: 2], "analysis: differs: *taxtriage-launch-command.*",
               "As nextflow.log, the .sh and .txt launch commands", closedBy: uuidNumbering),
        pairAC([.x1: 1, .x2: 1, .x3: 2, .x4: 2, .x5: 1, .x7: 1], "source manifest: only in A: *",
               "Only the GUI records the run in each source bundle's analyses-manifest.json (completeTaxTriageRun), for every sample of the request, a failed one too (X4)",
               closedBy: guiRoute),
        pairAC([.x3: 1, .x4: 1], "analysis: only in A: taxtriage-result.json",
               "The GUI's serial batch writes an aggregate result at its batch root. The executor's batch root keeps each sample's result in the sample's folder and writes none at the root",
               closedBy: guiRoute),
        pairAC([.x6: 1], "analysis: differs: .lungfish-run-in-progress.json",
               "Both cancelled runs keep their run record with the outcome. The GUI's names the --output command its row records, side C's the --project command it ran",
               closedBy: guiRoute),
        pairAC([.x4: 1], "terminal: A and C end differently",
               "Side C's batch completes with the sample that completed and exits 0 with the failed sample as a warning (warnOnFailedUnits), but its batch root holds no aggregate result to read the warning from, so its end reads Completed where the row reads Completed with Warnings",
               closedBy: guiRoute),
    ]

    // MARK: Records

    /// The result's root record, which the executor writes on side C in place of the pipeline's
    /// own, or of the serial batch's for two samples.
    private static let routeCRecords: [TaxTriageParityKnownDifference] = [
        recordC(everyCase, "argv",
                "The run level of side C's record names the taxtriage run command it ran (R1, UX 6), side A's the launch of Nextflow, the first sample's for a batch"),
        recordC(everyCase, "reproducibleCommand", "As argv"),
        recordC(everyCase, "toolName", "The pipeline's or the serial batch's record names taxtriage, the executor's lungfish-cli"),
        recordC(everyCase, "toolVersion", "As toolName, the pinned commit or the app's version against LGE's version"),
        recordC(everyCase, "workflowName", "TaxTriage or TaxTriage Serial Batch against lungfish.taxtriage.run, the executor's root record"),
        recordC([.x1: 1, .x2: 1, .x5: 1, .x6: 1, .x7: 1], "stderr",
                "The pipeline's record keeps the run's stderr, the executor's the run's warnings or its own cancel words, as on side B (B12)"),
        recordC([.x1: 3, .x2: 3, .x3: 3, .x4: 3, .x5: 3, .x7: 3], "*teps[Lungfish TaxTriage Index#1]",
                "The GUI's build-db step adds its lungfish-app taxtriage index step to the result's record, in steps, canonicalRunSteps and legacyRunSteps (O1). The executor's finalize records its index and removal steps under its own names"),
        recordC([.x1: 2, .x2: 2, .x5: 2, .x7: 2], "files[*|log]",
                "The GUI's index step reads nextflow.log and trace.txt as logs, and the record lists its inputs with that role beside the pipeline's outputs"),
        recordC([.x1: 2, .x2: 2, .x5: 2, .x7: 2], "outputs[*|log]", "As files"),
        recordC([.x1: 1, .x2: 1, .x3: 2, .x4: 1, .x5: 1, .x7: 1], "files[*|report]",
                "The GUI's index step reads each organism report as a report, and the record lists it with that role"),
        recordC([.x1: 1, .x2: 1, .x3: 2, .x4: 1, .x5: 1, .x7: 1], "outputs[*|report]", "As files"),
        recordC(completedCases, "files[*taxtriage.sqlite|output].format",
                "The GUI's index step names the database's format unknown, the executor's sqlite"),
        recordC(completedCases, "outputs[*taxtriage.sqlite|output].format", "As files"),
        recordC(completedCases, "output.format",
                "The run's output is its first output, analysis-metadata.json or the batch result on side A and taxtriage.sqlite on side C, whose record names no format for it"),
        recordC(completedCases, "output.path", "As output.format"),
        pairAC([.x1: 1, .x2: 1, .x3: 1, .x4: 1, .x5: 1],
               "record Project.lungfish/Analyses/*/taxtriage.sqlite.lungfish-provenance.json: resolvedDefaultOptions.samtoolsPath.value",
               "The index's record names the samtools it resolved. Side C's lungfish-cli takes the stand-in's conda root as its tool root (TaxTriageParityEngine.cliEnvironment), which holds no samtools, where side A's build-db names this Mac's managed samtools. X7's rebuild runs build-db on both sides",
               closedBy: "the parity's live class, whose sides all read one managed tool root (ruling O5)"),
    ]

    /// X3 and X4. The GUI's serial batch record against the executor's root record of the batch
    /// root, whose samples keep their own records.
    private static let routeCBatchRecords: [TaxTriageParityKnownDifference] = [
        recordC([.x3: 3, .x4: 3], "*teps[taxtriage#1]",
                "The serial batch record holds one taxtriage step per sample. The executor's root record names the samples' outputs, and each sample's record holds its own step"),
        recordC([.x3: 3, .x4: 3], "*teps[taxtriage#2]", "As taxtriage#1"),
        recordC([.x3: 3, .x4: 3], "*teps[lungfish-app-taxtriage-serial-batch#1]", "The serial batch record's step for the batch itself"),
        recordC([.x3: 17, .x4: 17], "explicitOptions.*",
                "The serial batch record files every run parameter as an explicit option (TaxTriageSerialBatchRunner.provenanceParameters). The executor's root record of a batch keeps them in each sample's record"),
        recordC([.x3: 17, .x4: 17], "legacyRunParameters.*", "As explicitOptions"),
        recordC([.x3: 3, .x4: 3], "files[<project>/Imports/*|input]",
                "The serial batch record lists each sample's input files. The executor's root record of a batch leaves them to the samples' records"),
        recordC([.x3: 1, .x4: 1], "files[*taxtriage-result.json|output]", "The serial batch record lists its aggregate result, which the executor's batch root never writes"),
        recordC([.x3: 1, .x4: 1], "outputs[*taxtriage-result.json|output]", "As files"),
        recordC([.x3: 1, .x4: 1], "output.sha256", "As output.path, the aggregate result against taxtriage.sqlite"),
        recordC([.x3: 1, .x4: 1], "output.size", "As output.sha256"),
    ]

    // MARK: Fixed facts of sides C and C'

    private static let routeCFacts: [TaxTriageParityKnownDifference] =
        factC([.x3: 1], "the analysis folder holds its result",
              "The executor's batch root keeps each sample's taxtriage-result.json in the sample's folder and writes no aggregate result at the root, which the viewer and the row of the GUI route read today",
              closedBy: guiRoute)
        + factC([.x4: 1], "the run ends Completed with Warnings, not exit 0",
                "Side C exits 0 with the failed sample as a warning, and its batch root holds no aggregate result for the end to read the warning from (TaxTriageParityComparison.outcome)",
                closedBy: guiRoute)
        + factC([.x7: 1], "record * names *taxtriage.sqlite with another digest",
                "X7's --force rebuild runs build-db taxtriage, which replaces taxtriage.sqlite after the executor's root record named its digest",
                closedBy: buildDbForce)
        + factC([.x7: 2], "record * names *top/*.top_report.tsv that does not exist",
                "X7's --force rebuild runs build-db taxtriage, whose legacy cleanup deletes the top/ the executor kept, which the root record and the database's record still name",
                closedBy: buildDbForce)
}
