// RNASeqResultManifest.swift - Schemas 1 and 2 of rnaseq-result.json (Phase 5.1 lane RS-KIND, 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The manifest of a `.lungfishrnaseq` folder, as `docs/formats/rnaseq-bundle.md` sets it. Keys are camel case, as the
// 12S result's are. A key enters only with a new schema number, so a schema 1 reader never meets one it must guess at.
// Schema 2 adds the cell map (`docs/formats/rnaseq-cell-map.md`), its modality, its `computed` origin and the keys
// `parent`, `cellMap` and `labelTables`. Every path is relative to the result's folder.

import Foundation

public struct RNASeqResultManifest: Codable, Equatable, Sendable {
    public static let filename = "rnaseq-result.json"
    /// The newest manifest schema this build reads. A reader accepts schemas 1 through this one (5.5 L2).
    public static let newestReadableSchemaVersion = 2
    public static let kindName = "rnaseq-result"

    /// A cell map is the only result written at schema 2. Bulk, single-cell and pseudobulk results stay at 1, so every
    /// older build keeps opening them (`docs/formats/rnaseq-cell-map.md`, Schemas 1 and 2).
    public enum Modality: String, Codable, Sendable { case bulk, singleCell = "single-cell", cellMap = "cell-map" }

    /// The schema a writer gives a result of `modality`. A writer never takes the newest readable schema as its own.
    public static func schemaVersion(for modality: Modality) -> Int {
        switch modality {
        case .bulk, .singleCell: return 1
        case .cellMap: return 2
        }
    }

    public struct Origin: Codable, Equatable, Sendable {
        /// `pseudobulk` is a bulk result whose UMIs LGE summed from a single-cell result by sample and label. `computed`
        /// is a cell map whose embedding `rnaseq cell-map compute` made, written only at schema 2.
        public enum Kind: String, Codable, Sendable { case imported, quantified, pseudobulk, computed }
        public var kind: Kind
        /// The tool and version that made imported files, or those of the single-cell result a pseudobulk summed. Nil
        /// when LGE ran the route.
        public var tool: String?
        public var toolVersion: String?
        /// The settings LGE chose for a `computed` cell map, `seed` and `threads` as decimal text, so a reader that shows
        /// the source never reads the record. A schema 2 key, written only for `computed` and absent from every other
        /// origin (`docs/formats/rnaseq-cell-map.md`, the `origin` row).
        public var settings: [String: String]?

        public init(kind: Kind, tool: String? = nil, toolVersion: String? = nil, settings: [String: String]? = nil) {
            self.kind = kind
            self.tool = tool
            self.toolVersion = toolVersion
            self.settings = settings
        }
    }

    /// One route: the counting tool, its version and every setting that changes counts.
    public struct Route: Codable, Equatable, Sendable {
        public var id: String
        public var tool: String
        public var toolVersion: String
        public var settings: [String: String]

        public init(id: String, tool: String, toolVersion: String, settings: [String: String]) {
            self.id = id
            self.tool = tool
            self.toolVersion = toolVersion
            self.settings = settings
        }
    }

    public struct ReferenceSet: Codable, Equatable, Sendable {
        public enum Layout: String, Codable, Sendable { case lge, deposit }
        public var id: String
        public var layout: Layout

        public init(id: String, layout: Layout) {
            self.id = id
            self.layout = layout
        }
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String

        public init(path: String, sha256: String) {
            self.path = path
            self.sha256 = sha256
        }
    }

    public struct CountEntry: Codable, Equatable, Sendable {
        public enum Rows: String, Codable, Sendable { case gene, transcript }
        public enum Unit: String, Codable, Sendable { case reads, pairs, umis, estimated }
        public enum Column: String, Codable, Sendable { case `default`, masked }
        public var path: String
        public var sha256: String
        public var rows: Rows
        public var unit: Unit
        public var column: Column

        public init(path: String, sha256: String, rows: Rows, unit: Unit, column: Column) {
            self.path = path
            self.sha256 = sha256
            self.rows = rows
            self.unit = unit
            self.column = column
        }
    }

    /// A kept file. `sample` is empty for a file that holds several samples, kept under `source/tables/`.
    public struct SourceFileEntry: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var size: Int64
        public var sample: String
        public var tool: String

        public init(path: String, sha256: String, size: Int64, sample: String, tool: String) {
            self.path = path
            self.sha256 = sha256
            self.size = size
            self.sample = sample
            self.tool = tool
        }
    }

    /// Single cell: one sample's matrix, features and barcodes, kept as given and never loaded.
    public struct MatrixEntry: Codable, Equatable, Sendable {
        public var sample: String
        public var matrix: FileEntry
        public var features: FileEntry
        public var barcodes: FileEntry
        public var format: String
        public var isGzip: Bool
        public var cellCount: Int
        public var featureCount: Int
        public var entryCount: Int

        public init(
            sample: String, matrix: FileEntry, features: FileEntry, barcodes: FileEntry,
            format: String = "matrix-market", isGzip: Bool, cellCount: Int, featureCount: Int, entryCount: Int
        ) {
            self.sample = sample
            self.matrix = matrix
            self.features = features
            self.barcodes = barcodes
            self.format = format
            self.isGzip = isGzip
            self.cellCount = cellCount
            self.featureCount = featureCount
            self.entryCount = entryCount
        }
    }

    public struct CellsSummary: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var schemaVersion: Int

        public init(path: String, sha256: String, schemaVersion: Int) {
            self.path = path
            self.sha256 = sha256
            self.schemaVersion = schemaVersion
        }
    }

    /// A cell map's single-cell parent. `path` is written from the folder that holds the cell map and is a pointer, never
    /// an identity: a reader trusts the folder it finds only when that folder's manifest has `manifestSHA256`.
    public struct Parent: Codable, Equatable, Sendable {
        public var path: String
        public var manifestSHA256: String
        public var cellsSummarySHA256: String

        public init(path: String, manifestSHA256: String, cellsSummarySHA256: String) {
            self.path = path
            self.manifestSHA256 = manifestSHA256
            self.cellsSummarySHA256 = cellsSummarySHA256
        }
    }

    public var schemaVersion: Int
    public var kind: String
    public var modality: Modality
    public var name: String
    public var createdAt: String
    public var origin: Origin
    public var route: Route
    /// Nil when the imported files state none, which a reader shows as Not recorded. It is written as `null`.
    public var referenceSet: ReferenceSet?
    public var samples: FileEntry
    public var genes: FileEntry
    public var counts: [CountEntry]
    public var sourceFiles: [SourceFileEntry]
    public var matrices: [MatrixEntry]?
    public var cellsSummary: CellsSummary?
    /// The path and sha256 of `quality/samples.quality.tsv`. Nil when the result keeps no quality table, which a reader shows as Not recorded.
    public var quality: FileEntry?
    public var notHost: [String]
    /// Schema 2, a cell map only: its single-cell parent.
    public var parent: Parent?
    /// Schema 2, a cell map only: the path, sha256 and `meta` schema of `cellmap.sqlite`.
    public var cellMap: CellsSummary?
    /// Schema 2, a cell map only: each `labels/<set>.tsv` in label-set order, so `verifyChecksums` covers it.
    public var labelTables: [FileEntry]?

    /// A nil `schemaVersion` is the schema of `modality` (`schemaVersion(for:)`), which every writer passes.
    public init(
        schemaVersion: Int? = nil,
        kind: String = RNASeqResultManifest.kindName,
        modality: Modality, name: String, createdAt: String, origin: Origin, route: Route,
        referenceSet: ReferenceSet?, samples: FileEntry, genes: FileEntry, counts: [CountEntry],
        sourceFiles: [SourceFileEntry], matrices: [MatrixEntry]? = nil, cellsSummary: CellsSummary? = nil,
        quality: FileEntry? = nil, notHost: [String] = [],
        parent: Parent? = nil, cellMap: CellsSummary? = nil, labelTables: [FileEntry]? = nil
    ) {
        self.schemaVersion = schemaVersion ?? Self.schemaVersion(for: modality)
        self.kind = kind
        self.modality = modality
        self.name = name
        self.createdAt = createdAt
        self.origin = origin
        self.route = route
        self.referenceSet = referenceSet
        self.samples = samples
        self.genes = genes
        self.counts = counts
        self.sourceFiles = sourceFiles
        self.matrices = matrices
        self.cellsSummary = cellsSummary
        self.quality = quality
        self.notHost = notHost
        self.parent = parent
        self.cellMap = cellMap
        self.labelTables = labelTables
    }

    /// Whether the values and keys agree with the schema number. The values and keys of schema 2 are read only at 2, and
    /// a schema 2 manifest is a cell map that names its parent and its database. A reader treats any other manifest as
    /// unreadable, so it never guesses at a value of the other schema.
    public var keysMatchSchema: Bool {
        let schemaTwoOnly = modality == .cellMap || origin.kind == .computed || origin.settings != nil || parent != nil
            || cellMap != nil || labelTables != nil
        switch schemaVersion {
        case 1: return !schemaTwoOnly
        case 2: return modality == .cellMap && parent != nil && cellMap != nil && (origin.settings == nil || origin.kind == .computed)
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, modality, name, createdAt, origin, route, referenceSet
        case samples, genes, counts, sourceFiles, matrices, cellsSummary, quality, notHost
        case parent, cellMap, labelTables
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(modality, forKey: .modality)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(origin, forKey: .origin)
        try container.encode(route, forKey: .route)
        try container.encode(referenceSet, forKey: .referenceSet)
        try container.encode(samples, forKey: .samples)
        try container.encode(genes, forKey: .genes)
        try container.encode(counts, forKey: .counts)
        try container.encode(sourceFiles, forKey: .sourceFiles)
        try container.encodeIfPresent(matrices, forKey: .matrices)
        try container.encodeIfPresent(cellsSummary, forKey: .cellsSummary)
        try container.encodeIfPresent(quality, forKey: .quality)
        try container.encode(notHost, forKey: .notHost)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encodeIfPresent(cellMap, forKey: .cellMap)
        try container.encodeIfPresent(labelTables, forKey: .labelTables)
    }
}
