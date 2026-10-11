// ClassifierParityKnownDifferences.swift - Every declared difference between the sides of a classifier parity case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision T2 in docs/plans/2026-10-11-phase-2-7.md. Side A (today's GUI path) and side B
// (its recorded command replayed) differ today, and each difference is declared here with its
// reason, the lane whose change removes it, and how many found differences it matches in each
// case. ClassifierCLIGUIParityReplayTests fails on a difference no entry declares and on an
// entry that matches more or fewer differences in a case than its count, so the list only
// shrinks, one difference at a time, and a new difference cannot hide under an old pattern. A
// lane that closes a difference lowers the count, or deletes the case or the entry, in the same
// commit. A against B stays in place until the legacy GUI paths retire in 2.9 (E14). Lane F3
// adds the entries of A against C, and C against C' declares none.

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
    /// The cases the entry applies to, each with the number of found differences it matches
    /// there.
    let counts: [ClassifierParityCase: Int]
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
    static let all: [ClassifierParityKnownDifference] = layout + kraken2Records + esVirituRecords + facts + namedFiles

    private static let retire = "2.9, when the legacy GUI paths retire (E14)"
    /// One difference in each sample's record, two in the K3 batch.
    private static let oneInEachKraken2Record: [ClassifierParityCase: Int] = [.k1: 1, .k2: 1, .k3: 2, .k4: 1]

    private static func pair(
        _ counts: [ClassifierParityCase: Int], _ id: String, _ reason: String, closedBy: String = retire
    ) -> ClassifierParityKnownDifference {
        ClassifierParityKnownDifference(counts: counts, scope: .pair(.a, .b), id: id, reason: reason, closedBy: closedBy)
    }

    // MARK: Folders

    private static let layout: [ClassifierParityKnownDifference] = [
        pair([.k1: 1, .k2: 1, .k3: 1, .k4: 1], "analysis: only in A: analysis-metadata.json",
             "AnalysesFolder writes it for the folder the GUI creates. The row's command names that folder with --output-dir, and a plain output folder gets none",
             closedBy: "A8, whose plain one-folder output gains analysis-metadata.json (A8 M2, E1)"),
        pair([.e1: 1, .e2: 1], "analysis: only in A: analysis-metadata.json",
             "AnalysesFolder writes it for the batch folder the GUI creates. The row's command names the sample folder below it with --output, which gets none under E1b"),
        pair([.k1: 1, .k2: 1, .k3: 2, .k4: 1, .e1: 1, .e2: 1], "source manifest: only in A: *",
             "Only the GUI records the run in the source bundle's analyses-manifest.json"),
        pair([.k1: 1, .k3: 1, .k4: 1], "analysis: only in A: *.lungfish-provenance/intermediates/classification-inputs/input-1-materialized-<UUID>.fastq",
             "D4. The GUI materializes the subset into a scratch folder it deletes, so the pipeline keeps a replay copy"),
        pair([.k1: 1, .k3: 1, .k4: 1], "analysis: only in B: *.lungfish-classify-inputs/materialized-<UUID>.fastq",
             "D4. The CLI materializes the subset into the output folder and keeps it"),
        pair([.k1: 1, .k2: 1, .k3: 2, .k4: 1], "analysis: differs: *classification-result.json",
             "D12. config.inputFiles names the GUI's deleted scratch file and the CLI's kept file, and the GUI's outputDirectory URL ends in a slash"),
        pair([.k3: 1, .e1: 1, .e2: 1], "analysis: only in A: .lungfish-provenance.json",
             "The GUI's batch record at the batch root. The row's command runs each sample alone (E8)"),
        pair([.k3: 2], "analysis: only in A: classification-batch-*",
             "The GUI's batch summary and batch manifest, which no per-sample command writes (E8)"),
        pair([.k3: 2], "analysis: only in A: kraken2.sqlite*",
             "The GUI builds kraken2.sqlite and its record with build-db after the batch (E6)"),
        pair([.k3: 6], "analysis: only in A: */classification*.lungfish-provenance.json",
             "The GUI's batch record writer leaves a record beside each sample output it names"),
        pair([.e1: 4, .e2: 4], "analysis: only in A: esviritu*",
             "A single GUI EsViritu run uses the batch layout and writes the batch manifest, the summary, esviritu.sqlite and its record (E2, E6)"),
        pair([.e1: 4, .e2: 4], "analysis: only in A: */bams/*",
             "The GUI's build-db esviritu moves the BAM and its index from _temp/ to bams/ and records each move. The row's command is a plain --output run, which builds no index, so side B keeps the BAM in _temp/ (E2)",
             closedBy: retire),
        pair([.e1: 2, .e2: 2], "analysis: only in B: */*_temp/*.third.filt.sorted.bam*",
             "The same BAM where the CLI leaves it, in _temp/. The row's command is a plain --output run, which builds no index, so side B keeps the BAM in _temp/ (E2)",
             closedBy: retire),
        pair([.e1: 1], "analysis: only in B: */.lungfish-esviritu-inputs/materialized-<UUID>.fastq",
             "D4. The CLI keeps the materialized subset, the GUI deletes its scratch copy"),
        pair([.e1: 1], "analysis: differs: */*.fastp.json",
             "D4. fastp's command names the GUI's scratch input and the CLI's kept input"),
        pair([.e1: 1, .e2: 1], "analysis: differs: */esviritu-result.json",
             "The GUI's outputDirectory URL ends in a slash, and for the subset config.inputFiles names the GUI's deleted scratch file (D12)"),
        pair([.e3: 1], "command: B has no command to run",
             "cli-parity-gap esviritu-batch. The EsViritu batch row records no command, so nothing replays the batch (E8). Side C' replays the new route's batch command"),
    ]

    // MARK: Records

    // Side A stays the legacy GUI path until 2.9 (T2) and A8 and A9 change side B only, so a
    // record fact closes in A8 or A9 only when the CLI record gains it. A difference that comes
    // from the GUI record's legacy shape closes when that path retires.

    private static func kraken2Record(
        _ fact: String, _ counts: [ClassifierParityCase: Int], _ reason: String, closedBy: String = retire
    ) -> ClassifierParityKnownDifference {
        pair(counts, "record Project.lungfish/Analyses/*/.lungfish-provenance.json: \(fact)", reason, closedBy: closedBy)
    }

    private static let kraken2Records: [ClassifierParityKnownDifference] = [
        kraken2Record("workflowName", oneInEachKraken2Record, "The pipeline's record (Metagenomics Classification or Profiling) against the lungfish.classify record the CLI writes in its place (BIO inventory 1.1). E15 keeps lungfish.classify on the CLI side"),
        kraken2Record("toolName", oneInEachKraken2Record, "The GUI record takes its run-level tool from its first step, the replay copy or the single-read mate staging, and the CLI record from kraken2"),
        kraken2Record("toolVersion", oneInEachKraken2Record, "As toolName, the LGE version of the copy step against kraken2's version"),
        kraken2Record("argv", oneInEachKraken2Record, "As toolName, the copy step's /bin/sh -c script against the CLI command (E11)"),
        kraken2Record("reproducibleCommand", oneInEachKraken2Record, "As argv"),
        kraken2Record("explicitOptions.*", [.k1: 16, .k2: 20, .k3: 39, .k4: 19], "The CLI record drops the pipeline's options, the database identity among them, and with them the readSetPlan of a merge bundle (D6, E13)",
                      closedBy: "A8 (E13)"),
        kraken2Record("legacyRunParameters.*", [.k1: 16, .k2: 20, .k3: 39, .k4: 19], "As explicitOptions"),
        kraken2Record("defaultOptions.*", [.k1: 6, .k2: 6, .k3: 12, .k4: 6], "The pipeline's defaults (confidence 0, read format unpaired) against the CLI's preset defaults (D7, D8, E12)",
                      closedBy: "A8 (E12)"),
        kraken2Record("resolvedDefaultOptions.*", [.k1: 5, .k2: 5, .k3: 10, .k4: 5], "The CLI record drops the database identity status, its core file sizes and the effective memory mapping (E9)",
                      closedBy: "A8 (E9)"),
        kraken2Record("files[*", [.k1: 4, .k2: 2, .k3: 7, .k4: 5], "D4. The GUI record names the scratch input and the replay copy, the CLI record the kept materialized input"),
        kraken2Record("outputs[*", [.k1: 2, .k2: 1, .k3: 3, .k4: 2], "The GUI record lists classification-result.json and the replay copy as outputs, the CLI record does not"),
        kraken2Record("output.*", [.k1: 2, .k2: 2, .k3: 4, .k4: 2], "The run's output is classification-result.json in the GUI record and the kreport in the CLI record"),
        kraken2Record("steps[*", [.k1: 7, .k2: 4, .k3: 11, .k4: 7], "D4. The GUI's copy or staging step against the CLI's fastq materialize step, so kraken2 reads another path and depends on another step"),
        kraken2Record("canonicalRunSteps[*", [.k1: 4, .k2: 4, .k3: 8, .k4: 4], "As steps"),
        kraken2Record("legacyRunSteps[*", [.k1: 4, .k2: 4, .k3: 8, .k4: 4], "As steps"),
    ]

    private static func esVirituRecord(
        _ fact: String, _ count: Int, _ reason: String, closedBy: String = retire
    ) -> ClassifierParityKnownDifference {
        pair([.e1: count], "record Project.lungfish/Analyses/*/.lungfish-provenance.json: \(fact)", reason, closedBy: closedBy)
    }

    private static func esVirituRecord(
        _ fact: String, _ counts: [ClassifierParityCase: Int], _ reason: String, closedBy: String = retire
    ) -> ClassifierParityKnownDifference {
        pair(counts, "record Project.lungfish/Analyses/*/.lungfish-provenance.json: \(fact)", reason, closedBy: closedBy)
    }

    private static let esVirituRecords: [ClassifierParityKnownDifference] = [
        esVirituRecord("argv", [.e1: 1, .e2: 1], "The replayed command runs through the analysis run executor, whose root record names the lungfish-cli command that ran (E1, E15), where the pipeline's record took EsViritu's argv. EsViritu's argv stays on its step, which in E1 also names the GUI's deleted scratch file (D4, D5)"),
        esVirituRecord("reproducibleCommand", [.e1: 1, .e2: 1], "As argv"),
        esVirituRecord("workflowName", [.e1: 1, .e2: 1], "As argv. The executor's root record, lungfish.esviritu.detect, replaces the pipeline's Viral Metagenomics Detection record in the plain --output folder (E2)"),
        esVirituRecord("toolName", [.e1: 1, .e2: 1], "As workflowName. The root record's tool is lungfish-cli, and EsViritu stays the tool of its step"),
        esVirituRecord("toolVersion", [.e1: 1, .e2: 1], "As toolName. The LGE version of lungfish-cli against EsViritu 1.3.3, which the EsViritu step still records"),
        esVirituRecord("output.*", [.e1: 2, .e2: 2], "The executor's run output is its first output, the detection table, where the pipeline's record names esviritu-result.json. Both stay in outputs with their digests"),
        esVirituRecord("explicitOptions.*", 5, "The GUI scans the input's read layout and puts the format it chose in the row's command (--read-format unpaired), so the replay scans nothing and records no scan. Both sides record the format"),
        esVirituRecord("legacyRunParameters.*", 5, "As explicitOptions"),
        esVirituRecord("files[*", 1, "D5. The GUI record names the deleted scratch input"),
        esVirituRecord("steps[*", 3, "As argv, in the EsViritu step and its log"),
        esVirituRecord("canonicalRunSteps[*", 1, "As argv"),
        esVirituRecord("legacyRunSteps[*", 1, "As argv"),
    ]

    // MARK: Fixed facts

    private static let facts: [ClassifierParityKnownDifference] = [
        ClassifierParityKnownDifference(
            counts: [.k2: 1, .k3: 1], scope: .side(.b),
            id: "fact: merge records its readSetPlan of 23 pairs and 77 merged reads",
            reason: "D6. The CLI record drops the pipeline's readSetPlan, so the 23 pairs and 77 merged reads are not in it",
            closedBy: "A8 (E13)"
        ),
        ClassifierParityKnownDifference(
            counts: [.k5: 1], scope: .side(.b),
            id: "fact: the run completes",
            reason: "As on side A, the replay throws Empty Kraken2 report. After BR's parser fix the replay still exits 64 with a failed record (F2 bio ruling 1)",
            closedBy: "A8, whose classify exits 0 with status completed on a degraded profile (A8 M0, E4)"
        ),
    ]

    // MARK: Named files

    /// Files the records of one side name that are gone or hold another digest (review F2
    /// fix 5). Side C must hold this fact with nothing declared.
    private static func namedFile(
        _ side: ClassifierParitySide, _ counts: [ClassifierParityCase: Int], _ file: String, _ reason: String, closedBy: String
    ) -> ClassifierParityKnownDifference {
        ClassifierParityKnownDifference(counts: counts, scope: .side(side), id: "fact: record * names \(file)", reason: reason, closedBy: closedBy)
    }

    /// The per-read output and the empty mate come from the shared ClassificationPipeline.
    private static let sharedPipeline = "A8 under E3, the owner review F2 proposes until the manager names another. The cause is in the shared ClassificationPipeline, so its fix moves A and B together"

    private static let namedFiles: [ClassifierParityKnownDifference] = [
        namedFile(.a, [.k1: 1, .k3: 2, .k4: 1, .e1: 2, .e3: 2], "<project>/.tmp/* that does not exist",
                  "D4, D5. The GUI's materialized scratch input, which it deletes after the run", closedBy: retire),
        namedFile(.a, [.k1: 1, .k2: 1, .k3: 4, .k4: 1], "*classification.kraken that does not exist",
                  "ClassificationPipeline gzips the per-read output to classification.kraken.gz and deletes it, and no step records the compression",
                  closedBy: sharedPipeline),
        namedFile(.b, [.k1: 1, .k2: 1, .k3: 2, .k4: 1], "*classification.kraken that does not exist",
                  "As on side A", closedBy: sharedPipeline),
        namedFile(.a, [.k2: 1, .k3: 2], "*.lungfish-classify-inputs/merged.emptymate.fastq that does not exist",
                  "ClassificationPipeline stages an empty mate for the merged reads and removes it after the run, where E3 keeps staged inputs",
                  closedBy: sharedPipeline),
        namedFile(.b, [.k2: 1, .k3: 1], "*.lungfish-classify-inputs/merged.emptymate.fastq that does not exist",
                  "As on side A", closedBy: sharedPipeline),
        namedFile(.a, [.e1: 6, .e2: 6, .e3: 20], "*/*_temp/*.third.filt.sorted.bam* that does not exist",
                  "The GUI's build-db esviritu moves the BAM and its index to bams/, and the records still name them in _temp/",
                  closedBy: "A7, whose BAM move is a recorded step (E7)"),
        namedFile(.a, [.e1: 3, .e2: 3, .e3: 10], "*/bams/*.third.filt.sorted.bam with another digest",
                  "The BAM that build-db esviritu moved to bams/ holds another digest than the records state",
                  closedBy: "A7, whose BAM move is a recorded step (E7)"),
    ]

    /// One line per found difference that no entry declares, and per entry that matches another
    /// number of found differences than its count for `parityCase` in `scope`, listing the
    /// differences it matches.
    static func failures(
        found: [ClassifierParityDifference],
        parityCase: ClassifierParityCase,
        scope: ClassifierParityScope
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
