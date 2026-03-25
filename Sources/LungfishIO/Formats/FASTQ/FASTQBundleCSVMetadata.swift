// FASTQBundleCSVMetadata.swift - CSV metadata import/export for FASTQ bundles
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "FASTQBundleCSVMetadata")

// MARK: - FASTQBundleCSVMetadata

/// Reads and writes CSV metadata files stored inside `.lungfishfastq` bundles.
///
/// The metadata file (`metadata.csv`) lives at the bundle root alongside the
/// FASTQ payload and sidecar JSON. It uses a simple two-column key/value
/// format or a freeform multi-column format with headers.
///
/// ## Two-column format (default)
///
/// ```csv
/// key,value
/// sample_name,Patient_42
/// collection_date,2025-01-15
/// tissue_type,Nasal swab
/// lab,CDC Atlanta
/// ```
///
/// ## Freeform format (auto-detected when >2 columns)
///
/// ```csv
/// sample_id,condition,replicate,batch
/// SRR123,treatment,1,batch_A
/// ```
///
/// ## Usage
///
/// ```swift
/// // Load
/// if let meta = FASTQBundleCSVMetadata.load(from: bundleURL) {
///     print(meta.keyValuePairs)  // ["sample_name": "Patient_42", ...]
/// }
///
/// // Save
/// let meta = FASTQBundleCSVMetadata(keyValuePairs: ["sample_name": "Patient_42"])
/// try FASTQBundleCSVMetadata.save(meta, to: bundleURL)
/// ```
public struct FASTQBundleCSVMetadata: Sendable, Equatable {

    /// Filename for the metadata CSV inside the bundle.
    public static let filename = "metadata.csv"

    /// Key-value metadata pairs (from two-column CSV or extracted from freeform).
    public let keyValuePairs: [String: String]

    /// Raw CSV headers (for freeform multi-column format).
    public let headers: [String]

    /// Raw CSV rows (for freeform multi-column format).
    /// Each inner array corresponds to one row of values.
    public let rows: [[String]]

    /// Whether this metadata uses the simple key/value format.
    public var isKeyValue: Bool {
        headers.count == 2
            && headers[0].lowercased().trimmingCharacters(in: .whitespaces) == "key"
            && headers[1].lowercased().trimmingCharacters(in: .whitespaces) == "value"
    }

    /// Creates key-value metadata.
    public init(keyValuePairs: [String: String]) {
        self.keyValuePairs = keyValuePairs
        self.headers = ["key", "value"]
        self.rows = keyValuePairs.sorted(by: { $0.key < $1.key }).map { [$0.key, $0.value] }
    }

    /// Creates freeform multi-column metadata.
    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows

        // Extract key-value pairs if in key/value format
        if headers.count == 2,
           headers[0].lowercased().trimmingCharacters(in: .whitespaces) == "key",
           headers[1].lowercased().trimmingCharacters(in: .whitespaces) == "value" {
            var pairs: [String: String] = [:]
            for row in rows where row.count >= 2 {
                let key = row[0].trimmingCharacters(in: .whitespaces)
                let value = row[1].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    pairs[key] = value
                }
            }
            self.keyValuePairs = pairs
        } else {
            // For freeform format, use first column as key, rest as composite value
            var pairs: [String: String] = [:]
            for row in rows where !row.isEmpty {
                let key = row[0].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, row.count > 1 {
                    pairs[key] = row.dropFirst().joined(separator: ", ")
                }
            }
            self.keyValuePairs = pairs
        }
    }

    /// Returns the value for a specific metadata key, case-insensitive.
    public func value(forKey key: String) -> String? {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespaces)
        for (k, v) in keyValuePairs {
            if k.lowercased().trimmingCharacters(in: .whitespaces) == normalizedKey {
                return v
            }
        }
        return nil
    }

    /// Returns a display label for this bundle, derived from metadata.
    ///
    /// Checks common label keys in priority order: `sample_name`, `label`,
    /// `name`, `sample_id`, `id`.
    public var displayLabel: String? {
        let labelKeys = ["sample_name", "label", "name", "sample_id", "id", "patient", "subject"]
        for key in labelKeys {
            if let val = value(forKey: key), !val.isEmpty {
                return val
            }
        }
        return nil
    }
}

// MARK: - Load / Save

extension FASTQBundleCSVMetadata {

    /// Returns the URL for the metadata CSV inside a bundle.
    public static func metadataURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(filename)
    }

    /// Returns true if a metadata CSV exists in the bundle.
    public static func exists(in bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: metadataURL(in: bundleURL).path)
    }

    /// Loads metadata from a bundle's `metadata.csv`, if present.
    public static func load(from bundleURL: URL) -> FASTQBundleCSVMetadata? {
        let url = metadataURL(in: bundleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return parse(csv: content)
        } catch {
            logger.warning("Failed to load CSV metadata from \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves metadata to a bundle's `metadata.csv`.
    public static func save(_ metadata: FASTQBundleCSVMetadata, to bundleURL: URL) throws {
        let url = metadataURL(in: bundleURL)
        let csv = serialize(metadata: metadata)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Saved CSV metadata to \(url.lastPathComponent) (\(metadata.keyValuePairs.count) entries)")
    }

    /// Deletes the metadata CSV from a bundle.
    public static func delete(from bundleURL: URL) {
        let url = metadataURL(in: bundleURL)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - CSV Parsing

    /// Parses a CSV string into metadata.
    static func parse(csv: String) -> FASTQBundleCSVMetadata? {
        let lines = csv.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first else { return nil }
        let headers = parseCSVLine(headerLine)
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            rows.append(fields)
        }

        return FASTQBundleCSVMetadata(headers: headers, rows: rows)
    }

    /// Parses a single CSV line, handling quoted fields.
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: - CSV Serialization

    /// Serializes metadata to a CSV string.
    static func serialize(metadata: FASTQBundleCSVMetadata) -> String {
        var lines: [String] = []
        lines.append(metadata.headers.map { escapeCSVField($0) }.joined(separator: ","))
        for row in metadata.rows {
            lines.append(row.map { escapeCSVField($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes a CSV field, quoting it if it contains commas, quotes, or newlines.
    static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
