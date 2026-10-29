// EsVirituPipeline+DatabaseReference.swift - The inputs of an EsViritu step, with its database's install receipt
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension EsVirituPipeline {
    /// The inputs the EsViritu step records, the reads with the bundle behind each file when there is one, then the
    /// database as a reference input when its install receipt adds up to its own digest (DB-IDENTITY, 3.1). The
    /// receipt sits in the database folder or in its parent, and the reference names the folder that holds it, which
    /// is the folder its checksum covers. Nothing is hashed, and a database with no receipt that adds up adds nothing.
    static func stepInputRecords(for config: EsVirituConfig) -> [FileRecord] {
        let reads = inputLineageRecords(for: config) ?? config.inputFiles.map { url in
            ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)
        }
        guard let reference = MetagenomicsDatabaseReceiptReference.resolve(
            databasePath: config.databasePath, allowingParentReceipt: true
        )?.reference else {
            return reads
        }
        return reads + [
            FileRecord(
                path: reference.path,
                sha256: reference.checksumSHA256,
                sizeBytes: reference.fileSize,
                format: .unknown,
                role: .reference
            ),
        ]
    }
}
