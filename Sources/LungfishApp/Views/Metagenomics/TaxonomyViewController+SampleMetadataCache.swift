// TaxonomyViewController+SampleMetadataCache.swift - The Kraken2 view's metadata cache refresh, off the main actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let metadataCacheLogger = Logger(subsystem: LogSubsystem.app, category: "TaxonomyMetadataCache")

extension TaxonomyViewController {
    /// Refreshes the open database's sample metadata cache after the view is handed a metadata store (Phase 2.13
    /// lane 13.35, M865). The store's records are copied on the main actor, and the refresh itself runs off it on
    /// ``refreshSampleMetadataCacheOffMain(database:records:)``, since it opens `kraken2.sqlite` and may write it.
    /// Each refresh waits for the one before it, so two quick changes of the store reach the file in order.
    ///
    /// - Returns: The refresh, which tests await through `sampleMetadataCacheRefresh`, or `nil` when there is no
    ///   store or no database to refresh.
    @discardableResult
    func scheduleSampleMetadataCacheRefresh(
        _ store: SampleMetadataStore?,
        database: Kraken2Database?
    ) -> Task<Void, Never>? {
        guard let store, let database else { return nil }
        let records = store.records
        let previous = sampleMetadataCacheRefresh
        let refresh = Task { @MainActor in
            await previous?.value
            await Self.refreshSampleMetadataCacheOffMain(database: database, records: records)
        }
        sampleMetadataCacheRefresh = refresh
        return refresh
    }

    /// The cache read and any write, on the global concurrent executor and never on the main actor. The database
    /// leaves the file as it is when the cache already holds the rows, so opening a result twice moves no byte.
    @concurrent nonisolated static func refreshSampleMetadataCacheOffMain(
        database: Kraken2Database,
        records: [String: [String: String]]
    ) async {
        do {
            if try database.refreshSampleMetadataCache(records: records) {
                metadataCacheLogger.info(
                    "Rewrote the sample metadata cache of \(database.databaseURL.lastPathComponent, privacy: .public)"
                )
            }
        } catch {
            metadataCacheLogger.error(
                "Could not refresh the sample metadata cache: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
