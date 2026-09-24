// FASTQConsumerRegistry.swift - Every FASTQ-consuming tool's declared read-layout handling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The owner contract (FASTQInputLayout.swift) asks every tool invocation
// that consumes FASTQ to say what it does with single-end, strictly
// interleaved, mixed (merged reads plus pairs), and R1/R2 input. The
// mappers declare next to their builder (MappingTool+ReadLayout). The rest
// are declared here, as they behave TODAY, with the source that decides the
// behaviour named in the rationale. `mixedHandlingIsGraceful == false` marks
// a consumer whose mixed handling pairs records by position and is recorded
// pending its own fix; FASTQConsumerRegistryTests pins that list so a new
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
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "TaxTriageSamplesheet fills fastq_2 only for two files; any single file is a single-end row."
            ),
        ]
    }

    // MARK: - Assemblers

    private static var assemblerDeclarations: [FASTQConsumerDeclaration] {
        let shortReadAssemblers: [(id: String, name: String, flags: String)] = [
            ("assemble.spades", "SPAdes", "-s (no --12)"),
            ("assemble.megahit", "MEGAHIT", "-r (no --12)"),
            ("assemble.skesa", "SKESA", "--reads (no --use_paired_ends)"),
        ]
        let shortRead = shortReadAssemblers.map { assembler in
            FASTQConsumerDeclaration(
                consumerID: assembler.id,
                displayName: assembler.name,
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "ManagedAssemblyPipeline passes one file as \(assembler.flags); only two R1/R2 files run as pairs."
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
        // Subcommands that ask FASTQPairingModeResolver (bundle pairingMode,
        // then a 400-record name probe) and pair records by position when it
        // says interleaved. The resolver has no mixed case, so a mixed bundle
        // recorded as interleaved is paired by position today.
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
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: entry.pairedFiles,
                ],
                mixedRationale: "FASTQPairingOptions resolves interleaved from bundle metadata or a name probe, then runs \(entry.tool), which pairs by position and mis-pairs a mixed file.",
                mixedHandlingIsGraceful: false
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

        let perRecord: [(id: String, name: String, tool: String, pairedFiles: FASTQReadLayoutHandling)] = [
            ("fastq.trim", "fastq trim", "fastp single-end", .asSingle),
            ("fastq.quality-trim", "fastq quality-trim", "fastp single-end", .asSingle),
            ("fastq.adapter-trim", "fastq adapter-trim", "fastp single-end", .asSingle),
            ("fastq.fixed-trim", "fastq fixed-trim", "fastp single-end", .asSingle),
            ("fastq.length-filter", "fastq length-filter", "seqkit seq per record", .asSingle),
            ("fastq.primer-remove", "fastq primer-remove", "bbduk or cutadapt per record", .asSingle),
            ("fastq.error-correct", "fastq error-correct", "tadpole without an interleaved flag", .asSingle),
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
                .mixedMergedAndPairs: .asSingle,
                .pairedFiles: .asSingle,
            ],
            mixedRationale: "bbmerge runs without an interleaved flag, so BBTools' name auto-detection pairs /1 /2 and Casava names in a strictly interleaved file and treats a mixed file as single reads."
        )
        let deinterleave = FASTQConsumerDeclaration(
            consumerID: "fastq.deinterleave",
            displayName: "fastq deinterleave",
            handling: [
                .singleEnd: .splitToR1R2,
                .strictlyInterleaved: .splitToR1R2,
                .mixedMergedAndPairs: .splitToR1R2,
                .pairedFiles: .asSingle,
            ],
            mixedRationale: "reformat interleaved=t splits by position whatever the file holds; a mixed file yields misaligned R1/R2.",
            mixedHandlingIsGraceful: false
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
        return positional + byName + single + [merge, deinterleave, interleave]
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
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: .asSingle,
                ],
                mixedRationale: "FASTQDerivativeService.isInterleavedBundle reads bundle metadata only and drives fastp --interleaved_in, cutadapt --interleaved, BBTools interleaved=t and the deacon split by position.",
                mixedHandlingIsGraceful: false
            ),
            FASTQConsumerDeclaration(
                consumerID: "ingest.clumpify",
                displayName: "Import clumpify / Trim Galore",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "FASTQIngestionPipeline passes one file without an interleaved flag (BBTools auto-detection may still pair /1 /2 names); only two files get in2= or --paired."
            ),
            FASTQConsumerDeclaration(
                consumerID: "recipe.convert-interleaved-to-paired",
                displayName: "Recipe engine interleaved-to-paired step",
                handling: [
                    .singleEnd: .splitToR1R2,
                    .strictlyInterleaved: .splitToR1R2,
                    .mixedMergedAndPairs: .splitToR1R2,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "RecipeEngine.convertInterleavedToPaired runs reformat out= out2= and splits by position.",
                mixedHandlingIsGraceful: false
            ),
            FASTQConsumerDeclaration(
                consumerID: "workflow-builder.native-runner",
                displayName: "Workflow Builder native runner",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .splitToR1R2,
                    .mixedMergedAndPairs: .splitToR1R2,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "WorkflowBuilderNativeRunner labels a file interleaved from the sidecar pairingMode alone and converts it to R1/R2 by position.",
                mixedHandlingIsGraceful: false
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
                mixedRationale: "IlluminaAmpliconPairMerger probes 400 records (identical names not accepted) and runs bbmerge interleaved=t when most steps look paired, which pairs by position.",
                mixedHandlingIsGraceful: false
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
                consumerID: "viralrecon.illumina",
                displayName: "Viral Recon (Illumina samplesheet)",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asSingle,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "ViralReconSamplesheetBuilder fills fastq_2 only for a second file; any single file is a single-end row."
            ),
        ]
    }
}
