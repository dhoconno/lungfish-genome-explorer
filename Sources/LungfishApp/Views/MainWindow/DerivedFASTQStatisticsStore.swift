// DerivedFASTQStatisticsStore.swift - Measures a derived bundle's uncounted statistics once a session
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The statistics a view shows for a derived bundle (Phase 3.0 lane DEMUX-STATS).
///
/// Stored statistics that were counted are shown as stored. Statistics that were not counted
/// (`FASTQStatisticsDisplayRules.storedStatisticsToShow`) are measured from the bundle's reads, and the result is kept
/// in memory for this session. A view writes nothing into the project (Phase 2.6 lane B3, UX 6), because recorded
/// directory digests cover the bundle's files, so an older bundle is measured once each session.
@MainActor
enum DerivedFASTQStatisticsStore {

    /// Measured statistics by bundle path with a stamp of the manifest file, kept for this session. A view writes
    /// nothing into the project (Phase 2.6 lane B3, UX 6), so an older bundle is measured once each session.
    private static var measuredThisSession: [String: (stamp: String, statistics: FASTQDatasetStatistics)] = [:]

    static func statistics(
        for manifest: FASTQDerivedBundleManifest,
        in bundleURL: URL,
        measure: @Sendable (URL) async throws -> FASTQDatasetStatistics
    ) async throws -> FASTQDatasetStatistics {
        if let stored = FASTQStatisticsDisplayRules.storedStatisticsToShow(manifest.cachedStatistics) {
            return stored
        }
        let key = bundleURL.standardizedFileURL.path
        var info = stat()
        let stamp = stat(FASTQBundle.derivedManifestURL(in: bundleURL).path, &info) == 0
            ? "\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" : key
        if let kept = measuredThisSession[key], kept.stamp == stamp { return kept.statistics }
        let measured = try await measure(bundleURL)
        measuredThisSession[key] = (stamp, measured)
        if measuredThisSession.count > 32, let old = measuredThisSession.keys.first(where: { $0 != key }) {
            measuredThisSession[old] = nil
        }
        return measured
    }
}
