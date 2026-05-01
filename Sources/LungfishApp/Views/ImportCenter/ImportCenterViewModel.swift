// ImportCenterViewModel.swift - View model for the Import Center
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import UniformTypeIdentifiers
import LungfishCore
import os.log
import Observation

/// Logger for the Import Center view model.
private let logger = Logger(subsystem: LogSubsystem.app, category: "ImportCenterVM")

// MARK: - Import History Entry

/// A persisted record of a single completed (or failed) import operation.
struct ImportHistoryEntry: Identifiable, Sendable, Codable {
    let id: UUID
    /// Human-readable label matching the import action, e.g. "BAM", "VCF", "NAO-MGS".
    let importAction: String
    /// The last path component of the imported file (or the first file, if multiple).
    let fileName: String
    /// When the import was dispatched.
    let date: Date
    /// Whether the import was dispatched without error. False entries are recorded
    /// when dispatch failed before reaching the app delegate.
    let succeeded: Bool
}

// MARK: - Import Card Info

/// Describes a single importable data type shown as a card in the Import Center.
struct ImportCardInfo: Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let sfSymbol: String
    /// Optional custom badge image (e.g. TextBadgeIcon) that replaces the SF Symbol.
    let customImage: NSImage?
    let fileHint: String?

    init(id: String, title: String, description: String, sfSymbol: String,
         customImage: NSImage? = nil, fileHint: String? = nil,
         tab: ImportCenterViewModel.Tab, importKind: ImportKind) {
        self.id = id
        self.title = title
        self.description = description
        self.sfSymbol = sfSymbol
        self.customImage = customImage
        self.fileHint = fileHint
        self.tab = tab
        self.importKind = importKind
    }
    let tab: ImportCenterViewModel.Tab
    let importKind: ImportKind

    struct OpenPanelConfiguration: Sendable {
        let allowedTypes: [UTType]?
        let canChooseFiles: Bool
        let canChooseDirectories: Bool
        let allowsMultipleSelection: Bool
        let allowsOtherFileTypes: Bool

        init(
            allowedTypes: [UTType]? = nil,
            canChooseFiles: Bool = true,
            canChooseDirectories: Bool = false,
            allowsMultipleSelection: Bool = true,
            allowsOtherFileTypes: Bool = false
        ) {
            self.allowedTypes = allowedTypes
            self.canChooseFiles = canChooseFiles
            self.canChooseDirectories = canChooseDirectories
            self.allowsMultipleSelection = allowsMultipleSelection
            self.allowsOtherFileTypes = allowsOtherFileTypes
        }
    }

    /// The kind of import action to perform when the user clicks "Import...".
    enum ImportKind: Sendable {
        /// Open a file panel with the given UTTypes and forward to the app delegate.
        case openPanel(configuration: OpenPanelConfiguration, action: ImportAction)
        /// Open a custom wizard sheet (e.g. NAO-MGS).
        case wizardSheet(action: ImportAction)
    }

    /// Identifies which import action to dispatch.
    enum ImportAction: Sendable {
        case fastq
        case ontRun
        case bam
        case vcf
        case fasta
        case annotationTrack
        case geneiousExport
        case clcWorkbenchExport
        case dnastarLasergeneExport
        case benchlingBulkExport
        case sequenceDesignLibraryExport
        case alignmentTreeExport
        case sequencingPlatformRunFolder
        case phylogeneticsResultSet
        case qiime2Archive
        case igvSessionTrackSet
        case bundleSampleMetadata
        case projectSampleMetadata
        case naoMgs
        case kraken2
        case esViritu
        case taxTriage
        case nvd
        case primerScheme
    }

    /// The underlying ``ImportAction`` regardless of whether the card uses a
    /// file panel or a wizard sheet.
    var importAction: ImportAction {
        switch importKind {
        case .openPanel(_, let action):  return action
        case .wizardSheet(let action):   return action
        }
    }
}

// MARK: - View Model

/// View model for the Import Center window.
///
/// Manages section state, import history, and the static catalog of importable
/// data types. All state is ``@MainActor``-isolated and uses ``@Observable``
/// for automatic SwiftUI invalidation.
@MainActor
@Observable
final class ImportCenterViewModel {

    // MARK: - Tab

    /// The sections of the Import Center.
    enum Tab: Int, CaseIterable, Hashable, Sendable {
        case sequencingReads
        case alignments
        case variants
        case classificationResults
        case references
        case applicationExports

        /// Human-readable tab title for the segmented control.
        var title: String {
            switch self {
            case .sequencingReads:       return "Sequencing Reads"
            case .alignments:            return "Alignments"
            case .variants:              return "Variants"
            case .classificationResults: return "Classification Results"
            case .references:            return "Reference Sequences"
            case .applicationExports:    return "Application Exports"
            }
        }

        /// SF Symbol for the tab.
        var sfSymbol: String {
            switch self {
            case .sequencingReads:       return "waveform.path"
            case .alignments:            return "arrow.left.arrow.right"
            case .variants:              return "diamond.fill"
            case .classificationResults: return "chart.bar.doc.horizontal"
            case .references:            return "doc.text"
            case .applicationExports:    return "shippingbox"
            }
        }

        /// Maps to the segmented control index.
        var segmentIndex: Int { rawValue }

        /// Creates a tab from a segmented control index.
        static func from(segmentIndex: Int) -> Tab {
            Tab(rawValue: segmentIndex) ?? .sequencingReads
        }
    }

    // MARK: - State

    /// Currently selected tab.
    var selectedTab: Tab = .sequencingReads

    // MARK: - Import History

    /// Persisted log of recent import operations (newest first, capped at 50).
    var importHistory: [ImportHistoryEntry] = []

    /// UserDefaults key used to persist import history.
    private static let historyDefaultsKey = "importHistory"
    /// Maximum number of history entries retained in UserDefaults.
    private static let maxHistoryEntries = 50

    /// The last 10 history entries whose ``importAction`` matches any action
    /// associated with the currently selected tab.
    var recentHistory: [ImportHistoryEntry] {
        let tabActions = tabImportActions(for: selectedTab)
        return importHistory
            .filter { tabActions.contains($0.importAction) }
            .prefix(10)
            .map { $0 }
    }

    /// Returns the string labels used in ``ImportHistoryEntry/importAction``
    /// for all cards belonging to the given tab.
    private func tabImportActions(for tab: Tab) -> Set<String> {
        let actions = allCards
            .filter { $0.tab == tab }
            .map { historyLabel(for: $0.importAction) }
        return Set(actions)
    }

    // MARK: - Card Catalog

    private static func importContentTypes(_ extensions: [String]) -> [UTType] {
        extensions.map { UTType(filenameExtension: $0) ?? .data } + [.folder]
    }

    /// All importable data type cards, organized by tab.
    let allCards: [ImportCardInfo] = [
        // Sequencing Reads
        ImportCardInfo(
            id: "fastq",
            title: "FASTQ Files",
            description: "Import paired-end or single-end sequencing reads. Supports individual files and folders with automatic pair detection.",
            sfSymbol: "waveform.path",
            fileHint: ".fastq.gz, .fq.gz, .fastq, .fq (files or folders)",
            tab: .sequencingReads,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "gz") ?? .data,
                        UTType(filenameExtension: "fastq") ?? .data,
                        UTType(filenameExtension: "fq") ?? .data,
                        .folder,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: true
                ),
                action: .fastq
            )
        ),
        ImportCardInfo(
            id: "ont-run",
            title: "ONT Run Folder",
            description: "Import an Oxford Nanopore run folder, including fastq_pass or individual barcode folders, into per-barcode FASTQ bundles.",
            sfSymbol: "dot.radiowaves.left.and.right",
            fileHint: "fastq_pass/ or barcode folder",
            tab: .sequencingReads,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: nil,
                    canChooseFiles: false,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .ontRun
            )
        ),

        // Alignments
        ImportCardInfo(
            id: "bam-cram",
            title: "BAM/CRAM Alignments",
            description: "Import aligned reads from BAM or CRAM files into the current dataset for alignment visualization.",
            sfSymbol: "arrow.left.arrow.right",
            fileHint: ".bam, .cram",
            tab: .alignments,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "bam") ?? .data,
                        UTType(filenameExtension: "cram") ?? .data,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    allowsMultipleSelection: true
                ),
                action: .bam
            )
        ),

        // Variants
        ImportCardInfo(
            id: "vcf",
            title: "VCF Variants",
            description: "Import variant calls from VCF files. Supports plain text and gzipped VCF with tabix indices.",
            sfSymbol: "diamond.fill",
            fileHint: ".vcf, .vcf.gz",
            tab: .variants,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "vcf") ?? .data,
                        UTType(filenameExtension: "gz") ?? .data,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    allowsMultipleSelection: true
                ),
                action: .vcf
            )
        ),
        // Classification Results
        ImportCardInfo(
            id: "nao-mgs",
            title: "NAO-MGS Results",
            description: "Import NAO metagenomic surveillance results. Parses virus_hits_final.tsv.gz or _virus_hits.tsv.gz files for taxonomic visualization.",
            sfSymbol: "n.circle",
            customImage: TextBadgeIcon.image(text: "NM", size: NSSize(width: 28, height: 28)),
            fileHint: "virus_hits_final.tsv.gz or _virus_hits.tsv.gz",
            tab: .classificationResults,
            importKind: .wizardSheet(action: .naoMgs)
        ),
        ImportCardInfo(
            id: "kraken2",
            title: "Kraken2 Results",
            description: "Import Kraken2 classification reports and Bracken abundance profiles for taxonomic composition analysis.",
            sfSymbol: "k.circle",
            fileHint: ".kreport, .kreport2, .bracken",
            tab: .classificationResults,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "kreport") ?? .data,
                        UTType(filenameExtension: "kreport2") ?? .data,
                        UTType(filenameExtension: "bracken") ?? .data,
                        UTType(filenameExtension: "txt") ?? .data,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    allowsMultipleSelection: true
                ),
                action: .kraken2
            )
        ),
        ImportCardInfo(
            id: "esviritu",
            title: "EsViritu Results",
            description: "Import EsViritu viral detection results for rapid virome characterization and visualization.",
            sfSymbol: "e.circle",
            customImage: TextBadgeIcon.image(text: "ES", size: NSSize(width: 28, height: 28)),
            fileHint: "EsViritu output directory",
            tab: .classificationResults,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "tsv") ?? .data,
                        UTType(filenameExtension: "txt") ?? .data,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: true
                ),
                action: .esViritu
            )
        ),
        ImportCardInfo(
            id: "taxtriage",
            title: "TaxTriage Results",
            description: "Import TaxTriage clinical triage reports for pathogen identification and abundance profiling.",
            sfSymbol: "t.circle",
            fileHint: "TaxTriage output directory",
            tab: .classificationResults,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "tsv") ?? .data,
                        UTType(filenameExtension: "csv") ?? .data,
                        UTType(filenameExtension: "txt") ?? .data,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: true
                ),
                action: .taxTriage
            )
        ),
        ImportCardInfo(
            id: "nvd",
            title: "NVD Results",
            description: "Import Novel Virus Diagnostics (NVD) classification results. Parses blast_concatenated.csv or .csv.gz with BLAST hit rankings and mapped reads.",
            sfSymbol: "microscope",
            customImage: TextBadgeIcon.image(text: "NVD", size: NSSize(width: 28, height: 28)),
            fileHint: "*_blast_concatenated.csv(.gz)",
            tab: .classificationResults,
            importKind: .wizardSheet(action: .nvd)
        ),

        // References
        ImportCardInfo(
            id: "fasta",
            title: "Reference Sequences",
            description: "Import standalone reference sequence files as .lungfishref bundles. Supports FASTA/GenBank/EMBL with .gz/.bgz/.bz2/.xz/.zst wrappers.",
            sfSymbol: "doc.text",
            fileHint: ".fa, .fasta, .fna, .faa, .ffn, .frn, .gb, .gbk, .gbff, .genbank, .embl (+ .gz/.bgz/.bz2/.xz/.zst)",
            tab: .references,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "fa") ?? .data,
                        UTType(filenameExtension: "fasta") ?? .data,
                        UTType(filenameExtension: "fna") ?? .data,
                        UTType(filenameExtension: "faa") ?? .data,
                        UTType(filenameExtension: "ffn") ?? .data,
                        UTType(filenameExtension: "frn") ?? .data,
                        UTType(filenameExtension: "fas") ?? .data,
                        UTType(filenameExtension: "fsa") ?? .data,
                        UTType(filenameExtension: "gb") ?? .data,
                        UTType(filenameExtension: "gbk") ?? .data,
                        UTType(filenameExtension: "gbff") ?? .data,
                        UTType(filenameExtension: "genbank") ?? .data,
                        UTType(filenameExtension: "embl") ?? .data,
                        UTType(filenameExtension: "gz") ?? .data,
                        UTType(filenameExtension: "gzip") ?? .data,
                        UTType(filenameExtension: "bgz") ?? .data,
                        UTType(filenameExtension: "bz2") ?? .data,
                        UTType(filenameExtension: "xz") ?? .data,
                        UTType(filenameExtension: "zst") ?? .data,
                        UTType(filenameExtension: "zstd") ?? .data,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    allowsMultipleSelection: true
                ),
                action: .fasta
            )
        ),
        ImportCardInfo(
            id: "annotation-track",
            title: "Annotation Track",
            description: "Attach GTF, GFF, GFF3, or BED annotations to an existing reference sequence bundle.",
            sfSymbol: "list.bullet.rectangle",
            fileHint: ".gtf, .gff, .gff3, .bed",
            tab: .references,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "gtf") ?? .data,
                        UTType(filenameExtension: "gff") ?? .data,
                        UTType(filenameExtension: "gff3") ?? .data,
                        UTType(filenameExtension: "bed") ?? .data,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    allowsMultipleSelection: true
                ),
                action: .annotationTrack
            )
        ),
        ImportCardInfo(
            id: "geneious-export",
            title: "Geneious Export",
            description: "Import a Geneious archive or export folder into one Lungfish project collection with native bundles and preserved artifacts.",
            sfSymbol: "shippingbox",
            fileHint: ".geneious archive or Geneious export folder",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "geneious") ?? .data,
                        .folder,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .geneiousExport
            )
        ),
        ImportCardInfo(
            id: "clc-workbench-export",
            title: "CLC Workbench Export",
            description: "Import a CLC Workbench export folder, archive, or native project file into an LGE collection with parseable references and preserved artifacts.",
            sfSymbol: "shippingbox",
            fileHint: ".zip, .clc, FASTA/FASTQ, GenBank, BAM/CRAM, VCF, GFF/GTF, Newick/NEXUS",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes([
                        "zip", "clc", "fa", "fasta", "fastq", "fq", "gb", "gbk", "embl", "bam", "cram", "sam",
                        "vcf", "gff", "gff3", "gtf", "bed", "wig", "bw", "nex", "nexus", "nwk", "newick",
                    ]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .clcWorkbenchExport
            )
        ),
        ImportCardInfo(
            id: "dnastar-lasergene-export",
            title: "DNASTAR Lasergene Export",
            description: "Import modern Lasergene or GenVision standard exports while preserving native project files that LGE cannot decode directly.",
            sfSymbol: "shippingbox",
            fileHint: ".zip, .seq, .pro, .sbd, .gvp, FASTA, GenBank, EMBL, BAM, VCF, GFF",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes([
                        "zip", "seq", "pro", "sbd", "gvp", "fa", "fasta", "fas", "gb", "gbk", "embl",
                        "bam", "vcf", "gff", "gff3", "txt",
                    ]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .dnastarLasergeneExport
            )
        ),
        ImportCardInfo(
            id: "benchling-bulk-export",
            title: "Benchling Bulk Export",
            description: "Import Benchling ZIP exports, GenBank, Multi-FASTA, CSV metadata, SVG maps, and SBOL RDF as a project migration collection.",
            sfSymbol: "shippingbox",
            fileHint: ".zip, .gb, .gbk, .fasta, .fa, .csv, .svg, .rdf",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes(["zip", "gb", "gbk", "genbank", "fa", "fasta", "csv", "svg", "rdf"]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .benchlingBulkExport
            )
        ),
        ImportCardInfo(
            id: "sequence-design-library-export",
            title: "Sequence Design Library Export",
            description: "Import sequence library exports from SnapGene, Vector NTI, MacVector, and similar tools using standard files where available.",
            sfSymbol: "square.stack.3d.up",
            fileHint: ".zip, GenBank, FASTA, EMBL, DDBJ, GCG, .dna, Vector NTI archives",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes([
                        "zip", "dna", "gb", "gbk", "genbank", "fa", "fasta", "embl", "ddbj", "gcg",
                        "ma4", "pa4", "oa4", "ga4", "ba6", "csv",
                    ]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .sequenceDesignLibraryExport
            )
        ),
        ImportCardInfo(
            id: "alignment-tree-export",
            title: "Alignment and Tree Export",
            description: "Inventory and preserve MSA and tree exports from MEGA, Jalview, UGENE, MacVector, CLC, and Geneious for future native viewers.",
            sfSymbol: "point.3.connected.trianglepath.dotted",
            fileHint: ".aln, .msf, .stockholm, .phylip, .nexus, .mega, .nwk, .newick",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes([
                        "zip", "aln", "clustal", "msf", "sto", "stockholm", "phy", "phylip", "nex", "nexus",
                        "mega", "nwk", "newick", "tree", "tre", "svg", "pdf", "html",
                    ]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .alignmentTreeExport
            )
        ),
        ImportCardInfo(
            id: "sequencing-platform-run-folder",
            title: "Sequencing Platform Run Folder",
            description: "Import platform run folders from Illumina, Oxford Nanopore, PacBio, or Ion Torrent while preserving run metadata and raw-signal artifacts.",
            sfSymbol: "externaldrive.connected.to.line.below",
            fileHint: "Run folder, .zip, FASTQ, BAM/CRAM/SAM, VCF/gVCF, POD5, XML/CSV/JSON reports",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes([
                        "zip", "fastq", "fq", "gz", "bam", "cram", "sam", "vcf", "gvcf", "bcf",
                        "bed", "gff", "csv", "tsv", "json", "xml", "pod5", "fast5", "pbi",
                    ]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .sequencingPlatformRunFolder
            )
        ),
        ImportCardInfo(
            id: "phylogenetics-result-set",
            title: "Phylogenetics Result Set",
            description: "Preserve Nextclade, Nextstrain, UShER, Taxonium, and related result folders without reducing rich tree metadata to plain Newick.",
            sfSymbol: "tree",
            fileHint: ".zip, aligned FASTA, TSV/CSV, JSON/NDJSON, Auspice JSON, Newick, .pb, .jsonl",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes([
                        "zip", "fa", "fasta", "tsv", "csv", "json", "ndjson", "jsonl", "gz", "nwk",
                        "newick", "pb", "mat", "trees",
                    ]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .phylogeneticsResultSet
            )
        ),
        ImportCardInfo(
            id: "qiime2-archive",
            title: "QIIME 2 Archive",
            description: "Import QIIME 2 archives and exported folders into a preserved collection while routing compatible FASTA, Newick, and TSV files.",
            sfSymbol: "archivebox",
            fileHint: ".qza, .qzv, .zip, exported QIIME 2 folders",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes(["qza", "qzv", "zip", "fa", "fasta", "nwk", "newick", "tsv", "biom"]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .qiime2Archive
            )
        ),
        ImportCardInfo(
            id: "igv-session-track-set",
            title: "IGV Session or Track Set",
            description: "Import local track files referenced by IGV sessions where possible and preserve the session file for future track-set support.",
            sfSymbol: "rectangle.stack.badge.play",
            fileHint: ".xml, .json, folders containing BAM/CRAM, VCF, BED/GFF, WIG/BigWig tracks",
            tab: .applicationExports,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: ImportCenterViewModel.importContentTypes([
                        "xml", "json", "bam", "cram", "sam", "vcf", "bed", "gff", "gff3", "gtf", "wig", "bw", "bigwig",
                    ]),
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false,
                    allowsOtherFileTypes: true
                ),
                action: .igvSessionTrackSet
            )
        ),
        ImportCardInfo(
            id: "primer-scheme",
            title: "Primer Scheme",
            description: "Import a .lungfishprimers bundle authored from a BED (and optional FASTA) for use with iVar primer trimming.",
            sfSymbol: "line.horizontal.3.decrease.circle",
            fileHint: ".bed (+ optional .fasta/.fa/.fna)",
            tab: .references,
            importKind: .wizardSheet(action: .primerScheme)
        ),
    ]

    /// Cards visible in the currently selected section.
    var visibleCards: [ImportCardInfo] {
        allCards.filter { $0.tab == selectedTab }
    }

    // MARK: - Initialisation

    init() {
        loadHistory()
    }

    // MARK: - Import Actions

    /// Performs the import action for a given card.
    ///
    /// For file-panel imports, opens an NSOpenPanel with the appropriate
    /// type filters and forwards selected URLs to the app delegate.
    /// For wizard-sheet imports, opens the appropriate wizard.
    func performImport(for card: ImportCardInfo) {
        switch card.importKind {
        case .openPanel(let configuration, let action):
            openFilePanel(configuration: configuration, action: action)
        case .wizardSheet(let action):
            openWizardSheet(action: action)
        }
    }

    // MARK: - Drag-and-Drop Import

    /// Handles files dropped onto an import card.
    ///
    /// Extracts URLs from the provided item providers and dispatches them
    /// through the same path as a file-panel selection.
    func performDropImport(urls: [URL], for card: ImportCardInfo) {
        guard !urls.isEmpty else { return }
        dispatchFileImport(urls: urls, action: card.importAction)
    }

    // MARK: - File Panel

    private func openFilePanel(configuration: ImportCardInfo.OpenPanelConfiguration, action: ImportCardInfo.ImportAction) {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else {
            logger.warning("No window available for file panel")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = configuration.canChooseFiles
        panel.canChooseDirectories = configuration.canChooseDirectories
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection
        panel.allowsOtherFileTypes = configuration.allowsOtherFileTypes
        if let allowedTypes = configuration.allowedTypes {
            panel.allowedContentTypes = allowedTypes
        }
        panel.message = panelMessage(for: action)

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.dispatchFileImport(urls: panel.urls, action: action)
        }
    }

    private func panelMessage(for action: ImportCardInfo.ImportAction) -> String {
        switch action {
        case .fastq:    return "Select FASTQ files or folders to import"
        case .ontRun:   return "Select an ONT output directory to import"
        case .bam:      return "Select BAM or CRAM alignment files to import"
        case .vcf:      return "Select VCF variant files to import"
        case .fasta:    return "Select standalone reference sequence files (.fa/.fasta/.gb/.embl, optionally .gz) to import"
        case .annotationTrack: return "Select GTF, GFF, GFF3, or BED annotation files to attach to a reference bundle"
        case .geneiousExport: return "Select a Geneious archive or export folder to import"
        case .clcWorkbenchExport: return "Select a CLC Workbench export folder, archive, or native project file"
        case .dnastarLasergeneExport: return "Select a DNASTAR Lasergene or GenVision export folder or file"
        case .benchlingBulkExport: return "Select a Benchling bulk export archive, folder, or standard exported file"
        case .sequenceDesignLibraryExport: return "Select a sequence design library export folder, archive, or file"
        case .alignmentTreeExport: return "Select an alignment or phylogenetic tree export"
        case .sequencingPlatformRunFolder: return "Select a sequencing platform run folder or downloaded analysis export"
        case .phylogeneticsResultSet: return "Select a phylogenetics result folder, archive, or file"
        case .qiime2Archive: return "Select a QIIME 2 archive or exported folder"
        case .igvSessionTrackSet: return "Select an IGV session file or local track-set folder"
        case .bundleSampleMetadata:
            return "Select a CSV or TSV file with sample metadata for the selected dataset"
        case .projectSampleMetadata: return "Select project sample metadata"
        case .kraken2:  return "Select Kraken2 report files to import"
        case .esViritu: return "Select EsViritu result files or directory"
        case .taxTriage: return "Select TaxTriage result files or directory"
        case .naoMgs:   return "Select NAO-MGS results"
        case .nvd:      return "Select NVD results directory"
        case .primerScheme: return "Primer scheme import runs via the wizard sheet"
        }
    }

    /// Dispatches imported file URLs to the appropriate app delegate method
    /// and records the operation in import history.
    func dispatchFileImport(urls: [URL], action: ImportCardInfo.ImportAction) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            logger.error("Cannot access AppDelegate for import dispatch")
            recordHistory(urls: urls, action: action, succeeded: false)
            return
        }

        // Close Import Center so it doesn't obscure the main window
        ImportCenterWindowController.close()

        switch action {
        case .fastq:
            appDelegate.importFASTQFromURLs(urls)
        case .ontRun:
            for url in urls {
                appDelegate.importONTRunFromURL(url)
            }
        case .bam:
            for url in urls {
                appDelegate.importBAMFromURL(url)
            }
        case .vcf:
            for url in urls {
                appDelegate.importVCFFromURL(url)
            }
        case .fasta:
            for url in urls {
                appDelegate.importFASTAFromURL(url)
            }
        case .annotationTrack:
            appDelegate.importAnnotationTracksFromURLs(urls)
        case .geneiousExport:
            for url in urls {
                appDelegate.importGeneiousExportFromURL(url)
            }
        case .clcWorkbenchExport,
             .dnastarLasergeneExport,
             .benchlingBulkExport,
             .sequenceDesignLibraryExport,
             .alignmentTreeExport,
             .sequencingPlatformRunFolder,
             .phylogeneticsResultSet,
             .qiime2Archive,
             .igvSessionTrackSet:
            guard let kind = applicationExportKind(for: action) else { break }
            for url in urls {
                appDelegate.importApplicationExportFromURL(url, kind: kind)
            }
        case .bundleSampleMetadata:
            for url in urls {
                appDelegate.importBundleSampleMetadataFromURL(url)
            }
        case .projectSampleMetadata:
            break
        case .kraken2:
            for url in urls {
                appDelegate.importKraken2ResultFromURL(url)
            }
        case .esViritu:
            for url in urls {
                appDelegate.importEsVirituResultFromURL(url)
            }
        case .taxTriage:
            for url in urls {
                appDelegate.importTaxTriageResultFromURL(url)
            }
        case .naoMgs:
            break // Handled by wizard sheet path
        case .nvd:
            break // Handled by wizard sheet path
        case .primerScheme:
            break // Handled by wizard sheet path
        }

        recordHistory(urls: urls, action: action, succeeded: true)
        logger.info("Dispatched \(urls.count) file(s) for \(String(describing: action)) import")
    }

    // MARK: - Wizard Sheets

    private func openWizardSheet(action: ImportCardInfo.ImportAction) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            logger.error("Cannot access AppDelegate for wizard sheet")
            return
        }

        // Close the Import Center window so the wizard sheet isn't hidden behind it
        ImportCenterWindowController.close()

        switch action {
        case .naoMgs:
            appDelegate.launchNaoMgsImport(nil)
        case .projectSampleMetadata:
            appDelegate.importProjectSampleMetadata(nil)
        case .nvd:
            appDelegate.launchNvdImport(nil)
        case .primerScheme:
            appDelegate.launchPrimerSchemeImport(nil)
        case .kraken2:
            appDelegate.launchKraken2Classification(nil)
        case .esViritu:
            appDelegate.launchEsVirituDetection(nil)
        case .taxTriage:
            appDelegate.launchTaxTriage(nil)
        default:
            logger.warning("No wizard sheet defined for action: \(String(describing: action))")
        }
    }

    private func applicationExportKind(for action: ImportCardInfo.ImportAction) -> ApplicationExportKind? {
        switch action {
        case .clcWorkbenchExport: return .clcWorkbench
        case .dnastarLasergeneExport: return .dnastarLasergene
        case .benchlingBulkExport: return .benchlingBulk
        case .sequenceDesignLibraryExport: return .sequenceDesignLibrary
        case .alignmentTreeExport: return .alignmentTree
        case .sequencingPlatformRunFolder: return .sequencingPlatformRunFolder
        case .phylogeneticsResultSet: return .phylogeneticsResultSet
        case .qiime2Archive: return .qiime2Archive
        case .igvSessionTrackSet: return .igvSessionTrackSet
        default: return nil
        }
    }

    // MARK: - History Management

    /// Returns the human-readable label stored in ``ImportHistoryEntry/importAction``
    /// for a given ``ImportCardInfo/ImportAction``.
    private func historyLabel(for action: ImportCardInfo.ImportAction) -> String {
        switch action {
        case .fastq:    return "FASTQ"
        case .ontRun:   return "ONT Run"
        case .bam:      return "BAM"
        case .vcf:      return "VCF"
        case .fasta:    return "FASTA"
        case .annotationTrack: return "Annotation Track"
        case .geneiousExport: return "Geneious"
        case .clcWorkbenchExport: return "CLC Workbench"
        case .dnastarLasergeneExport: return "DNASTAR Lasergene"
        case .benchlingBulkExport: return "Benchling Bulk"
        case .sequenceDesignLibraryExport: return "Sequence Library"
        case .alignmentTreeExport: return "Alignment Tree"
        case .sequencingPlatformRunFolder: return "Sequencing Run"
        case .phylogeneticsResultSet: return "Phylogenetics"
        case .qiime2Archive: return "QIIME 2"
        case .igvSessionTrackSet: return "IGV Session"
        case .bundleSampleMetadata: return "Bundle Metadata"
        case .projectSampleMetadata: return "Project Metadata"
        case .naoMgs:   return "NAO-MGS"
        case .kraken2:  return "Kraken2"
        case .esViritu: return "EsViritu"
        case .taxTriage: return "TaxTriage"
        case .nvd:      return "NVD"
        case .primerScheme: return "Primer Scheme"
        }
    }

    /// Appends one history entry per URL, then persists the updated list.
    private func recordHistory(urls: [URL], action: ImportCardInfo.ImportAction, succeeded: Bool) {
        let label = historyLabel(for: action)
        let now = Date()
        let newEntries = urls.map { url in
            ImportHistoryEntry(
                id: UUID(),
                importAction: label,
                fileName: url.lastPathComponent,
                date: now,
                succeeded: succeeded
            )
        }
        importHistory.insert(contentsOf: newEntries, at: 0)
        if importHistory.count > Self.maxHistoryEntries {
            importHistory = Array(importHistory.prefix(Self.maxHistoryEntries))
        }
        saveHistory()
    }

    /// Removes all history entries and persists the empty list.
    func clearHistory() {
        importHistory = []
        saveHistory()
    }

    // MARK: - UserDefaults Persistence

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyDefaultsKey) else { return }
        do {
            importHistory = try JSONDecoder().decode([ImportHistoryEntry].self, from: data)
        } catch {
            logger.warning("Failed to decode import history: \(error.localizedDescription)")
            importHistory = []
        }
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(importHistory)
            UserDefaults.standard.set(data, forKey: Self.historyDefaultsKey)
        } catch {
            logger.warning("Failed to encode import history: \(error.localizedDescription)")
        }
    }
}
