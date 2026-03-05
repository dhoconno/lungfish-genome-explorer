// AlignmentDuplicateService.swift - Duplicate marking/removal workflows for alignment tracks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let duplicateLogger = Logger(subsystem: "com.lungfish.browser", category: "AlignmentDuplicateService")

/// Service for running `samtools markdup` workflows on bundle alignment tracks.
public final class AlignmentDuplicateService: @unchecked Sendable {

    /// Result of a duplicate workflow.
    public struct WorkflowResult: Sendable {
        public let bundleURL: URL
        public let processedTracks: Int
        public let newTrackIds: [String]
    }

    /// Runs duplicate marking for all alignment tracks in a bundle, replacing existing tracks.
    ///
    /// Produces marked BAM files inside `alignments/marked/` and re-imports them as tracks.
    public static func markDuplicatesInBundle(
        bundleURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> WorkflowResult {
        let manifest = try BundleManifest.load(from: bundleURL)
        let tracks = manifest.alignments
        guard !tracks.isEmpty else {
            throw AlignmentDuplicateError.noAlignmentTracks
        }

        let outputRoot = bundleURL.appendingPathComponent("alignments/marked", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let newTrackIds = try await runDuplicateWorkflow(
            bundleURL: bundleURL,
            tracks: tracks,
            outputRoot: outputRoot,
            removeDuplicates: false,
            suffix: "marked",
            progressHandler: progressHandler
        )

        try removeAlignmentTracks(tracks, from: bundleURL)
        progressHandler?(1.0, "Duplicate marking complete.")
        return WorkflowResult(bundleURL: bundleURL, processedTracks: tracks.count, newTrackIds: newTrackIds)
    }

    /// Creates a sibling `.lungfishref` bundle with duplicate reads removed.
    ///
    /// The source bundle is copied first; then all copied alignment tracks are replaced by
    /// deduplicated BAM tracks in `alignments/deduplicated/`.
    public static func createDeduplicatedBundle(
        from sourceBundleURL: URL,
        outputBundleURL: URL? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
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

        let newTrackIds = try await runDuplicateWorkflow(
            bundleURL: targetURL,
            tracks: tracks,
            outputRoot: outputRoot,
            removeDuplicates: true,
            suffix: "deduplicated",
            progressHandler: { progress, message in
                // Reserve 0-8% for copy step; map workflow to 8-100%.
                let mapped = 0.08 + progress * 0.92
                progressHandler?(mapped, message)
            }
        )

        try removeAlignmentTracks(tracks, from: targetURL)
        progressHandler?(1.0, "Deduplicated bundle ready.")
        return WorkflowResult(bundleURL: targetURL, processedTracks: tracks.count, newTrackIds: newTrackIds)
    }

    // MARK: - Workflow Internals

    @discardableResult
    private static func runDuplicateWorkflow(
        bundleURL: URL,
        tracks: [AlignmentTrackInfo],
        outputRoot: URL,
        removeDuplicates: Bool,
        suffix: String,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> [String] {
        let refPath = findReferenceFASTA(in: bundleURL)
        var createdTrackIds: [String] = []
        createdTrackIds.reserveCapacity(tracks.count)

        for (index, track) in tracks.enumerated() {
            let baseProgress = Double(index) / Double(max(1, tracks.count))
            let nextProgress = Double(index + 1) / Double(max(1, tracks.count))
            progressHandler?(baseProgress, "Preparing \(track.name)...")

            guard let sourcePath = resolveAlignmentPath(for: track, bundleURL: bundleURL) else {
                throw AlignmentDuplicateError.sourcePathNotFound(track.sourcePath)
            }

            let outputName = "\(track.id).\(suffix).bam"
            let outputURL = outputRoot.appendingPathComponent(outputName)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let outputIndexURL = URL(fileURLWithPath: outputURL.path + ".bai")
            if FileManager.default.fileExists(atPath: outputIndexURL.path) {
                try FileManager.default.removeItem(at: outputIndexURL)
            }

            try await runMarkdupPipeline(
                inputURL: URL(fileURLWithPath: sourcePath),
                outputURL: outputURL,
                removeDuplicates: removeDuplicates,
                referenceFastaPath: refPath,
                progressHandler: { stageProgress, stageMessage in
                    let mapped = baseProgress + stageProgress * (nextProgress - baseProgress)
                    progressHandler?(mapped, "\(track.name): \(stageMessage)")
                }
            )

            let importResult = try await BAMImportService.importBAM(
                bamURL: outputURL,
                bundleURL: bundleURL,
                name: removeDuplicates ? "\(track.name) [deduplicated]" : "\(track.name) [dup-marked]",
                progressHandler: { stageProgress, stageMessage in
                    // Last 20% of the per-track slice for metadata import/index validation.
                    let perTrackStart = baseProgress + 0.8 * (nextProgress - baseProgress)
                    let perTrackEnd = nextProgress
                    let mapped = perTrackStart + stageProgress * (perTrackEnd - perTrackStart)
                    progressHandler?(mapped, "\(track.name): \(stageMessage)")
                }
            )
            // The intermediate markdup output has been re-imported into the bundle's
            // normalized alignment storage; remove the transient file pair.
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: outputIndexURL)
            createdTrackIds.append(importResult.trackInfo.id)
        }

        return createdTrackIds
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

    /// Runs the canonical markdup pipeline:
    /// sort -n → fixmate -m → sort → markdup (-r optional) → index
    private static func runMarkdupPipeline(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws {
        let runner = NativeToolRunner.shared
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempDir = outputDir.appendingPathComponent(".markdup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nameSortedURL = tempDir.appendingPathComponent("name.sorted.bam")
        let fixmateURL = tempDir.appendingPathComponent("fixmate.bam")
        let coordSortedURL = tempDir.appendingPathComponent("coord.sorted.bam")

        let size = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        let longTimeout = max(600.0, Double(size) / 10_000_000.0)

        progressHandler?(0.05, "Sorting by read name...")
        var sortNameArgs = ["sort", "-n", "-o", nameSortedURL.path]
        if let referenceFastaPath {
            sortNameArgs += ["--reference", referenceFastaPath]
        }
        sortNameArgs.append(inputURL.path)
        try await runSamtoolsOrThrow(runner, arguments: sortNameArgs, timeout: longTimeout)

        progressHandler?(0.30, "Running fixmate...")
        var fixmateArgs = ["fixmate", "-m"]
        if let referenceFastaPath {
            fixmateArgs += ["--reference", referenceFastaPath]
        }
        fixmateArgs += [nameSortedURL.path, fixmateURL.path]
        try await runSamtoolsOrThrow(runner, arguments: fixmateArgs, timeout: longTimeout)

        progressHandler?(0.55, "Sorting by coordinate...")
        var sortCoordArgs = ["sort", "-o", coordSortedURL.path]
        if let referenceFastaPath {
            sortCoordArgs += ["--reference", referenceFastaPath]
        }
        sortCoordArgs.append(fixmateURL.path)
        try await runSamtoolsOrThrow(runner, arguments: sortCoordArgs, timeout: longTimeout)

        progressHandler?(0.78, removeDuplicates ? "Removing duplicates..." : "Marking duplicates...")
        var markdupArgs = ["markdup"]
        if removeDuplicates {
            markdupArgs.append("-r")
        }
        markdupArgs += [coordSortedURL.path, outputURL.path]
        try await runSamtoolsOrThrow(runner, arguments: markdupArgs, timeout: longTimeout)

        progressHandler?(0.93, "Indexing output BAM...")
        try await runSamtoolsOrThrow(runner, arguments: ["index", outputURL.path], timeout: 3600)

        progressHandler?(1.0, "Done")
        duplicateLogger.info("runMarkdupPipeline: Completed \(outputURL.lastPathComponent, privacy: .public)")
    }

    private static func runSamtoolsOrThrow(
        _ runner: NativeToolRunner,
        arguments: [String],
        timeout: TimeInterval
    ) async throws {
        let result = try await runner.run(.samtools, arguments: arguments, timeout: timeout)
        guard result.isSuccess else {
            throw AlignmentDuplicateError.samtoolsFailed(result.stderr.isEmpty ? "samtools exited with \(result.exitCode)" : result.stderr)
        }
    }

    private static func findReferenceFASTA(in bundleURL: URL) -> String? {
        let manifest = try? BundleManifest.load(from: bundleURL)
        guard let path = manifest?.genome?.path else { return nil }
        let fastaURL = bundleURL.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: fastaURL.path) ? fastaURL.path : nil
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
