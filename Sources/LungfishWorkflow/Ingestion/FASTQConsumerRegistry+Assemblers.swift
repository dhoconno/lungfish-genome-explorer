// FASTQConsumerRegistry+Assemblers.swift - The assemblers' read-layout declarations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQConsumerRegistry {

    // MARK: - Assemblers

    static var assemblerDeclarations: [FASTQConsumerDeclaration] {
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
}
