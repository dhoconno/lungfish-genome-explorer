// PlanReadPairs.swift - The pairs of read files a plan declares, which the executor checks for mate names before any step (FIX-ROUTES-5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The R1 and R2 files a plan declares, as the plan's relative paths (BIO-ROUTES-4 items 1 and 2). A plan has no field for
/// its layout, so it is read from the two places a plan records it:
///
/// - A read import plan lists a sample's reads as R1, R2 and then the file an SRA download names after the run alone, in
///   that order (`ImportFastqPlanOptions.swift:330`, `SamplePair.inputFiles`), so its pair is its first two `input`
///   entries whatever their number. A plan whose merged-to-mixed step, an `interleave` step with no argv
///   (`PlanRunner+Storage.swift:50-57`), reads its three `input` entries lists them as the merged reads, R1 and R2, so
///   its pair is the second and third entry, and the merged reads are never read as a mate.
/// - An RNA-seq plan names each pair `inputs/pair<n>_R1<suffix>` and `inputs/pair<n>_R2<suffix>`
///   (`SalmonPlan+Inputs.swift:57-58`) and each single read `inputs/single<n><suffix>`, so a pair is the two entries that
///   share `<n>`, in the order of `<n>`.
package enum PlanReadPairs {
    package struct Pair: Equatable, Sendable {
        package var r1: String
        package var r2: String

        package init(r1: String, r2: String) {
            self.r1 = r1
            self.r2 = r2
        }
    }

    /// The directory and name start of an RNA-seq plan's pair file (`SalmonPlan+Inputs.swift:57-58`) and of its single read (`:61`).
    private static let pairPrefix = "inputs/pair"
    private static let singlePrefix = "inputs/single"

    /// The pairs `entries` and `steps` declare, none for a plan of one read.
    package static func declared(entries: [PlanEntry], steps: [PlanStep]) -> [Pair] {
        let inputs = entries.filter { $0.role == .input }.map(\.relativePath)
        // An RNA-seq frame names every read `inputs/pair<n>_R<m>...` or `inputs/single<n>...`. Its pairs are the named ones,
        // and single reads, the runs or lanes of a single-end sample, have no mate, so no two of them are read as a pair.
        if inputs.contains(where: { $0.hasPrefix(pairPrefix) || $0.hasPrefix(singlePrefix) }) { return rnaSeqPairs(in: inputs) }
        guard inputs.count >= 2 else { return [] }
        let mergedFirst = inputs.count == 3 && steps.contains {
            $0.kind == .interleave && $0.arguments.isEmpty && $0.inputs == inputs
        }
        return mergedFirst ? [Pair(r1: inputs[1], r2: inputs[2])] : [Pair(r1: inputs[0], r2: inputs[1])]
    }

    /// Each `inputs/pair<n>_R1…` with the `inputs/pair<n>_R2…` of the same `<n>`, in the order of `<n>`.
    private static func rnaSeqPairs(in inputs: [String]) -> [Pair] {
        var firsts: [Int: String] = [:]
        var seconds: [Int: String] = [:]
        for path in inputs where path.hasPrefix(pairPrefix) {
            let rest = path.dropFirst(pairPrefix.count)
            let digits = rest.prefix { $0 >= "0" && $0 <= "9" }
            guard let number = Int(digits) else { continue }
            let mate = rest.dropFirst(digits.count)
            if mate.hasPrefix("_R1") {
                firsts[number] = path
            } else if mate.hasPrefix("_R2") {
                seconds[number] = path
            }
        }
        return firsts.keys.sorted().compactMap { number in
            seconds[number].map { Pair(r1: firsts[number] ?? "", r2: $0) }
        }
    }
}
