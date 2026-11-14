// RNASeqResultManifest.swift - Schema 1 of rnaseq-result.json (Phase 5.1 lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The manifest of a `.lungfishrnaseq` folder, as `docs/formats/rnaseq-bundle.md` sets it. Keys are camel case, as the
// 12S result's are. A key enters only with a new schema number, so a schema 1 reader never meets one it must guess at.
// Every path is relative to the result's folder.

import Foundation

public struct RNASeqResultManifest: Codable, Equatable, Sendable {
    public static let filename = "rnaseq-result.json"
    public static let currentSchemaVersion = 1
    public static let kindName = "rnaseq-result"

    public enum Modality: String, Codable, Sendable { case bulk, singleCell = "single-cell" }

    public struct Origin: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case imported, quantified }
        public var kind: Kind
        /// The tool and version that made imported files, nil when LGE ran the route.
        public var tool: String?
        public var toolVersion: String?

        public init(kind: Kind, tool: String? = nil, toolVersion: String? = nil) {
            self.kind = kind
            self.tool = tool
            self.toolVersion = toolVersion
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

    public init(
        schemaVersion: Int = RNASeqResultManifest.currentSchemaVersion,
        kind: String = RNASeqResultManifest.kindName,
        modality: Modality, name: String, createdAt: String, origin: Origin, route: Route,
        referenceSet: ReferenceSet?, samples: FileEntry, genes: FileEntry, counts: [CountEntry],
        sourceFiles: [SourceFileEntry], matrices: [MatrixEntry]? = nil, cellsSummary: CellsSummary? = nil,
        quality: FileEntry? = nil, notHost: [String] = []
    ) {
        self.schemaVersion = schemaVersion
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
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, modality, name, createdAt, origin, route, referenceSet
        case samples, genes, counts, sourceFiles, matrices, cellsSummary, quality, notHost
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
    }
}
