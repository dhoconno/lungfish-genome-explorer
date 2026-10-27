// FASTQDerivativeService+BBToolsArguments.swift - The BBTools argv of the derivative dedupe and merge steps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

extension FASTQDerivativeService {
    /// The `clumpify.sh` argv of a recipe dedupe step on one file, interleaved or not.
    static func dedupeArguments(
        input: URL,
        output: URL,
        heapGB: Int,
        substitutions: Int,
        interleaved: Bool,
        optical: Bool,
        opticalDistance: Int
    ) -> [String] {
        var args = [
            "in=\(input.path)",
            "out=\(output.path)",
            "-Xmx\(heapGB)g",
            "dedupe=t",
            "subs=\(substitutions)",
            "ow=t",
        ]
        if interleaved { args.append("interleaved=t") }
        if optical {
            args.append("optical=t")
            args.append("dupedist=\(opticalDistance)")
        }
        args += BBToolsQualityArguments.keepEveryScore
        return args
    }

    /// The `bbmerge.sh` argv of a recipe merge step.
    static func mergeArguments(
        source: URL,
        merged: URL,
        unmerged: URL,
        minOverlap: Int,
        interleaved: Bool,
        strict: Bool
    ) -> [String] {
        var args = [
            "in=\(source.path)",
            "out=\(merged.path)",
            "outu=\(unmerged.path)",
            "minoverlap=\(minOverlap)",
            // Stated, not guessed: bbmerge's own detection does not pair
            // identically named mates (SRA dumps), and on /1 /2 names it
            // pairs by position and drops the last read of an odd count.
            interleaved ? "interleaved=t" : "interleaved=f",
        ]
        if strict { args.append("strict=t") }
        args += BBToolsQualityArguments.readAndWrite
        return args
    }
}
