// EsVirituDetectionExport.swift - The EsViritu detections export that the viewer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The EsViritu detections export (Phase 2.12 lane 12.31, ARCH ruling 1.1 row A1, BIO ruling on 12.31 G1).
///
/// The view's writer and `esviritu export detections` order the batch's assemblies and name the metadata files with
/// these functions, so the view, the in-app writer and the leaf agree on the rows and on the record's inputs.
public enum EsVirituDetectionExport {
    /// Orders batch assemblies by read count, highest first, then by sample id and then by assembly accession, so
    /// assemblies with tied read counts keep one order from launch to launch.
    public static func assemblyPrecedes(_ lhs: ViralAssembly, _ rhs: ViralAssembly) -> Bool {
        if lhs.totalReads != rhs.totalReads {
            return lhs.totalReads > rhs.totalReads
        }
        let lhsSample = lhs.contigs.first?.sampleId ?? ""
        let rhsSample = rhs.contigs.first?.sampleId ?? ""
        if lhsSample != rhsSample {
            return lhsSample < rhsSample
        }
        return lhs.assembly < rhs.assembly
    }

    /// The sample metadata files of a result folder, the table and its edit journal, that an export reads when it
    /// writes a metadata column. Empty when it writes none. A caller keeps only the files that exist.
    public static func metadataInputURLs(in resultURL: URL, writesMetadata: Bool) -> [URL] {
        guard writesMetadata else { return [] }
        let folder = resultURL.appendingPathComponent("metadata", isDirectory: true)
        return [
            folder.appendingPathComponent("sample_metadata.tsv"),
            folder.appendingPathComponent("sample_metadata_edits.json"),
        ]
    }
}

extension EsVirituDetectionExport {
    /// Builds delimited export content from all detections.
    public static func buildDelimitedExport(
        result: LungfishIO.EsVirituResult,
        separator: String,
        metadataHeaders: [String],
        metadataValuesBySample: [String: [String]]
    ) -> String {
        var lines: [String] = []

        var headers = [
            "Sample ID", "Virus Name", "Accession", "Assembly", "Kingdom", "Phylum",
            "Class", "Order", "Family", "Genus", "Species", "Subspecies",
            "Read Count", "RPKMF", "Coverage", "Identity", "Covered Bases",
            "Nucleotide Diversity", "Assembly Length", "Filtered Reads",
            "Segment", "Length",
        ]
        // Append visible metadata column headers
        headers.append(contentsOf: metadataHeaders)
        lines.append(headers.joined(separator: separator))

        for detection in result.detections {
            var row = [
                escapeField(detection.sampleId, separator: separator),
                escapeField(detection.name, separator: separator),
                detection.accession,
                detection.assembly,
                escapeField(detection.kingdom ?? "", separator: separator),
                escapeField(detection.phylum ?? "", separator: separator),
                escapeField(detection.tclass ?? "", separator: separator),
                escapeField(detection.order ?? "", separator: separator),
                escapeField(detection.family ?? "", separator: separator),
                escapeField(detection.genus ?? "", separator: separator),
                escapeField(detection.species ?? "", separator: separator),
                escapeField(detection.subspecies ?? "", separator: separator),
                "\(detection.readCount)",
                String(format: "%.2f", detection.rpkmf),
                String(format: "%.2f", detection.meanCoverage),
                String(format: "%.2f", detection.avgReadIdentity),
                "\(detection.coveredBases)",
                String(format: "%.6f", detection.pi),
                "\(detection.assemblyLength)",
                "\(detection.filteredReadsInSample)",
                detection.segment ?? "",
                "\(detection.length)",
            ]
            for value in metadataValuesBySample[detection.sampleId] ?? [] {
                row.append(escapeField(value, separator: separator))
            }
            lines.append(row.joined(separator: separator))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes a field for CSV output.
    private static func escapeField(_ value: String, separator: String) -> String {
        guard separator == "," else { return value }
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
