// MappingResultExportBuilder.swift - The mapping table export and the values its record resolves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

enum MappingResultExportError: LocalizedError {
    case noData
    case unsupportedFormat(ResultExportFormat)

    var errorDescription: String? {
        switch self {
        case .noData:
            return "No mapping result data is loaded; cannot export."
        case .unsupportedFormat(let format):
            return "Export format '\(format.rawValue)' is not supported for mapping results."
        }
    }
}

enum MappingResultExportBuilder {
    private static let numericLocale = Locale(identifier: "en_US_POSIX")

    static func delimitedContent(for result: MappingResult, separator: String) -> String {
        let headers = [
            "Contig",
            "Length",
            "Mapped Reads",
            "% Mapped",
            "Mean Depth",
            "Coverage Breadth",
            "Median MAPQ",
            "Mean Identity",
        ]
        let rows = result.contigs.map { contig in
            [
                escaped(contig.contigName, separator: separator),
                "\(contig.contigLength)",
                "\(contig.mappedReads)",
                String(format: "%.4f", locale: numericLocale, contig.mappedReadPercent),
                String(format: "%.4f", locale: numericLocale, contig.meanDepth),
                String(format: "%.4f", locale: numericLocale, contig.coverageBreadth),
                String(format: "%.4f", locale: numericLocale, contig.medianMAPQ),
                String(format: "%.4f", locale: numericLocale, contig.meanIdentity),
            ].joined(separator: separator)
        }
        return ([headers.joined(separator: separator)] + rows).joined(separator: "\n") + "\n"
    }

    /// The export record's resolved values. `contigCount` stays the number of
    /// rows written. A result that records both reference counts (schema 2)
    /// adds them, and a schema-1 result adds neither (BIO ruling Q-S3, fix 5).
    static func resolvedValues(for result: MappingResult, sourceCount: Int) -> [String: ParameterValue] {
        var values: [String: ParameterValue] = [
            "contigCount": .integer(result.contigs.count),
            "mappedReads": .integer(result.mappedReads),
            "sourceCount": .integer(sourceCount),
            "totalReads": .integer(result.totalReads),
        ]
        if let referenceCount = result.referenceCount, let unalignedReferenceCount = result.unalignedReferenceCount {
            values["referenceCount"] = .integer(referenceCount)
            values["unalignedReferenceCount"] = .integer(unalignedReferenceCount)
        }
        return values
    }

    private static func escaped(_ value: String, separator: String) -> String {
        guard value.contains(separator) || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
