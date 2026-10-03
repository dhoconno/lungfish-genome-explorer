// FASTQConsumerRegistry+GUIAndRecipes.swift - The in-process GUI derivative, ingestion and recipe read-layout declarations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQConsumerRegistry {

    // MARK: - GUI in-process derivatives, ingestion, recipes

    static var guiAndRecipeDeclarations: [FASTQConsumerDeclaration] {
        [
            FASTQConsumerDeclaration(
                consumerID: "gui.fastq-derivative",
                displayName: "FASTQ derivative (in-process GUI path)",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "FASTQDerivativeService.resolvedReadLayout scans the materialized reads with the bundle metadata as hints; fastp --interleaved_in, cutadapt --interleaved, BBTools interleaved=t and the deacon split (all positional) run only for a strictly interleaved file. Deinterleave and PE merge refuse a mixed file with a message; PE repair (by name) accepts it."
            ),
            FASTQConsumerDeclaration(
                consumerID: "ingest.clumpify",
                displayName: "Import clumpify / Trim Galore",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "FASTQIngestionPipeline scans one file by NAME (FASTQPairInterleaver.countMixed) and always states the layout: a strictly interleaved file runs clumpify interleaved=t, a file without mates interleaved=f, and a mixed file is partitioned by name so its pairs run with interleaved=t and its unpaired reads with interleaved=f; the output read count is verified. Trim Galore splits a strictly interleaved file into R1/R2 and runs --paired, and refuses a mixed file. Two files get in2= or --paired."
            ),
            FASTQConsumerDeclaration(
                consumerID: "recipe.convert-interleaved-to-paired",
                displayName: "Recipe engine interleaved-to-paired step",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .splitToR1R2,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "RecipeEngine.convertInterleavedToPaired resolves the layout first and runs reformat interleaved=t out= out2= only for a strictly interleaved file; a mixed or single-end file continues as .single and a later paired step reports the format mismatch."
            ),
        ]
    }
}
