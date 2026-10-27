// BBToolsStepArguments.swift - The BBTools argv of the import recipe, merge and genotyping steps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {
    /// The `bbmerge.sh` argv of a recipe merge step.
    static func mergeArguments(
        input: URL,
        merged: URL,
        unmerged: URL,
        minOverlap: Int,
        threads: Int,
        interleaved: Bool,
        strict: Bool
    ) -> [String] {
        var args = [
            "in=\(input.path)",
            "out=\(merged.path)",
            "outu=\(unmerged.path)",
            "minoverlap=\(minOverlap)",
            "threads=\(threads)",
            // bbmerge only pairs identically named mates when told to.
            interleaved ? "interleaved=t" : "interleaved=f",
        ]
        if strict { args.append("strict=t") }
        return args
    }

    /// The `bbduk.sh` argv of a recipe length filter on an interleaved file, which keeps both mates of a pair or none.
    static func interleavedLengthFilterArguments(
        input: URL,
        output: URL,
        minLength: Int?,
        maxLength: Int?,
        threads: Int
    ) -> [String] {
        var args = ["in=\(input.path)", "out=\(output.path)"]
        if let minLength { args.append("minlen=\(minLength)") }
        if let maxLength { args.append("maxlen=\(maxLength)") }
        args.append("interleaved=t")
        args.append("threads=\(threads)")
        return args
    }
}

extension IlluminaAmpliconPairMerger {
    /// The `bbmerge.sh` argv that merges the pairs of an amplicon input before mapping.
    static func bbmergeArguments(input: URL, merged: URL, unmerged: URL, threads: Int) -> [String] {
        [
            "in=\(input.path)",
            "out=\(merged.path)",
            "outu=\(unmerged.path)",
            "interleaved=t",
            "threads=\(max(1, threads))",
        ]
    }
}

extension FullLengthONTMHCGenotypingPipeline {
    /// The `bbduk.sh` argv that trims one primer off the reads of a full-length ONT sample. `ktrim` is `l` for the
    /// forward primer and `r` for the reverse primer.
    static func primerTrimArguments(input: URL, output: URL, primers: URL, ktrim: String) -> [String] {
        [
            "in=\(input.path)",
            "out=\(output.path)",
            "ref=\(primers.path)",
            "k=15",
            "mink=11",
            "hdist=1",
            "ktrim=\(ktrim)",
            "rcomp=t",
            "threads=1",
        ]
    }

    /// The `reformat.sh` argv that keeps the reads of a full-length ONT sample inside the length window.
    static func lengthFilterArguments(input: URL, output: URL, minimumLength: Int, maximumLength: Int) -> [String] {
        [
            "in=\(input.path)",
            "out=\(output.path)",
            "minlength=\(minimumLength)",
            "maxlength=\(maximumLength)",
            "threads=1",
        ]
    }
}
