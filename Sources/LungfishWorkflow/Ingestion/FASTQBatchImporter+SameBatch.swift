// FASTQBatchImporter+SameBatch.swift - No sample of an import replaces a bundle the same import wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {

    /// The bundles one import has published, so that no later sample of the
    /// same import replaces one, whatever `--force` says.
    ///
    /// Two samples of one import can name one bundle. When the check leaves a
    /// run's third file out, the pair and the third file are two samples of
    /// the run's name (``checkingUnpairedReads(_:)``). Two files of one stem
    /// from two folders name one bundle too, and so do two names that differ
    /// only in case on a volume that ignores case. Without `--force` the
    /// later sample finds the bundle and is skipped. With `--force` it
    /// replaced the bundle and moved it to the Trash, so a run's reads whose
    /// mate is missing took the place of its pairs (f10-report.md, concern
    /// 1). `--force` now replaces only a bundle that was there before the
    /// import.
    ///
    /// The Import FASTQ sheet runs `import fastq` once per sample, so it
    /// keeps the same record across its samples and its duplicate dialog
    /// never offers to replace a bundle of the same sheet.
    public struct BundlesWrittenByThisImport: Sendable {
        private var paths: Set<String> = []
        private var files: Set<FileIdentity> = []

        public init() {}

        /// Records a bundle a sample of this import published.
        public mutating func insert(_ bundleURL: URL) {
            paths.insert(bundleURL.standardizedFileURL.path)
            if let file = FileIdentity(of: bundleURL) { files.insert(file) }
        }

        /// Whether the bundle at `bundleURL` exists and is one this import
        /// wrote. The file decides, not the spelling of its path, so a name
        /// that differs only in case on a volume that ignores case is the
        /// same bundle.
        public func contains(_ bundleURL: URL) -> Bool {
            guard FileManager.default.fileExists(atPath: bundleURL.path) else { return false }
            return paths.contains(bundleURL.standardizedFileURL.path)
                || FileIdentity(of: bundleURL).map(files.contains) == true
        }

        /// Why `pair` is skipped when its bundle is one this import wrote, or
        /// nil when it is not.
        func reasonToSkip(_ pair: SamplePair, in projectDirectory: URL) -> String? {
            guard contains(FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDirectory)) else { return nil }
            return "Bundle already exists. An earlier sample of this import wrote it, and --force never replaces "
                + "a bundle the same import wrote."
        }
    }

    /// The volume and the file number of a file, which every spelling of its
    /// path shares.
    private struct FileIdentity: Hashable {
        let volume: Int
        let fileNumber: Int

        init?(of url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let volume = (attributes[.systemNumber] as? NSNumber)?.intValue,
                  let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue
            else { return nil }
            self.volume = volume
            self.fileNumber = fileNumber
        }
    }
}
