// FASTQOperationReadPairingCapabilities.swift - The FASTQ operations' read-pairing capabilities
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadPairingCapabilityRegistry {
    static var fastqOperationCapabilities: [ReadPairingCapabilityDeclaration] {
        let byName = "pairs adjacent records by fragment name and keeps the other reads single, so a sample's pairs and single reads go in one stream."
        let positional = "pairs records by position, so it pairs a sample only when every fragment is a pair and runs a mixed sample as single reads."
        let perRecord = "treats every record on its own."

        let streamTools: [(String, String)] = [
            ("fastq.trim", "fastp through FastpPairedRunner"),
            ("fastq.quality-trim", "fastp through FastpPairedRunner"),
            ("fastq.adapter-trim", "fastp through FastpPairedRunner"),
            ("fastq.fixed-trim", "fastp through FastpPairedRunner"),
            ("fastq.merge", "fastq merge"),
            ("fastq.repair", "BBTools repair"),
            ("fastq.deinterleave", "fastq deinterleave"),
            ("fastq.search-text", "fastq search-text"),
            ("fastq.search-motif", "fastq search-motif"),
            ("ingest.clumpify", "The import clumpify step"),
            ("fastq.deduplicate", "clumpify dedupe through FASTQSplitByNameRunner"),
            ("fastq.primer-remove", "Primer removal through FASTQSplitByNameRunner"),
        ]
        let positionalTools: [(String, String)] = [
            ("fastq.subsample", "reformat interleaved=t"),
            ("fastq.contaminant-filter", "bbduk interleaved=t"),
            ("fastq.entropy-filter", "bbduk interleaved=t"),
            ("fastq.sequence-filter", "bbduk interleaved=t"),
            ("fastq.scrub-human", "The deacon R1 and R2 split"),
            ("fastq.deacon-ribo", "The deacon R1 and R2 split"),
            ("fastq.ribodetector", "ribodetector_cpu -i R1 R2"),
            ("fastq.interleave", "fastq interleave"),
            ("recipe.convert-interleaved-to-paired", "The recipe interleaved-to-paired step"),
        ]
        let perRecordTools: [(String, String)] = [
            ("fastq.length-filter", "seqkit seq"),
            ("fastq.error-correct", "tadpole"),
        ]

        return streamTools.map {
            ReadPairingCapabilityDeclaration(consumerID: $0.0, capability: .bothInOneRunAsNameInterleavedStream, rationale: "\($0.1) \(byName)")
        } + positionalTools.map {
            ReadPairingCapabilityDeclaration(consumerID: $0.0, capability: .pairsOnlyWhenAllPaired, rationale: "\($0.1) \(positional)")
        } + perRecordTools.map {
            ReadPairingCapabilityDeclaration(consumerID: $0.0, capability: .singleReadsOnly, rationale: "\($0.1) \(perRecord)")
        }
    }
}
