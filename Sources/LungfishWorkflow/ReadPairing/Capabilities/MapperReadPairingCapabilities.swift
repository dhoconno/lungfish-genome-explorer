// MapperReadPairingCapabilities.swift - The short-read mappers' read-pairing capabilities
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadPairingCapabilityRegistry {
    static var mapperCapabilities: [ReadPairingCapabilityDeclaration] {
        [
            ReadPairingCapabilityDeclaration(
                consumerID: "map.minimap2",
                capability: .bothInOneRunAsNameInterleavedStream,
                rationale: "The short-read preset pairs adjacent records of one name and maps the rest as single reads, so a sample's pairs and single reads go in one stream. The long-read presets never pair.",
                adopted: true
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "map.bwa-mem2",
                capability: .bothInOneRunAsNameInterleavedStream,
                rationale: "With -p bwa-mem2 pairs adjacent records of one name and maps the rest as single reads, so a sample's pairs and single reads go in one stream.",
                adopted: true
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "map.bowtie2",
                capability: .bothInOneRunAsSeparateFiles,
                rationale: "bowtie2 takes -1 R1 -2 R2 and -U for single reads in one run.",
                adopted: true
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "map.bbmap",
                capability: .pairsOrSinglesPerRun,
                rationale: "BBMap takes one kind of read per run, so pairs and single reads map in two runs and samtools merge joins the sorted BAMs.",
                adopted: true
            ),
        ]
    }
}
