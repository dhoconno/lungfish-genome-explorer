// BlastSubmissionRecord.swift - The record `lungfish blast submit` writes beside its query copy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What `lungfish blast submit` saves in its result folder (Phase 2.11 lane A65, plan decision C1).
///
/// ## Layout
///
/// ```
/// <output>/query.fasta                                   the query, copied from the caller's file
/// <output>/blast-result.json                             this record
/// <output>/blast-result.json.lungfish-provenance.json    its provenance, with query.fasta as its source
/// ```
///
/// The folder keeps its own copy of the query, so the record names a file that still exists after
/// the project's `.tmp` sweep removes the file the viewer wrote (BIO 6, ARCH 5). The record names the
/// copy's SHA-256 and the lineage the caller gave, the classifier result, sample, taxon or contig
/// and the count and seed of a subsample, beside the search settings and the per-read verdicts.
public struct BlastSubmissionRecord: Codable, Sendable {
    /// Schema version written into every record.
    public static let currentSchemaVersion = 1
    /// The record's file name in the result folder.
    public static let recordFileName = "blast-result.json"
    /// The query copy's file name in the result folder.
    public static let queryFileName = "query.fasta"

    /// The query copy the search read.
    public struct Query: Codable, Sendable, Equatable {
        /// The copy's name, relative to the record's folder.
        public var fileName: String
        /// Lower-case hex SHA-256 of the copy's bytes.
        public var sha256: String
        public var sequenceCount: Int

        public init(fileName: String, sha256: String, sequenceCount: Int) {
            self.fileName = fileName
            self.sha256 = sha256
            self.sequenceCount = sequenceCount
        }
    }

    /// Where the sequences came from, as the caller named it. Each field is nil when not given.
    public struct Lineage: Codable, Sendable, Equatable {
        /// The classifier or assembly result folder the sequences were read from. A record in a project
        /// writes a folder of that project as `@/<path in the project>` (Phase 2.12), and a record
        /// written before, or outside a project, holds the path as given. Read it with
        /// ``sourceResultURL(recordAt:)``.
        public var sourceResult: String?
        public var sample: String?
        public var taxId: Int?
        public var contig: String?
        /// The number of sequences a subsample drew, and its seed when the draw was seeded.
        public var subsampleCount: Int?
        public var subsampleSeed: UInt64?

        public init(
            sourceResult: String? = nil,
            sample: String? = nil,
            taxId: Int? = nil,
            contig: String? = nil,
            subsampleCount: Int? = nil,
            subsampleSeed: UInt64? = nil
        ) {
            self.sourceResult = sourceResult
            self.sample = sample
            self.taxId = taxId
            self.contig = contig
            self.subsampleCount = subsampleCount
            self.subsampleSeed = subsampleSeed
        }

        /// The source result of a record stored at `recordURL`, its `@/` path resolved in the project
        /// that holds the record now. An absolute path, as a record before Phase 2.12 holds it, reads as
        /// written. Nil when the record names no source result.
        public func sourceResultURL(recordAt recordURL: URL) -> URL? {
            guard let sourceResult else { return nil }
            let path = PortablePath.resolve(path: sourceResult, context: .forFile(at: recordURL))
            return URL(fileURLWithPath: path)
        }
    }

    /// The settings the search was submitted with.
    public struct Search: Codable, Sendable, Equatable {
        public var program: String
        public var database: String
        public var entrezQuery: String?
        public var eValueThreshold: Double
        public var maxTargetSeqs: Int
        public var extraArgs: String
        public var taxonomy: BlastTaxonomyContext

        public init(_ request: BlastVerificationRequest) {
            self.program = request.program
            self.database = request.database
            self.entrezQuery = request.entrezQuery
            self.eValueThreshold = request.eValueThreshold
            self.maxTargetSeqs = request.maxTargetSeqs
            self.extraArgs = request.extraArgs
            self.taxonomy = request.taxonomyContext
        }
    }

    public var schemaVersion: Int
    public var savedAt: Date
    public var query: Query
    public var lineage: Lineage
    public var search: Search
    public var result: BlastVerificationResult

    public init(
        schemaVersion: Int = BlastSubmissionRecord.currentSchemaVersion,
        savedAt: Date,
        query: Query,
        lineage: Lineage,
        search: Search,
        result: BlastVerificationResult
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.query = query
        self.lineage = lineage
        self.search = search
        self.result = result
    }

    /// The encoder the command writes the record with, and the decoder that reads it back.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads the record at `url`.
    public static func load(_ url: URL) throws -> BlastSubmissionRecord {
        try decoder.decode(BlastSubmissionRecord.self, from: Data(contentsOf: url))
    }
}
