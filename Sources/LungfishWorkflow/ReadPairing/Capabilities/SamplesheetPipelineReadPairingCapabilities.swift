// SamplesheetPipelineReadPairingCapabilities.swift - EsViritu, TaxTriage, Viral Recon and genotyping inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadPairingCapabilityRegistry {
    static var samplesheetPipelineCapabilities: [ReadPairingCapabilityDeclaration] {
        let allSingleWhenMixed = "A sample that mixes merged reads and pairs runs with every read single-end, the result states that, and no read is dropped."
        return [
            ReadPairingCapabilityDeclaration(
                consumerID: "classify.esviritu",
                capability: .pairsOnlyWhenAllPaired,
                rationale: "EsViritu runs a sample paired or unpaired, never both. \(allSingleWhenMixed)",
                adopted: true
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "classify.taxtriage",
                capability: .pairsOnlyWhenAllPaired,
                rationale: "TaxTriage reads pairs only as samplesheet fastq_1 and fastq_2. \(allSingleWhenMixed)"
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "viralrecon.illumina",
                capability: .pairsOnlyWhenAllPaired,
                rationale: "viralrecon reads pairs only as samplesheet fastq_1 and fastq_2. \(allSingleWhenMixed)"
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "genotype.illumina-mhc",
                capability: .bothInOneRunAsNameInterleavedStream,
                rationale: "IlluminaAmpliconPairMerger partitions one stream by fragment name, merges the pairs with bbmerge and passes the merged reads through."
            ),
            ReadPairingCapabilityDeclaration(
                consumerID: "genotype.ont-mhc",
                capability: .singleReadsOnly,
                rationale: "Oxford Nanopore amplicons are long reads, mapped each on its own."
            ),
        ]
    }
}
