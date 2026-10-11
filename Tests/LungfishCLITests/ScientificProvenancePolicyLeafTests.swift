// ScientificProvenancePolicyLeafTests.swift - The provenance policy entry of every CLI leaf command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Pins the provenance policy entry that `ScientificProvenancePolicy.cliCommand(path:)` gives every
/// leaf command of `lungfish-cli`, so a change to the lookup rule shows which leaves it moves.
///
/// The leaves come from the golden help index, `Tests/Fixtures/golden/cli-help/index.tsv`, which
/// lists every command path the executable registers, hidden commands included. A leaf is a path
/// that no other path extends. The table holds the id of the entry each leaf resolves to, or nil
/// when it resolves to none. A new CLI leaf needs a row, and the failure message prints it.
///
/// At the base of Phase 2.7 the lookup falls back to the entry of the last path component. That
/// gives 32 leaves the entry of another command (`import bam` holds `cli.bam`) and gives 172
/// leaves of command groups no entry at all (`esviritu detect`). The commit that changes the rule
/// changes the rows of those leaves and no others.
final class ScientificProvenancePolicyLeafTests: XCTestCase {
    func testEveryLeafResolvesToItsPinnedEntry() throws {
        let leaves = try Self.helpIndexLeaves()
        XCTAssertFalse(leaves.isEmpty, "the help index lists no command")

        var unpinned: [String] = []
        var moved: [String] = []
        for leaf in leaves {
            let key = leaf.joined(separator: " ")
            let actual = ScientificProvenancePolicy.cliCommand(path: leaf)?.id
            guard let pinned = Self.pinnedEntryIDs[key] else {
                unpinned.append("        \"\(key)\": \(Self.literal(actual)),")
                continue
            }
            if pinned != actual {
                moved.append("\(key): pinned \(Self.literal(pinned)), resolves to \(Self.literal(actual))")
            }
        }
        let leafKeys = Set(leaves.map { $0.joined(separator: " ") })
        let stale = Self.pinnedEntryIDs.keys.filter { !leafKeys.contains($0) }.sorted()

        XCTAssertTrue(unpinned.isEmpty, "Leaves with no pinned row. Add these rows:\n\(unpinned.joined(separator: "\n"))")
        XCTAssertTrue(moved.isEmpty, "Leaves whose entry moved:\n\(moved.joined(separator: "\n"))")
        XCTAssertTrue(stale.isEmpty, "Pinned rows for paths that are no leaf of the help index:\n\(stale.joined(separator: "\n"))")
    }

    // MARK: - The help index

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LungfishCLITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    /// Every path of the help index that no other path extends, without the executable name and in
    /// the order of the joined path.
    private static func helpIndexLeaves() throws -> [[String]] {
        let index = repositoryRoot.appendingPathComponent("Tests/Fixtures/golden/cli-help/index.tsv")
        let text = try String(contentsOf: index, encoding: .utf8)
        let paths: [[String]] = text.split(separator: "\n").dropFirst().compactMap { row in
            guard let command = row.split(separator: "\t", omittingEmptySubsequences: false).first else { return nil }
            let words = command.split(separator: " ").map(String.init)
            return words.count > 1 ? Array(words.dropFirst()) : nil
        }
        return paths
            .filter { path in !paths.contains { $0.count > path.count && Array($0.prefix(path.count)) == path } }
            .sorted { $0.joined(separator: " ") < $1.joined(separator: " ") }
    }

    private static func literal(_ id: String?) -> String {
        id.map { "\"\($0)\"" } ?? "nil"
    }

    // MARK: - The pinned table

    /// The id of the entry each leaf resolves to, by the leaf's path. nil means the leaf has none.
    private static let pinnedEntryIDs: [String: String?] = [
        "align mafft": nil,
        "analyze composition": nil,
        "analyze stats": nil,
        "analyze validate": nil,
        "assemble": "cli.assemble",
        "bam adopt-mapping": nil,
        "bam annotate": nil,
        "bam annotate-best": nil,
        "bam annotate-cds-best": nil,
        "bam filter": nil,
        "bam markdup": "cli.markdup",
        "bam primer-trim": nil,
        "blast verify": nil,
        "build-db esviritu": "cli.esviritu",
        "build-db kraken2": "cli.build-db",
        "build-db taxtriage": "cli.taxtriage",
        "bundle create": nil,
        "bundle deduplicate-alignments": nil,
        "bundle export": nil,
        "bundle extract-annotations": nil,
        "bundle info": nil,
        "bundle list": nil,
        "bundle mark-duplicates": nil,
        "bundle validate": nil,
        "conda classify": "cli.kraken2.classify",
        "conda db download": "cli.conda.db.download",
        "conda db info": nil,
        "conda db install-managed": nil,
        "conda db list": nil,
        "conda db recommend": nil,
        "conda db remove": nil,
        "conda db update": nil,
        "conda envs": nil,
        "conda export-pack": nil,
        "conda extract": "cli.extract",
        "conda install": nil,
        "conda list": nil,
        "conda lock": nil,
        "conda offline-export": nil,
        "conda offline-install": nil,
        "conda packs": nil,
        "conda remove": nil,
        "conda run": nil,
        "conda search": "cli.search",
        "conda setup": nil,
        "convert": "cli.convert",
        "cz-id import": "cli.import",
        "cz-id summary": nil,
        "debug container": nil,
        "debug env": nil,
        "debug fastq-ingest": "cli.debug.fastq-ingest",
        "debug resource-smoke": nil,
        "debug workflow-log": nil,
        "demo fetch": "cli.fetch",
        "demo info": nil,
        "demo list": nil,
        "esviritu db-status": nil,
        "esviritu detect": nil,
        "esviritu download-db": nil,
        "extract contigs": nil,
        "extract reads": nil,
        "extract sequence": "cli.sequence",
        "fastq 12s-export": "cli.fastq.12s-export",
        "fastq 12s-export-unresolved": "cli.fastq.12s-export-unresolved",
        "fastq 12s-match": "cli.fastq.12s-match",
        "fastq 12s-reference-bundle": "cli.fastq.12s-reference-bundle",
        "fastq 12s-reference-metadata": "cli.fastq.12s-reference-metadata",
        "fastq adapter-trim": nil,
        "fastq contaminant-filter": nil,
        "fastq deacon-ribo": nil,
        "fastq deduplicate": nil,
        "fastq deinterleave": nil,
        "fastq demultiplex": nil,
        "fastq entropy-filter": nil,
        "fastq error-correct": nil,
        "fastq fixed-trim": nil,
        "fastq full-length-ont-mhc-genotype": nil,
        "fastq genotype": "cli.genotype",
        "fastq genotype-cohort": nil,
        "fastq import-ont": nil,
        "fastq interleave": nil,
        "fastq length-filter": nil,
        "fastq materialize": nil,
        "fastq merge": nil,
        "fastq mhc-reference-bundle": "cli.fastq.mhc-reference-bundle",
        "fastq ont-barcode-genotype": nil,
        "fastq ont-fluidigm-samples": nil,
        "fastq ont-genotype": nil,
        "fastq ont-pacbio-barcode-demux": nil,
        "fastq orient": "cli.orient",
        "fastq pbaa-cluster": "cli.fastq.pbaa-cluster",
        "fastq platform": nil,
        "fastq primer-remove": nil,
        "fastq qc-summary": nil,
        "fastq quality-trim": nil,
        "fastq repair": nil,
        "fastq reverse-complement": nil,
        "fastq ribodetector": nil,
        "fastq savont-cluster": "cli.fastq.savont-cluster",
        "fastq scout": nil,
        "fastq scrub-human": nil,
        "fastq search-motif": nil,
        "fastq search-text": nil,
        "fastq sequence-filter": nil,
        "fastq subsample": nil,
        "fastq translate": "cli.translate",
        "fastq trim": nil,
        "fetch ena fasta": nil,
        "fetch ena reads": nil,
        "fetch ena search": "cli.search",
        "fetch genome": nil,
        "fetch ncbi": nil,
        "fetch search": "cli.search",
        "fetch sra download": nil,
        "fetch sra info": nil,
        "fetch sra search": "cli.search",
        "freyja demix": nil,
        "gatk bqsr": nil,
        "gatk collect-metrics": nil,
        "gatk filter": nil,
        "gatk haplotype-caller": nil,
        "gatk joint-genotype": nil,
        "gatk leftalign": nil,
        "gatk markdup": "cli.markdup",
        "gatk select": nil,
        "gatk validate-sam": nil,
        "gatk variants-to-table": nil,
        "genotype ai-haplotyping": nil,
        "genotype apply-annotations": nil,
        "genotype export": nil,
        "genotype export-labkey": nil,
        "genotype export-pivot-xlsx": nil,
        "genotype export-xlsx": nil,
        "genotype list-cohorts": nil,
        "genotype list-samples": nil,
        "genotype replay-call-overrides": nil,
        "genotype replay-manual-haplotype-assignments": nil,
        "genotype replay-matrix-annotation": nil,
        "haplotypes bundle-create": nil,
        "haplotypes bundle-install": nil,
        "haplotypes bundle-replace-reference": nil,
        "haplotypes bundle-save": nil,
        "haplotypes delete": nil,
        "haplotypes duplicate": nil,
        "haplotypes export": nil,
        "haplotypes import": "cli.import",
        "haplotypes list": nil,
        "haplotypes save": nil,
        "haplotypes validate": nil,
        "help": nil,
        "import application-export": nil,
        "import bam": "cli.bam",
        "import cz-id": "cli.cz-id",
        "import esviritu": "cli.esviritu",
        "import fasta": nil,
        "import fastq": "cli.fastq",
        "import geneious": nil,
        "import kraken2": "cli.import",
        "import metadata": "cli.metadata",
        "import msa": "cli.msa",
        "import nao-mgs": "cli.nao-mgs",
        "import nvd": "cli.nvd",
        "import sample-metadata": nil,
        "import taxtriage": "cli.taxtriage",
        "import tree": "cli.tree",
        "import vcf": nil,
        "import-fastq": "cli.import-fastq",
        "kraken2 classify": "cli.kraken2.classify",
        "map": "cli.map",
        "markdup": "cli.markdup",
        "metadata export": nil,
        "metadata export-biosample": nil,
        "metadata get": nil,
        "metadata import": "cli.import",
        "metadata set": nil,
        "msa actions": nil,
        "msa annotate add": nil,
        "msa annotate delete": nil,
        "msa annotate edit": nil,
        "msa annotate project": "cli.project",
        "msa consensus": nil,
        "msa describe": nil,
        "msa discriminating-sites": nil,
        "msa distance": nil,
        "msa export": nil,
        "msa extract": "cli.extract",
        "msa mask columns": nil,
        "msa trim columns": nil,
        "nao-mgs import": "cli.import",
        "nao-mgs summary": nil,
        "nvd import": "cli.import",
        "nvd summary": nil,
        "ops stats": nil,
        "orient": "cli.orient",
        "primers analysis annotated-reference": "cli.primers.analysis.annotated-reference",
        "primers analysis audit": "cli.primers.analysis.audit",
        "primers analysis export-order": "cli.primers.analysis.export-order",
        "primers analysis history": "cli.primers.analysis.history",
        "primers analysis inspect": "cli.primers.analysis.inspect",
        "primers design olivar": nil,
        "primers design primalscheme3": "cli.primers.design.primalscheme3",
        "primers design primer3": "cli.primers.design.primer3",
        "primers design varvamp": nil,
        "primers import": "cli.import",
        "primers scheme-from-analysis": nil,
        "project lock": nil,
        "project migrate": nil,
        "project unlock": nil,
        "provenance bibliography": nil,
        "provenance export": nil,
        "provenance verify": nil,
        "run-headless": "cli.run-headless",
        "search": "cli.search",
        "sequence annotate-orfs": nil,
        "sequence delete-annotation-track": nil,
        "sequence delete-annotations": nil,
        "sequence update-annotation": nil,
        "storage dedupe": nil,
        "storage info": nil,
        "taxtriage check-prerequisites": nil,
        "taxtriage run": nil,
        "tools update": nil,
        "translate": "cli.translate",
        "tree export subtree": nil,
        "tree extract-subtree": nil,
        "tree infer iqtree": nil,
        "tree relabel": nil,
        "tree reroot": nil,
        "universal-search": "cli.universal-search",
        "variants call": nil,
        "variants extract-sample": nil,
        "variants phase": nil,
        "variants query": nil,
        "version": nil,
        "workflow list": nil,
        "workflow run": nil,
        "workflow validate": nil,
    ]
}
