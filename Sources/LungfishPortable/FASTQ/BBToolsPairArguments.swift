// BBToolsPairArguments.swift - The reformat.sh argv that joins two mate files and splits one file back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The `reformat.sh` argv of a pair conversion, shared by every site that interleaves two mate files or splits an
/// interleaved file (row BBTOOLS-QIN). One builder gives every site the same flags, and a test reaches it without the
/// app. The layout is always stated, so BBTools' own name detection cannot pair a file by position.
package enum BBToolsPairArguments {
    /// R1 and R2 files into one interleaved file.
    package static func interleave(r1: String, r2: String, output: String) -> [String] {
        [
            "in1=\(r1)",
            "in2=\(r2)",
            "out=\(output)",
            "interleaved=t",
        ] + BBToolsQualityArguments.keepEveryScore
    }

    /// One interleaved file into R1 and R2 files. `verifyNames` adds `vint=t`, so the tool stops at two records whose
    /// names it does not read as mates. Every site runs this through ``runDeinterleave(input:out1:out2:launcher:isolation:run:failureWords:)``.
    package static func deinterleave(input: String, out1: String, out2: String, verifyNames: Bool = true) -> [String] {
        [
            "in=\(input)",
            "out1=\(out1)",
            "out2=\(out2)",
            "interleaved=t",
        ] + (verifyNames ? ["vint=t"] : []) + BBToolsQualityArguments.keepEveryScore
    }

    /// What `reformat.sh` says when `vint=t` stops it, the line above its Java stack (measured on bbmap 40.02).
    private static let namesRefusal = "Names are not paired"

    /// Splits an interleaved file with `reformat.sh`. LGE's own name check decides, and `vint=t` holds only where it
    /// agrees.
    ///
    /// `vint=t` reads `/1` `/2`, Casava comments and identical names as mates, and refuses `SRR123.1.1` and
    /// `SRR123.1.2` and `read_1` and `read_2` (measured). So a refusal is not the answer. On one, LGE's check reads every
    /// name. A false pair throws its `mateNameMismatch` words, never the tool's stack, and a true pair runs once more
    /// without `vint=t`.
    ///
    /// A failed run leaves no partial output. An output that was there before the run and that the tool did not touch
    /// stays. The arguments returned are those of the run that made the outcome.
    package static func runDeinterleave<Outcome>(
        input: String,
        out1: String,
        out2: String,
        launcher: any PortableChildLauncher,
        isolation: isolated (any Actor)? = #isolation,
        run: ([String]) async throws -> Outcome,
        failureWords: (Outcome) -> String?
    ) async throws -> (outcome: Outcome, arguments: [String]) {
        let fm = FileManager.default
        func stamp(_ path: String) -> String? {
            guard let attributes = try? fm.attributesOfItem(atPath: path) else { return nil }
            return "\(attributes[.size] ?? 0) \(attributes[.modificationDate] ?? 0)"
        }
        let before = [out1, out2].map { (path: $0, stamp: stamp($0)) }
        func removeWhatTheRunWrote() {
            for output in before where stamp(output.path) != output.stamp {
                try? fm.removeItem(atPath: output.path)
            }
        }
        do {
            let arguments = deinterleave(input: input, out1: out1, out2: out2)
            let outcome = try await run(arguments)
            guard let words = failureWords(outcome) else { return (outcome, arguments) }
            removeWhatTheRunWrote()
            guard words.contains(namesRefusal) else { return (outcome, arguments) }
            try await PortableStorageChecks.detachedWork {
                try FASTQPairInterleaver.verifyMates(interleaved: URL(fileURLWithPath: input), launcher: launcher)
            }
            let unchecked = deinterleave(input: input, out1: out1, out2: out2, verifyNames: false)
            let second = try await run(unchecked)
            if failureWords(second) != nil { removeWhatTheRunWrote() }
            return (second, unchecked)
        } catch {
            removeWhatTheRunWrote()
            throw error
        }
    }
}
