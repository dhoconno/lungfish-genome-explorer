// ProvenanceToolIdentity.swift - Name, version and kind of the tool behind a provenance record
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceToolIdentity

public struct ProvenanceToolIdentity: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let kind: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case kind
    }

    public init(name: String, version: String = "unknown", kind: String? = nil) {
        self.name = ProvenanceName.required(name)
        self.version = ProvenanceVersion.required(version)
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = ProvenanceName.required(try container.decodeIfPresent(String.self, forKey: .name))
        version = ProvenanceVersion.required(try container.decodeIfPresent(String.self, forKey: .version))
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
    }
}
