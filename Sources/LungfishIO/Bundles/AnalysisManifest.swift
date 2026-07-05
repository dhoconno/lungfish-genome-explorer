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
    /// no longer exist under `projectURL/Analyses/`.
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

    /// Removes entries whose `Analyses/{analysisDirectoryName}` directory is absent.
    ///
    /// - Returns: The number of entries removed.
    @discardableResult
    public static func pruneStaleEntries(manifest: inout AnalysisManifest, projectURL: URL) -> Int {
        let analysesBase = projectURL.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        let fm = FileManager.default
        let before = manifest.analyses.count

        manifest.analyses = manifest.analyses.filter { entry in
            let dir = analysesBase.appendingPathComponent(entry.analysisDirectoryName, isDirectory: true)
            let exists = fm.fileExists(atPath: dir.path)
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
