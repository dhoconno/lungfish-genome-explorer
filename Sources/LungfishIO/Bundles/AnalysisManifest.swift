// AnalysisManifest.swift - Per-bundle analysis history manifest
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "AnalysisManifest")

// MARK: - AnalysisParameterValue

/// A type-safe, Codable union for tool parameter values stored in analysis manifests.
///
/// LungfishIO does not depend on LungfishWorkflow, so this is defined locally
/// rather than reusing `AnyCodableValue` from that module.
public enum AnalysisParameterValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Int before Bool: JSON integer 1 would otherwise decode as Bool(true).
        // JSON boolean true/false do NOT decode as Int, so this order is safe.
        if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .double(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
}

// MARK: - AnalysisManifestEntry

/// A single record in a bundle's analysis history.
public struct AnalysisManifestEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let tool: String
    public let timestamp: Date
    /// Path to the analysis directory relative to `Analyses/`.
    ///
    /// Historical manifests stored only the directory basename; readers still
    /// resolve those entries by basename for compatibility.
    public let analysisDirectoryName: String
    public let displayName: String
    public let parameters: [String: AnalysisParameterValue]
    public let summary: String
    public let status: AnalysisStatus

    /// Outcome of the analysis run.
    public enum AnalysisStatus: String, Codable, Sendable {
        case completed
        case failed
    }

    public init(
        id: UUID = UUID(),
        tool: String,
        timestamp: Date = Date(),
        analysisDirectoryName: String,
        displayName: String,
        parameters: [String: AnalysisParameterValue] = [:],
        summary: String,
        status: AnalysisStatus = .completed
    ) {
        self.id = id
        self.tool = tool
        self.timestamp = timestamp
        self.analysisDirectoryName = analysisDirectoryName
        self.displayName = displayName
        self.parameters = parameters
        self.summary = summary
        self.status = status
    }
}

// MARK: - AnalysisManifest

/// The top-level structure serialized to `analyses-manifest.json` inside a bundle.
public struct AnalysisManifest: Codable, Sendable {
    /// Filename written alongside the bundle contents.
    public static let filename = "analyses-manifest.json"

    public var schemaVersion: Int = 1
    public var analyses: [AnalysisManifestEntry]

    public init(analyses: [AnalysisManifestEntry] = []) {
        self.analyses = analyses
    }
}

public enum AnalysisManifestStoreError: Error, LocalizedError, Sendable {
    case corruptManifest(path: String)

    public var errorDescription: String? {
        switch self {
        case .corruptManifest(let path):
            return "Could not decode existing analysis manifest at '\(path)'"
        }
    }
}

// MARK: - AnalysisManifestStore

/// Reads, writes, and prunes the `analyses-manifest.json` stored inside a bundle directory.
public enum AnalysisManifestStore {

    // MARK: - Load

    /// Loads the manifest from `bundleURL`, pruning entries whose analysis directories
    /// no longer exist under `projectURL/Analyses/` or grouped descendants.
    ///
    /// Returns an empty manifest when the file is missing or cannot be decoded.
    public static func load(bundleURL: URL, projectURL: URL) -> AnalysisManifest {
        let manifestURL = bundleURL.appendingPathComponent(AnalysisManifest.filename)

        guard let data = try? Data(contentsOf: manifestURL) else {
            logger.debug("No manifest found at \(manifestURL.path); returning empty")
            return AnalysisManifest()
        }

        guard var manifest = try? decoder.decode(AnalysisManifest.self, from: data) else {
            logger.warning("Could not decode manifest at \(manifestURL.path); returning empty")
            return AnalysisManifest()
        }

        let pruned = pruneStaleEntries(manifest: &manifest, projectURL: projectURL)
        if pruned > 0 {
            logger.info("Pruned \(pruned) stale entries; re-saving manifest")
            try? save(manifest, to: manifestURL)
        }

        return manifest
    }

    // MARK: - Record

    /// Appends `entry` to the bundle's manifest and saves atomically.
    public static func recordAnalysis(_ entry: AnalysisManifestEntry, bundleURL: URL) throws {
        let manifestURL = bundleURL.appendingPathComponent(AnalysisManifest.filename)

        var manifest: AnalysisManifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            do {
                manifest = try decoder.decode(AnalysisManifest.self, from: data)
            } catch {
                logger.error("Could not decode existing manifest at \(manifestURL.path); refusing to overwrite")
                throw AnalysisManifestStoreError.corruptManifest(path: manifestURL.path)
            }
        } else {
            manifest = AnalysisManifest()
        }

        manifest.analyses.append(entry)
        try save(manifest, to: manifestURL)
        logger.info("Recorded \(entry.tool) analysis '\(entry.analysisDirectoryName)' in bundle manifest")
    }

    // MARK: - Prune

    /// Resolves a manifest entry to its analysis directory, including user-created
    /// grouping folders under `Analyses/`.
    public static func resolveAnalysisDirectory(for entry: AnalysisManifestEntry, projectURL: URL) -> URL? {
        let analysesBase = projectURL.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        let rawName = entry.analysisDirectoryName
        guard !rawName.isEmpty,
              !rawName.hasPrefix("/") else {
            return nil
        }

        let pathComponents = rawName.split(separator: "/").map(String.init)
        guard !pathComponents.isEmpty,
              !pathComponents.contains("..") else {
            return nil
        }

        let explicitURL = pathComponents.reduce(analysesBase) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        let fm = FileManager.default
        if directoryExists(at: explicitURL, fileManager: fm) {
            return explicitURL
        }

        guard pathComponents.count == 1,
              directoryExists(at: analysesBase, fileManager: fm),
              let enumerator = fm.enumerator(
                  at: analysesBase,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var matches: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == rawName,
                  directoryExists(at: url, fileManager: fm) else {
                continue
            }
            matches.append(url)
        }

        return matches.sorted { $0.path < $1.path }.first
    }

    /// Returns the manifest path for an analysis directory relative to `projectURL/Analyses/`.
    ///
    /// Direct children produce their basename. Grouped/nested analysis directories preserve
    /// their group components, for example `Reviewed/minimap2-2026-01-15T10-00-00`.
    public static func analysisDirectoryPath(for analysisDirectoryURL: URL, projectURL: URL) -> String? {
        let analysesBase = projectURL
            .appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let analysisURL = analysisDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let baseComponents = analysesBase.pathComponents
        let analysisComponents = analysisURL.pathComponents

        guard analysisComponents.count > baseComponents.count,
              Array(analysisComponents.prefix(baseComponents.count)) == baseComponents else {
            return nil
        }

        let relativeComponents = Array(analysisComponents.dropFirst(baseComponents.count))
        guard !relativeComponents.isEmpty,
              !relativeComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return relativeComponents.joined(separator: "/")
    }

    /// Removes entries whose analysis directory is absent from `Analyses/`.
    ///
    /// - Returns: The number of entries removed.
    @discardableResult
    public static func pruneStaleEntries(manifest: inout AnalysisManifest, projectURL: URL) -> Int {
        let before = manifest.analyses.count

        manifest.analyses = manifest.analyses.filter { entry in
            let exists = resolveAnalysisDirectory(for: entry, projectURL: projectURL) != nil
            if !exists {
                logger.info("Pruning stale manifest entry: \(entry.analysisDirectoryName)")
            }
            return exists
        }

        return before - manifest.analyses.count
    }

    // MARK: - Private Helpers

    private static func save(_ manifest: AnalysisManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func directoryExists(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
