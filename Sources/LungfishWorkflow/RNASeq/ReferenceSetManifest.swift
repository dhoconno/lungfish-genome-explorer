// ReferenceSetManifest.swift - `reference-set.json`, the manifest of an RNA-seq reference set (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The keys are the table of `docs/formats/reference-set.md`, section Layout. No type outside `RNASeq/` names a set.

import Foundation

public struct ReferenceSetManifest: Codable, Sendable, Equatable {
    public static let filename = "reference-set.json"
    public static let currentSchemaVersion = 1
    public static let folderExtension = "lungfishrefset"

    public struct Assembly: Codable, Sendable, Equatable {
        public var name: String
        public var accession: String?
        public var sourceURL: String?
    }

    public struct Annotation: Codable, Sendable, Equatable {
        public var source: String
        public var release: String
        public var path: String
        public var sha256: String
    }

    public struct Genome: Codable, Sendable, Equatable {
        public var path: String
        public var sha256: String
        /// The `.lungfishref` the FASTA came from, and that bundle's `md5_checksum`, when it came from one.
        public var referenceBundle: String?
        public var referenceBundleMD5: String?
    }

    public struct Extra: Codable, Sendable, Equatable {
        public var name: String
        public var kind: ReferenceSetExtraKind
        public var path: String
        public var sha256: String
        /// The extra's own annotation, kept in the deposit layout only.
        public var annotationPath: String?
        public var annotationSHA256: String?
        public var records: [String]
        public var notHost: Bool
    }

    public struct Layout: Codable, Sendable, Equatable {
        /// `lge` or `deposit`.
        public var kind: String
        public var study: String?

        public init(kind: String, study: String? = nil) {
            self.kind = kind
            self.study = study
        }
    }

    public struct Mask: Codable, Sendable, Equatable {
        public var name: String
        public var features: [String]
    }

    public struct DerivedFile: Codable, Sendable, Equatable {
        public var path: String
        public var sha256: String
        public var size: Int64
        public var tool: String
        public var version: String
    }

    public struct Derived: Codable, Sendable, Equatable {
        public var transcripts: DerivedFile
        public var genes: DerivedFile
        public var transcriptGenes: DerivedFile
    }

    /// What the owner changed from the annotation as given, which the record names.
    public struct Derivation: Codable, Sendable, Equatable {
        public var exonsAdded: [String]
        public var keptWithoutExon: [String]
        /// Each feature of empty `gene_id` as `<contig>\t<type>\t<start>\t<end>`.
        public var droppedFeatures: [String]
        /// Each transcript id that named more than one gene, contig or strand, and its new id in the GTF gffread read.
        public var renamedTranscripts: [RenamedTranscript]
        /// `derived/genes-without-features.tsv`, the genes with no exon line and no CDS line.
        public var genesWithoutFeatures: ListedFile
    }

    public struct RenamedTranscript: Codable, Sendable, Equatable {
        public var transcript: String
        public var gene: String
        /// `<gene_id>:<transcript_id>`.
        public var renamed: String
    }

    /// A derived list with its path, sha256 and count of rows below the header.
    public struct ListedFile: Codable, Sendable, Equatable {
        public var path: String
        public var sha256: String
        public var count: Int
    }

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var species: String
    public var assembly: Assembly
    public var annotation: Annotation
    public var genome: Genome
    public var extras: [Extra]
    public var layout: Layout
    public var mitochondrialContigs: [String]
    public var masks: [Mask]
    public var derived: Derived
    public var derivation: Derivation

    /// Every file the manifest names with its sha256, relative to the set folder.
    public var namedFiles: [(path: String, sha256: String)] {
        var files = [(genome.path, genome.sha256), (annotation.path, annotation.sha256)]
        for extra in extras {
            files.append((extra.path, extra.sha256))
            if let path = extra.annotationPath, let sha = extra.annotationSHA256 { files.append((path, sha)) }
        }
        files += [derived.transcripts, derived.genes, derived.transcriptGenes].map { ($0.path, $0.sha256) }
        files.append((derivation.genesWithoutFeatures.path, derivation.genesWithoutFeatures.sha256))
        return files
    }

    /// Reads the manifest of `setURL`. A schema newer than this build knows is refused in words before the decode.
    public static func load(from setURL: URL) throws -> ReferenceSetManifest {
        let url = setURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { throw ReferenceSetError.unreadable(url.path) }
        struct Version: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
        guard version <= currentSchemaVersion else { throw ReferenceSetError.newerSchema(version) }
        return try JSONDecoder().decode(ReferenceSetManifest.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
