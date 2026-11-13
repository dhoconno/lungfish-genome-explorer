// FASTQBatchImporter+AdapterTrimArguments.swift - The fastp argv of a legacy recipe's adapter trim on one file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {
    /// The fastp argv of a legacy recipe's adapter trim on one file, interleaved or single reads.
    ///
    /// An interleaved file keeps the argv it always had, and adds the step's adapters only when the step names them:
    /// fastp trims its pairs by overlap and guesses nothing there, which was measured order-free (ruling BIO-PROBES-E,
    /// item 10). Single reads pass the step's adapter when it names one. When it names none they pass TruSeq Read 1
    /// and the bundled known adapters (``FastpPairedRunner/SingleReadAdapters``), because fastp's single-end guess
    /// changed with the order of the reads (ruling BIO-PROBES-E, items 2 and 3).
    static func legacyAdapterTrimArguments(
        input: URL,
        output: URL,
        r2Output: URL,
        threads: Int,
        interleaved: Bool,
        adapterSequence: String?,
        adapterSequenceR2: String?
    ) throws -> [String] {
        var args = ["-i", input.path, "-o", output.path,
                    "-w", String(threads), "--json", "/dev/null", "--html", "/dev/null"]
        if interleaved {
            args += ["--interleaved_in"]
            args += ["-O", r2Output.path]
            if let adapterSequence { args += ["--adapter_sequence", adapterSequence] }
            if let adapterSequenceR2 { args += ["--adapter_sequence_r2", adapterSequenceR2] }
        } else if let adapterSequence {
            args += ["--adapter_sequence", adapterSequence]
        } else {
            args += try FastpPairedRunner.SingleReadAdapters.bundled().arguments
        }
        return args
    }
}
