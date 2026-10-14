// CLIEventContract.swift - What each lungfish-cli leaf command writes for a machine reader
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One row per leaf command, which is a command with no subcommands. A row is keyed by
// the leaf's path without the root name, such as "msa annotate add". The table is data
// only, and `CLIEventContractCoverageTests` is what gives it force. That suite walks the
// command tree the way `--experimental-dump-help` does and fails when a leaf has no row
// or a row names no leaf, so a lane that adds, renames or removes a command edits this
// file in the same commit. It also checks the help text of each `.events` leaf, decodes
// the checked-in transcripts of each `.events` leaf, and counts the `.legacy` rows.
//
// How a leaf earns each case.
//
//   .events   The leaf prints `CLIEvent` lines (docs/formats/cli-events.md) when its
//             switch is on, or on every run when it has none. Its transcripts live in
//             Tests/Fixtures/cli-events/commands, in a folder named by the path with hyphens.
//   .result   The leaf prints one JSON document to standard output, when its JSON switch
//             is on or on every run. The id names the shape of that document. It is the
//             path with hyphens unless the shape is shared or an inventory id names it.
//   .legacy   The leaf prints a private stream shape that a later sub-phase retires. The
//             id is the Phase 2.6 inventory id in lower case with a short name. A row is
//             deleted, never edited, when its shape goes, and the test that counts the
//             shapes loses the id in the same commit (plan decision S18, no ratchet).
//   .text     The leaf prints human text only, or prints text for a switch it lists. The
//             reason says which, and the same string stands for every leaf in its group.
//
// A leaf that lists `--format json` and prints text anyway is a `.text` row that says so,
// and sub-phases 2.10 to 2.12 settle each of them. The facts behind the rows were read from
// the leaf sources at program commit 7c44460fc.

/// What a leaf command writes for a machine reader (plan decision S18).
package enum CLIEventContract: Sendable, Equatable {
    /// Emits `CLIEvent` lines. `flag` is the switch that turns them on
    /// (`--format json`, or ``CLIEventContractTable/alwaysOn`` for a leaf that prints them
    /// on every run),
    /// and `channel` is where they go.
    case events(flag: String, channel: Channel)
    /// Prints one JSON result object, named by a schema id, not a Swift type,
    /// because some decode in App (architecture correction 8).
    case result(schemaID: String)
    /// A private stream shape still in use, with the sub-phase that retires it.
    case legacy(schemaID: String, removeBy: String)
    /// Human text only, with the reason.
    case text(reason: String)

    package enum Channel: String, Sendable { case standardOutput, standardError }
}

/// The contract of every leaf command of `lungfish-cli`.
package enum CLIEventContractTable {
    /// One entry per leaf command, keyed by its path without the root,
    /// for example "msa annotate add". `help` is the subcommand that ArgumentParser
    /// adds to the root, which `--experimental-dump-help` lists as a leaf.
    package static let entries: [String: CLIEventContract] = {
        var all: [String: CLIEventContract] = [:]
        for group in [events, results, legacy, text] {
            for (path, contract) in group {
                precondition(all.updateValue(contract, forKey: path) == nil, "Two contract rows for \(path)")
            }
        }
        return all
    }()

    // MARK: Switches and reasons

    private static let formatJSON = "--format json"
    /// The two ONT FASTQ commands print events on every run, with no switch, because the FASTQ
    /// operations dialog runs them without `--format json`. Its runner reads the channel each row names.
    package static let alwaysOn = "no switch, every run"
    private static let ignoresFormat = "lists --format json and ignores it, 2.10 to 2.12"
    private static let humanTextOnly = "text output only, lists no machine switch"
    private static let exportFormat = "its --format names an export file format, not machine output"
    private static let helpCommand = "the help subcommand that ArgumentParser adds to the root, human text only"

    // MARK: Leaves that emit events (59)

    private static let events: [String: CLIEventContract] = [
        "align mafft": .events(flag: formatJSON, channel: .standardOutput),
        // `--json-events` is a hidden alias since 2.10 (lane A46, decision C7).
        "assemble": .events(flag: formatJSON, channel: .standardOutput),
        "bam annotate": .events(flag: formatJSON, channel: .standardOutput),
        "bam consensus": .events(flag: formatJSON, channel: .standardOutput),
        "bam filter": .events(flag: formatJSON, channel: .standardOutput),
        "bam primer-trim": .events(flag: formatJSON, channel: .standardOutput),
        "bam remove-track": .events(flag: formatJSON, channel: .standardOutput),
        "build-db esviritu": .events(flag: formatJSON, channel: .standardOutput),
        "build-db kraken2": .events(flag: formatJSON, channel: .standardOutput),
        "build-db taxtriage": .events(flag: formatJSON, channel: .standardOutput),
        "bundle deduplicate-alignments": .events(flag: formatJSON, channel: .standardOutput),
        "bundle mark-duplicates": .events(flag: formatJSON, channel: .standardOutput),
        "conda classify": .events(flag: formatJSON, channel: .standardOutput),
        "conda db update": .events(flag: formatJSON, channel: .standardOutput),
        "conda install": .events(flag: formatJSON, channel: .standardOutput),
        "demo fetch": .events(flag: formatJSON, channel: .standardOutput),
        "esviritu detect": .events(flag: formatJSON, channel: .standardOutput),
        "extract reads": .events(flag: formatJSON, channel: .standardOutput),
        "fastq import-ont": .events(flag: formatJSON, channel: .standardOutput),
        "fastq ingest": .events(flag: formatJSON, channel: .standardOutput),
        "fastq ont-fluidigm-samples": .events(flag: alwaysOn, channel: .standardError),
        "fastq ont-pacbio-barcode-demux": .events(flag: alwaysOn, channel: .standardError),
        "fastq platform": .events(flag: formatJSON, channel: .standardOutput),
        "fetch genome": .events(flag: formatJSON, channel: .standardOutput),
        "fetch ncbi": .events(flag: formatJSON, channel: .standardOutput),
        "fetch pathoplexus": .events(flag: formatJSON, channel: .standardOutput),
        "fetch sra download": .events(flag: formatJSON, channel: .standardOutput),
        "import application-export": .events(flag: formatJSON, channel: .standardOutput),
        "import fastq": .events(flag: formatJSON, channel: .standardOutput),
        "import geneious": .events(flag: formatJSON, channel: .standardOutput),
        "import msa": .events(flag: formatJSON, channel: .standardOutput),
        "import tree": .events(flag: formatJSON, channel: .standardOutput),
        "import-fastq": .events(flag: formatJSON, channel: .standardOutput),
        "kraken2 classify": .events(flag: formatJSON, channel: .standardOutput),
        "map": .events(flag: formatJSON, channel: .standardOutput),
        "msa annotate add": .events(flag: formatJSON, channel: .standardOutput),
        "msa annotate delete": .events(flag: formatJSON, channel: .standardOutput),
        "msa annotate edit": .events(flag: formatJSON, channel: .standardOutput),
        "msa annotate project": .events(flag: formatJSON, channel: .standardOutput),
        "msa consensus": .events(flag: formatJSON, channel: .standardOutput),
        "msa discriminating-sites": .events(flag: formatJSON, channel: .standardOutput),
        "msa distance": .events(flag: formatJSON, channel: .standardOutput),
        "msa export": .events(flag: formatJSON, channel: .standardOutput),
        "msa extract": .events(flag: formatJSON, channel: .standardOutput),
        "msa mask columns": .events(flag: formatJSON, channel: .standardOutput),
        "msa trim columns": .events(flag: formatJSON, channel: .standardOutput),
        "sequence add-annotation": .events(flag: formatJSON, channel: .standardOutput),
        "sequence attach-track": .events(flag: formatJSON, channel: .standardOutput),
        "taxtriage run": .events(flag: formatJSON, channel: .standardOutput),
        "tools update": .events(flag: formatJSON, channel: .standardOutput),
        "tree export subtree": .events(flag: formatJSON, channel: .standardOutput),
        "tree extract-subtree": .events(flag: formatJSON, channel: .standardOutput),
        "tree infer iqtree": .events(flag: formatJSON, channel: .standardOutput),
        "tree relabel": .events(flag: formatJSON, channel: .standardOutput),
        "tree reroot": .events(flag: formatJSON, channel: .standardOutput),
        "variants call": .events(flag: formatJSON, channel: .standardOutput),
        "variants delete": .events(flag: formatJSON, channel: .standardOutput),
        "variants import-sample-metadata": .events(flag: formatJSON, channel: .standardOutput),
        "workflow run": .events(flag: formatJSON, channel: .standardOutput),
    ]

    // MARK: Leaves that print one JSON result (65)

    private static let results: [String: CLIEventContract] = [
        "analyze composition": .result(schemaID: "analyze-composition"),
        "analyze stats": .result(schemaID: "analyze-stats"),
        "analyze validate": .result(schemaID: "analyze-validate"),
        "bam markdup": .result(schemaID: "markdup-summary"),
        "blast verify": .result(schemaID: "blast-verify"),
        "bundle create": .result(schemaID: "bundle-create"),
        "bundle info": .result(schemaID: "bundle-info"),
        "bundle list": .result(schemaID: "bundle-list"),
        "bundle validate": .result(schemaID: "bundle-validate"),
        "convert": .result(schemaID: "convert"),
        "cz-id summary": .result(schemaID: "cz-id-summary"),
        "debug container": .result(schemaID: "debug-container"),
        "debug env": .result(schemaID: "debug-env"),
        "debug fastq-ingest": .result(schemaID: "debug-fastq-ingest"),
        "demo info": .result(schemaID: "demo-info"),
        "demo list": .result(schemaID: "demo-list"),
        "extract sequence": .result(schemaID: "extract-sequence"),
        "fastq genotype": .result(schemaID: "r5-genotype-cohort-report"),
        "fastq genotype-cohort": .result(schemaID: "r5-genotype-cohort-report"),
        "fastq ont-genotype": .result(schemaID: "fastq-ont-genotype"),
        "fastq pbaa-cluster": .result(schemaID: "fastq-pbaa-cluster"),
        "fastq savont-cluster": .result(schemaID: "fastq-savont-cluster"),
        "fetch ena fasta": .result(schemaID: "fetch-ena-fasta"),
        "fetch ena reads": .result(schemaID: "fetch-ena-reads"),
        "fetch ena search": .result(schemaID: "fetch-ena-search"),
        "fetch search": .result(schemaID: "fetch-search"),
        "fetch sra info": .result(schemaID: "fetch-sra-info"),
        "fetch sra search": .result(schemaID: "fetch-sra-search"),
        "genotype ai-haplotyping": .result(schemaID: "genotype-ai-haplotyping"),
        "genotype apply-annotations": .result(schemaID: "genotype-apply-annotations"),
        "genotype export": .result(schemaID: "genotype-export"),
        "genotype export-labkey": .result(schemaID: "genotype-export-labkey"),
        "genotype export-pivot-xlsx": .result(schemaID: "genotype-export-pivot-xlsx"),
        "genotype export-xlsx": .result(schemaID: "genotype-export-xlsx"),
        "haplotypes bundle-create": .result(schemaID: "haplotypes-bundle-create"),
        "haplotypes bundle-install": .result(schemaID: "haplotypes-bundle-install"),
        "haplotypes bundle-replace-reference": .result(schemaID: "haplotypes-bundle-replace-reference"),
        "haplotypes bundle-save": .result(schemaID: "haplotypes-write"),
        "haplotypes delete": .result(schemaID: "haplotypes-delete"),
        "haplotypes duplicate": .result(schemaID: "haplotypes-write"),
        "haplotypes export": .result(schemaID: "haplotypes-export"),
        "haplotypes import": .result(schemaID: "haplotypes-write"),
        "haplotypes list": .result(schemaID: "haplotypes-list"),
        "haplotypes save": .result(schemaID: "haplotypes-write"),
        "haplotypes validate": .result(schemaID: "haplotypes-validate"),
        "import sample-metadata": .result(schemaID: "import-sample-metadata"),
        "markdup": .result(schemaID: "markdup-summary"),
        "metadata export": .result(schemaID: "metadata-export"),
        "metadata get": .result(schemaID: "metadata-get"),
        "metadata import": .result(schemaID: "metadata-import"),
        "metadata set": .result(schemaID: "metadata-set"),
        "msa actions": .result(schemaID: "msa-actions"),
        "msa describe": .result(schemaID: "msa-describe"),
        "nao-mgs summary": .result(schemaID: "nao-mgs-summary"),
        "nvd summary": .result(schemaID: "nvd-summary"),
        "primers analysis inspect": .result(schemaID: "primers-analysis-inspect"),
        "project lock": .result(schemaID: "project-lock"),
        "project migrate": .result(schemaID: "project-migrate"),
        "project unlock": .result(schemaID: "project-unlock"),
        "search": .result(schemaID: "search"),
        "storage dedupe": .result(schemaID: "storage-dedupe"),
        "storage info": .result(schemaID: "storage-info"),
        "translate": .result(schemaID: "translate"),
        "universal-search": .result(schemaID: "universal-search"),
        "workflow validate": .result(schemaID: "workflow-validate"),
    ]

    // MARK: Private stream shapes still in use (7 leaves)

    // `fastq genotype`, `genotype-cohort`, `ont-barcode-genotype` and `full-length-ont-mhc-genotype`
    // also print R3 on standard error beside their document, so the lane that retires R3 converts
    // all six leaves.
    private static let legacy: [String: CLIEventContract] = [
        "bam annotate-best": .legacy(schemaID: "s12-bam-annotate-best", removeBy: "2.9"),
        "bam annotate-cds-best": .legacy(schemaID: "s13-bam-annotate-cds-best", removeBy: "2.9"),
        "extract contigs": .legacy(schemaID: "r4-reference-bundle-path-line", removeBy: "2.9"),
        "fastq 12s-match": .legacy(schemaID: "r3-twelve-s-progress-text", removeBy: "2.8"),
        "fastq 12s-reference-bundle": .legacy(schemaID: "r3-twelve-s-progress-text", removeBy: "2.8"),
        "fastq full-length-ont-mhc-genotype": .legacy(schemaID: "r2-full-length-ont-mhc", removeBy: "2.8"),
        "fastq ont-barcode-genotype": .legacy(schemaID: "r1-ont-barcode-genotyping", removeBy: "2.8"),
    ]

    // MARK: Leaves with human text only (114)

    private static let text: [String: CLIEventContract] = [
        "bam adopt-mapping": .text(reason: ignoresFormat),
        "bundle export": .text(reason: humanTextOnly),
        "bundle extract-annotations": .text(reason: ignoresFormat),
        "conda db download": .text(reason: ignoresFormat),
        "conda db info": .text(reason: ignoresFormat),
        "conda db install-managed": .text(reason: ignoresFormat),
        "conda db list": .text(reason: ignoresFormat),
        "conda db recommend": .text(reason: ignoresFormat),
        "conda db remove": .text(reason: ignoresFormat),
        "conda envs": .text(reason: ignoresFormat),
        "conda export-pack": .text(reason: ignoresFormat),
        "conda extract": .text(reason: ignoresFormat),
        "conda list": .text(reason: ignoresFormat),
        "conda lock": .text(reason: ignoresFormat),
        "conda offline-export": .text(reason: ignoresFormat),
        "conda offline-install": .text(reason: ignoresFormat),
        "conda packs": .text(reason: ignoresFormat),
        "conda remove": .text(reason: ignoresFormat),
        "conda run": .text(reason: ignoresFormat),
        "conda search": .text(reason: ignoresFormat),
        "conda setup": .text(reason: ignoresFormat),
        "cz-id import": .text(reason: ignoresFormat),
        "debug resource-smoke": .text(reason: humanTextOnly),
        "debug workflow-log": .text(reason: ignoresFormat),
        "esviritu db-status": .text(reason: ignoresFormat),
        "esviritu download-db": .text(reason: ignoresFormat),
        "fastq 12s-export": .text(reason: humanTextOnly),
        "fastq 12s-export-unresolved": .text(reason: humanTextOnly),
        "fastq 12s-reference-metadata": .text(reason: humanTextOnly),
        "fastq adapter-trim": .text(reason: humanTextOnly),
        "fastq contaminant-filter": .text(reason: humanTextOnly),
        "fastq deacon-ribo": .text(reason: ignoresFormat),
        "fastq deduplicate": .text(reason: humanTextOnly),
        "fastq deinterleave": .text(reason: humanTextOnly),
        "fastq demultiplex": .text(reason: ignoresFormat),
        "fastq entropy-filter": .text(reason: ignoresFormat),
        "fastq error-correct": .text(reason: humanTextOnly),
        "fastq fixed-trim": .text(reason: humanTextOnly),
        "fastq interleave": .text(reason: humanTextOnly),
        "fastq length-filter": .text(reason: humanTextOnly),
        "fastq materialize": .text(reason: humanTextOnly),
        "fastq merge": .text(reason: humanTextOnly),
        "fastq mhc-reference-bundle": .text(reason: humanTextOnly),
        "fastq orient": .text(reason: humanTextOnly),
        "fastq primer-remove": .text(reason: humanTextOnly),
        "fastq qc-summary": .text(reason: humanTextOnly),
        "fastq quality-trim": .text(reason: humanTextOnly),
        "fastq repair": .text(reason: humanTextOnly),
        "fastq reverse-complement": .text(reason: humanTextOnly),
        "fastq ribodetector": .text(reason: ignoresFormat),
        "fastq scout": .text(reason: ignoresFormat),
        "fastq scrub-human": .text(reason: humanTextOnly),
        "fastq search-motif": .text(reason: humanTextOnly),
        "fastq search-text": .text(reason: humanTextOnly),
        "fastq sequence-filter": .text(reason: humanTextOnly),
        "fastq subsample": .text(reason: humanTextOnly),
        "fastq translate": .text(reason: humanTextOnly),
        "fastq trim": .text(reason: humanTextOnly),
        "freyja demix": .text(reason: humanTextOnly),
        "gatk bqsr": .text(reason: humanTextOnly),
        "gatk collect-metrics": .text(reason: humanTextOnly),
        "gatk filter": .text(reason: humanTextOnly),
        "gatk haplotype-caller": .text(reason: humanTextOnly),
        "gatk joint-genotype": .text(reason: humanTextOnly),
        "gatk leftalign": .text(reason: humanTextOnly),
        "gatk markdup": .text(reason: humanTextOnly),
        "gatk select": .text(reason: humanTextOnly),
        "gatk validate-sam": .text(reason: humanTextOnly),
        "gatk variants-to-table": .text(reason: humanTextOnly),
        "genotype list-cohorts": .text(reason: humanTextOnly),
        "genotype list-samples": .text(reason: humanTextOnly),
        "genotype replay-call-overrides": .text(reason: humanTextOnly),
        "genotype replay-manual-haplotype-assignments": .text(reason: humanTextOnly),
        "genotype replay-matrix-annotation": .text(reason: humanTextOnly),
        "help": .text(reason: helpCommand),
        "import bam": .text(reason: ignoresFormat),
        "import cz-id": .text(reason: ignoresFormat),
        "import esviritu": .text(reason: ignoresFormat),
        "import fasta": .text(reason: ignoresFormat),
        "import kraken2": .text(reason: ignoresFormat),
        "import metadata": .text(reason: ignoresFormat),
        "import nao-mgs": .text(reason: ignoresFormat),
        "import nvd": .text(reason: ignoresFormat),
        "import taxtriage": .text(reason: ignoresFormat),
        "import vcf": .text(reason: ignoresFormat),
        "metadata export-biosample": .text(reason: ignoresFormat),
        "nao-mgs import": .text(reason: ignoresFormat),
        "nvd import": .text(reason: ignoresFormat),
        "ops stats": .text(reason: ignoresFormat),
        "orient": .text(reason: ignoresFormat),
        "primers analysis annotated-reference": .text(reason: humanTextOnly),
        "primers analysis audit": .text(reason: humanTextOnly),
        "primers analysis export-order": .text(reason: humanTextOnly),
        "primers analysis history": .text(reason: humanTextOnly),
        "primers design olivar": .text(reason: humanTextOnly),
        "primers design primalscheme3": .text(reason: humanTextOnly),
        "primers design primer3": .text(reason: humanTextOnly),
        "primers design varvamp": .text(reason: humanTextOnly),
        "primers import": .text(reason: humanTextOnly),
        "primers scheme-from-analysis": .text(reason: humanTextOnly),
        "provenance bibliography": .text(reason: humanTextOnly),
        "provenance export": .text(reason: exportFormat),
        "provenance verify": .text(reason: humanTextOnly),
        "run-headless": .text(reason: humanTextOnly),
        "sequence annotate-orfs": .text(reason: ignoresFormat),
        "sequence delete-annotation-track": .text(reason: ignoresFormat),
        "sequence delete-annotations": .text(reason: ignoresFormat),
        "sequence update-annotation": .text(reason: ignoresFormat),
        "taxtriage check-prerequisites": .text(reason: ignoresFormat),
        "variants extract-sample": .text(reason: ignoresFormat),
        "variants phase": .text(reason: ignoresFormat),
        "variants query": .text(reason: ignoresFormat),
        "version": .text(reason: humanTextOnly),
        "workflow list": .text(reason: ignoresFormat),
    ]
}
