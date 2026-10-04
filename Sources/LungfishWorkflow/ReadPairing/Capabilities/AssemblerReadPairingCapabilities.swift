// AssemblerReadPairingCapabilities.swift - The assemblers' read-pairing capabilities
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadPairingCapabilityRegistry {
    static var assemblerCapabilities: [ReadPairingCapabilityDeclaration] {
        [
            ReadPairingCapabilityDeclaration(
                consumerID: "assemble.spades",
                capability: .bothInOneRunAsSeparateFiles,
                rationale: "SPAdes takes -1 R1 -2 R2, --merged for merged reads and -s for other single reads in one run.",
                adopted: true
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "assemble.megahit",
                capability: .bothInOneRunAsSeparateFiles,
                rationale: "MEGAHIT takes -1 R1 -2 R2 and -r for single reads in one run.",
                adopted: true
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "assemble.skesa",
                capability: .bothInOneRunAsSeparateFiles,
                rationale: "SKESA takes --reads R1,R2 for pairs and one more --reads per single-read file in one run.",
                adopted: true
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "assemble.flye",
                capability: .singleReadsOnly,
                rationale: "Flye assembles long reads, each read on its own."
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "assemble.hifiasm",
                capability: .singleReadsOnly,
                rationale: "hifiasm assembles long reads, each read on its own."
            ),
        ]
    }
}
