// RNASeqFixtures.swift - Paths of the RNA-seq fixtures of Phase 5
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.1 lane RS-KIND. `Tests/Fixtures/rnaseq` holds the small results that lane P5-LAYOUT cut from the data of
// the reproduction stage (`Tests/Fixtures/rnaseq/README.md`). This file finds that folder from its own path, as
// `CLIEventCompatCorpus` finds `cli-events`, so no test depends on the working directory or on a bundle resource.

import Foundation

public enum RNASeqFixtures {
    /// `Tests/Fixtures/rnaseq`, found from the checkout that holds this file.
    public static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LungfishTestSupport
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("Tests/Fixtures/rnaseq", isDirectory: true)
    }

    /// The two SEQC runs of C1 that `salmon-c1/` holds, salmon 2.11.0 folders.
    public static let salmonRunIDs = ["SRR896663", "SRR896743"]

    /// The four files each salmon folder keeps, as paths under the run's folder.
    public static let salmonFiles = ["quant.sf", "cmd_info.json", "lib_format_counts.json", "aux_info/meta_info.json"]

    public static func salmonRun(_ runID: String) -> URL {
        root.appendingPathComponent("salmon-c1/\(runID)", isDirectory: true)
    }

    /// C9's UMI counts, genes by samples, with `gene_id` as the first column and no reference set named.
    public static var umiCounts: URL {
        root.appendingPathComponent("umi-table-c9/counts.tsv")
    }

    /// STARsolo's filtered matrix folder of pbmc_1k_v3, `matrix.mtx`, `features.tsv` and `barcodes.tsv`.
    public static var starsoloFiltered: URL {
        root.appendingPathComponent("starsolo-pbmc_1k_v3/Solo.out/Gene/filtered", isDirectory: true)
    }
}
