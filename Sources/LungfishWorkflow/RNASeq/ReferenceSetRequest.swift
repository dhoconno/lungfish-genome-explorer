// ReferenceSetRequest.swift - What a reference set is built from, its id and its refusals (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum ReferenceSetExtraKind: String, Codable, Sendable, CaseIterable {
    case virus, bacterium
    case spikeIn = "spike-in"
}

/// LGE's layout, or the deposit layout of one study, a named reproduce option (`reference-set.md`).
public enum ReferenceSetLayout: Sendable, Equatable {
    case lge
    case deposit(study: String)

    var idComponent: String {
        switch self {
        case .lge: return "lge"
        case .deposit(let study): return "deposit-\(study)"
        }
    }

    var manifestLayout: ReferenceSetManifest.Layout {
        switch self {
        case .lge: return .init(kind: "lge")
        case .deposit(let study): return .init(kind: "deposit", study: study)
        }
    }
}

/// A sequence the person adds, such as a virus. In LGE's layout each record is one feature. In the deposit layout an
/// extra may bring the deposit's own annotation, whose features and names it keeps.
public struct ReferenceSetExtraInput: Sendable, Equatable {
    public var name: String
    public var kind: ReferenceSetExtraKind
    public var fasta: URL
    public var annotation: URL?
    /// A GTF whose `gene_biotype "rRNA"` gene lines are the extra's rRNA mask, in either layout and never features
    /// (BIO-NOTHOST-BARCODE items 1 to 5).
    public var mask: URL?

    public init(name: String, kind: ReferenceSetExtraKind, fasta: URL, annotation: URL? = nil, mask: URL? = nil) {
        self.name = name
        self.kind = kind
        self.fasta = fasta
        self.annotation = annotation
        self.mask = mask
    }
}

public struct ReferenceSetRequest: Sendable {
    public var name: String
    public var species: String
    public var assemblyName: String
    public var assemblyAccession: String?
    public var assemblySourceURL: String?
    public var annotationSource: String
    public var annotationRelease: String
    /// A FASTA, plain or gzip, or a `.lungfishref` whose genome is read and never written.
    public var genome: URL
    public var annotation: URL
    public var extras: [ReferenceSetExtraInput]
    public var layout: ReferenceSetLayout
    /// The contigs the person names as mitochondrial. Empty lets the owner find them, never by a gene name.
    public var mitochondrialContigs: [String]
    public var assemblyReport: URL?
    /// A named default, whose sha256 values the inputs must equal.
    public var expected: ReferenceSetDefault?

    public init(
        name: String, species: String, assemblyName: String, assemblyAccession: String? = nil,
        assemblySourceURL: String? = nil, annotationSource: String, annotationRelease: String, genome: URL,
        annotation: URL, extras: [ReferenceSetExtraInput] = [], layout: ReferenceSetLayout = .lge,
        mitochondrialContigs: [String] = [], assemblyReport: URL? = nil, expected: ReferenceSetDefault? = nil
    ) {
        self.name = name
        self.species = species
        self.assemblyName = assemblyName
        self.assemblyAccession = assemblyAccession
        self.assemblySourceURL = assemblySourceURL
        self.annotationSource = annotationSource
        self.annotationRelease = annotationRelease
        self.genome = genome
        self.annotation = annotation
        self.extras = extras
        self.layout = layout
        self.mitochondrialContigs = mitochondrialContigs
        self.assemblyReport = assemblyReport
        self.expected = expected
    }
}

/// `<species>-<assembly>-<annotation source and release>-<layout>-<digest>` (`reference-set.md`, section The id).
public enum ReferenceSetID {
    public struct Content: Sendable, Equatable {
        public var role: String
        public var fileName: String
        public var sha256: String

        public init(role: String, fileName: String, sha256: String) {
            self.role = role
            self.fileName = fileName
            self.sha256 = sha256
        }
    }

    public static func make(
        species: String, assembly: String, annotationSource: String, annotationRelease: String,
        layout: ReferenceSetLayout, contents: [Content], deriveVersion: String
    ) -> String {
        var list = contents.map { "\($0.role)\t\($0.fileName)\t\($0.sha256)\n" }.joined()
        list += "layout\t\(layout.idComponent)\nderive\tgffread \(deriveVersion)\n"
        let digest = sha256Hex(Data(list.utf8)).prefix(12)
        let parts = [species.lowercased(), assembly, (annotationSource + annotationRelease).lowercased(), layout.idComponent]
        return parts.map(component).joined(separator: "-") + "-" + digest
    }

    static func component(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
