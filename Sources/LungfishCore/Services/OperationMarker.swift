// OperationMarker.swift — Shared in-progress sentinel for operation output directories
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Manages a `.processing` sentinel file inside directories being built by long-running operations.
///
/// The sidebar hides any directory containing this marker file. This prevents users from
/// seeing incomplete results, broken bundles, or half-written data while an operation is
/// still running.
///
/// ## Convention
///
/// **Every operation that creates a user-visible directory** (result folders, FASTQ bundles,
/// reference bundles, derivative outputs) **MUST** call ``markInProgress(_:detail:)``
/// immediately after directory creation and ``clearInProgress(_:)`` on successful completion.
///
/// The recommended pattern uses `defer` to ensure cleanup:
///
/// ```swift
/// try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
/// OperationMarker.markInProgress(outputDir, detail: "Running classification…")
/// defer { OperationMarker.clearInProgress(outputDir) }
/// // ... long-running work ...
/// ```
///
/// On failure, either clean up the directory entirely (the marker goes with it) or leave
/// the marker so the sidebar ignores the incomplete directory.
public enum OperationMarker {

    /// Sentinel filename placed inside directories that are still being built.
    public static let filename = ".processing"

    /// Returns `true` when the directory contains the `.processing` sentinel file.
    public static func isInProgress(_ directoryURL: URL) -> Bool {
        let markerURL = directoryURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Writes the `.processing` sentinel file into the directory.
    ///
    /// - Parameters:
    ///   - directoryURL: The directory to mark as in-progress.
    ///   - detail: Human-readable description of the operation (e.g., "Importing Kraken2 results…").
    public static func markInProgress(_ directoryURL: URL, detail: String = "Processing\u{2026}") {
        let markerURL = directoryURL.appendingPathComponent(filename)
        try? detail.data(using: .utf8)?.write(to: markerURL, options: .atomic)
    }

    /// Removes the `.processing` sentinel file, marking the directory as ready.
    ///
    /// Safe to call when no marker exists (no-op).
    public static func clearInProgress(_ directoryURL: URL) {
        let markerURL = directoryURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: markerURL)
    }
}
