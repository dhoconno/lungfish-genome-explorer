// RNASeqResultWriter.swift - The one writer of an RNA-seq result (Phase 5.1 lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One component creates, settles and discards every `.lungfishrnaseq` folder, for an import and for a quantification
// alike (`docs/formats/rnaseq-bundle.md`, section The one writer). It stages the folder as
// `.<name>.lungfishrnaseq.creating-<UUID>` beside its final name, copies the tool's files into `source/` hashing each as
// it reads it, writes the tables, publishes the manifest through `DurableReplace`, writes the root record last through
// `ProvenanceWriter` and renames the stage into place with `RENAME_EXCL` through `PortableRename`, so no listing sees a
// result without its record. A throw or a cancel removes the stage. The caller supplies the record's envelope, and the
// writer invents no run fact. The reader is `RNASeqResultBundle` in LungfishIO.

import Foundation
import LungfishCore
import LungfishIO

public struct RNASeqResultWriter: Sendable {
    public typealias Manifest = RNASeqResultManifest

    /// A file of the tool, copied as given.
    public struct SourceFile: Sendable {
        public var url: URL
        /// Where the file sits under its sample's folder, as the tool wrote it, such as `aux_info/meta_info.json`.
        public var relativePath: String
        /// The sample the file belongs to. Nil for a file of several samples, which is kept as `source/tables/<file name>`.
        public var sample: String?
        public var tool: String

        public init(url: URL, relativePath: String, sample: String?, tool: String) {
            self.url = url
            self.relativePath = relativePath
            self.sample = sample
            self.tool = tool
        }
    }

    /// One count table. The file name follows from `rows` and `column`.
    public struct CountInput: Sendable {
        public var rows: Manifest.CountEntry.Rows
        public var column: Manifest.CountEntry.Column
        public var unit: Manifest.CountEntry.Unit
        public var table: RNASeqCountTable

        public init(rows: Manifest.CountEntry.Rows, column: Manifest.CountEntry.Column, unit: Manifest.CountEntry.Unit, table: RNASeqCountTable) {
            self.rows = rows
            self.column = column
            self.unit = unit
            self.table = table
        }
    }

    /// Where `genes.tsv` comes from (`rnaseq-bundle.md`, row genes.tsv).
    public enum GeneTable: Sendable {
        /// The feature ids of the count tables, for a result whose `referenceSet` is null. Every other column is empty.
        case ids([String])
        /// The set's `derived/genes.tsv` and the gene ids the result keeps. Every gene kept copies the file as it is.
        case referenceSetTable(url: URL, keeping: [String])
    }

    public struct Request: Sendable {
        public var name: String
        public var modality: Manifest.Modality
        public var origin: Manifest.Origin
        public var route: Manifest.Route
        public var referenceSet: Manifest.ReferenceSet?
        public var samples: [RNASeqSampleRecord]
        public var genes: GeneTable
        public var counts: [CountInput]
        public var sourceFiles: [SourceFile]
        public var notHost: [String]
        /// Single cell. Each file a matrix names must be among `sourceFiles` of its sample. The writer reads each matrix
        /// once from its copy in the stage, writes `cells.sqlite` and fills `matrices` and `cellsSummary` from that pass.
        public var matrices: [MatrixInput]?
        /// Single cell. The id prefixes of the genomes of a reference of two or more, such as `hg19` and `mm10`.
        public var genomes: [String]
        /// `quality/samples.quality.tsv`, the columns and then one row a sample. A row whose sample is not in `samples`
        /// is refused. Nil writes no file and no manifest key.
        public var quality: RNASeqQualityTable?
        public var createdAt: Date

        public init(
            name: String, modality: Manifest.Modality, origin: Manifest.Origin, route: Manifest.Route,
            referenceSet: Manifest.ReferenceSet?, samples: [RNASeqSampleRecord], genes: GeneTable, counts: [CountInput],
            sourceFiles: [SourceFile], notHost: [String], matrices: [MatrixInput]? = nil,
            genomes: [String] = [], quality: RNASeqQualityTable? = nil, createdAt: Date = Date()
        ) {
            self.name = name
            self.modality = modality
            self.origin = origin
            self.route = route
            self.referenceSet = referenceSet
            self.samples = samples
            self.genes = genes
            self.counts = counts
            self.sourceFiles = sourceFiles
            self.notHost = notHost
            self.matrices = matrices
            self.genomes = genomes
            self.quality = quality
            self.createdAt = createdAt
        }
    }

    /// One sample's matrix, features and barcodes, as paths under the sample's folder of the tool.
    public struct MatrixInput: Sendable, Equatable {
        public var sample: String
        public var matrix: String
        public var features: String
        public var barcodes: String

        public init(sample: String, matrix: String, features: String, barcodes: String) {
            self.sample = sample
            self.matrix = matrix
            self.features = features
            self.barcodes = barcodes
        }
    }

    /// The steps a test observes. Each is reported with the stage folder once it is done.
    package enum Stage: Sendable { case staged, sourcesCopied, tablesWritten, manifestPublished, recordWritten }

    let provenanceWriter: ProvenanceWriter
    let stageObserver: (@Sendable (Stage, URL) throws -> Void)?

    public init(provenanceWriter: ProvenanceWriter = ProvenanceWriter()) {
        self.provenanceWriter = provenanceWriter
        stageObserver = nil
    }

    package init(provenanceWriter: ProvenanceWriter, stageObserver: (@Sendable (Stage, URL) throws -> Void)?) {
        self.provenanceWriter = provenanceWriter
        self.stageObserver = stageObserver
    }

    /// Publishes `request` as the folder `resultURL`, whose name ends in `.lungfishrnaseq` and which does not exist yet.
    /// The caller names it, so the envelope can name it too.
    @discardableResult
    public func write(_ request: Request, to resultURL: URL, envelope: ProvenanceEnvelope) throws -> URL {
        guard RNASeqResultBundle.isBundleURL(resultURL) else {
            throw RNASeqResultWriterError.notAResultFolder(resultURL.lastPathComponent)
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: resultURL.path) else {
            throw RNASeqResultWriterError.alreadyExists(resultURL.lastPathComponent)
        }
        try checkQuality(request)
        let stage = resultURL.deletingLastPathComponent()
            .appendingPathComponent(".\(resultURL.lastPathComponent).creating-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            try note(.staged, stage)
            try DurableReplace.transaction {
                try fill(stage, request: request, resultURL: resultURL, envelope: envelope)
            }
            try PortableRename.exclusive(stage, to: resultURL)
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }
        return resultURL
    }

    func note(_ stage: Stage, _ url: URL) throws {
        try stageObserver?(stage, url)
        try Task.checkCancellation()
    }

    private func fill(_ stage: URL, request: Request, resultURL: URL, envelope: ProvenanceEnvelope) throws {
        let copied = try copySources(request, into: stage)
        try note(.sourcesCopied, stage)
        let (matrices, cellsSummary) = try writeCells(request, copied: copied, into: stage)

        var samples = request.samples
        for index in samples.indices { samples[index].sourceFolder = copied.folders[samples[index].id] }
        let samplesData = try RNASeqSampleRecord.tsvData(samples)
        let genesData = try genesTable(for: request)
        try DurableReplace.replace(samplesData, named: "samples.tsv", in: stage)
        try DurableReplace.replace(genesData, named: "genes.tsv", in: stage)
        let counts = try writeCounts(request.counts, into: stage)
        let quality = try writeQuality(request.quality, into: stage)
        try note(.tablesWritten, stage)

        let manifest = Manifest(
            modality: request.modality, name: request.name,
            createdAt: ISO8601DateFormatter().string(from: request.createdAt),
            origin: request.origin, route: request.route, referenceSet: request.referenceSet,
            samples: .init(path: "samples.tsv", sha256: RNASeqResultBundle.sha256Hex(samplesData)),
            genes: .init(path: "genes.tsv", sha256: RNASeqResultBundle.sha256Hex(genesData)),
            counts: counts, sourceFiles: copied.entries,
            matrices: matrices, cellsSummary: cellsSummary,
            quality: quality, notHost: request.notHost)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try DurableReplace.replace(try encoder.encode(manifest), named: Manifest.filename, in: stage)
        try note(.manifestPublished, stage)

        try provenanceWriter.write(envelope, to: stage, bundleLayoutRoot: resultURL)
        try note(.recordWritten, stage)
    }
}
