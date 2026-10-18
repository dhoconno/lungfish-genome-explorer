// NaoMgsNvdImportFixtures.swift - Small NAO-MGS and NVD results with dotted sample ids, and a managed storage with a fixture taxonomy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow

/// The results that the `import nao-mgs` and `import nvd` tests import (Phase 2.12 lane 12.05). The NAO-MGS result
/// carries the dotted sample ids `S1.2024` and `S2.2024` and the NVD run carries the same two, so a test sees
/// whether a name is read whole (BIO 5). No tool and no network are needed.
///
/// A NAO-MGS import installs NCBI Taxonomy into the managed storage when names are missing. A test gives the
/// command, or its own process, a storage root under the scratch folder that already holds a fixture taxonomy
/// (`installFixtureTaxonomy(in:)`), so the install stays off the network and out of the user's managed storage.
enum NaoMgsNvdImportFixtures {
    /// A non-English locale for a child process (X12).
    static let nonEnglishLocale = ["LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8"]

    /// The environment of a command whose managed storage is `storage`. The guard turns a write outside it into a stop.
    static func storageEnvironment(_ storage: URL) -> [String: String] {
        ["LUNGFISH_STORAGE_ROOT": storage.path, "LUNGFISH_FORBID_REAL_MANAGED_STORAGE_WRITES": "1"]
    }

    private static let naoMgsHeader = [
        "seq_id", "sample", "aligner_taxid_lca", "aligner_taxid_top", "aligner_length_normalized_score_mean",
        "aligner_taxid_lca_combined", "aligner_n_assignments_combined", "aligner_length_normalized_score_mean_combined",
        "aligner_taxid_lca_artificial", "aligner_n_assignments_artificial", "aligner_length_normalized_score_mean_artificial",
        "query_len", "query_len_rev", "query_seq", "query_seq_rev", "query_qual", "query_qual_rev",
        "prim_align_genome_id_all", "prim_align_taxid_all", "prim_align_fragment_length", "prim_align_best_alignment_score",
        "prim_align_best_alignment_score_rev", "prim_align_edit_distance", "prim_align_edit_distance_rev",
        "prim_align_ref_start", "prim_align_ref_start_rev", "prim_align_query_rc", "prim_align_query_rc_rev",
        "prim_align_pair_status",
    ]

    /// One hit on taxon 28875, shaped like the rows of `Tests/Fixtures/naomgs/virus_hits_final.tsv.gz`.
    private static func naoMgsRow(read: Int, sample: String) -> String {
        let forward = "GAATCCATGTTCACATTTTTAAACTTTCCAACCATTAAGCAATTTTCAAACGGTGCATATATCGTAAAACATACTATTAAATTGAAGCAGGAAAAATGGCTGGGTAAAAGAGTGTCA"
        let reverse = "TGACACTCTTTTACCCAGCCATTTTTCCTGCTTCAATTTAATAGTATGTTTTACGATATATGCACCGTTTGAAAATTGCTTAATGGTTGGAAAGTTTAAAAATGTGAACATGGATT"
        return [
            "LH00642:161:23KFJ7LT4:2:1331:20578:\(13300 + read)", sample, "28875", "28875", "40.56970674428022", "28875", "10",
            "40.56970674428022", "NA", "0", "NA", String(forward.count), String(reverse.count), forward, reverse,
            String(repeating: "I", count: forward.count), String(repeating: "I", count: reverse.count),
            "KU048583.1", "28875", "117", "226", "224", "1", "1", "688", "689", "False", "True", "CP",
        ].joined(separator: "\t")
    }

    /// `S1.2024/virus_hits_final.tsv`, three hits of sample `S1.2024` and two of `S2.2024`.
    static func naoMgsResult(in root: URL, folderName: String = "S1.2024") throws -> URL {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rows = (1...3).map { naoMgsRow(read: $0, sample: "S1.2024") } + (4...5).map { naoMgsRow(read: $0, sample: "S2.2024") }
        try ([naoMgsHeader.joined(separator: "\t")] + rows).joined(separator: "\n").appending("\n")
            .write(to: folder.appendingPathComponent("virus_hits_final.tsv"), atomically: true, encoding: .utf8)
        return folder
    }

    /// `nvd.2024/`, a run with the `05_labkey_bundling` table of experiment `EXP001`, two hits for sample `S1.2024`
    /// and one for `S2.2024`. It has no BAM, so no samtools runs.
    static func nvdRun(in root: URL, folderName: String = "nvd.2024") throws -> URL {
        let run = root.appendingPathComponent(folderName, isDirectory: true)
        let labkey = run.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        try FileManager.default.createDirectory(at: labkey, withIntermediateDirectories: true)
        let header = "experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,"
            + "bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,"
            + "stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank"
        func row(_ sample: String, _ contig: String) -> String {
            "EXP001,megablast,\(sample),\(contig),29829,MT192765.1,Severe acute respiratory syndrome coronavirus 2,"
                + "species:SARS-CoV-2,29800,99.9,0.0,55000.0,SARS-CoV-2,2697049,2.5.0,run-001,197,200,"
                + "2.5.0,2697049,dominant,SARS-CoV-2,species"
        }
        try ([header, row("S1.2024", "NODE_1"), row("S1.2024", "NODE_2"), row("S2.2024", "NODE_1")])
            .joined(separator: "\n").appending("\n")
            .write(to: labkey.appendingPathComponent("EXP001_blast_concatenated.csv"), atomically: true, encoding: .utf8)
        return run
    }

    /// Adds a sparse file of `gigabytes` GB to `folder`. It takes no disk space, and hashing it for the record takes
    /// seconds, which holds an import at work.
    static func addLargeSparseFile(to folder: URL, gigabytes: UInt64 = 4) throws {
        let file = folder.appendingPathComponent("hold.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: gigabytes * 1_073_741_824)
    }

    /// Installs a small NCBI Taxonomy into a managed storage under `root` and returns the storage root.
    static func installFixtureTaxonomy(in root: URL) async throws -> URL {
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        let databases = storage.appendingPathComponent("databases", isDirectory: true)
        try FileManager.default.createDirectory(at: databases, withIntermediateDirectories: true)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: databases,
            catalog: MetagenomicsDatabaseInfo.builtInCatalog.filter { $0.tool == MetagenomicsTool.ncbiTaxonomy.rawValue },
            databaseInstaller: NCBITaxonomyFixture.installer(
                archive: root.appendingPathComponent("taxdump.tar.gz"),
                scientificNames: [28875: "Fixture virus alpha"]
            )
        )
        _ = try await registry.downloadDatabase(name: "NCBI Taxonomy") { _, _ in }
        return storage
    }

    /// The `naomgs-*` folders an import made in `imports`.
    static func naoMgsFolders(in imports: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
            .filter { $0.hasPrefix("naomgs-") }
            .sorted()
    }

    /// The hidden staging folders an NVD import made in `imports`, which it promotes to `nvd-*` once the record is written.
    static func nvdStagingFolders(in imports: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
            .filter { $0.hasPrefix(".lungfish-nvd-import-") }
            .sorted()
    }

    /// Every entry of `imports`, hidden ones included.
    static func entries(in imports: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []).sorted()
    }

    /// Points this process, and so every command it starts, at `storage`. Returns what to give back to ``restoreStorage(_:)``.
    static func useStorage(_ storage: URL) -> String? {
        let before = ProcessInfo.processInfo.environment["LUNGFISH_STORAGE_ROOT"]
        setenv("LUNGFISH_STORAGE_ROOT", storage.path, 1)
        return before
    }

    static func restoreStorage(_ before: String?) {
        if let before { setenv("LUNGFISH_STORAGE_ROOT", before, 1) } else { unsetenv("LUNGFISH_STORAGE_ROOT") }
    }

    /// The published `nvd-*` folders in `imports`.
    static func nvdFolders(in imports: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
            .filter { $0.hasPrefix("nvd-") }
            .sorted()
    }
}
