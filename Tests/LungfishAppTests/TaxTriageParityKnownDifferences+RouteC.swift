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
        pairAC([.x1: 1, .x2: 1, .x3: 2, .x4: 1, .x5: 1, .x7: 1], "analysis: only in C: *top/*.top_report.tsv",
               "The GUI's build-db step deletes top/ with the other intermediate folders, and the executor's finalize keeps it and records what it removes (2.8 T5, row 258), as X7's rebuild of the executor's result does since B30 M3. X4's failed sample writes no top report",
               closedBy: guiRoute),
        pairAC([.x4: 1], "source manifest: only in A: *",
               "X4. The GUI records the run in the analyses-manifest.json of every sample of the request, the failed one too (completeTaxTriageRun). Since B30 M1 the command records each completed sample only, as Kraken2 does",
               closedBy: guiRoute),
        // B30 M3 (T5). Both batch roots hold the aggregate result and each entry its summary, whose runtime the
        // source-manifest compare masks (B30 ruling Q1, vote V-B30), so the source manifests of X3 and X4 agree.
        pairAC([.x4: 1], "analysis: differs: taxtriage-result.json",
               "X4. The aggregate lists the failed sample as its launch was asked to run it. The GUI's sample names the file its wizard resolved in the bundle, with its read layout. The executor's names the bundle the plan named, with no read layout, because a failed launch hands back no resolved sample (B30 M3)",
               closedBy: guiRoute),
        pairAC([.x6: 1], "analysis: differs: .lungfish-run-in-progress.json",
               "Both cancelled runs keep their run record with the outcome. The GUI's names the --output command its row records, side C's the --project command it ran",
               closedBy: guiRoute),
        pairAC([.x6: 3], "project: only in C: .tmp/taxtriage-run-<UUID>/*",
               "As on side B. Side C's cancelled taxtriage run --project leaves its launch scratch in the project's .tmp/ for the abandoned-scratch sweep (N7, A2 review fix 1), where the GUI's in-process route removes it after its own cancelled record (T13)",
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
        recordC([.x6: 1], "steps[taxtriage#1].reproducibleCommand",
                "As on side B. Side C keeps its scratch for the sweep (N7), so the reader's re-root reads its command from the -w folder on, and side A's from the --outdir folder on",
                closedBy: readerReroot),
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
    ]

    // MARK: Fixed facts of sides C and C'

    /// None since B30 M3. The aggregate result closed X3's and X4's, and the rebuild of an executor result,
    /// which keeps top/ and refreshes the root record, closed X7's.
    private static let routeCFacts: [TaxTriageParityKnownDifference] = []
}
