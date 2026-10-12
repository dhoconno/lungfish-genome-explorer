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
        commandFact([.e1: 6, .e2: 6, .e3: 20], "fact: record * names *_temp/*.third.filt.sorted.bam* that does not exist",
            "build-db esviritu writes its record and the sidecars of esviritu.sqlite, the BAM and its index after the move and the markdup, and their run level still names the BAM and its index in _temp/. A removal step accounts for step facts, never the run level (P1, BIO checklist 2)",
            closedBy: bamRunLevel),
        commandFact([.e1: 5, .e2: 5, .e3: 14], "fact: record * names */bams/*.third.filt.sorted.bam* with another digest",
            "The same records name the BAM in bams/ at their run level with its digest from before the markdup, and the batch root names the BAM and its index as the run's outputs with their digests from before the markdup",
            closedBy: bamRunLevel),
    ].flatMap { $0 }
}
