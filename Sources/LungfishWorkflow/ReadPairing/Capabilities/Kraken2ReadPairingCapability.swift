// Kraken2ReadPairingCapability.swift - Kraken2's read-pairing capability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadPairingCapabilityRegistry {
    static var kraken2Capabilities: [ReadPairingCapabilityDeclaration] {
        [
            ReadPairingCapabilityDeclaration(
                consumerID: "classify.kraken2",
                capability: .bothInOneRunAsSeparateFiles,
                rationale: "One kraken2 run classifies pairs with --paired and single reads as single reads. A header-only mate file is staged beside each single-read file, so kraken2 reads it as a pair whose second mate is empty, which gives each single read the call of a single-end run."
            ),
        ]
    }
}
