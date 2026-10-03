// ProvenanceOptions.swift - Explicit, default and resolved options recorded for a run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceOptions

public struct ProvenanceOptions: Codable, Sendable, Equatable {
    public let explicit: [String: ParameterValue]
    public let defaults: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]

    private enum CodingKeys: String, CodingKey {
        case explicit
        case defaults
        case resolvedDefaults
        case userVisibleOptions
    }

    public init(
        explicit: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolvedDefaults: [String: ParameterValue] = [:]
    ) {
        self.explicit = explicit
        self.defaults = defaults
        self.resolvedDefaults = resolvedDefaults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedExplicit = try Self.decodeMapIfPresent(from: container, forKey: .explicit) ?? [:]
        let userVisibleOptions = try Self.decodeMapIfPresent(from: container, forKey: .userVisibleOptions) ?? [:]
        let legacyTopLevelOptions = try Self.decodeLegacyTopLevelOptions(from: decoder)
        decodedExplicit.merge(legacyTopLevelOptions) { current, _ in current }
        decodedExplicit.merge(userVisibleOptions) { _, userVisible in userVisible }

        explicit = decodedExplicit
        defaults = try Self.decodeMapIfPresent(from: container, forKey: .defaults) ?? [:]
        resolvedDefaults = try Self.decodeMapIfPresent(from: container, forKey: .resolvedDefaults) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(explicit, forKey: .explicit)
        try container.encode(defaults, forKey: .defaults)
        try container.encode(resolvedDefaults, forKey: .resolvedDefaults)
    }

    private static func decodeMapIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [String: ParameterValue]? {
        guard container.contains(key) else { return nil }
        let values = try container.decode([String: FlexibleParameterValue].self, forKey: key)
        return values.mapValues(\.value)
    }

    private static func decodeLegacyTopLevelOptions(from decoder: Decoder) throws -> [String: ParameterValue] {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let reservedKeys: Set<String> = [
            CodingKeys.explicit.stringValue,
            CodingKeys.defaults.stringValue,
            CodingKeys.resolvedDefaults.stringValue,
            CodingKeys.userVisibleOptions.stringValue,
        ]

        var values: [String: ParameterValue] = [:]
        for key in container.allKeys where !reservedKeys.contains(key.stringValue) {
            values[key.stringValue] = try container.decode(FlexibleParameterValue.self, forKey: key).value
        }
        return values
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    private struct FlexibleParameterValue: Decodable {
        let value: ParameterValue

        init(from decoder: Decoder) throws {
            if let typedValue = try? ParameterValue(from: decoder) {
                value = typedValue
                return
            }

            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = .null
            } else if let boolValue = try? container.decode(Bool.self) {
                value = .boolean(boolValue)
            } else if let intValue = try? container.decode(Int.self) {
                value = .integer(intValue)
            } else if let doubleValue = try? container.decode(Double.self) {
                value = .number(doubleValue)
            } else if let stringValue = try? container.decode(String.self) {
                value = .string(stringValue)
            } else if let arrayValue = try? container.decode([FlexibleParameterValue].self) {
                value = .array(arrayValue.map(\.value))
            } else if let dictionaryValue = try? container.decode([String: FlexibleParameterValue].self) {
                value = .dictionary(dictionaryValue.mapValues(\.value))
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported provenance option value"
                )
            }
        }
    }
}
