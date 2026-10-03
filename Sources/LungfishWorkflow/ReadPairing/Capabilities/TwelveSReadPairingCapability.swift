// TwelveSReadPairingCapability.swift - 12S amplicon matching's read-pairing capability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadPairingCapabilityRegistry {
    static var twelveSCapabilities: [ReadPairingCapabilityDeclaration] {
        [
            ReadPairingCapabilityDeclaration(
                consumerID: "twelve-s.amplicon-matching",
                capability: .singleReadsOnly,
                rationale: "12S matching counts each record on its own. Counting a pair once is open for Phase 2, which also decides what a pair whose mates match different species counts as."
            ),
        ]
    }
}
