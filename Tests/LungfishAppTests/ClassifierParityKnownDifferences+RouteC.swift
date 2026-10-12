// ClassifierParityKnownDifferences+RouteC.swift - Side A against side C, and the facts the command's runs do not hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane F3, panel decisions T2, E10 and E15. Side C runs each case through the GUI route over
// `lungfish-cli`, and side C' runs the command side C's row recorded. Each difference of side A,
// today's GUI path, against side C is declared here with its reason and a count per case, and
// the list may only shrink. Most close when the legacy GUI paths retire in 2.9 (E14). Sides C
// and C' run the same command, so a fixed fact one of them does not hold is declared for both,
// and C against C' declares nothing.
//
// The counts come from a run of the class with `LUNGFISH_PARITY_DUMP` set, as every count in
// ClassifierParityKnownDifferences.swift does.

import Foundation

extension ClassifierParityKnownDifferences {
    static let routeC: [ClassifierParityKnownDifference] = aAgainstC + commandFacts

    private static func aAgainstC(
        _ counts: [ClassifierParityCase: Int], _ id: String, _ reason: String, closedBy: String = retire
    ) -> ClassifierParityKnownDifference {
        ClassifierParityKnownDifference(counts: counts, scope: .pair(.a, .c), id: id, reason: reason, closedBy: closedBy)
    }

    /// A fixed fact the command's run does not hold, on side C and on side C'.
    private static func commandFact(
        _ counts: [ClassifierParityCase: Int], _ id: String, _ reason: String, closedBy: String
    ) -> [ClassifierParityKnownDifference] {
        [ClassifierParitySide.c, .cPrime].map {
            ClassifierParityKnownDifference(counts: counts, scope: .side($0), id: id, reason: reason, closedBy: closedBy)
        }
    }

    // MARK: A against C

    // Folders, then the rows, then the records. A record fact closes only when side A's legacy
    // shape goes, so every entry closes in 2.9 unless it names another lane.
    private static let aAgainstC: [ClassifierParityKnownDifference] = [
        aAgainstC([.k1: 1, .k2: 1, .k3: 2, .k4: 1, .k5: 1, .k6: 1], "analysis: differs: *classification-result.json",
            "BIO D12. config.inputFiles names the GUI's deleted scratch file or the bundle's own files where the command names the files it kept, and the GUI's outputDirectory URL ends in a slash"),
        aAgainstC([.k3: 1], "analysis: differs: classification-batch-result.json",
            "The GUI's batch manifest names the merge sample single-end, as the grouper sees it, and the executor's names it paired, as its read-set plan runs it (E8, E13)"),
        aAgainstC([.e1: 1, .e2: 1, .e3: 2], "analysis: differs: */esviritu-result.json",
            "The GUI's outputDirectory URL ends in a slash, and for the subset config.inputFiles names the GUI's deleted scratch file (BIO D12)"),
        aAgainstC([.e1: 1, .e3: 1], "analysis: differs: */*.fastp.json",
            "BIO D4. fastp's command names the GUI's scratch input and the command's kept input"),
        aAgainstC([.k1: 1, .k3: 1, .k4: 1], "analysis: only in A: *.lungfish-provenance/intermediates/classification-inputs/input-1-materialized-<UUID>.fastq",
            "BIO D4. The GUI materializes the subset into a scratch folder it deletes, so the pipeline keeps a replay copy"),
        aAgainstC([.k1: 1, .k3: 1, .k4: 1], "analysis: only in C: *.lungfish-classify-inputs/materialized-<UUID>.fastq",
            "BIO D4, E3. The command materializes the subset into the result folder and keeps it, a batch at the batch root"),
        aAgainstC([.e1: 1, .e3: 1], "analysis: only in C: .lungfish-esviritu-inputs/materialized-<UUID>.fastq",
            "BIO D4, E3. The command keeps the materialized subset at the root of the result folder, where the GUI deletes its scratch copy"),
        aAgainstC([.k1: 2, .k2: 2, .k4: 2, .k5: 2, .k6: 2], "analysis: only in C: kraken2.sqlite*",
            "UX D19, E6. A single run builds kraken2.sqlite and its record at the end of the run, where the GUI builds them the first time the user selects the result"),
        aAgainstC([.k1: 3, .k2: 3, .k4: 3, .k5: 3, .k6: 3], "analysis: only in C: classification*.lungfish-provenance.json",
            "UX D19, E6. The build-db core the finalize runs records each file it reads or writes beside it"),
        aAgainstC([.e1: 1], "source manifest: differs: *",
            "UX D18. The executor's entry in the source bundle's analyses-manifest.json records other parameters than the GUI's entry, isPairedEnd where the GUI's names inputReadLayout. UX accepted it in its review of lane F3 (finding e), since the display names and summaries are equal and only the Inspector's Analyses parameter line changes"),
        aAgainstC([.k1: 3, .k3: 3, .k4: 3, .e1: 3, .e3: 3], "row: * only in A: *Materializing virtual FASTQ...",
            "UX D5, UX D6. The GUI's own resolver reports the virtual subset's materialization in two lines around the materializer's, and the command reports the materializer's line alone. UX accepted the loss in its review of lane F3 (finding c), since the materializer's own line shows through the long part of a materialization on both routes and the two lines add nothing a user acts on"),
        aAgainstC([.k1: 3, .k3: 3, .k4: 3, .e1: 3, .e3: 3], "row: * only in A: *Materialization complete",
            "As Materializing virtual FASTQ..."),
        aAgainstC([.e1: 3, .e2: 3, .e3: 3], "row: * only in C: *Writing the EsViritu batch summary…",
            "A9's finalize writes the batch summary with a progress line of its own (X1 review, section 3)"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 1, .k4: 1, .k5: 1, .k6: 1, .e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info] Parsed * rows from *",
            "UX D19 and A9's finalize. The command builds the viewer database at the end of the run, and the row logs the builder's lines (X1 review, section 3)"),
        aAgainstC([.e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info] Parsed * coverage windows from *",
            "As Parsed, the EsViritu builder's coverage table"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 1, .k4: 1, .k5: 1, .k6: 1, .e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info] Built database at *",
            "As Parsed"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 1, .k4: 1, .k5: 1, .k6: 1, .e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info] Cleanup complete. Freed *",
            "As Parsed. Freed Zero KB is a 2.8 words item"),
        aAgainstC([.e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info] Counting reads per organism...",
            "As Parsed, the EsViritu builder's read count step"),
        aAgainstC([.e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info]   Marked duplicates in *",
            "As Counting reads per organism"),
        aAgainstC([.e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info]   Updated read counts for *",
            "As Counting reads per organism"),
        aAgainstC([.e1: 1, .e2: 1, .e3: 1], "row: log line only in C: [info] Running markdup on *",
            "As Counting reads per organism"),
        aAgainstC([.k5: 1, .k6: 1], "row: log line only in C: [info] Kraken classification completed, but Bracken profiling did not complete: *",
            "E4. The command also reports the degraded profile in a line of its own, which the row logs at info (S16), beside the one warning line both rows show"),
        aAgainstC([.k3: 22], "row: log line only in C: [info] Sample */2 (*): *",
            "UX D6. The CLI route logs every progress line of a batch sample at info, where the in-process batch row shows them as details and overlay lines and logs none. UX accepted it in its review of lane F3 (finding d), since the single runs already log every message and the batch log is where a user looks when one sample fails"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 1, .k4: 1, .k5: 1, .k6: 1, .e1: 1, .e2: 1, .e3: 1], "record *: workflowName",
            "UX D21. The pipeline's records (Metagenomics Classification or Profiling, EsViritu Batch) against the executor's root records, lungfish.classify and lungfish.esviritu.detect (E15)"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 2, .k4: 1, .k5: 1, .k6: 1, .e1: 1, .e2: 1, .e3: 1], "record *: toolName",
            "The GUI record takes its run-level tool from its first step, and the executor's root record names lungfish-cli"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 3, .k4: 1, .k5: 1, .k6: 1, .e1: 1, .e2: 1, .e3: 1], "record *: toolVersion",
            "As toolName, the version of that first step against the LGE version of lungfish-cli"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 2, .k4: 1, .k5: 1, .k6: 1, .e1: 2, .e2: 1, .e3: 2], "record *: argv",
            "The GUI record's argv is its first step's, the copy or staging script or the tool's own, or the legacy batch writer's. The executor's root record names the command that ran (E11)"),
        aAgainstC([.k1: 1, .k2: 1, .k3: 2, .k4: 1, .k5: 1, .k6: 1, .e1: 2, .e2: 1, .e3: 2], "record *: reproducibleCommand",
            "As argv"),
        aAgainstC([.k5: 1, .k6: 1], "record *: durableReplayArgv",
            "The GUI record of a plain file holds kraken2's command as its replay argv, and the root record names the command that ran"),
        aAgainstC([.k1: 11, .k2: 15, .k3: 21, .k4: 14, .k5: 14, .k6: 14, .e1: 9, .e2: 4, .e3: 4], "record *: explicitOptions.*",
            "The GUI record holds every pipeline option, and the root record holds the options its command line gave (BIO D6, E12, E13)"),
        aAgainstC([.k1: 11, .k2: 15, .k3: 21, .k4: 14, .k5: 14, .k6: 14, .e1: 9, .e2: 4, .e3: 4], "record *: legacyRunParameters.*",
            "As explicitOptions"),
        aAgainstC([.k1: 6, .k2: 6, .k3: 7, .k4: 6, .k5: 6, .k6: 6, .e1: 3, .e2: 3, .e3: 3], "record *: defaultOptions.*",
            "The pipeline's defaults against the command's one table (BIO D7, BIO D8, E12)"),
        aAgainstC([.k1: 5, .k2: 5, .k3: 12, .k4: 5, .k5: 5, .k6: 5, .e1: 4, .e2: 4, .e3: 4], "record *: resolvedDefaultOptions.*",
            "The root record resolves the database through the install receipt and names no core file sizes, memory mapping, extra arguments or minimizer flag (E9). The tool's step keeps them"),
        aAgainstC([.k1: 4, .k2: 1, .k3: 18, .k4: 4, .k5: 1, .k6: 1, .e1: 4, .e2: 2, .e3: 4], "record *: files[*",
            "BIO D4. The GUI record names its scratch input and replay copy, the command's records the kept materialized input, and the database through another identity (E9)"),
        aAgainstC([.k1: 1, .k3: 9, .k4: 1, .e1: 2, .e2: 2, .e3: 2], "record *: outputs[*",
            "BIO D4. The GUI record lists the replay copy of the materialized input as an output"),
        aAgainstC([.k1: 2, .k2: 2, .k4: 2, .k5: 2, .k6: 2], "record *: output.*",
            "The run's output is classification-result.json in the GUI record and the kreport or detection table in the root record"),
        // A step's toolVersion that holds each side's own LGE version is masked in this pair
        // (ruling R1 of Phase 2.8), so K5 and K6 hold no step difference.
        aAgainstC([.k1: 7, .k2: 4, .k3: 47, .k4: 7, .e1: 7, .e2: 1, .e3: 7], "record *: steps[*",
            "BIO D4. The GUI's copy or staging step and its legacy build-db run against the command's fastq materialize step and the finalize's steps, so each tool reads other paths and depends on other steps"),
        aAgainstC([.k1: 4, .k2: 4, .k3: 27, .k4: 4, .e1: 3, .e2: 1, .e3: 3], "record *: canonicalRunSteps[*",
            "As steps"),
        aAgainstC([.k1: 4, .k2: 4, .k3: 27, .k4: 4, .e1: 3, .e2: 1, .e3: 3], "record *: legacyRunSteps[*",
            "As steps"),
        aAgainstC([.k3: 1, .e1: 1, .e2: 1, .e3: 1], "record *: stderr",
            "The GUI record keeps EsViritu's log as the run's stderr, and the root record keeps it on the EsViritu step"),
    ]

    // MARK: Facts of the command's runs

    /// Review F2 fix 5 asked side C to hold the named-file fact with nothing declared. These are
    /// defects of code both routes share, so they show on side C and side C' as on side A.
    private static let commandFacts: [ClassifierParityKnownDifference] = [
        commandFact([.e1: 6, .e2: 6, .e3: 20], "fact: record * names *_temp/*.third.filt.sorted.bam* that does not exist",
            "As on side A", closedBy: bamRunLevel),
        commandFact([.e1: 5, .e2: 5, .e3: 14], "fact: record * names */bams/*.third.filt.sorted.bam* with another digest",
            "As on side A, and the batch root names the BAM and its index as the run's outputs with their digests from before the markdup",
            closedBy: bamRunLevel),
    ].flatMap { $0 }
}
