// MappingResult.swift - Shared mapping result persistence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct MappingContigSummary: Sendable, Codable, Equatable {
    /// Explicit canonical sample identity for a sample × contig row.
    public let sampleID: String?
    /// Persisted alignment track identity for this row, when it was derived
    /// from a specific bundled BAM rather than the legacy mapping summary.
    public let alignmentTrackID: String?
    /// Exact read-group predicate used to produce this row. An empty set is
    /// intentional: selecting the row must clear any earlier RG filter.
    public let readGroupIDs: Set<String>
    public let contigName: String
    public let contigLength: Int
    public let mappedReads: Int
    public let mappedReadPercent: Double
    public let meanDepth: Double
    public let coverageBreadth: Double
    public let medianMAPQ: Double
    public let meanIdentity: Double

    private enum CodingKeys: String, CodingKey {
        case sampleID
        case alignmentTrackID
        case readGroupIDs
        case contigName
        case contigLength
        case mappedReads
        case mappedReadPercent
        case meanDepth
        case coverageBreadth
        case medianMAPQ
        case meanIdentity
    }

    public init(
        sampleID: String? = nil,
        alignmentTrackID: String? = nil,
        readGroupIDs: Set<String> = [],
        contigName: String,
        contigLength: Int,
        mappedReads: Int,
        mappedReadPercent: Double,
        meanDepth: Double,
        coverageBreadth: Double,
        medianMAPQ: Double,
        meanIdentity: Double
    ) {
        self.sampleID = sampleID
        self.alignmentTrackID = alignmentTrackID
        self.readGroupIDs = readGroupIDs
        self.contigName = contigName
        self.contigLength = contigLength
        self.mappedReads = mappedReads
        self.mappedReadPercent = mappedReadPercent
        self.meanDepth = meanDepth
        self.coverageBreadth = coverageBreadth
        self.medianMAPQ = medianMAPQ
        self.meanIdentity = meanIdentity
    }

    /// Keeps mapping-result sidecars written before row-level BAM identity was
    /// introduced readable. Their omitted identity fields mean a legacy row
    /// with an explicitly empty read-group predicate.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampleID = try container.decodeIfPresent(String.self, forKey: .sampleID)
        alignmentTrackID = try container.decodeIfPresent(String.self, forKey: .alignmentTrackID)
        readGroupIDs = try container.decodeIfPresent(Set<String>.self, forKey: .readGroupIDs) ?? []
        contigName = try container.decode(String.self, forKey: .contigName)
        contigLength = try container.decode(Int.self, forKey: .contigLength)
        mappedReads = try container.decode(Int.self, forKey: .mappedReads)
        mappedReadPercent = try container.decode(Double.self, forKey: .mappedReadPercent)
        meanDepth = try container.decode(Double.self, forKey: .meanDepth)
        coverageBreadth = try container.decode(Double.self, forKey: .coverageBreadth)
        medianMAPQ = try container.decode(Double.self, forKey: .medianMAPQ)
        meanIdentity = try container.decode(Double.self, forKey: .meanIdentity)
    }

    /// Persist read-group predicates in a stable order so mapping-result
    /// sidecars are reproducible even though callers naturally use a Set for
    /// selection and lookup.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sampleID, forKey: .sampleID)
        try container.encodeIfPresent(alignmentTrackID, forKey: .alignmentTrackID)
        try container.encode(readGroupIDs.sorted(), forKey: .readGroupIDs)
        try container.encode(contigName, forKey: .contigName)
        try container.encode(contigLength, forKey: .contigLength)
        try container.encode(mappedReads, forKey: .mappedReads)
        try container.encode(mappedReadPercent, forKey: .mappedReadPercent)
        try container.encode(meanDepth, forKey: .meanDepth)
        try container.encode(coverageBreadth, forKey: .coverageBreadth)
        try container.encode(medianMAPQ, forKey: .medianMAPQ)
        try container.encode(meanIdentity, forKey: .meanIdentity)
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
    /// Saves the sidecar into `directory`, encoding its paths relative to the
    /// directory where the completed analysis will live. Publication writes
    /// into a staging directory first, so its final destination can differ
    /// from the sidecar's temporary write location.
    func save(to directory: URL, relativeTo finalDirectory: URL? = nil) throws {
        let pathAnchor = finalDirectory ?? directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            PersistedMappingResult(
                schemaVersion: 1,
                mapper: mapper,
                modeID: modeID,
                sourceReferenceBundlePath: sourceReferenceBundleURL.map { Self.storedPath(for: $0, relativeTo: pathAnchor) },
                viewerBundlePath: viewerBundleURL.map { Self.storedPath(for: $0, relativeTo: pathAnchor) },
                bamPath: Self.storedPath(for: bamURL, relativeTo: pathAnchor),
                baiPath: Self.storedPath(for: baiURL, relativeTo: pathAnchor),
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
            let legacyContext = legacyPathContext(
                fromBAMPath: persisted.bamPath,
                currentDirectory: directory
            )
            return MappingResult(
                mapper: persisted.mapper,
                modeID: persisted.modeID,
                sourceReferenceBundleURL: persisted.sourceReferenceBundlePath.map {
                    resolvedURL(for: $0, relativeTo: directory, legacyContext: legacyContext)
                },
                viewerBundleURL: persisted.viewerBundlePath.map {
                    resolvedURL(for: $0, relativeTo: directory, legacyContext: legacyContext)
                },
                bamURL: resolvedURL(
                    for: persisted.bamPath,
                    relativeTo: directory,
                    legacyContext: legacyContext
                ),
                baiURL: resolvedURL(
                    for: persisted.baiPath,
                    relativeTo: directory,
                    legacyContext: legacyContext
                ),
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
            let legacyContext = legacyPathContext(
                fromBAMPath: persisted.bamPath,
                currentDirectory: directory
            )
            return MappingResult(
                mapper: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                bamURL: resolvedURL(
                    for: persisted.bamPath,
                    relativeTo: directory,
                    legacyContext: legacyContext
                ),
                baiURL: resolvedURL(
                    for: persisted.baiPath,
                    relativeTo: directory,
                    legacyContext: legacyContext
                ),
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
        if standardizedURL.hasPrefix(relativePrefix) {
            return String(standardizedURL.dropFirst(relativePrefix.count))
        }

        guard FASTQBundle.findProjectRoot(from: directory) != nil else {
            return standardizedURL
        }
        return FASTQBundle.projectRelativePath(for: url, from: directory) ?? standardizedURL
    }

    private struct LegacyPathContext {
        let oldAnalysisDirectory: URL
        let oldProjectRoot: URL?
        let currentProjectRoot: URL?
    }

    private static func legacyPathContext(
        fromBAMPath bamPath: String,
        currentDirectory: URL
    ) -> LegacyPathContext? {
        guard bamPath.hasPrefix("/") else { return nil }

        let oldAnalysisDirectory = URL(fileURLWithPath: bamPath)
            .standardizedFileURL
            .deletingLastPathComponent()
        let currentDirectory = currentDirectory.standardizedFileURL
        let oldProjectRoot = syntacticProjectRoot(containing: oldAnalysisDirectory)
        let currentProjectRoot = FASTQBundle.findProjectRoot(from: currentDirectory)

        let projectRootsMatchAnalysisLocation: Bool
        if let oldProjectRoot, let currentProjectRoot {
            projectRootsMatchAnalysisLocation = relativeDescendantPath(
                from: oldProjectRoot,
                to: oldAnalysisDirectory
            ) == relativeDescendantPath(
                from: currentProjectRoot,
                to: currentDirectory
            )
        } else {
            projectRootsMatchAnalysisLocation = false
        }

        return LegacyPathContext(
            oldAnalysisDirectory: oldAnalysisDirectory,
            oldProjectRoot: projectRootsMatchAnalysisLocation ? oldProjectRoot : nil,
            currentProjectRoot: projectRootsMatchAnalysisLocation ? currentProjectRoot : nil
        )
    }

    private static func resolvedURL(
        for path: String,
        relativeTo directory: URL,
        legacyContext: LegacyPathContext? = nil
    ) -> URL {
        if path.hasPrefix("@/") {
            return FASTQBundle.resolveBundle(relativePath: path, from: directory)
        }
        guard path.hasPrefix("/") else {
            return directory.appendingPathComponent(path).standardizedFileURL
        }

        let absoluteURL = URL(fileURLWithPath: path).standardizedFileURL
        if let legacyContext {
            if let localSuffix = relativeDescendantPath(
                from: legacyContext.oldAnalysisDirectory,
                to: absoluteURL
            ) {
                let localCandidate = directory
                    .appendingPathComponent(localSuffix)
                    .standardizedFileURL
                if FileManager.default.fileExists(atPath: localCandidate.path) {
                    return localCandidate
                }
            }

            if let oldProjectRoot = legacyContext.oldProjectRoot,
               let currentProjectRoot = legacyContext.currentProjectRoot,
               let projectSuffix = relativeDescendantPath(from: oldProjectRoot, to: absoluteURL) {
                let projectCandidate = currentProjectRoot
                    .appendingPathComponent(projectSuffix)
                    .standardizedFileURL
                if FileManager.default.fileExists(atPath: projectCandidate.path) {
                    return projectCandidate
                }
            }
        }

        return absoluteURL
    }

    private static func syntacticProjectRoot(containing url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while true {
            if candidate.pathExtension.lowercased() == "lungfish" {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent != candidate else { return nil }
            candidate = parent
        }
    }

    private static func relativeDescendantPath(from ancestor: URL, to descendant: URL) -> String? {
        let ancestorPath = ancestor.standardizedFileURL.path
        let descendantPath = descendant.standardizedFileURL.path
        if descendantPath == ancestorPath {
            return ""
        }
        let prefix = ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/"
        guard descendantPath.hasPrefix(prefix) else { return nil }
        return String(descendantPath.dropFirst(prefix.count))
    }
}
