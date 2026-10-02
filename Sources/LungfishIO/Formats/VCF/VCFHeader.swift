// VCFHeader.swift - Parsed VCF header information
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - VCFHeader

/// Parsed VCF header information.
public struct VCFHeader: Sendable {

    /// File format version (e.g., "VCFv4.3")
    public let fileFormat: String

    /// INFO field definitions
    public let infoFields: [String: VCFFieldDefinition]

    /// FORMAT field definitions
    public let formatFields: [String: VCFFieldDefinition]

    /// FILTER definitions
    public let filters: [String: String]

    /// Contig definitions with lengths
    public let contigs: [String: Int]

    /// Sample names
    public let sampleNames: [String]

    /// Other header lines
    public let otherHeaders: [String: String]

    public init(
        fileFormat: String = "VCFv4.3",
        infoFields: [String: VCFFieldDefinition] = [:],
        formatFields: [String: VCFFieldDefinition] = [:],
        filters: [String: String] = [:],
        contigs: [String: Int] = [:],
        sampleNames: [String] = [],
        otherHeaders: [String: String] = [:]
    ) {
        self.fileFormat = fileFormat
        self.infoFields = infoFields
        self.formatFields = formatFields
        self.filters = filters
        self.contigs = contigs
        self.sampleNames = sampleNames
        self.otherHeaders = otherHeaders
    }
}
