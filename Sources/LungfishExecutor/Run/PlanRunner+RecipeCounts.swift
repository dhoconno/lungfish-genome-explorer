// PlanRunner+RecipeCounts.swift - The input and output reads run --plan states for each recipe step (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

extension PlanRunner {
    /// The suffixes that mark a reads file among a recipe step's inputs and outputs. A step lists its reads first and
    /// then any database index or report (`RecipePlannedInvocation`), and neither of those carries one of these.
    static let readsFileSuffixes = [".fastq.gz", ".fq.gz", ".fastq.bgz", ".fastq", ".fq"]

    /// Sets a recipe step's input and output read counts from its files (tally K4.1, BIO fix 2 of the K4 part B
    /// review), in the units of the Mac's `RecipeEngine.countReadsForRecipeStep`. A file is counted once a run, so a
    /// step's input takes the count of the step that wrote it. A count that cannot be made stays nil, as the Mac's
    /// does, and a signal during a count ends the step as interrupted, as a signal after an argv step's end does.
    func countReads(of step: PlanStep, into record: inout ExecutorStepRecord, counted: inout [String: Int64]) {
        let launcher = ExecutorChildLauncher(
            controller: controller, decompressor: prepared.decompressor,
            allowedPrograms: Set(prepared.manifest.tools.map(\.path)), graceSeconds: prepared.plan.graceSeconds
        )
        record.inputReadCount = readCount(of: step.inputs, counted: &counted, launcher: launcher)
        record.outputReadCount = readCount(of: step.outputs, counted: &counted, launcher: launcher)
        if let signal = controller.interruptSignal {
            record.outcome = .interrupted
            record.signal = signal
            record.signalName = ExecutorSignals.name(signal)
            record.outputs = []
            record.inputReadCount = nil
            record.outputReadCount = nil
            record.reason = "The executor received \(ExecutorSignals.name(signal)) and stopped the step."
        }
    }

    /// The reads of the reads files among `paths`: the records of one file, the pairs of two (the first file's
    /// records), and every record of three, a merged layout. Nil for no reads file or more than three, or for a file
    /// that cannot be counted, such as one whose lines are not whole four-line records.
    private func readCount(
        of paths: [String], counted: inout [String: Int64], launcher: ExecutorChildLauncher
    ) -> Int64? {
        let reads = paths.filter { path in Self.readsFileSuffixes.contains { path.lowercased().hasSuffix($0) } }
        let files: ArraySlice<String>
        switch reads.count {
        case 1, 3: files = reads[...]
        case 2: files = reads.prefix(1)
        default: return nil
        }
        var total: Int64 = 0
        for path in files {
            if let known = counted[path] {
                total += known
                continue
            }
            let url = URL(fileURLWithPath: resolver.workRoot).appendingPathComponent(path)
            guard controller.interruptSignal == nil,
                  let records = try? FASTQPairInterleaver.countRecords(in: url, launcher: launcher) else { return nil }
            counted[path] = Int64(records)
            total += Int64(records)
        }
        return total
    }
}
