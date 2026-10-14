// ClassifierParityKnownDifferences+RouteC.swift - The facts the command's runs do not hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane F3, panel decisions T2, E10 and E15. Side C runs each case through the GUI route over
// `lungfish-cli`, and side C' runs the command side C's row recorded. Both run the same command, so
// a fixed fact one of them does not hold is declared for both, and C against C' declares nothing.
// The entries of side A against side C that stood here went with side A in Phase 2.9 (E14, QA Q12).
//
// The counts come from a run of the class with `LUNGFISH_PARITY_DUMP` set, as every count in this
// list does.

import Foundation

extension ClassifierParityKnownDifferences {
    /// A fixed fact the command's run does not hold, on side C and on side C'.
    private static func commandFact(
        _ counts: [ClassifierParityCase: Int], _ id: String, _ reason: String, closedBy: String
    ) -> [ClassifierParityKnownDifference] {
        [ClassifierParitySide.c, .cPrime].map {
            ClassifierParityKnownDifference(counts: counts, scope: .side($0), id: id, reason: reason, closedBy: closedBy)
        }
    }

    // MARK: Facts of the command's runs

    /// Review F2 fix 5 asked side C to hold the named-file fact with nothing declared. These are
    /// defects of the code the route shares with the command, so they show on side C and side C'.
    static let commandFacts: [ClassifierParityKnownDifference] = [
        commandFact([.e1: 2, .e2: 2, .e3: 4], "fact: record * names */bams/*.third.filt.sorted.bam* with another digest",
            "The batch root names the BAM and its index as the run's outputs with their digests from before the markdup. The records build-db esviritu writes name them as the run left them since 2.10 A39 M2",
            closedBy: bamRunLevel),
    ].flatMap { $0 }
}
