// FastqBBToolsArguments.swift - The BBTools argv of the fastq subcommands that build it inline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FastqSequenceFilterSubcommand {
    /// The `bbduk.sh` argv of one sequence filter run. `literal` wins over `referenceURL`, as the options do.
    static func bbdukArguments(
        inputURL: URL,
        outputPath: String,
        keepMatched: Bool,
        interleaved: Bool,
        literal: String?,
        referenceURL: URL?,
        minOverlap: Int,
        errorRate: Double,
        searchReverseComplement: Bool,
        searchEnd: String
    ) -> [String] {
        var args: [String] = ["in=\(inputURL.path)"]

        if keepMatched {
            args.append("outm=\(outputPath)")
        } else {
            args.append("out=\(outputPath)")
        }
        // Pair-aware: a pair counts as matched when either mate matches
        // (bbduk's default removeifeitherbad=t), so `outm=` receives both
        // mates and `out=` drops both. Nothing is ever split. interleaved=f
        // is stated for the single-read case so bbduk's own name detection
        // cannot pair a mixed file by position.
        args.append(interleaved ? "interleaved=t" : "interleaved=f")

        if let literal {
            args.append("literal=\(literal)")
        } else if let referenceURL {
            args.append("ref=\(referenceURL.path)")
        }

        args.append("k=\(minOverlap)")
        args.append("hdist=0")
        args.append("edist=\(max(1, Int((errorRate * Double(minOverlap)).rounded())))")

        if searchReverseComplement {
            args.append("rcomp=t")
        }

        switch searchEnd {
        case "left":
            args.append("restrictleft=\(minOverlap * 3)")
        case "right":
            args.append("restrictright=\(minOverlap * 3)")
        default:
            break
        }
        return args
    }
}

extension FastqMergeSubcommand {
    /// The `bbmerge.sh` argv of one merge run. Only strictly interleaved pairs reach it.
    static func bbmergeArguments(input: URL, merged: URL, unmerged: URL, minOverlap: Int, strict: Bool) -> [String] {
        var args = [
            "in=\(input.path)",
            "out=\(merged.path)",
            "outu=\(unmerged.path)",
            "minoverlap=\(minOverlap)",
            "interleaved=t",
        ]
        if strict { args.append("strict=t") }
        return args
    }
}

extension FastqSubsampleSubcommand {
    /// The `reformat.sh` argv that samples an interleaved file by whole pairs.
    static func reformatSampleArguments(
        input: String,
        output: String,
        proportion: Double?,
        count: Int?,
        seed: Int64
    ) -> [String] {
        var args = [
            "in=\(input)",
            "out=\(output)",
            "interleaved=t",
        ]
        if let proportion {
            args.append("samplerate=\(proportion)")
        }
        if let count {
            // With interleaved=t, reformat.sh's samplereadstarget counts
            // output PAIRS. --count is a read count (the dialog says
            // "Keep a fixed number of reads"), so ask for count/2 pairs.
            args.append("samplereadstarget=\(Self.interleavedPairTarget(forReadCount: count))")
        }
        args.append("sampleseed=\(seed)")
        return args
    }
}

extension FastqRepairSubcommand {
    /// The `repair.sh` argv that pairs the reads of a file and sets the reads without a mate aside.
    static func repairArguments(input: URL, repaired: URL, singletons: URL) -> [String] {
        [
            "in=\(input.path)",
            "out=\(repaired.path)",
            "outs=\(singletons.path)",
        ]
    }
}

extension FastqErrorCorrectSubcommand {
    /// The `tadpole.sh` argv of one error correction run.
    static func tadpoleArguments(input: URL, output: String, kmerSize: Int) -> [String] {
        [
            "in=\(input.path)",
            "out=\(output)",
            "mode=correct",
            "ecc=t",
            "k=\(kmerSize)",
            // Per record, as FASTQConsumerRegistry declares. Left to guess,
            // tadpole pairs /1 /2 names by position and aborts on an odd
            // record count.
            "interleaved=f",
            // In input order. tadpole drops no read, but it wrote its chunks
            // of reads as its threads finished them, so a pair that
            // straddled two chunks of a file mixing pairs with single reads
            // lost its adjacency (final review A, N7). The records written
            // are the same either way.
            "ordered=t",
        ]
    }
}
