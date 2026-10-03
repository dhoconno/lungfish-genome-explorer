// FASTQConsumerRegistry+GenotypingAndWorkflows.swift - The genotyping, 12S and Viral Recon read-layout declarations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQConsumerRegistry {

    // MARK: - Genotyping, 12S, Viral Recon

    static var genotypingAndWorkflowDeclarations: [FASTQConsumerDeclaration] {
        [
            FASTQConsumerDeclaration(
                consumerID: "genotype.illumina-mhc",
                displayName: "Illumina MHC genotyping pair merge",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "IlluminaAmpliconPairMerger resolves the layout through FASTQInputLayoutResolver; a mixed file is first partitioned by NAME (FASTQPairInterleaver.partitionMixed), bbmerge interleaved=t runs on the strict pairs only, and the merged reads bypass it into the mapping FASTQ untouched."
            ),
            FASTQConsumerDeclaration(
                consumerID: "genotype.ont-mhc",
                displayName: "ONT MHC genotyping",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "Long-read amplicons; ONTGenotypingPipeline maps with pairedEnd false."
            ),
            FASTQConsumerDeclaration(
                consumerID: "twelve-s.amplicon-matching",
                displayName: "12S amplicon matching",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "Reads are matched record by record in process; each mate counts on its own."
            ),
            FASTQConsumerDeclaration(
                consumerID: ViralReconReadPairing.consumerID,
                displayName: "Viral Recon (Illumina samplesheet)",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .splitToR1R2,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "viralrecon reads pairs only as samplesheet fastq_1/fastq_2. ViralReconReadPairing resolves a single file's layout through FASTQInputLayoutResolver inside the run (GUI operation and `workflow run nf-core/viralrecon` alike), splits a strictly interleaved file into gzip R1/R2 with FASTQPairInterleaver.deinterleave and writes both columns; two files are a paired row; a mixed or single-end file stays a single-end row with a warning, because a positional split would mis-pair it."
            ),
        ]
    }
}
