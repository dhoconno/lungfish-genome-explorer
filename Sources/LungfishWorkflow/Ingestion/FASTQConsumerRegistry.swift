// FASTQConsumerRegistry.swift - Every FASTQ-consuming tool's declared read-layout handling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The owner contract (FASTQInputLayout.swift) asks every tool invocation
// that consumes FASTQ to say what it does with single-end, strictly
// interleaved, mixed (merged reads plus pairs), and R1/R2 input. The
// mappers declare next to their builder (MappingTool+ReadLayout). The rest
// are declared here, with the source that decides the behaviour named in
// the rationale. Every consumer now resolves its layout through
// FASTQInputLayoutResolver (metadata, then a record scan) and either pairs
// mixed input by NAME or runs it as single reads; `mixedHandlingIsGraceful
// == false` is reserved for a consumer that still pairs mixed input by
// position, and FASTQConsumerRegistryTests pins that list (empty) so a new
// unsafe consumer cannot slip in unnoticed.

import Foundation
import LungfishIO

public enum FASTQConsumerRegistry {

    /// Every declaration, mappers first.
    public static var declarations: [FASTQConsumerDeclaration] {
        MappingTool.allCases.map(\.fastqConsumerDeclaration)
            + classifierDeclarations
            + assemblerDeclarations
            + fastqSubcommandDeclarations
            + guiAndRecipeDeclarations
            + genotypingAndWorkflowDeclarations
    }

    /// The declaration for a consumer ID, if registered.
    public static func declaration(for consumerID: String) -> FASTQConsumerDeclaration? {
        declarations.first { $0.consumerID == consumerID }
    }

    /// Consumers whose declared mixed handling is not graceful.
    public static var consumersWithUngracefulMixedHandling: [FASTQConsumerDeclaration] {
        declarations.filter { !$0.mixedHandlingIsGraceful }
    }

    // MARK: - Classifiers

    private static var classifierDeclarations: [FASTQConsumerDeclaration] {
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

    // MARK: - Assemblers

    private static var assemblerDeclarations: [FASTQConsumerDeclaration] {
        // Verified against the installed tools' help on 2026-09-27 (SPAdes
        // 4.3.0 `--12`, MEGAHIT 1.2.9 `--12`, SKESA 2.5.1 `--use_paired_ends`):
        // each pairs the records of one file by POSITION, so only a strictly
        // interleaved file runs as pairs and a mixed file stays single.
        let shortReadAssemblers: [(id: String, name: String, single: String, interleaved: String)] = [
            ("assemble.spades", "SPAdes", "-s", "--12"),
            ("assemble.megahit", "MEGAHIT", "-r", "--12"),
            ("assemble.skesa", "SKESA", "--reads", "--reads with --use_paired_ends"),
        ]
        let shortRead = shortReadAssemblers.map { assembler in
            FASTQConsumerDeclaration(
                consumerID: assembler.id,
                displayName: assembler.name,
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "ManagedAssemblyPipeline resolves one file's layout through AssemblyRunRequest.readPairing (FASTQInputLayoutResolver in lungfish-cli assemble): a strictly interleaved file runs as \(assembler.interleaved), two R1/R2 files run as pairs, and a mixed file runs as \(assembler.single) single reads because \(assembler.interleaved) pairs records by position."
            )
        }
        let longRead = [("assemble.flye", "Flye"), ("assemble.hifiasm", "hifiasm")].map { assembler in
            FASTQConsumerDeclaration(
                consumerID: assembler.0,
                displayName: assembler.1,
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "Long-read assembler: every record is a single read and two input files are rejected."
            )
        }
        return shortRead + longRead
    }

    // MARK: - lungfish-cli fastq subcommands

    private static var fastqSubcommandDeclarations: [FASTQConsumerDeclaration] {
        // Subcommands whose pair-aware tool pairs records by POSITION. Their
        // --pairing option resolves the layout through FASTQPairingModeResolver
        // (FASTQInputLayoutResolver underneath) and turns the tool's pair mode
        // on only for a strictly interleaved file; mixed input runs as single
        // reads, and the provenance records readLayout and readLayoutReason.
        let positionalWhenInterleaved: [(id: String, name: String, tool: String, pairedFiles: FASTQReadLayoutHandling)] = [
            ("fastq.subsample", "fastq subsample", "reformat interleaved=t", .asSingle),
            ("fastq.contaminant-filter", "fastq contaminant-filter", "bbduk interleaved=t", .asSingle),
            ("fastq.entropy-filter", "fastq entropy-filter", "bbduk interleaved=t", .asSingle),
            ("fastq.deduplicate", "fastq deduplicate", "clumpify interleaved=t", .asSingle),
            ("fastq.sequence-filter", "fastq sequence-filter", "bbduk interleaved=t", .asSingle),
            ("fastq.scrub-human", "fastq scrub-human", "reformat interleaved=t split, deacon on R1/R2", .asSingle),
            ("fastq.deacon-ribo", "fastq deacon-ribo", "reformat interleaved=t split, deacon on R1/R2", .asPairs),
        ]
        let positional = positionalWhenInterleaved.map { entry in
            FASTQConsumerDeclaration(
                consumerID: entry.id,
                displayName: entry.name,
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: entry.pairedFiles,
                ],
                mixedRationale: "\(entry.tool) pairs by position, so FASTQPairingOptions.resolvePairing turns it on only for a strictly interleaved file; a mixed file runs as single reads with a warning, and --pairing interleaved is verified against the records."
            )
        }

        let byName = [
            ("fastq.search-text", "fastq search-text"),
            ("fastq.search-motif", "fastq search-motif"),
            ("fastq.repair", "fastq repair"),
        ].map { entry in
            FASTQConsumerDeclaration(
                consumerID: entry.0,
                displayName: entry.1,
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "Mates are matched by fragment name (seqkit grep re-extraction, or BBTools repair), so unpaired records in a mixed file stay single."
            )
        }

        let fastp = [
            ("fastq.trim", "fastq trim"),
            ("fastq.quality-trim", "fastq quality-trim"),
            ("fastq.adapter-trim", "fastq adapter-trim"),
            ("fastq.fixed-trim", "fastq fixed-trim"),
        ].map { entry in
            FASTQConsumerDeclaration(
                consumerID: entry.0,
                displayName: entry.1,
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "FastpPairedRunner scans the records by name (FASTQPairInterleaver.countMixed) and states the layout: a strictly interleaved file is partitioned by name into R1/R2 and runs fastp -i R1 -I R2 with two outputs that are interleaved again, so both mates are kept or dropped together and adapters are found by overlap analysis; a mixed file is partitioned the same way so its pairs run paired and its unpaired reads single-end; --pairing single runs every record on its own. fastp single-end mode discarded a read it trimmed to nothing even with --disable_length_filtering and kept its mate, which broke every later positional pair."
            )
        }

        let perRecord: [(id: String, name: String, tool: String, pairedFiles: FASTQReadLayoutHandling)] = [
            ("fastq.length-filter", "fastq length-filter", "seqkit seq per record", .asSingle),
            ("fastq.primer-remove", "fastq primer-remove", "bbduk interleaved=f or cutadapt per record", .asSingle),
            ("fastq.error-correct", "fastq error-correct", "tadpole interleaved=f", .asSingle),
            ("fastq.ribodetector", "fastq ribodetector", "ribodetector_cpu -i", .asPairs),
        ]
        let single = perRecord.map { entry in
            FASTQConsumerDeclaration(
                consumerID: entry.id,
                displayName: entry.name,
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: entry.pairedFiles,
                ],
                mixedRationale: "Runs \(entry.tool); every record is treated on its own."
            )
        }

        let merge = FASTQConsumerDeclaration(
            consumerID: "fastq.merge",
            displayName: "fastq merge",
            handling: [
                .singleEnd: .asSingle,
                .strictlyInterleaved: .asPairs,
                .mixedMergedAndPairs: .asPairs,
                .pairedFiles: .asSingle,
            ],
            mixedRationale: "FastqMergeSubcommand resolves the layout first: a strictly interleaved file runs bbmerge interleaved=t (identical names included); a mixed file is partitioned by NAME, bbmerge merges the strict pairs, and the merged reads pass through into the output untouched; a single-end file is refused."
        )
        let deinterleave = FASTQConsumerDeclaration(
            consumerID: "fastq.deinterleave",
            displayName: "fastq deinterleave",
            handling: [
                .singleEnd: .asSingle,
                .strictlyInterleaved: .splitToR1R2,
                .mixedMergedAndPairs: .splitToR1R2,
                .pairedFiles: .asSingle,
            ],
            mixedRationale: "A strictly interleaved file is split by position with reformat interleaved=t. A mixed file is split by NAME in process (FASTQPairInterleaver.partitionMixed): pairs go to --out1/--out2 and reads without a mate to --unpaired, which the command requires for such a file. A single-end file is refused."
        )
        let interleave = FASTQConsumerDeclaration(
            consumerID: "fastq.interleave",
            displayName: "fastq interleave",
            handling: [
                .singleEnd: .asSingle,
                .strictlyInterleaved: .asSingle,
                .mixedMergedAndPairs: .asSingle,
                .pairedFiles: .asPairs,
            ],
            mixedRationale: "Takes two R1/R2 files only."
        )
        return positional + byName + fastp + single + [merge, deinterleave, interleave]
    }

    // MARK: - GUI in-process derivatives, ingestion, recipes

    private static var guiAndRecipeDeclarations: [FASTQConsumerDeclaration] {
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

    // MARK: - Genotyping, 12S, Viral Recon

    private static var genotypingAndWorkflowDeclarations: [FASTQConsumerDeclaration] {
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
