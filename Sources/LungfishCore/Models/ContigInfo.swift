// ContigInfo.swift - Information about a contig/chromosome from VCF header
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ContigInfo

/// Information about a contig/chromosome from VCF header.
public struct ContigInfo: Sendable, Identifiable {
    public var id: String { name }

    /// Contig name
    public let name: String

    /// Contig length in base pairs
    public let length: Int?

    /// Assembly identifier
    public let assembly: String?

    public init(name: String, length: Int? = nil, assembly: String? = nil) {
        self.name = name
        self.length = length
        self.assembly = assembly
    }
}

extension ContigInfo: Codable {}
