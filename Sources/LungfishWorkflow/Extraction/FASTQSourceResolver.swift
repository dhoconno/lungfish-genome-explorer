// FASTQSourceResolver.swift - Centralized FASTQ source resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Centralized resolver that locates readable FASTQ file(s) for any bundle type.
///
/// Handles physical FASTQs, virtual derivative bundles, and multi-file bundles.
/// Temp files use UUID-based names for safe concurrent operation.
///
/// ## Resolution Strategy
///
/// The resolver tries these strategies in order:
/// 1. **Source-file manifest** (`source-files.json`) -- resolves multi-file bundles
/// 2. **Physical FASTQ files** in the bundle (excluding `preview.fastq` when others exist)
/// 3. **Derived manifest** (`derived.manifest.json`) -- delegates to an injected materializer
/// 4. **Fallback scan** -- any `.fastq` / `.fastq.gz` file in the bundle
///
/// ## Materialization
///
/// Virtual (derived) bundles contain only a `preview.fastq` on disk. To resolve the
/// full FASTQ, callers must inject a ``materializer`` closure. This is typically wired
/// to `FASTQDerivativeService.shared.materializeDatasetFASTQ` from the app layer.
/// Without a materializer, derived bundles throw ``ExtractionError/noSourceFASTQ``.
///
/// ## Thread Safety
///
/// `FASTQSourceResolver` is an actor, safe to use from any isolation domain.
public final class FASTQSourceResolver: Sendable {

    /// Closure type for materializing a derived bundle into a temporary FASTQ file.
    ///
    /// - Parameters:
    ///   - bundleURL: The `.lungfishfastq` bundle to materialize.
    ///   - tempDirectory: Directory where temporary output should be written.
    ///   - progress: Callback for reporting progress messages.
    /// - Returns: URL of the materialized FASTQ file.
    public typealias Materializer = @Sendable (
        _ bundleURL: URL,
        _ tempDirectory: URL,
        _ progress: @Sendable (String) -> Void
    ) async throws -> URL

    /// Optional materializer for derived/virtual bundles.
    ///
    /// When set, derived bundles (those containing `derived.manifest.json`) are
    /// materialized via this closure. When `nil`, derived bundles that lack physical
    /// FASTQ files throw ``ExtractionError/noSourceFASTQ``.
    public nonisolated(unsafe) var materializer: Materializer?

    /// Creates a new resolver.
    public init() {}

    /// Resolves readable FASTQ file URL(s) for the given bundle.
    ///
    /// - Parameters:
    ///   - bundleURL: A `.lungfishfastq` bundle directory.
    ///   - tempDirectory: Directory for any temporary files produced during materialization.
    ///   - progress: Callback reporting progress as `(fraction, message)`.
    /// - Returns: One or more FASTQ file URLs ready for processing.
    /// - Throws: ``ExtractionError/noSourceFASTQ`` if no FASTQ files can be resolved.
    public func resolve(
        bundleURL: URL,
        tempDirectory: URL,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        // Verify bundle exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExtractionError.noSourceFASTQ
        }

        // Strategy 1: Multi-file manifest (source-files.json)
        if FASTQSourceFileManifest.exists(in: bundleURL) {
            if let manifest = try? FASTQSourceFileManifest.load(from: bundleURL) {
                let urls = manifest.resolveFileURLs(relativeTo: bundleURL)
                let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                if !existing.isEmpty {
                    return existing
                }
            }
        }

        // Strategy 2: Physical FASTQ files (not preview.fastq if others exist)
        let physicalFiles = findPhysicalFASTQFiles(in: bundleURL)
        let nonPreview = physicalFiles.filter { $0.lastPathComponent != "preview.fastq" }
        if !nonPreview.isEmpty {
            return nonPreview
        }

        // Strategy 3: Derived manifest -- delegate to materializer
        if FASTQBundle.isDerivedBundle(bundleURL) {
            if let materializer = self.materializer {
                progress(0.1, "Materializing virtual FASTQ...")
                let materializedURL = try await materializer(bundleURL, tempDirectory) { message in
                    progress(0.5, message)
                }
                progress(1.0, "Materialization complete")
                return [materializedURL]
            }
            // No materializer provided for a derived bundle
            throw ExtractionError.noSourceFASTQ
        }

        // Strategy 4: Fallback -- include preview.fastq if it's all we have
        if !physicalFiles.isEmpty {
            return physicalFiles
        }

        throw ExtractionError.noSourceFASTQ
    }

    /// Generates a UUID-based temporary file name.
    ///
    /// - Parameter ext: The file extension (e.g., `"fastq"`, `"fastq.gz"`).
    /// - Returns: A unique file name such as `"a1b2c3d4e5f6.fastq"`.
    public static func tempFileName(extension ext: String) -> String {
        "\(UUID().uuidString.lowercased().prefix(12)).\(ext)"
    }

    // MARK: - Private Helpers

    /// Scans the bundle directory for `.fastq` and `.fastq.gz` files (non-recursive).
    private func findPhysicalFASTQFiles(in bundleURL: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { FASTQBundle.isFASTQFileURL($0) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}
