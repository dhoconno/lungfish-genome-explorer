// BundleAlignmentTrackRemovalService.swift - Remove derived alignment tracks from bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public enum BundleAlignmentTrackRemovalError: Error, LocalizedError, Sendable, Equatable {
    case trackNotFound(String)
    case notDerivedTrack(String)
    case invalidBundleRelativePath(String)
    case escapedBundlePath(String)

    public var errorDescription: String? {
        switch self {
        case .trackNotFound(let trackID):
            return "Could not find alignment track '\(trackID)' in the bundle."
        case .notDerivedTrack(let trackID):
            return "Alignment track '\(trackID)' is a source alignment and cannot be removed by this action."
        case .invalidBundleRelativePath(let path):
            return "Alignment artifact path must be bundle-relative: \(path)"
        case .escapedBundlePath(let path):
            return "Alignment artifact path escapes the bundle root: \(path)"
        }
    }
}

public struct BundleAlignmentTrackRemovalResult: Sendable, Equatable {
    public let bundleURL: URL
    public let removedTrack: AlignmentTrackInfo
    public let removedArtifactURLs: [URL]

    public init(
        bundleURL: URL,
        removedTrack: AlignmentTrackInfo,
        removedArtifactURLs: [URL]
    ) {
        self.bundleURL = bundleURL
        self.removedTrack = removedTrack
        self.removedArtifactURLs = removedArtifactURLs
    }
}

public actor BundleAlignmentTrackRemovalService {
    public typealias ManifestSaver = @Sendable (BundleManifest, URL) throws -> Void

    private let fileManager: FileManager
    private let manifestSaver: ManifestSaver

    public init(
        fileManager: FileManager = .default,
        manifestSaver: @escaping ManifestSaver = PreparedAlignmentAttachmentService.atomicManifestSave(manifest:bundleURL:)
    ) {
        self.fileManager = fileManager
        self.manifestSaver = manifestSaver
    }

    public func removeDerivedAlignmentTrack(
        bundleURL: URL,
        trackID: String
    ) async throws -> BundleAlignmentTrackRemovalResult {
        let manifest = try BundleManifest.load(from: bundleURL)
        guard let track = manifest.alignments.first(where: { $0.id == trackID }) else {
            throw BundleAlignmentTrackRemovalError.trackNotFound(trackID)
        }
        guard isDerivedAlignmentTrack(track) else {
            throw BundleAlignmentTrackRemovalError.notDerivedTrack(trackID)
        }

        let artifactPaths = [
            track.sourcePath,
            track.indexPath,
            track.metadataDBPath,
        ].compactMap { $0 }
        let artifactURLs = try artifactPaths.map {
            try resolvedRemovableBundleURL(bundleURL: bundleURL, relativePath: $0)
        }

        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try? Data(contentsOf: manifestURL)
        do {
            try manifestSaver(manifest.removingAlignmentTrack(id: trackID), bundleURL)

            var removedArtifactURLs: [URL] = []
            for url in artifactURLs where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removedArtifactURLs.append(url)
            }

            return BundleAlignmentTrackRemovalResult(
                bundleURL: bundleURL,
                removedTrack: track,
                removedArtifactURLs: removedArtifactURLs
            )
        } catch {
            if let originalManifestData {
                try? originalManifestData.write(to: manifestURL, options: .atomic)
            }
            throw error
        }
    }

    private func isDerivedAlignmentTrack(_ track: AlignmentTrackInfo) -> Bool {
        track.sourcePath.hasPrefix("alignments/filtered/")
    }

    private func resolvedRemovableBundleURL(
        bundleURL: URL,
        relativePath: String
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw BundleAlignmentTrackRemovalError.invalidBundleRelativePath(relativePath)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else {
            throw BundleAlignmentTrackRemovalError.invalidBundleRelativePath(relativePath)
        }
        for component in components {
            guard isValidRelativePathComponent(component) else {
                throw BundleAlignmentTrackRemovalError.invalidBundleRelativePath(relativePath)
            }
        }

        let bundleRoot = bundleURL.standardizedFileURL
        let realBundleRoot = bundleRoot.resolvingSymlinksInPath().standardizedFileURL
        let logicalURL = components.reduce(bundleRoot) { partial, component in
            partial.appendingPathComponent(component)
        }
        let physicalURL = fileManager.fileExists(atPath: logicalURL.path)
            ? logicalURL.resolvingSymlinksInPath().standardizedFileURL
            : logicalURL.standardizedFileURL

        guard isContained(physicalURL, within: realBundleRoot) else {
            throw BundleAlignmentTrackRemovalError.escapedBundlePath(relativePath)
        }

        return logicalURL.standardizedFileURL
    }

    private func isValidRelativePathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
    }

    private func isContained(_ url: URL, within rootURL: URL) -> Bool {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return url.path == rootURL.path || url.path.hasPrefix(rootPath)
    }
}
