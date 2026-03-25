// NCBIBioSampleExporter.swift - NCBI BioSample TSV export for FASTQ metadata
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - NCBIBioSampleExporter

/// Exports `FASTQSampleMetadata` to NCBI BioSample submission TSV format.
///
/// The output follows the Pathogen.cl.1.0 or Pathogen.env.1.0 package
/// format depending on the selected package type. The TSV can be submitted
/// directly to NCBI's BioSample submission portal.
///
/// ## Usage
///
/// ```swift
/// let samples: [FASTQSampleMetadata] = [...]
/// let tsv = NCBIBioSampleExporter.export(samples: samples)
/// try tsv.write(to: outputURL, atomically: true, encoding: .utf8)
/// ```
public enum NCBIBioSampleExporter {

    /// NCBI BioSample package types.
    public enum BioSamplePackage: String, Sendable {
        /// Pathogen: clinical or host-associated; version 1.0
        case pathogenClinical = "Pathogen.cl.1.0"
        /// Pathogen: environmental/food/other; version 1.0
        case pathogenEnvironmental = "Pathogen.env.1.0"

        /// Human-readable label.
        public var displayLabel: String {
            switch self {
            case .pathogenClinical: return "Pathogen Clinical (Pathogen.cl.1.0)"
            case .pathogenEnvironmental: return "Pathogen Environmental (Pathogen.env.1.0)"
            }
        }
    }

    /// NCBI BioSample attribute names in submission template order.
    private static let bioSampleAttributes: [String] = [
        "sample_name",
        "sample_title",
        "organism",
        "collected_by",
        "collection_date",
        "geo_loc_name",
        "host",
        "host_disease",
        "isolation_source",
        "lat_lon",
        "instrument_model",
        "library_strategy",
        "purpose_of_sequencing",
    ]

    /// Extracts the value for a BioSample attribute from sample metadata.
    private static func value(for attribute: String, in sample: FASTQSampleMetadata) -> String {
        switch attribute {
        case "sample_name": return sample.sampleName
        case "sample_title": return sample.sampleName
        case "organism": return sample.organism ?? "metagenome"
        case "collected_by": return sample.sampleCollectedBy ?? ""
        case "collection_date": return sample.collectionDate ?? ""
        case "geo_loc_name": return sample.geoLocName ?? ""
        case "host": return sample.host ?? ""
        case "host_disease": return sample.hostDisease ?? ""
        case "isolation_source": return sample.sampleType ?? ""
        case "lat_lon": return ""
        case "instrument_model": return sample.sequencingInstrument ?? ""
        case "library_strategy": return sample.libraryStrategy ?? ""
        case "purpose_of_sequencing": return sample.purposeOfSequencing ?? ""
        default: return ""
        }
    }

    /// Exports an array of sample metadata to NCBI BioSample TSV format.
    ///
    /// - Parameters:
    ///   - samples: The sample metadata to export.
    ///   - package: The BioSample package type (default: clinical).
    /// - Returns: A TSV string suitable for NCBI BioSample submission.
    public static func export(
        samples: [FASTQSampleMetadata],
        package: BioSamplePackage = .pathogenClinical
    ) -> String {
        guard !samples.isEmpty else { return "" }

        var lines: [String] = []

        // Comment line identifying the package
        lines.append("# BioSample package: \(package.rawValue)")
        lines.append("# Exported from Lungfish Genome Browser")
        lines.append("")

        // Header row
        lines.append(bioSampleAttributes.joined(separator: "\t"))

        // Data rows
        for sample in samples {
            let values = bioSampleAttributes.map { attr in
                value(for: attr, in: sample)
            }
            lines.append(values.joined(separator: "\t"))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Exports to a file URL.
    ///
    /// - Parameters:
    ///   - samples: The sample metadata to export.
    ///   - url: The output file URL.
    ///   - package: The BioSample package type.
    public static func exportToFile(
        samples: [FASTQSampleMetadata],
        url: URL,
        package: BioSamplePackage = .pathogenClinical
    ) throws {
        let tsv = export(samples: samples, package: package)
        try tsv.write(to: url, atomically: true, encoding: .utf8)
    }
}
