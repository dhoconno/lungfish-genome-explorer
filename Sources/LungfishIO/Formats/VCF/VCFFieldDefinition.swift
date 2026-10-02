// VCFFieldDefinition.swift - Definition of a VCF INFO or FORMAT field
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Definition of a VCF INFO or FORMAT field.
public struct VCFFieldDefinition: Sendable {
    public let id: String
    public let number: String  // "1", "A", "G", "R", "."
    public let type: String    // "Integer", "Float", "String", "Flag", "Character"
    public let description: String

    public init(id: String, number: String, type: String, description: String) {
        self.id = id
        self.number = number
        self.type = type
        self.description = description
    }
}
