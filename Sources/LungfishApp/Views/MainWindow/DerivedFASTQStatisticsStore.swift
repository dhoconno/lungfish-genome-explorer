// DerivedFASTQStatisticsStore.swift - Measures a derived bundle's uncounted statistics once and stores them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let storeLogger = Logger(subsystem: "com.lungfish.app", category: "DerivedFASTQStatisticsStore")

/// The statistics a view shows for a derived bundle (Phase 3.0 lane DEMUX-STATS).
///
/// Stored statistics that were counted are shown as stored. Statistics that were not counted
/// (`FASTQStatisticsDisplayRules.storedStatisticsToShow`) are measured from the bundle's reads once and written back
/// into the bundle's derived manifest, through the save the demultiplexer uses, so a large bundle is measured at most
/// once. When the save fails, on a read-only volume or a locked project, the measured numbers are still shown and kept
/// for this session, and the save is not tried again.
@MainActor
enum DerivedFASTQStatisticsStore {

    /// Measured statistics whose save failed, by bundle path, kept for this session.
    private static var unsaved: [String: FASTQDatasetStatistics] = [:]

    static func statistics(
        for manifest: FASTQDerivedBundleManifest,
        in bundleURL: URL,
        measure: @Sendable (URL) async throws -> FASTQDatasetStatistics,
        save: (FASTQDerivedBundleManifest, URL) throws -> Void = { try FASTQBundle.saveDerivedManifest($0, in: $1) }
    ) async throws -> FASTQDatasetStatistics {
        if let stored = FASTQStatisticsDisplayRules.storedStatisticsToShow(manifest.cachedStatistics) {
            return stored
        }
        let key = bundleURL.standardizedFileURL.path
        if let kept = unsaved[key] { return kept }

        let measured = try await measure(bundleURL)
        let updated = FASTQDerivedBundleManifest(
            id: manifest.id, name: manifest.name, createdAt: manifest.createdAt,
            parentBundleRelativePath: manifest.parentBundleRelativePath,
            rootBundleRelativePath: manifest.rootBundleRelativePath,
            rootFASTQFilename: manifest.rootFASTQFilename,
            payload: manifest.payload, lineage: manifest.lineage, operation: manifest.operation,
            cachedStatistics: measured,
            pairingMode: manifest.pairingMode, readClassification: manifest.readClassification,
            batchOperationID: manifest.batchOperationID, sequenceFormat: manifest.sequenceFormat,
            provenance: manifest.provenance, payloadChecksums: manifest.payloadChecksums,
            materializationState: manifest.materializationState
        )
        do {
            try save(updated, bundleURL)
        } catch {
            unsaved[key] = measured
            storeLogger.error(
                "Measured \(bundleURL.lastPathComponent, privacy: .public) but could not store the statistics: \(error.localizedDescription, privacy: .public). Showing them for this session."
            )
        }
        return measured
    }
}
