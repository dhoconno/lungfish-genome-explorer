// Kraken2TaxonomyTableExport+Reports.swift - Whether a Kraken2 result folder still holds the reports its database was built from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension Kraken2TaxonomyTableExport {
    /// Whether `resultURL` still holds the Kraken 2 reports `build-db` needs.
    public static func reportsAvailable(in resultURL: URL) -> Bool {
        let fm = FileManager.default
        if let manifest = MetagenomicsBatchResultStore.loadClassification(from: resultURL) {
            return manifest.samples.contains { record in
                let kreport = resultURL
                    .appendingPathComponent(record.resultDirectory, isDirectory: true)
                    .appendingPathComponent("classification.kreport")
                return fm.fileExists(atPath: kreport.path)
            }
        }
        return fm.fileExists(atPath: resultURL.appendingPathComponent("classification.kreport").path)
    }
}
