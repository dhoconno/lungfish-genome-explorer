// NvdDataConverter.swift — Utility functions for NVD data display and extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Utility functions for extracting, formatting, and converting NVD data.
enum NvdDataConverter {

    /// Extracts a contig sequence from a multi-FASTA file by matching the header.
    ///
    /// Reads the FASTA file line by line, finds the `>` header whose first word
    /// matches `contigName`, and collects all subsequent sequence lines until the
    /// next `>` header or end of file.
    ///
    /// - Parameters:
    ///   - fastaURL: URL of the multi-FASTA file.
    ///   - contigName: The contig/sequence name to find (matched against the first
    ///     word of each FASTA header, i.e. everything before the first whitespace).
    /// - Returns: The concatenated sequence string, or `nil` if the contig was not found
    ///   or the file could not be read.
    static func extractContigSequence(from fastaURL: URL, contigName: String) -> String? {
        guard let contents = try? String(contentsOf: fastaURL, encoding: .utf8) else {
            return nil
        }

        var found = false
        var sequence: [String] = []

        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix(">") {
                if found {
                    // We hit the next header — stop collecting
                    break
                }
                // Extract the first word from the header (everything after '>' up to first whitespace)
                let headerBody = String(trimmed.dropFirst())
                let firstWord = headerBody.split(separator: " ", maxSplits: 1).first.map(String.init) ?? headerBody
                if firstWord == contigName {
                    found = true
                }
            } else if found {
                sequence.append(trimmed)
            }
        }

        guard !sequence.isEmpty else { return nil }
        return sequence.joined()
    }

    /// Formats a display name from a SPAdes-style contig ID and length.
    ///
    /// Extracts the NODE number from identifiers like `NODE_1183_length_227_cov_1.116279`
    /// and formats as `"NODE_1183 (227 bp)"`.
    ///
    /// - Parameters:
    ///   - qseqid: The full query sequence ID from the BLAST output.
    ///   - qlen: The contig length in bases.
    /// - Returns: A human-readable display name.
    static func displayName(for qseqid: String, qlen: Int) -> String {
        let parts = qseqid.split(separator: "_")

        // Try to extract NODE_N from SPAdes-style IDs
        if parts.count >= 2, parts[0].uppercased() == "NODE" {
            let nodeName = "\(parts[0])_\(parts[1])"
            return "\(nodeName) (\(formatLength(qlen)))"
        }

        // For other naming conventions, truncate long names
        let name = qseqid.count > 30 ? String(qseqid.prefix(27)) + "..." : qseqid
        return "\(name) (\(formatLength(qlen)))"
    }

    /// Strips the common prefix from an array of sample IDs.
    ///
    /// Delegates to `NvdSamplePickerView.commonPrefix(of:)` for consistent behavior
    /// across the sample picker and the result view controller.
    ///
    /// - Parameter names: Array of sample ID strings.
    /// - Returns: The longest common prefix ending at a word boundary.
    static func commonPrefix(of names: [String]) -> String {
        NvdSamplePickerView.commonPrefix(of: names)
    }

    // MARK: - Private Helpers

    /// Formats a base-pair length with comma separators and "bp" suffix.
    private static func formatLength(_ length: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: length)) ?? "\(length)"
        return "\(formatted) bp"
    }
}
