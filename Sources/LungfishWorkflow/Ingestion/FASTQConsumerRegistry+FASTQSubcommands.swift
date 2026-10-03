// FASTQConsumerRegistry+FASTQSubcommands.swift - The lungfish-cli fastq subcommands' read-layout declarations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQConsumerRegistry {

    // MARK: - lungfish-cli fastq subcommands

    static var fastqSubcommandDeclarations: [FASTQConsumerDeclaration] {
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

        // Verified against the installed ribodetector_cpu 0.3.3 help on
        // 2026-09-27: `-i R1 R2 -o out1 out2` classifies each fragment from
        // both mates and keeps or drops the pair together (`-e` decides
        // discordant pairs). Handed one interleaved file it judges every
        // record alone and orphans the surviving mate.
        let ribodetector = FASTQConsumerDeclaration(
            consumerID: "fastq.ribodetector",
            displayName: "fastq ribodetector",
            handling: [
                .singleEnd: .asSingle,
                .strictlyInterleaved: .asPairs,
                .mixedMergedAndPairs: .asSingle,
                .pairedFiles: .asPairs,
            ],
            mixedRationale: "FastqRiboDetectorSubcommand resolves the layout through FASTQPairingOptions: a strictly interleaved file is split by position into R1/R2 (FASTQPairInterleaver.deinterleave), ribodetector_cpu runs -i R1 R2 so both mates are kept or dropped together, and each output class is interleaved again; two files run as R1/R2 directly; a mixed file runs as single reads with a warning, because a positional split would mis-pair it."
        )

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
        return positional + byName + fastp + single + [ribodetector, merge, deinterleave, interleave]
    }
}
