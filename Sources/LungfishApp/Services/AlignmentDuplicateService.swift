// AlignmentDuplicateService.swift - Duplicate marking/removal workflows for alignment tracks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Service for running `samtools markdup` workflows on bundle alignment tracks.
public final class AlignmentDuplicateService: @unchecked Sendable {
    typealias DuplicateMetadataAppender = @Sendable (
        _ metadataDBURL: URL,
        _ sourceTrack: AlignmentTrackInfo,
        _ sourceAlignmentPath: String,
        _ duplicateMode: Bool,
        _ commandHistory: [AlignmentCommandExecutionRecord]
    ) throws -> Void

    /// Result of a duplicate workflow.
    public struct WorkflowResult: Sendable {
        public let bundleURL: URL
        public let processedTracks: Int
        public let newTrackIds: [String]
    }

    /// Runs duplicate marking for all alignment tracks in a bundle, replacing existing tracks.
    ///
    /// Produces marked BAM files inside `alignments/marked/` and re-attaches them as tracks.
    public static func markDuplicatesInBundle(
        bundleURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        markdupPipeline: any AlignmentMarkdupPipelining = AlignmentMarkdupPipeline(),
        attachmentService: PreparedAlignmentAttachmentService = PreparedAlignmentAttachmentService(),
        trackIDProvider: @escaping @Sendable () -> String = { "aln_\(String(UUID().uuidString.prefix(8)))" }
    ) async throws -> WorkflowResult {
        try await markDuplicatesInBundle(
            bundleURL: bundleURL,
            progressHandler: progressHandler,
            markdupPipeline: markdupPipeline,
            attachmentService: attachmentService,
            metadataAppender: appendDuplicateMetadata,
            trackIDProvider: trackIDProvider
        )
    }

    static func markDuplicatesInBundle(
        bundleURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        markdupPipeline: any AlignmentMarkdupPipelining = AlignmentMarkdupPipeline(),
        attachmentService: PreparedAlignmentAttachmentService = PreparedAlignmentAttachmentService(),
        metadataAppender: @escaping DuplicateMetadataAppender,
        trackIDProvider: @escaping @Sendable () -> String = { "aln_\(String(UUID().uuidString.prefix(8)))" }
    ) async throws -> WorkflowResult {
        let manifest = try BundleManifest.load(from: bundleURL)
        let tracks = manifest.alignments
        guard !tracks.isEmpty else {
            throw AlignmentDuplicateError.noAlignmentTracks
        }

        let outputRoot = bundleURL.appendingPathComponent("alignments/marked", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let newTrackIDs = try await runDuplicateWorkflow(
            bundleURL: bundleURL,
            tracks: tracks,
            outputRoot: outputRoot,
            relativeDirectory: "alignments/marked",
            removeDuplicates: false,
            suffix: "marked",
            outputTrackNameSuffix: "[dup-marked]",
            progressHandler: progressHandler,
            markdupPipeline: markdupPipeline,
            attachmentService: attachmentService,
            metadataAppender: metadataAppender,
            trackIDProvider: trackIDProvider
        )

        try removeAlignmentTracks(tracks, from: bundleURL)
        progressHandler?(1.0, "Duplicate marking complete.")
        return WorkflowResult(bundleURL: bundleURL, processedTracks: tracks.count, newTrackIds: newTrackIDs)
    }

    /// Creates a sibling `.lungfishref` bundle with duplicate reads removed.
    ///
    /// The source bundle is copied first; then all copied alignment tracks are replaced by
    /// deduplicated BAM tracks in `alignments/deduplicated/`.
    public static func createDeduplicatedBundle(
        from sourceBundleURL: URL,
        outputBundleURL: URL? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        markdupPipeline: any AlignmentMarkdupPipelining = AlignmentMarkdupPipeline(),
        attachmentService: PreparedAlignmentAttachmentService = PreparedAlignmentAttachmentService(),
        trackIDProvider: @escaping @Sendable () -> String = { "aln_\(String(UUID().uuidString.prefix(8)))" }
    ) async throws -> WorkflowResult {
        let sourceManifest = try BundleManifest.load(from: sourceBundleURL)
        let tracks = sourceManifest.alignments
        guard !tracks.isEmpty else {
            throw AlignmentDuplicateError.noAlignmentTracks
        }

        let targetURL = uniqueDeduplicatedBundleURL(for: sourceBundleURL, preferred: outputBundleURL)
        try FileManager.default.copyItem(at: sourceBundleURL, to: targetURL)
        progressHandler?(0.08, "Created deduplicated bundle copy.")

        let outputRoot = targetURL.appendingPathComponent("alignments/deduplicated", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let newTrackIDs = try await runDuplicateWorkflow(
            bundleURL: targetURL,
            tracks: tracks,
            outputRoot: outputRoot,
            relativeDirectory: "alignments/deduplicated",
            removeDuplicates: true,
            suffix: "deduplicated",
            outputTrackNameSuffix: "[deduplicated]",
            progressHandler: { progress, message in
                let mappedProgress = 0.08 + progress * 0.92
                progressHandler?(mappedProgress, message)
            },
            markdupPipeline: markdupPipeline,
            attachmentService: attachmentService,
            metadataAppender: appendDuplicateMetadata,
            trackIDProvider: trackIDProvider
        )

        try removeAlignmentTracks(tracks, from: targetURL)
        progressHandler?(1.0, "Deduplicated bundle ready.")
        return WorkflowResult(bundleURL: targetURL, processedTracks: tracks.count, newTrackIds: newTrackIDs)
    }

    // MARK: - Workflow Internals

    @discardableResult
    private static func runDuplicateWorkflow(
        bundleURL: URL,
        tracks: [AlignmentTrackInfo],
        outputRoot: URL,
        relativeDirectory: String,
        removeDuplicates: Bool,
        suffix: String,
        outputTrackNameSuffix: String,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        markdupPipeline: any AlignmentMarkdupPipelining,
        attachmentService: PreparedAlignmentAttachmentService,
        metadataAppender: @escaping DuplicateMetadataAppender,
        trackIDProvider: @escaping @Sendable () -> String
    ) async throws -> [String] {
        let referenceFASTAPath = findReferenceFASTA(in: bundleURL)
        var createdTrackIDs: [String] = []
        createdTrackIDs.reserveCapacity(tracks.count)

        for (index, track) in tracks.enumerated() {
            let baseProgress = Double(index) / Double(max(1, tracks.count))
            let nextProgress = Double(index + 1) / Double(max(1, tracks.count))
            progressHandler?(baseProgress, "Preparing \(track.name)...")

            guard let sourcePath = resolveAlignmentPath(for: track, bundleURL: bundleURL) else {
                throw AlignmentDuplicateError.sourcePathNotFound(track.sourcePath)
            }

            let outputURL = outputRoot.appendingPathComponent("\(track.id).\(suffix).bam")
            let outputIndexURL = URL(fileURLWithPath: outputURL.path + ".bai")
            try replaceIfPresent(at: outputURL)
            try replaceIfPresent(at: outputIndexURL)

            let pipelineResult: AlignmentMarkdupPipelineResult
            do {
                pipelineResult = try await markdupPipeline.run(
                    inputURL: URL(fileURLWithPath: sourcePath),
                    outputURL: outputURL,
                    removeDuplicates: removeDuplicates,
                    referenceFastaPath: referenceFASTAPath,
                    progressHandler: { stageProgress, stageMessage in
                        let mappedProgress = baseProgress + stageProgress * 0.8 * (nextProgress - baseProgress)
                        progressHandler?(mappedProgress, "\(track.name): \(stageMessage)")
                    }
                )
            } catch let error as AlignmentMarkdupPipelineError {
                switch error {
                case .samtoolsFailed(let message):
                    throw AlignmentDuplicateError.samtoolsFailed(message)
                }
            }

            progressHandler?(
                baseProgress + 0.85 * (nextProgress - baseProgress),
                "\(track.name): Attaching derived alignment..."
            )

            let attachment = try await attachmentService.attach(
                request: PreparedAlignmentAttachmentRequest(
                    bundleURL: bundleURL,
                    stagedBAMURL: pipelineResult.outputURL,
                    stagedIndexURL: pipelineResult.indexURL,
                    outputTrackID: trackIDProvider(),
                    outputTrackName: "\(track.name) \(outputTrackNameSuffix)",
                    relativeDirectory: relativeDirectory
                )
            )
            do {
                try metadataAppender(
                    attachment.metadataDBURL,
                    track,
                    sourcePath,
                    removeDuplicates,
                    pipelineResult.commandHistory
                )
            } catch {
                try rollbackAttachedTrack(attachment.trackInfo, from: bundleURL)
                throw error
            }
            createdTrackIDs.append(attachment.trackInfo.id)
        }

        return createdTrackIDs
    }

    /// Removes old alignment tracks from manifest and prunes their sidecar files.
    private static func removeAlignmentTracks(_ tracks: [AlignmentTrackInfo], from bundleURL: URL) throws {
        var manifest = try BundleManifest.load(from: bundleURL)
        for track in tracks {
            manifest = manifest.removingAlignmentTrack(id: track.id)
            if let dbPath = track.metadataDBPath {
                let dbURL = bundleURL.appendingPathComponent(dbPath)
                try? FileManager.default.removeItem(at: dbURL)
            }
            if let sourceURL = resolveBundleOrAbsoluteURL(track.sourcePath, bundleURL: bundleURL),
               FileManager.default.fileExists(atPath: sourceURL.path),
               sourceURL.path.hasPrefix(bundleURL.path + "/") {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            if let indexURL = resolveBundleOrAbsoluteURL(track.indexPath, bundleURL: bundleURL),
               FileManager.default.fileExists(atPath: indexURL.path),
               indexURL.path.hasPrefix(bundleURL.path + "/") {
                try? FileManager.default.removeItem(at: indexURL)
            }
        }
        try manifest.save(to: bundleURL)
    }

    /// Resolves stale alignment source paths via bookmark if needed.
    private static func resolveAlignmentPath(for track: AlignmentTrackInfo, bundleURL: URL) -> String? {
        if let directURL = resolveBundleOrAbsoluteURL(track.sourcePath, bundleURL: bundleURL),
           FileManager.default.fileExists(atPath: directURL.path) {
            return directURL.path
        }
        guard let bookmarkString = track.sourceBookmark,
              let bookmarkData = Data(base64Encoded: bookmarkString) else {
            return nil
        }
        var isStale = false
        if let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: resolvedURL.path) {
            return resolvedURL.path
        }
        return nil
    }

    private static func resolveBundleOrAbsoluteURL(_ path: String, bundleURL: URL) -> URL? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return bundleURL.appendingPathComponent(path)
    }

    /// Builds a unique output URL for a deduplicated sibling bundle.
    static func uniqueDeduplicatedBundleURL(for sourceBundleURL: URL, preferred: URL? = nil) -> URL {
        if let preferred {
            if !FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        }

        let parent = sourceBundleURL.deletingLastPathComponent()
        let sourceName = sourceBundleURL.deletingPathExtension().lastPathComponent
        let base = parent.appendingPathComponent("\(sourceName)-deduplicated.lungfishref")
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }

        for n in 2...999 {
            let candidate = parent.appendingPathComponent("\(sourceName)-deduplicated-\(n).lungfishref")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appendingPathComponent("\(sourceName)-deduplicated-\(UUID().uuidString.prefix(8)).lungfishref")
    }

    private static func findReferenceFASTA(in bundleURL: URL) -> String? {
        let manifest = try? BundleManifest.load(from: bundleURL)
        guard let path = manifest?.genome?.path else { return nil }
        let fastaURL = bundleURL.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: fastaURL.path) ? fastaURL.path : nil
    }

    private static func replaceIfPresent(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func rollbackAttachedTrack(_ track: AlignmentTrackInfo, from bundleURL: URL) throws {
        try removeAlignmentTracks([track], from: bundleURL)
    }

    private static func appendDuplicateMetadata(
        metadataDBURL: URL,
        sourceTrack: AlignmentTrackInfo,
        sourceAlignmentPath: String,
        duplicateMode: Bool,
        commandHistory: [AlignmentCommandExecutionRecord]
    ) throws {
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: metadataDBURL)

        metadataDB.setFileInfo("original_source_path", value: sourceAlignmentPath)
        metadataDB.setFileInfo("original_source_format", value: sourceTrack.format.rawValue)
        metadataDB.setFileInfo(
            "derivation_kind",
            value: duplicateMode ? "deduplicated_alignment" : "duplicate_marked_alignment"
        )
        metadataDB.setFileInfo("derivation_source_track_id", value: sourceTrack.id)
        metadataDB.setFileInfo("derivation_source_track_name", value: sourceTrack.name)
        metadataDB.setFileInfo("derivation_source_manifest_path", value: sourceTrack.sourcePath)
        metadataDB.setFileInfo("derivation_source_alignment_path", value: sourceAlignmentPath)
        metadataDB.setFileInfo(
            "derivation_command_chain",
            value: commandHistory.map(\.commandLine).joined(separator: " | ")
        )

        var parentStep: Int?
        for command in commandHistory {
            parentStep = metadataDB.addProvenanceRecord(
                tool: command.tool,
                subcommand: command.subcommand,
                command: command.commandLine,
                inputFile: command.inputFile,
                outputFile: command.outputFile,
                exitCode: 0,
                parentStep: parentStep
            )
        }
    }
}

public enum AlignmentDuplicateError: Error, LocalizedError, Sendable {
    case noAlignmentTracks
    case sourcePathNotFound(String)
    case samtoolsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAlignmentTracks:
            return "No alignment tracks are loaded in this bundle."
        case .sourcePathNotFound(let path):
            return "Could not resolve alignment source file: \(path)"
        case .samtoolsFailed(let message):
            return "samtools duplicate workflow failed: \(message)"
        }
    }
}
