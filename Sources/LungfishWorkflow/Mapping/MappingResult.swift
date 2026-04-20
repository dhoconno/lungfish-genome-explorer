// MappingResult.swift - Shared mapping result persistence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct MappingContigSummary: Sendable, Codable, Equatable {
    public let contigName: String
    public let contigLength: Int
    public let mappedReads: Int
    public let mappedReadPercent: Double
    public let meanDepth: Double
    public let coverageBreadth: Double
    public let medianMAPQ: Double
    public let meanIdentity: Double

    public init(
        contigName: String,
        contigLength: Int,
        mappedReads: Int,
        mappedReadPercent: Double,
        meanDepth: Double,
        coverageBreadth: Double,
        medianMAPQ: Double,
        meanIdentity: Double
    ) {
        self.contigName = contigName
        self.contigLength = contigLength
        self.mappedReads = mappedReads
        self.mappedReadPercent = mappedReadPercent
        self.meanDepth = meanDepth
        self.coverageBreadth = coverageBreadth
        self.medianMAPQ = medianMAPQ
        self.meanIdentity = meanIdentity
    }
}

public struct MappingResult: Sendable, Codable, Equatable {
    public let mapper: MappingTool
    public let modeID: String
    public let sourceReferenceBundleURL: URL?
    public let viewerBundleURL: URL?
    public let bamURL: URL
    public let baiURL: URL
    public let totalReads: Int
    public let mappedReads: Int
    public let unmappedReads: Int
    public let wallClockSeconds: Double
    public let contigs: [MappingContigSummary]

    public init(
        mapper: MappingTool,
        modeID: String,
        sourceReferenceBundleURL: URL? = nil,
        viewerBundleURL: URL? = nil,
        bamURL: URL,
        baiURL: URL,
        totalReads: Int,
        mappedReads: Int,
        unmappedReads: Int,
        wallClockSeconds: Double,
        contigs: [MappingContigSummary]
    ) {
        self.mapper = mapper
        self.modeID = modeID
        self.sourceReferenceBundleURL = sourceReferenceBundleURL
        self.viewerBundleURL = viewerBundleURL
        self.bamURL = bamURL
        self.baiURL = baiURL
        self.totalReads = totalReads
        self.mappedReads = mappedReads
        self.unmappedReads = unmappedReads
        self.wallClockSeconds = wallClockSeconds
        self.contigs = contigs
    }

    public func withViewerBundle(
        viewerBundleURL: URL,
        sourceReferenceBundleURL: URL?
    ) -> MappingResult {
        MappingResult(
            mapper: mapper,
            modeID: modeID,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            viewerBundleURL: viewerBundleURL,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: totalReads,
            mappedReads: mappedReads,
            unmappedReads: unmappedReads,
            wallClockSeconds: wallClockSeconds,
            contigs: contigs
        )
    }
}

private let mappingResultSidecarFilename = "mapping-result.json"
private let legacyAlignmentResultFilename = "alignment-result.json"

private struct PersistedMappingResult: Codable, Sendable {
    let schemaVersion: Int
    let mapper: MappingTool
    let modeID: String
    let sourceReferenceBundlePath: String?
    let viewerBundlePath: String?
    let bamPath: String
    let baiPath: String
    let totalReads: Int
    let mappedReads: Int
    let unmappedReads: Int
    let wallClockSeconds: Double
    let contigs: [MappingContigSummary]
}

private struct PersistedLegacyAlignmentResult: Codable, Sendable {
    let schemaVersion: Int
    let bamPath: String
    let baiPath: String
    let totalReads: Int
    let mappedReads: Int
    let unmappedReads: Int
    let toolVersion: String
    let wallClockSeconds: Double
    let savedAt: Date
}

public enum MappingResultLoadError: Error, LocalizedError, Sendable {
    case sidecarNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .sidecarNotFound(let directory):
            return "No saved mapping result in \(directory.path)"
        }
    }
}

public extension MappingResult {
    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            PersistedMappingResult(
                schemaVersion: 1,
                mapper: mapper,
                modeID: modeID,
                sourceReferenceBundlePath: sourceReferenceBundleURL.map { Self.storedPath(for: $0, relativeTo: directory) },
                viewerBundlePath: viewerBundleURL.map { Self.storedPath(for: $0, relativeTo: directory) },
                bamPath: Self.storedPath(for: bamURL, relativeTo: directory),
                baiPath: Self.storedPath(for: baiURL, relativeTo: directory),
                totalReads: totalReads,
                mappedReads: mappedReads,
                unmappedReads: unmappedReads,
                wallClockSeconds: wallClockSeconds,
                contigs: contigs
            )
        )
        try data.write(
            to: directory.appendingPathComponent(mappingResultSidecarFilename),
            options: Data.WritingOptions.atomic
        )
    }

    static func load(from directory: URL) throws -> MappingResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let mappingSidecarURL = directory.appendingPathComponent(mappingResultSidecarFilename)
        if FileManager.default.fileExists(atPath: mappingSidecarURL.path) {
            let data = try Data(contentsOf: mappingSidecarURL)
            let persisted = try decoder.decode(PersistedMappingResult.self, from: data)
            return MappingResult(
                mapper: persisted.mapper,
                modeID: persisted.modeID,
                sourceReferenceBundleURL: persisted.sourceReferenceBundlePath.map { resolvedURL(for: $0, relativeTo: directory) },
                viewerBundleURL: persisted.viewerBundlePath.map { resolvedURL(for: $0, relativeTo: directory) },
                bamURL: resolvedURL(for: persisted.bamPath, relativeTo: directory),
                baiURL: resolvedURL(for: persisted.baiPath, relativeTo: directory),
                totalReads: persisted.totalReads,
                mappedReads: persisted.mappedReads,
                unmappedReads: persisted.unmappedReads,
                wallClockSeconds: persisted.wallClockSeconds,
                contigs: persisted.contigs
            )
        }

        let legacySidecarURL = directory.appendingPathComponent(legacyAlignmentResultFilename)
        if FileManager.default.fileExists(atPath: legacySidecarURL.path) {
            let data = try Data(contentsOf: legacySidecarURL)
            let persisted = try decoder.decode(PersistedLegacyAlignmentResult.self, from: data)
            return MappingResult(
                mapper: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                bamURL: resolvedURL(for: persisted.bamPath, relativeTo: directory),
                baiURL: resolvedURL(for: persisted.baiPath, relativeTo: directory),
                totalReads: persisted.totalReads,
                mappedReads: persisted.mappedReads,
                unmappedReads: persisted.unmappedReads,
                wallClockSeconds: persisted.wallClockSeconds,
                contigs: []
            )
        }

        throw MappingResultLoadError.sidecarNotFound(directory)
    }

    static func exists(in directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent(mappingResultSidecarFilename).path)
            || fm.fileExists(atPath: directory.appendingPathComponent(legacyAlignmentResultFilename).path)
    }

    private static func storedPath(for url: URL, relativeTo directory: URL) -> String {
        let standardizedDirectory = directory.standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL.path
        let relativePrefix = standardizedDirectory.hasSuffix("/") ? standardizedDirectory : standardizedDirectory + "/"
        guard standardizedURL.hasPrefix(relativePrefix) else {
            return standardizedURL
        }
        return String(standardizedURL.dropFirst(relativePrefix.count))
    }

    private static func resolvedURL(for path: String, relativeTo directory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return directory.appendingPathComponent(path)
    }
}
