// TwelveSReadPairingCapability.swift - 12S amplicon matching's read-pairing capability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadPairingCapabilityRegistry {
    static var twelveSCapabilities: [ReadPairingCapabilityDeclaration] {
        [
            ReadPairingCapabilityDeclaration(
                consumerID: "twelve-s.amplicon-matching",
                capability: .bothInOneRunAsSeparateFiles,
                rationale: "12S matching reads a sample's fragments itself and counts each once. A merged read is one fragment. An unmerged pair is one fragment when both mates give the identical call, R2 read as its reverse complement, and a pair whose mates disagree is left out of every count and tallied. A mixed stream reaches it split by name, as for Kraken2.",
                adopted: true
            ),
        ]
    }
}
