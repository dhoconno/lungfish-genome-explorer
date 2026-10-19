// BundleBrowserLoader.swift - Precedence-aware loader for bundle browser summaries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

package struct BundleBrowserLoadResult: Equatable {
    enum Source: Equatable {
        case manifest
        case mirror
        case synthesized
    }

    package let summary: BundleBrowserSummary
    let source: Source
}

package struct BundleBrowserLoader {
    var mirrorStoreFactory: (URL) throws -> BundleBrowserMirrorStore
    var synthesizer: (URL, BundleManifest) throws -> BundleBrowserSummary

    package init(
        mirrorStoreFactory: @escaping (URL) throws -> BundleBrowserMirrorStore = { try BundleBrowserMirrorStore(projectURL: $0) },
        synthesizer: @escaping (URL, BundleManifest) throws -> BundleBrowserSummary = { bundleURL, manifest in
            try BundleSequenceSummarySynthesizer.summarize(bundleURL: bundleURL, manifest: manifest)
        }
    ) {
        self.mirrorStoreFactory = mirrorStoreFactory
        self.synthesizer = synthesizer
    }

    static func bundleKey(for bundleURL: URL, manifest: BundleManifest) -> String {
        (
            [
            bundleURL.standardizedFileURL.path,
            manifest.identifier,
            manifest.modifiedDate.ISO8601Format(),
            String(manifest.genome?.totalLength ?? 0),
            String(manifest.alignments.count),
            ]
            + variantDatabaseFingerprintLines(bundleURL: bundleURL, manifest: manifest)
        ).joined(separator: "\n")
    }

    package func load(bundleURL: URL, manifest: BundleManifest) throws -> BundleBrowserLoadResult {
        if let summary = manifest.browserSummary {
            return BundleBrowserLoadResult(summary: summary, source: .manifest)
        }

        // A genome bundle's summary follows from its manifest alone, so it is built in memory and the project
        // mirror is neither read nor written (lane 12.37, ARCH ruling Q-S4 item 3, UX 6). A reference open passes
        // a manifest that already holds it, built off the main actor. A variant-only bundle keeps the mirror,
        // since its summary reads the variant databases.
        if manifest.genome != nil, let summary = manifest.withSynthesizedBrowserSummaryIfNeeded().browserSummary {
            return BundleBrowserLoadResult(summary: summary, source: .synthesized)
        }

        if let projectURL = ProjectTempDirectory.findProjectRoot(bundleURL) {
            let key = Self.bundleKey(for: bundleURL, manifest: manifest)
            if let cached = ((try? loadFromMirror(projectURL: projectURL, bundleKey: key)) ?? nil) {
                return BundleBrowserLoadResult(summary: cached, source: .mirror)
            }

            let summary = try synthesizer(bundleURL, manifest)
            try? persistToMirror(projectURL: projectURL, bundleKey: key, summary: summary)
            return BundleBrowserLoadResult(summary: summary, source: .synthesized)
        }

        return BundleBrowserLoadResult(
            summary: try synthesizer(bundleURL, manifest),
            source: .synthesized
        )
    }

    private func loadFromMirror(projectURL: URL, bundleKey: String) throws -> BundleBrowserSummary? {
        let store = try mirrorStoreFactory(projectURL)
        return try store.fetch(bundleKey: bundleKey)
    }

    private func persistToMirror(projectURL: URL, bundleKey: String, summary: BundleBrowserSummary) throws {
        let store = try mirrorStoreFactory(projectURL)
        try store.upsert(summary: summary, bundleKey: bundleKey)
    }

    private static func variantDatabaseFingerprintLines(bundleURL: URL, manifest: BundleManifest) -> [String] {
        manifest.variants.sorted { $0.id < $1.id }.flatMap { track in
            guard let databasePath = track.databasePath else {
                return ["variant-db:\(track.id):none"]
            }

            let databaseURL = bundleURL.appendingPathComponent(databasePath)
            let standardizedURL = databaseURL.standardizedFileURL
            let fileManager = FileManager.default

            func fingerprintLine(for url: URL, label: String) -> String {
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                    return "variant-db:\(track.id):\(label):\(url.path):missing"
                }

                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                return "variant-db:\(track.id):\(label):\(url.path):\(size):\(modificationDate)"
            }

            return [
                fingerprintLine(for: standardizedURL, label: "main"),
                fingerprintLine(for: URL(fileURLWithPath: standardizedURL.path + "-wal"), label: "wal"),
                fingerprintLine(for: URL(fileURLWithPath: standardizedURL.path + "-shm"), label: "shm"),
            ]
        }
    }
}
