// MappingResultLayoutService.swift - The on-disk layout of a mapping result, shared by the app and the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Produces the project layout of a mapping run.
///
/// A mapping run from the window leaves three things behind that the mapper
/// itself does not write: the `Analyses/<tool>-<timestamp>/` directory the
/// run lands in, a copy of the reference bundle inside that directory with
/// the BAM attached as an alignment track (the "viewer bundle" the viewport
/// opens), and the rewritten result sidecars that point at that copy. The
/// window and `lungfish-cli map` both call this service, so one CLI
/// invocation produces the same layout as the window; the `Copy CLI Command`
/// of a window run reproduces it because ``MappingCLIInvocationBuilder``
/// emits the `--project` and `--track-name` this service consumes.
public enum MappingResultLayoutService {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    /// What ``publishViewerBundle(result:request:trackName:fileManager:progress:)`` left behind.
    public struct ViewerBundlePublication: Sendable, Equatable {
        /// The result with `viewerBundleURL` and `sourceReferenceBundleURL` set;
        /// this is what the published `mapping-result.json` records.
        public let result: MappingResult
        /// `<output directory>/<reference bundle name>.lungfishref`.
        public let viewerBundleURL: URL
        /// The bundle the viewer was copied from.
        public let sourceReferenceBundleURL: URL
        /// The alignment track the BAM was attached as.
        public let trackInfo: AlignmentTrackInfo
    }

    // MARK: - Naming

    /// The alignment track name a run gets when the caller names none:
    /// `"<Tool> Mapping"`, for example `minimap2 Mapping`.
    public static func defaultTrackName(for tool: MappingTool) -> String {
        "\(tool.displayName) Mapping"
    }

    /// The track name a request records: its own `outputTrackName` when it
    /// has one, else ``defaultTrackName(for:)``.
    public static func trackName(for request: MappingRunRequest) -> String {
        let explicit = request.outputTrackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return explicit.isEmpty ? defaultTrackName(for: request.tool) : explicit
    }

    // MARK: - Analysis directory

    /// Creates `Analyses/<tool>-<timestamp>/` in `projectURL`, with the
    /// `analysis-metadata.json` sidecar that keeps the folder recognisable
    /// if it is renamed. This is what the window does before a run starts.
    @discardableResult
    public static func createAnalysisDirectory(tool: MappingTool, in projectURL: URL) throws -> URL {
        try AnalysesFolder.createAnalysisDirectory(tool: tool.rawValue, in: projectURL)
    }

    // MARK: - Viewer bundle

    /// The reference bundle a run's viewer copy is taken from, or `nil` when
    /// the reference FASTA is not inside a `.lungfishref` bundle.
    public static func sourceReferenceBundleURL(
        result: MappingResult,
        request: MappingRunRequest,
        fileManager: FileManager = .default
    ) -> URL? {
        let inferred = ReferenceBundleSourceResolver.canonicalSourceBundleURL(
            for: request.referenceFASTAURL,
            projectURL: request.projectURL
        )
        let candidate = request.sourceReferenceBundleURL
            ?? result.sourceReferenceBundleURL
            ?? (inferred?.pathExtension.lowercased() == "lungfishref" ? inferred : nil)
        guard let candidate, fileManager.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// Copies the reference bundle into the result directory, attaches the
    /// BAM as an alignment track named `trackName` (default
    /// ``trackName(for:)``), and rewrites `mapping-result.json`,
    /// `mapping-provenance.json`, and the canonical provenance envelope so
    /// they point at the copy. Returns `nil` when the reference is not inside
    /// a `.lungfishref` bundle, in which case nothing is written.
    ///
    /// The copy is prepared under a hidden candidate name and published with
    /// an atomic rename, so a failure leaves no half-built viewer behind.
    public static func publishViewerBundle(
        result: MappingResult,
        request: MappingRunRequest,
        trackName explicitTrackName: String? = nil,
        fileManager: FileManager = .default,
        progress: ProgressHandler? = nil
    ) async throws -> ViewerBundlePublication? {
        guard let sourceBundleURL = sourceReferenceBundleURL(
            result: result,
            request: request,
            fileManager: fileManager
        ) else {
            return nil
        }

        let outputDirectory = request.outputDirectory
        let viewerBundleURL = outputDirectory.appendingPathComponent(
            sourceBundleURL.lastPathComponent,
            isDirectory: true
        )
        let candidateName = [
            ".\(sourceBundleURL.deletingPathExtension().lastPathComponent)",
            "candidate-\(UUID().uuidString)",
            sourceBundleURL.pathExtension,
        ].joined(separator: ".")
        let candidateBundleURL = outputDirectory.appendingPathComponent(candidateName, isDirectory: true)
        defer {
            if fileManager.fileExists(atPath: candidateBundleURL.path) {
                try? fileManager.removeItem(at: candidateBundleURL)
            }
        }

        progress?(0.0, "Preparing lightweight reference bundle for integrated BAM viewing.")
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundleURL,
            viewerBundleURL: candidateBundleURL,
            fileManager: fileManager
        )

        let resolvedTrackName: String
        if let explicitTrackName, !explicitTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTrackName = explicitTrackName
        } else {
            resolvedTrackName = trackName(for: request)
        }
        // The mapper already wrote a coordinate-sorted, indexed BAM at the
        // result root; the viewer copy is an APFS clone of it (shared blocks,
        // not a second sort), so the result does not hold the BAM twice in full.
        let importResult = try await BAMImportService.importBAM(
            bamURL: result.bamURL,
            bundleURL: candidateBundleURL,
            name: resolvedTrackName,
            materialization: .adoptCoordinateSorted,
            progressHandler: progress
        )

        let preparedResult = result.withViewerBundle(
            viewerBundleURL: viewerBundleURL,
            sourceReferenceBundleURL: sourceBundleURL
        )
        progress?(1.0, "Publishing reference mapping viewer.")
        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidateBundleURL,
            finalBundleURL: viewerBundleURL,
            fileManager: fileManager
        ) { publishedBundleURL, publicationPlan in
            try MappingViewerBundlePublicationService.publish(
                result: preparedResult,
                resultDirectoryURL: outputDirectory,
                sourceReferenceBundleURL: sourceBundleURL,
                viewerBundleURL: publishedBundleURL,
                fileManager: fileManager,
                viewerPublicationPlan: publicationPlan
            )
        }
        return ViewerBundlePublication(
            result: preparedResult,
            viewerBundleURL: viewerBundleURL,
            sourceReferenceBundleURL: sourceBundleURL,
            trackInfo: importResult.trackInfo
        )
    }

    // MARK: - Analysis history

    /// The `.lungfishfastq` (or `.lungfishref`) bundle an input list belongs
    /// to: the URL itself when it is a bundle, else the bundle enclosing it.
    public static func findSourceBundle(for inputFiles: [URL]) -> URL? {
        for url in inputFiles {
            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: url) {
                return bundleURL
            }
            if let referenceBundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: url) {
                return referenceBundleURL
            }
        }
        return nil
    }

    /// The analysis directory as the bundle's `analyses-manifest.json`
    /// names it: project-relative when the directory is inside `projectURL`,
    /// else its last path component.
    public static func analysisManifestDirectoryName(for analysisDirectoryURL: URL, projectURL: URL?) -> String {
        if let projectURL,
           let relativePath = AnalysisManifestStore.analysisDirectoryPath(
               for: analysisDirectoryURL,
               projectURL: projectURL
           ) {
            return relativePath
        }
        return analysisDirectoryURL.lastPathComponent
    }

    /// Records the run in the source FASTQ bundle's `analyses-manifest.json`
    /// (the sidebar's analysis history). `originalInputURLs` are the bundles
    /// the user chose (a materialized scratch copy has no enclosing bundle);
    /// `resolvedRequest` is the request that actually ran, whose resolved
    /// fields the manifest records. Returns the bundle written to, or `nil`
    /// when the inputs belong to no bundle.
    @discardableResult
    public static func recordAnalysisManifest(
        originalInputURLs: [URL],
        resolvedRequest: MappingRunRequest,
        result: MappingResult,
        projectURL: URL?,
        status: AnalysisManifestEntry.AnalysisStatus = .completed
    ) throws -> URL? {
        guard let bundleURL = findSourceBundle(for: originalInputURLs) else { return nil }
        let entry = AnalysisManifestEntry(
            tool: resolvedRequest.tool.rawValue,
            analysisDirectoryName: analysisManifestDirectoryName(
                for: resolvedRequest.outputDirectory,
                projectURL: projectURL ?? resolvedRequest.projectURL
            ),
            displayName: defaultTrackName(for: resolvedRequest.tool),
            parameters: resolvedRequest.summaryParameters(),
            summary: "\(result.mappedReads)/\(result.totalReads) reads mapped",
            status: status
        )
        try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
        return bundleURL
    }
}
