// FASTQBatchImporter+DedupeArguments.swift - The clumpify argv of a recipe's dedupe step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishPortable

extension FASTQBatchImporter {
    /// The `clumpify.sh` argv of a recipe dedupe step on separate R1 and R2 files. It pins the heap and carries
    /// ``BBToolsOutOfMemory/flag`` right after it, so a full heap ends the launch at once.
    static func pairedDedupeArguments(
        r1: URL, r2: URL, outR1: URL, outR2: URL,
        heapGB: Int, substitutions: Int, optical: Bool, opticalDistance: Int, threads: Int
    ) -> [String] {
        var args = [
            "in1=\(r1.path)", "in2=\(r2.path)",
            "out1=\(outR1.path)", "out2=\(outR2.path)",
            "-Xmx\(heapGB)g", BBToolsOutOfMemory.flag, "dedupe=t",
            "subs=\(substitutions)", "ow=t",
            "threads=\(threads)",
        ]
        if optical {
            args += ["optical=t", "dupedist=\(opticalDistance)"]
        }
        args += BBToolsQualityArguments.keepEveryScore
        return args
    }

    /// The `clumpify.sh` argv of a recipe dedupe step on one file, interleaved or not. It pins no heap, so BBTools
    /// sizes it from free memory, and it carries ``BBToolsOutOfMemory/flag`` so a full heap ends the launch at once.
    static func interleavedDedupeArguments(
        input: URL, output: URL, optical: Bool, threads: Int, interleaved: Bool
    ) -> [String] {
        [
            "in=\(input.path)",
            "out=\(output.path)",
            BBToolsOutOfMemory.flag,
            "dedupe=t",
            "optical=\(optical ? "t" : "f")",
            "threads=\(threads)",
            // Stated, not guessed: BBTools does not pair identically named mates on its own, and when it does pair
            // /1 /2 names by position an odd record count loses a read.
            interleaved ? "interleaved=t" : "interleaved=f",
        ] + BBToolsQualityArguments.keepEveryScore
    }
}
