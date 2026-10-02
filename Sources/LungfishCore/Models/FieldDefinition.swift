// FieldDefinition.swift - Definition of an INFO or FORMAT field from VCF header
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - FieldDefinition

/// Definition of an INFO or FORMAT field from VCF header.
public struct FieldDefinition: Sendable {

    /// Field identifier
    public let id: String

    /// Number of values (A=per-alt, R=per-allele, G=per-genotype, .=variable)
    public let number: String

    /// Data type (Integer, Float, Flag, Character, String)
    public let type: String

    /// Field description
    public let description: String

    /// Source (for INFO fields)
    public let source: String?

    /// Version (for INFO fields)
    public let version: String?

    public init(
        id: String,
        number: String,
        type: String,
        description: String,
        source: String? = nil,
        version: String? = nil
    ) {
        self.id = id
        self.number = number
        self.type = type
        self.description = description
        self.source = source
        self.version = version
    }
}

extension FieldDefinition: Codable {}
