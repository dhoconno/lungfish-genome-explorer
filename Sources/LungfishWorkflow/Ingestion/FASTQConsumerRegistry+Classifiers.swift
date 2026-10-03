// FASTQConsumerRegistry+Classifiers.swift - The classifiers' read-layout declarations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQConsumerRegistry {

    // MARK: - Classifiers

    static var classifierDeclarations: [FASTQConsumerDeclaration] {
        [
            FASTQConsumerDeclaration(
                consumerID: "classify.kraken2",
                displayName: "Kraken2",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .splitToR1R2,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "kraken2 has no interleaved mode. ClassificationPipeline splits a strictly interleaved file with FASTQPairInterleaver.deinterleave and runs --paired; a mixed file runs unpaired (ClassificationConfig.ReadFormat.forSingleFile)."
            ),
            FASTQConsumerDeclaration(
                consumerID: "classify.esviritu",
                displayName: "EsViritu",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "fastp --interleaved_in pairs by position, so EsVirituConfig runs a mixed file as -p unpaired and EsVirituPipeline re-verifies the file it runs on."
            ),
            FASTQConsumerDeclaration(
                consumerID: "classify.taxtriage",
                displayName: "TaxTriage",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .splitToR1R2,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "TaxTriage reads pairs only as samplesheet fastq_1/fastq_2. TaxTriagePipeline resolves a single Illumina file's layout through FASTQInputLayoutResolver, splits a strictly interleaved file with ClassificationPipeline.splitInterleavedInput (FASTQPairInterleaver.deinterleave), and writes both halves in the samplesheet; a mixed file stays a single-end row because a positional split would mis-pair it."
            ),
        ]
    }
}
