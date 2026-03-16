// ToolVersionsManifest.swift - Decodable manifest for bundled tool versions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Decoded representation of `tool-versions.json`, the single source of truth
/// for all embedded bioinformatics tool versions, licenses, and source URLs.
///
/// Used by `NativeToolRunner.bundledVersions` at runtime and by the About window
/// to display accurate version and license information.
public struct ToolVersionsManifest: Codable, Sendable {
    public let formatVersion: String
    public let lastUpdated: String
    public let buildArchitecture: String
    public let tools: [ToolEntry]

    public struct ToolEntry: Codable, Sendable, Identifiable {
        public var id: String { name }

        public let name: String
        public let displayName: String
        public let version: String
        public let license: String
        public let licenseId: String
        public let sourceUrl: String
        public let releaseUrl: String
        public let licenseUrl: String
        public let copyright: String
        public let executables: [String]
        public let dependencies: [String]
        public let provisioningMethod: String
        public let notes: String?
    }
}
