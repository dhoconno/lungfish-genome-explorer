// ScientificProvenancePolicyLeafTests.swift - The provenance policy entry of every CLI leaf command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Pins the provenance policy entry that `ScientificProvenancePolicy.cliCommand(path:)` gives every
/// leaf command of `lungfish-cli`, and checks that no leaf holds the entry of another command.
///
/// The leaves come from the golden help index, `Tests/Fixtures/golden/cli-help/index.tsv`, which
/// lists every command path the executable registers, hidden commands included. A leaf is a path
/// that no other path extends. The table holds the id of the entry each leaf resolves to, or nil
/// when it resolves to none. A new CLI leaf needs a row, and the failure message prints it.
///
/// The lookup takes the exact row of the path, else the row of its longest registered prefix, else
/// the entry of the command group that starts the path (plan decision E16). It never takes the
/// entry of the path's last component, which gave 32 leaves the entry of another command and left
/// 172 without one.
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

    func testEveryLeafEntryBelongsToItsOwnCommandGroup() throws {
        var foreign: [String] = []
        var missing: [String] = []
        for leaf in try Self.helpIndexLeaves() {
            let key = leaf.joined(separator: " ")
            let group = leaf[0]
            guard let entry = ScientificProvenancePolicy.cliCommand(path: leaf) else {
                if !Self.groupsWithoutAnEntry.contains(group) { missing.append(key) }
                continue
            }
            let isOwn = entry.id == "cli.\(group)" || entry.id.hasPrefix("cli.\(group).")
            if !isOwn && Self.entriesOfAnotherCommand[key] != entry.id {
                foreign.append("\(key) resolves to \(entry.id)")
            }
        }
        XCTAssertTrue(foreign.isEmpty, "Leaves that hold the entry of another command:\n\(foreign.joined(separator: "\n"))")
        XCTAssertTrue(missing.isEmpty, "Leaves of a scientific command group with no entry:\n\(missing.joined(separator: "\n"))")
    }

    func testEveryAllowedEntryOfAnotherCommandIsALeafThatResolvesToIt() throws {
        let leaves = Set(try Self.helpIndexLeaves().map { $0.joined(separator: " ") })
        for (key, id) in Self.entriesOfAnotherCommand {
            XCTAssertTrue(leaves.contains(key), "\(key) is no leaf of the help index")
            let path = key.split(separator: " ").map(String.init)
            XCTAssertEqual(ScientificProvenancePolicy.cliCommand(path: path)?.id, id)
        }
    }

    func testAPathTakesItsExactRowThenItsLongestRegisteredPrefixThenItsGroup() {
        func id(_ path: [String]) -> String? { ScientificProvenancePolicy.cliCommand(path: path)?.id }

        // The exact row of the path.
        XCTAssertEqual(id(["kraken2", "classify"]), "cli.kraken2.classify")
        XCTAssertEqual(id(["conda", "classify"]), "cli.kraken2.classify")
        XCTAssertEqual(id(["conda", "extract"]), "cli.conda.extract")
        XCTAssertEqual(id(["fastq", "12s-match"]), "cli.fastq.12s-match")
        XCTAssertEqual(id(["fastq", "mhc-reference-bundle"]), "cli.fastq.mhc-reference-bundle")

        // The longest registered prefix of a path that no row names.
        XCTAssertEqual(id(["conda", "db", "download", "all"]), "cli.conda.db.download")
        XCTAssertEqual(id(["fastq", "pbaa-cluster", "dry-run"]), "cli.fastq.pbaa-cluster")
        XCTAssertEqual(id(["primers", "analysis", "inspect", "details"]), "cli.primers.analysis.inspect")

        // The group's entry, for a leaf that shares its name with another command or with none.
        XCTAssertEqual(id(["import", "bam"]), "cli.import")
        XCTAssertEqual(id(["import", "search"]), "cli.import")
        XCTAssertEqual(id(["fetch", "search"]), "cli.fetch")
        XCTAssertEqual(id(["bam", "markdup"]), "cli.bam")
        XCTAssertEqual(id(["esviritu", "detect"]), "cli.esviritu")
        XCTAssertEqual(id(["fastq", "a-leaf-that-does-not-exist"]), "cli.fastq")
        XCTAssertEqual(id(["primers", "analysis", "unlisted"]), "cli.primers")
        XCTAssertEqual(id(["fastq"]), "cli.fastq")

        // A group that holds no entry of its own gives none, and never another command's.
        XCTAssertNil(id(["conda", "search"]))
        XCTAssertNil(id(["demo", "fetch"]))
        XCTAssertNil(id(["debug", "env"]))

        // Case and blanks are not part of the path.
        XCTAssertEqual(id(["Fastq", " 12S-Match "]), "cli.fastq.12s-match")
        XCTAssertEqual(id(["", "fastq", "trim"]), "cli.fastq")
        XCTAssertNil(id([]))
        XCTAssertNil(id(["  "]))
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

    /// Command groups that hold no entry of their own, because they maintain the installation or the
    /// managed storage and write no scientific data (`ScientificCLIProvenanceCoverageTests` gives the
    /// reasons). `help` is the argument parser's own subcommand. A leaf of one of them gets an entry
    /// only from an exact row.
    private static let groupsWithoutAnEntry: Set<String> = ["conda", "debug", "demo", "storage", "version", "help"]

    /// Leaves whose entry belongs to another command on purpose. `conda classify` and
    /// `kraken2 classify` are one command, `ClassifyCommand`.
    private static let entriesOfAnotherCommand: [String: String] = [
        "conda classify": "cli.kraken2.classify",
    ]

    // MARK: - The pinned table

    /// The id of the entry each leaf resolves to, by the leaf's path. nil means the leaf has none.
    private static let pinnedEntryIDs: [String: String?] = [
        "align mafft": "cli.align",
        "analyze composition": "cli.analyze",
        "analyze stats": "cli.analyze",
        "analyze validate": "cli.analyze",
        "assemble": "cli.assemble",
        "bam adopt-mapping": "cli.bam",
        "bam annotate": "cli.bam",
        "bam annotate-best": "cli.bam",
        "bam annotate-cds-best": "cli.bam",
        "bam filter": "cli.bam",
        "bam markdup": "cli.bam",
        "bam primer-trim": "cli.bam",
        "blast verify": "cli.blast",
        "build-db esviritu": "cli.build-db",
        "build-db kraken2": "cli.build-db",
        "build-db taxtriage": "cli.build-db",
        "bundle create": "cli.bundle",
        "bundle deduplicate-alignments": "cli.bundle",
        "bundle export": "cli.bundle",
        "bundle extract-annotations": "cli.bundle",
        "bundle info": "cli.bundle",
        "bundle list": "cli.bundle",
        "bundle mark-duplicates": "cli.bundle",
        "bundle validate": "cli.bundle",
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
        "conda extract": "cli.conda.extract",
        "conda install": nil,
        "conda list": nil,
        "conda lock": nil,
        "conda offline-export": nil,
        "conda offline-install": nil,
        "conda packs": nil,
        "conda remove": nil,
        "conda run": nil,
        "conda search": nil,
        "conda setup": nil,
        "convert": "cli.convert",
        "cz-id import": "cli.cz-id",
        "cz-id summary": "cli.cz-id",
        "debug container": nil,
        "debug env": nil,
        "debug fastq-ingest": "cli.debug.fastq-ingest",
        "debug resource-smoke": nil,
        "debug workflow-log": nil,
        "demo fetch": nil,
        "demo info": nil,
        "demo list": nil,
        "esviritu db-status": "cli.esviritu",
        "esviritu detect": "cli.esviritu",
        "esviritu download-db": "cli.esviritu",
        "extract contigs": "cli.extract",
        "extract reads": "cli.extract",
        "extract sequence": "cli.extract",
        "fastq 12s-export": "cli.fastq.12s-export",
        "fastq 12s-export-unresolved": "cli.fastq.12s-export-unresolved",
        "fastq 12s-match": "cli.fastq.12s-match",
        "fastq 12s-reference-bundle": "cli.fastq.12s-reference-bundle",
        "fastq 12s-reference-metadata": "cli.fastq.12s-reference-metadata",
        "fastq adapter-trim": "cli.fastq",
        "fastq contaminant-filter": "cli.fastq",
        "fastq deacon-ribo": "cli.fastq",
        "fastq deduplicate": "cli.fastq",
        "fastq deinterleave": "cli.fastq",
        "fastq demultiplex": "cli.fastq",
        "fastq entropy-filter": "cli.fastq",
        "fastq error-correct": "cli.fastq",
        "fastq fixed-trim": "cli.fastq",
        "fastq full-length-ont-mhc-genotype": "cli.fastq",
        "fastq genotype": "cli.fastq",
        "fastq genotype-cohort": "cli.fastq",
        "fastq import-ont": "cli.fastq",
        "fastq interleave": "cli.fastq",
        "fastq length-filter": "cli.fastq",
        "fastq materialize": "cli.fastq",
        "fastq merge": "cli.fastq",
        "fastq mhc-reference-bundle": "cli.fastq.mhc-reference-bundle",
        "fastq ont-barcode-genotype": "cli.fastq",
        "fastq ont-fluidigm-samples": "cli.fastq",
        "fastq ont-genotype": "cli.fastq",
        "fastq ont-pacbio-barcode-demux": "cli.fastq",
        "fastq orient": "cli.fastq",
        "fastq pbaa-cluster": "cli.fastq.pbaa-cluster",
        "fastq platform": "cli.fastq",
        "fastq primer-remove": "cli.fastq",
        "fastq qc-summary": "cli.fastq",
        "fastq quality-trim": "cli.fastq",
        "fastq repair": "cli.fastq",
        "fastq reverse-complement": "cli.fastq",
        "fastq ribodetector": "cli.fastq",
        "fastq savont-cluster": "cli.fastq.savont-cluster",
        "fastq scout": "cli.fastq",
        "fastq scrub-human": "cli.fastq",
        "fastq search-motif": "cli.fastq",
        "fastq search-text": "cli.fastq",
        "fastq sequence-filter": "cli.fastq",
        "fastq subsample": "cli.fastq",
        "fastq translate": "cli.fastq",
        "fastq trim": "cli.fastq",
        "fetch ena fasta": "cli.fetch",
        "fetch ena reads": "cli.fetch",
        "fetch ena search": "cli.fetch",
        "fetch genome": "cli.fetch",
        "fetch ncbi": "cli.fetch",
        "fetch search": "cli.fetch",
        "fetch sra download": "cli.fetch",
        "fetch sra info": "cli.fetch",
        "fetch sra search": "cli.fetch",
        "freyja demix": "cli.freyja",
        "gatk bqsr": "cli.gatk",
        "gatk collect-metrics": "cli.gatk",
        "gatk filter": "cli.gatk",
        "gatk haplotype-caller": "cli.gatk",
        "gatk joint-genotype": "cli.gatk",
        "gatk leftalign": "cli.gatk",
        "gatk markdup": "cli.gatk",
        "gatk select": "cli.gatk",
        "gatk validate-sam": "cli.gatk",
        "gatk variants-to-table": "cli.gatk",
        "genotype ai-haplotyping": "cli.genotype",
        "genotype apply-annotations": "cli.genotype",
        "genotype export": "cli.genotype",
        "genotype export-labkey": "cli.genotype",
        "genotype export-pivot-xlsx": "cli.genotype",
        "genotype export-xlsx": "cli.genotype",
        "genotype list-cohorts": "cli.genotype",
        "genotype list-samples": "cli.genotype",
        "genotype replay-call-overrides": "cli.genotype",
        "genotype replay-manual-haplotype-assignments": "cli.genotype",
        "genotype replay-matrix-annotation": "cli.genotype",
        "haplotypes bundle-create": "cli.haplotypes",
        "haplotypes bundle-install": "cli.haplotypes",
        "haplotypes bundle-replace-reference": "cli.haplotypes",
        "haplotypes bundle-save": "cli.haplotypes",
        "haplotypes delete": "cli.haplotypes",
        "haplotypes duplicate": "cli.haplotypes",
        "haplotypes export": "cli.haplotypes",
        "haplotypes import": "cli.haplotypes",
        "haplotypes list": "cli.haplotypes",
        "haplotypes save": "cli.haplotypes",
        "haplotypes validate": "cli.haplotypes",
        "help": nil,
        "import application-export": "cli.import",
        "import bam": "cli.import",
        "import cz-id": "cli.import",
        "import esviritu": "cli.import",
        "import fasta": "cli.import",
        "import fastq": "cli.import",
        "import geneious": "cli.import",
        "import kraken2": "cli.import",
        "import metadata": "cli.import",
        "import msa": "cli.import",
        "import nao-mgs": "cli.import",
        "import nvd": "cli.import",
        "import sample-metadata": "cli.import",
        "import taxtriage": "cli.import",
        "import tree": "cli.import",
        "import vcf": "cli.import",
        "import-fastq": "cli.import-fastq",
        "kraken2 classify": "cli.kraken2.classify",
        "map": "cli.map",
        "markdup": "cli.markdup",
        "metadata export": "cli.metadata",
        "metadata export-biosample": "cli.metadata",
        "metadata get": "cli.metadata",
        "metadata import": "cli.metadata",
        "metadata set": "cli.metadata",
        "msa actions": "cli.msa",
        "msa annotate add": "cli.msa",
        "msa annotate delete": "cli.msa",
        "msa annotate edit": "cli.msa",
        "msa annotate project": "cli.msa",
        "msa consensus": "cli.msa",
        "msa describe": "cli.msa",
        "msa discriminating-sites": "cli.msa",
        "msa distance": "cli.msa",
        "msa export": "cli.msa",
        "msa extract": "cli.msa",
        "msa mask columns": "cli.msa",
        "msa trim columns": "cli.msa",
        "nao-mgs import": "cli.nao-mgs",
        "nao-mgs summary": "cli.nao-mgs",
        "nvd import": "cli.nvd",
        "nvd summary": "cli.nvd",
        "ops stats": "cli.ops",
        "orient": "cli.orient",
        "primers analysis annotated-reference": "cli.primers.analysis.annotated-reference",
        "primers analysis audit": "cli.primers.analysis.audit",
        "primers analysis export-order": "cli.primers.analysis.export-order",
        "primers analysis history": "cli.primers.analysis.history",
        "primers analysis inspect": "cli.primers.analysis.inspect",
        "primers design olivar": "cli.primers",
        "primers design primalscheme3": "cli.primers.design.primalscheme3",
        "primers design primer3": "cli.primers.design.primer3",
        "primers design varvamp": "cli.primers",
        "primers import": "cli.primers",
        "primers scheme-from-analysis": "cli.primers",
        "project lock": "cli.project",
        "project migrate": "cli.project",
        "project unlock": "cli.project",
        "provenance bibliography": "cli.provenance",
        "provenance export": "cli.provenance",
        "provenance verify": "cli.provenance",
        "run-headless": "cli.run-headless",
        "search": "cli.search",
        "sequence annotate-orfs": "cli.sequence",
        "sequence delete-annotation-track": "cli.sequence",
        "sequence delete-annotations": "cli.sequence",
        "sequence update-annotation": "cli.sequence",
        "storage dedupe": nil,
        "storage info": nil,
        "taxtriage check-prerequisites": "cli.taxtriage",
        "taxtriage run": "cli.taxtriage",
        "tools update": "cli.tools",
        "translate": "cli.translate",
        "tree export subtree": "cli.tree",
        "tree extract-subtree": "cli.tree",
        "tree infer iqtree": "cli.tree",
        "tree relabel": "cli.tree",
        "tree reroot": "cli.tree",
        "universal-search": "cli.universal-search",
        "variants call": "cli.variants",
        "variants extract-sample": "cli.variants",
        "variants phase": "cli.variants",
        "variants query": "cli.variants",
        "version": nil,
        "workflow list": "cli.workflow",
        "workflow run": "cli.workflow",
        "workflow validate": "cli.workflow",
    ]
}
