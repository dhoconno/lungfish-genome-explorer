// VCFMetadata.swift - Metadata from VCF file header
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - VCFMetadata

/// Metadata from VCF file header.
public struct VCFMetadata: Sendable {

    /// VCF format version
    public var fileFormat: String?

    /// File date
    public var fileDate: String?

    /// Reference genome used
    public var reference: String?

    /// Contig/chromosome definitions
    public var contigs: [ContigInfo]

    /// INFO field definitions
    public var infoFields: [String: FieldDefinition]

    /// FORMAT field definitions
    public var formatFields: [String: FieldDefinition]

    /// FILTER definitions
    public var filters: [String: String]

    /// Source program
    public var source: String?

    /// Creates empty metadata.
    public init(
        fileFormat: String? = nil,
        fileDate: String? = nil,
        reference: String? = nil,
        contigs: [ContigInfo] = [],
        infoFields: [String: FieldDefinition] = [:],
        formatFields: [String: FieldDefinition] = [:],
        filters: [String: String] = [:],
        source: String? = nil
    ) {
        self.fileFormat = fileFormat
        self.fileDate = fileDate
        self.reference = reference
        self.contigs = contigs
        self.infoFields = infoFields
        self.formatFields = formatFields
        self.filters = filters
        self.source = source
    }
}

// MARK: - VCFMetadata Codable

extension VCFMetadata: Codable {}
