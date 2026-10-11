// ClassifierParityKnownDifferences.swift - Every declared difference between the sides of a classifier parity case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision T2 in docs/plans/2026-10-11-phase-2-7.md. Side A (today's GUI path) and side B
// (its recorded command replayed) differ today, and each difference is declared here with its
// reason and the lane whose change removes it. ClassifierCLIGUIParityReplayTests fails on a
// difference no entry declares and on an entry that matches no difference, so the list only
// shrinks. A lane that closes a difference deletes its entry in the same commit. A against B
// stays in place until the legacy GUI paths retire in 2.9 (E14). Lane F3 adds the entries of
// A against C, and C against C' declares none.

import Foundation

/// Where a declared difference applies.
enum ClassifierParityScope: Hashable, Sendable, CustomStringConvertible {
    /// How the second side differs from the first, the reference side.
    case pair(ClassifierParitySide, ClassifierParitySide)
    /// A fixed fact one side does not hold.
    case side(ClassifierParitySide)

    var description: String {
        switch self {
        case .pair(let reference, let candidate): return "\(reference) against \(candidate)"
        case .side(let side): return "side \(side)"
        }
    }
}

/// One declared difference.
struct ClassifierParityKnownDifference: Sendable {
    let cases: [ClassifierParityCase]
    let scope: ClassifierParityScope
    /// The id of the difference, where `*` stands for any run of characters.
    let id: String
    let reason: String
    /// The lane whose change removes the difference, or the phase that retires the path.
    let closedBy: String

    func matches(_ difference: ClassifierParityDifference) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: id).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return difference.id.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ClassifierParityKnownDifferences {
    /// The D numbers are the GUI and CLI differences of the BIO inventory, section 1.3.
    static let all: [ClassifierParityKnownDifference] = layout + kraken2Records + esVirituRecords + facts

    private static let kraken2: [ClassifierParityCase] = [.k1, .k2, .k3, .k4]
    private static let retire = "2.9, when the legacy GUI paths retire (E14)"

    private static func pair(
        _ cases: [ClassifierParityCase], _ id: String, _ reason: String, closedBy: String = retire
    ) -> ClassifierParityKnownDifference {
        ClassifierParityKnownDifference(cases: cases, scope: .pair(.a, .b), id: id, reason: reason, closedBy: closedBy)
    }

    // MARK: Folders

    private static let layout: [ClassifierParityKnownDifference] = [
        pair(kraken2 + [.e1, .e2], "analysis: only in A: analysis-metadata.json",
             "AnalysesFolder writes it for the folder the GUI creates. The row's command names that folder with --output-dir or --output, and a plain output folder gets none (E1, E2)"),
        pair(kraken2 + [.e1, .e2], "source manifest: only in A: *",
             "Only the GUI records the run in the source bundle's analyses-manifest.json"),
        pair([.k1, .k3, .k4], "analysis: only in A: *.lungfish-provenance/intermediates/classification-inputs/input-1-materialized-<UUID>.fastq",
             "D4. The GUI materializes the subset into a scratch folder it deletes, so the pipeline keeps a replay copy"),
        pair([.k1, .k3, .k4], "analysis: only in B: *.lungfish-classify-inputs/materialized-<UUID>.fastq",
             "D4. The CLI materializes the subset into the output folder and keeps it"),
        pair(kraken2, "analysis: differs: *classification-result.json",
             "D12. config.inputFiles names the GUI's deleted scratch file and the CLI's kept file, and the GUI's outputDirectory URL ends in a slash"),
        pair([.k3, .e1, .e2], "analysis: only in A: .lungfish-provenance.json",
             "The GUI's batch record at the batch root. The row's command runs each sample alone (E8)"),
        pair([.k3], "analysis: only in A: classification-batch-*",
             "The GUI's batch summary and batch manifest, which no per-sample command writes (E8)"),
        pair([.k3], "analysis: only in A: kraken2.sqlite*",
             "The GUI builds kraken2.sqlite and its record with build-db after the batch (E6)"),
        pair([.k3], "analysis: only in A: */classification*.lungfish-provenance.json",
             "The GUI's batch record writer leaves a record beside each sample output it names"),
        pair([.e1, .e2], "analysis: only in A: esviritu*",
             "A single GUI EsViritu run uses the batch layout and writes the batch manifest, the summary, esviritu.sqlite and its record (E2, E6)"),
        pair([.e1, .e2], "analysis: only in A: */bams/*",
             "The GUI's build-db esviritu moves the BAM and its index from _temp/ to bams/ and records each move",
             closedBy: "A7 records the move (E7). The CLI moves it once A9's finalize builds the index (E6), else 2.9"),
        pair([.e1, .e2], "analysis: only in B: */*_temp/*.third.filt.sorted.bam*",
             "The same BAM where the CLI leaves it, in _temp/",
             closedBy: "A7 records the move (E7). The CLI moves it once A9's finalize builds the index (E6), else 2.9"),
        pair([.e1, .e2], "analysis: only in B: */*.detected_virus.assembly_summary.tsv",
             "The GUI's build-db esviritu cleanup deletes the assembly summary table", closedBy: "A7 (E7)"),
        pair([.e1, .e2], "analysis: only in B: */*.virus_coverage_windows.tsv",
             "The GUI's build-db esviritu cleanup deletes the coverage windows table", closedBy: "A7 (E7)"),
        pair([.e1], "analysis: only in B: */.lungfish-esviritu-inputs/materialized-<UUID>.fastq",
             "D4. The CLI keeps the materialized subset, the GUI deletes its scratch copy"),
        pair([.e1], "analysis: differs: */*.fastp.json",
             "D4. fastp's command names the GUI's scratch input and the CLI's kept input"),
        pair([.e1, .e2], "analysis: differs: */esviritu-result.json",
             "The GUI's outputDirectory URL ends in a slash, and for the subset config.inputFiles names the GUI's deleted scratch file (D12)"),
        pair([.e3], "command: B has no command to run",
             "cli-parity-gap esviritu-batch. The EsViritu batch row records no command, so nothing replays the batch (E8). Side C' replays the new route's batch command"),
        pair([.k5], "analysis: only B keeps its analysis folder",
             "D2. The GUI deletes a failed run's folder, and the CLI keeps it with its failed record and its run record (E5)"),
    ]

    // MARK: Records

    private static func kraken2Record(_ fact: String, _ reason: String, closedBy: String = "A8") -> ClassifierParityKnownDifference {
        pair(kraken2, "record Project.lungfish/Analyses/*/.lungfish-provenance.json: \(fact)", reason, closedBy: closedBy)
    }

    private static let kraken2Records: [ClassifierParityKnownDifference] = [
        kraken2Record("workflowName", "The pipeline's record (Metagenomics Classification or Profiling) against the lungfish.classify record the CLI writes in its place (BIO inventory 1.1)"),
        kraken2Record("toolName", "The GUI record takes its run-level tool from its first step, the replay copy or the single-read mate staging, and the CLI record from kraken2"),
        kraken2Record("toolVersion", "As toolName, the LGE version of the copy step against kraken2's version"),
        kraken2Record("argv", "As toolName, the copy step's /bin/sh -c script against the CLI command (E11)"),
        kraken2Record("reproducibleCommand", "As argv"),
        kraken2Record("explicitOptions.*", "The CLI record drops the pipeline's options, the database identity among them, and with them the readSetPlan of a merge bundle (D6, E13)"),
        kraken2Record("legacyRunParameters.*", "As explicitOptions"),
        kraken2Record("defaultOptions.*", "The pipeline's defaults (confidence 0, read format unpaired) against the CLI's preset defaults (D7, D8, E12)"),
        kraken2Record("resolvedDefaultOptions.*", "The CLI record drops the database identity status, its core file sizes and the effective memory mapping (E9)"),
        kraken2Record("files[*", "D4. The GUI record names the scratch input and the replay copy, the CLI record the kept materialized input"),
        kraken2Record("outputs[*", "The GUI record lists classification-result.json and the replay copy as outputs, the CLI record does not"),
        kraken2Record("output.*", "The run's output is classification-result.json in the GUI record and the kreport in the CLI record"),
        kraken2Record("steps[*", "D4. The GUI's copy or staging step against the CLI's fastq materialize step, so kraken2 reads another path and depends on another step"),
        kraken2Record("canonicalRunSteps[*", "As steps"),
        kraken2Record("legacyRunSteps[*", "As steps"),
    ]

    private static func esVirituRecord(_ fact: String, _ reason: String) -> ClassifierParityKnownDifference {
        pair([.e1], "record Project.lungfish/Analyses/*/.lungfish-provenance.json: \(fact)", reason, closedBy: "A9")
    }

    private static let esVirituRecords: [ClassifierParityKnownDifference] = [
        esVirituRecord("argv", "D4, D5. EsViritu reads the GUI's deleted scratch file and the CLI's kept input"),
        esVirituRecord("reproducibleCommand", "As argv"),
        esVirituRecord("explicitOptions.*", "The GUI records its input layout scan (inputReadLayout and its counts), the CLI does not"),
        esVirituRecord("legacyRunParameters.*", "As explicitOptions"),
        esVirituRecord("files[*", "D5. The GUI record names the deleted scratch input"),
        esVirituRecord("steps[*", "As argv, in the EsViritu step and its log"),
        esVirituRecord("canonicalRunSteps[*", "As argv"),
        esVirituRecord("legacyRunSteps[*", "As argv"),
    ]

    // MARK: Fixed facts

    private static let facts: [ClassifierParityKnownDifference] = [
        ClassifierParityKnownDifference(
            cases: [.k2, .k3], scope: .side(.b),
            id: "fact: merge records its readSetPlan of 23 pairs and 77 merged reads",
            reason: "D6. The CLI record drops the pipeline's readSetPlan, so the 23 pairs and 77 merged reads are not in it",
            closedBy: "A8 (E13)"
        ),
        ClassifierParityKnownDifference(
            cases: [.k5], scope: .side(.a),
            id: "fact: the run completes",
            reason: "Kraken2 classifies none of the 40 reads, KreportParser finds no classified row and throws Empty Kraken2 report, and the run fails before Bracken runs, so it never degrades to Completed with Warnings as memo BIO O7 expected",
            closedBy: "a panel ruling, no 2.7 lane changes it (reported by F2)"
        ),
        ClassifierParityKnownDifference(
            cases: [.k5], scope: .side(.b),
            id: "fact: the run completes",
            reason: "As on side A, the replay throws Empty Kraken2 report",
            closedBy: "a panel ruling, no 2.7 lane changes it (reported by F2)"
        ),
    ]

    /// One line per found difference that no entry declares and per entry that matches no
    /// found difference, for `parityCase` in `scope`.
    static func failures(
        found: [ClassifierParityDifference],
        parityCase: ClassifierParityCase,
        scope: ClassifierParityScope
    ) -> [String] {
        let declared = all.filter { $0.cases.contains(parityCase) && $0.scope == scope }
        var lines: [String] = []
        for difference in found where !declared.contains(where: { $0.matches(difference) }) {
            lines.append("not declared: \(difference)")
        }
        for entry in declared where !found.contains(where: entry.matches) {
            lines.append("declared but gone, delete the entry (closed by \(entry.closedBy)): \(entry.id)")
        }
        return lines
    }
}
