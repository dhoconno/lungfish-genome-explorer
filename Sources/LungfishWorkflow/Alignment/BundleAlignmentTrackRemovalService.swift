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
    /// The record of the removal, which names each removed file with its digest and size. It was
    /// written after the manifest no longer named the track and before any file went.
    public let recordURL: URL?
    /// Files the manifest no longer names that could not be deleted. They hold nothing the bundle
    /// reads, and the record names each one.
    public let leftoverArtifactURLs: [URL]

    public init(
        bundleURL: URL,
        removedTrack: AlignmentTrackInfo,
        removedArtifactURLs: [URL],
        recordURL: URL? = nil,
        leftoverArtifactURLs: [URL] = []
    ) {
        self.bundleURL = bundleURL
        self.removedTrack = removedTrack
        self.removedArtifactURLs = removedArtifactURLs
        self.recordURL = recordURL
        self.leftoverArtifactURLs = leftoverArtifactURLs
    }
}

/// Removes a derived alignment track, one `bam filter` made, from a bundle. The Inspector's row
/// runs it through `lungfish-cli bam remove-track` (Phase 2.10 lane A51).
///
/// The removal hashes each file it will remove, checking for a cancel as it reads, and a cancel up
/// to then changes nothing in the bundle and records the run as cancelled. Then it saves the
/// manifest without the track, which is the point after which a cancel no longer stops it, writes
/// the record that names each file it removes with its digest and size (2.7 E7, BIO 6), and only
/// then deletes the files (SWIFT 4). A file it cannot delete is left and reported, because the
/// manifest no longer names it.
public actor BundleAlignmentTrackRemovalService {
    public typealias ManifestSaver = @Sendable (BundleManifest, URL) throws -> Void
    /// Writes a removal's record to the file it is given.
    public typealias RecordWriter = @Sendable (ProvenanceEnvelope, URL) throws -> Void

    private let fileManager: FileManager
    private let manifestSaver: ManifestSaver
    private let recordWriter: RecordWriter

    public init(
        fileManager: FileManager = .default,
        recordWriter: @escaping RecordWriter = BundleAlignmentTrackRemovalRecord.write(_:to:),
        manifestSaver: @escaping ManifestSaver = PreparedAlignmentAttachmentService.atomicManifestSave(manifest:bundleURL:)
    ) {
        self.fileManager = fileManager
        self.recordWriter = recordWriter
        self.manifestSaver = manifestSaver
    }

    /// The command that reproduces a removal of `trackID` from `bundleURL`, which its record names.
    public static func cliArgv(bundleURL: URL, trackID: String) -> [String] {
        BundleAlignmentTrackRemovalRecord.cliArgv(bundleURL: bundleURL, trackID: trackID)
    }

    public func removeDerivedAlignmentTrack(
        bundleURL: URL,
        trackID: String
    ) async throws -> BundleAlignmentTrackRemovalResult {
        let clock = ProvenanceRunClock()
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
        let removableURLs = (artifactURLs
            + artifactURLs.flatMap(ProvenancePublicationArtifacts.fileSidecarArtifacts(for:)))
            .filter { fileManager.fileExists(atPath: $0.path) }

        let record = BundleAlignmentTrackRemovalRecord(bundleURL: bundleURL, track: track, clock: clock)
        let removedFiles: [ProvenanceFileDescriptor]
        do {
            removedFiles = try removableURLs.map(BundleAlignmentTrackRemovalRecord.removedFileDescriptor(for:))
            try Task.checkCancellation()
        } catch is CancellationError {
            try recordWriter(try record.cancelled(), record.recordURL)
            throw CancellationError()
        }

        // The commit point. From here the removal finishes, so a cancel no longer stops it.
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try? Data(contentsOf: manifestURL)
        try manifestSaver(manifest.removingAlignmentTrack(id: trackID), bundleURL)
        do {
            try recordWriter(try record.completed(removing: removedFiles), record.recordURL)
        } catch {
            if let originalManifestData {
                try? originalManifestData.write(to: manifestURL, options: .atomic)
            }
            throw error
        }

        var removedArtifactURLs: [URL] = []
        var leftoverArtifactURLs: [URL] = []
        for url in removableURLs {
            do {
                try fileManager.removeItem(at: url)
                removedArtifactURLs.append(url)
            } catch {
                leftoverArtifactURLs.append(url)
            }
        }
        return BundleAlignmentTrackRemovalResult(
            bundleURL: bundleURL,
            removedTrack: track,
            removedArtifactURLs: removedArtifactURLs,
            recordURL: record.recordURL,
            leftoverArtifactURLs: leftoverArtifactURLs
        )
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
