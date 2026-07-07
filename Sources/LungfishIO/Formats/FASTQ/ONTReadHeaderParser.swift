// ONTReadHeaderParser.swift - Parse Oxford Nanopore FASTQ read headers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Parsed metadata from an Oxford Nanopore FASTQ read header.
///
/// ONT headers have the format:
/// ```
/// @readid runid=... ch=... start_time=... flow_cell_id=... sample_id=... barcode=...
/// ```
public struct ONTReadMetadata: Sendable, Equatable, Codable {
    public let readID: String
    public let runID: String?
    public let channel: Int?
    public let flowCellID: String?
    public let sampleID: String?
    public let barcode: String?
    public let barcodeAlias: String?
    public let basecallModel: String?
    public let protocolGroupID: String?
    public let basecallGPU: String?
}

public enum ONTReadHeaderParser {
    /// Parses an ONT read header line into structured metadata.
    ///
    /// - Parameter headerLine: The full header line (with or without leading `@`).
    /// - Returns: Parsed metadata, or `nil` if the line doesn't look like an ONT header.
    public static func parse(headerLine: String) -> ONTReadMetadata? {
        let line = headerLine.hasPrefix("@") ? String(headerLine.dropFirst()) : headerLine
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }

        let readID = String(first)
        var fields: [String: String] = [:]

        for token in tokens.dropFirst() {
            guard let eqIdx = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<eqIdx])
            let value = String(token[token.index(after: eqIdx)...])
            fields[key] = value
        }

        // Require at least one ONT-specific field to confirm this is ONT
        guard fields["runid"] != nil || fields["flow_cell_id"] != nil || fields["barcode"] != nil else {
            return nil
        }

        return ONTReadMetadata(
            readID: readID,
            runID: fields["runid"],
            channel: fields["ch"].flatMap { Int($0) },
            flowCellID: fields["flow_cell_id"],
            sampleID: fields["sample_id"],
            barcode: fields["barcode"],
            barcodeAlias: fields["barcode_alias"],
            basecallModel: fields["basecall_model_version_id"],
            protocolGroupID: fields["protocol_group_id"],
            basecallGPU: fields["basecall_gpu"]
        )
    }
}
