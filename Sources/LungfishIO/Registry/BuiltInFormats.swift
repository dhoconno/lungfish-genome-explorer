// BuiltInFormats.swift - Concrete FormatImporter/FormatExporter implementations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - FASTA Importer

/// Imports FASTA sequence files.
public final class FASTAFormatImporter: FormatImporter, @unchecked Sendable {

    public let descriptor = FormatDescriptor(
        identifier: .fasta,
        displayName: "FASTA",
        formatDescription: "Simple nucleotide or protein sequence format",
        extensions: ["fa", "fasta", "fna", "faa", "ffn", "frn", "fas"],
        capabilities: .nucleotideSequence,
        uiCategory: .sequence
    )

    public init() {}

    public func importDocument(from url: URL) async throws -> ImportResult {
        let reader = try FASTAReader(url: url)
        let sequences = try await reader.readAll()
        return ImportResult(
            sequences: sequences,
            sourceURL: url,
            sourceFormat: .fasta
        )
    }
}

// MARK: - FASTA Exporter

/// Exports sequences to FASTA format.
public final class FASTAFormatExporter: FormatExporter, @unchecked Sendable {

    public let descriptor = FormatDescriptor(
        identifier: .fasta,
        displayName: "FASTA",
        formatDescription: "Simple nucleotide or protein sequence format",
        extensions: ["fa", "fasta"],
        capabilities: .nucleotideSequence,
        uiCategory: .sequence
    )

    public var requiredCapabilities: DocumentCapability { .nucleotideSequence }

    public init() {}

    public func export(document: ImportResult, to url: URL) async throws {
        guard !document.sequences.isEmpty else {
            throw ExportError.incompatibleDocument(format: .fasta, reason: "No sequences to export")
        }
        let writer = FASTAWriter(url: url)
        try writer.write(document.sequences)
    }

    public func dataLossWarnings(for document: ImportResult) -> [DataLossWarning] {
        var warnings: [DataLossWarning] = []
        if document.annotationCount > 0 {
            warnings.append(.annotationsLost)
        }
        if document.sequences.contains(where: { $0.qualityScores != nil }) {
            warnings.append(.qualityScoresLost)
        }
        return warnings
    }
}

// MARK: - GenBank Importer

/// Imports GenBank annotated sequence files.
public final class GenBankFormatImporter: FormatImporter, @unchecked Sendable {

    public let descriptor = FormatDescriptor(
        identifier: .genbank,
        displayName: "GenBank",
        formatDescription: "Annotated sequence format with features and metadata",
        extensions: ["gb", "gbk", "genbank", "gbff"],
        capabilities: [.nucleotideSequence, .annotations],
        uiCategory: .sequence
    )

    public init() {}

    public func importDocument(from url: URL) async throws -> ImportResult {
        let reader = try GenBankReader(url: url)
        let records = try await reader.readAll()

        var sequences: [LungfishCore.Sequence] = []
        var annotationsBySequence: [String: [SequenceAnnotation]] = [:]

        for record in records {
            sequences.append(record.sequence)
            if !record.annotations.isEmpty {
                annotationsBySequence[record.sequence.name, default: []].append(contentsOf: record.annotations)
            }
        }

        let metadata = LoadedMetadata(
            accession: records.first?.accession
        )

        return ImportResult(
            sequences: sequences,
            annotationsBySequence: annotationsBySequence,
            sourceURL: url,
            sourceFormat: .genbank,
            metadata: metadata
        )
    }
}

// MARK: - GenBank Exporter

/// Exports sequences and annotations to GenBank format.
public final class GenBankFormatExporter: FormatExporter, @unchecked Sendable {

    public let descriptor = FormatDescriptor(
        identifier: .genbank,
        displayName: "GenBank",
        formatDescription: "Annotated sequence format with features and metadata",
        extensions: ["gb", "gbk"],
        capabilities: [.nucleotideSequence, .annotations],
        uiCategory: .sequence
    )

    public var requiredCapabilities: DocumentCapability { .nucleotideSequence }

    public init() {}

    public func export(document: ImportResult, to url: URL) async throws {
        guard !document.sequences.isEmpty else {
            throw ExportError.incompatibleDocument(format: .genbank, reason: "No sequences to export")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MMM-yyyy"
        let dateString = dateFormatter.string(from: Date()).uppercased()

        var records: [GenBankRecord] = []
        for sequence in document.sequences {
            let annotations = document.annotationsBySequence[sequence.name] ?? []
            let moleculeType: MoleculeType
            switch sequence.alphabet {
            case .dna: moleculeType = .dna
            case .rna: moleculeType = .rna
            case .protein: moleculeType = .protein
            }
            let locus = LocusInfo(
                name: sequence.name,
                length: sequence.length,
                moleculeType: moleculeType,
                topology: sequence.isCircular ? .circular : .linear,
                division: nil,
                date: dateString
            )
            records.append(GenBankRecord(
                sequence: sequence,
                annotations: annotations,
                locus: locus,
                definition: sequence.description,
                accession: nil,
                version: nil
            ))
        }

        let writer = GenBankWriter(url: url)
        try writer.write(records)
    }
}

// MARK: - GFF3 Importer

/// Imports GFF3 annotation files.
public final class GFF3FormatImporter: FormatImporter, @unchecked Sendable {

    public let descriptor = FormatDescriptor(
        identifier: .gff3,
        displayName: "GFF3",
        formatDescription: "General Feature Format version 3 for annotations",
        extensions: ["gff", "gff3"],
        capabilities: .annotations,
        uiCategory: .annotation
    )

    public init() {}

    public func importDocument(from url: URL) async throws -> ImportResult {
        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: url)

        var annotationsBySequence: [String: [SequenceAnnotation]] = [:]
        for annotation in annotations {
            let chrom = annotation.chromosome ?? "unknown"
            annotationsBySequence[chrom, default: []].append(annotation)
        }

        return ImportResult(
            annotationsBySequence: annotationsBySequence,
            sourceURL: url,
            sourceFormat: .gff3
        )
    }
}

// MARK: - GFF3 Exporter

/// Exports annotations to GFF3 format.
public final class GFF3FormatExporter: FormatExporter, @unchecked Sendable {

    public let descriptor = FormatDescriptor(
        identifier: .gff3,
        displayName: "GFF3",
        formatDescription: "General Feature Format version 3 for annotations",
        extensions: ["gff3"],
        capabilities: .annotations,
        uiCategory: .annotation
    )

    public var requiredCapabilities: DocumentCapability { .annotations }

    public init() {}

    public func export(document: ImportResult, to url: URL) async throws {
        let allAnnotations = document.annotationsBySequence.values.flatMap { $0 }
        guard !allAnnotations.isEmpty else {
            throw ExportError.incompatibleDocument(format: .gff3, reason: "No annotations to export")
        }
        try await GFF3Writer.write(allAnnotations, to: url, source: "Lungfish")
    }

    public func dataLossWarnings(for document: ImportResult) -> [DataLossWarning] {
        var warnings: [DataLossWarning] = []
        if !document.sequences.isEmpty {
            warnings.append(DataLossWarning(
                severity: .info,
                message: "Sequence data will not be included in GFF3 output",
                affectedCapability: .nucleotideSequence
            ))
        }
        return warnings
    }
}
