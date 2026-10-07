// FASTQBatchImporter+SameBatch.swift - No sample of an import writes a bundle the same import wrote or failed to write
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {

    /// The bundles one import has published or failed to write, so that no
    /// later sample of the same import writes one, whatever `--force` says.
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
    /// import. When the pair failed, the third file took the run's name, and
    /// under `--force` replaced the run's earlier complete bundle (review
    /// B-S2), so a bundle an earlier sample failed to write keeps every later
    /// sample out too.
    ///
    /// The Import FASTQ sheet runs `import fastq` once per sample, so it
    /// keeps the same record across its samples and its duplicate dialog
    /// never offers to replace a bundle of the same sheet.
    public struct BundlesWrittenByThisImport: Sendable {
        private var paths: Set<String> = []
        private var files: Set<FileIdentity> = []
        private var failedPaths: Set<String> = []

        public init() {}

        /// Records a bundle a sample of this import published.
        public mutating func insert(_ bundleURL: URL) {
            paths.insert(bundleURL.standardizedFileURL.path)
            if let file = FileIdentity(of: bundleURL) { files.insert(file) }
        }

        /// Records a bundle a sample of this import tried to write and
        /// failed to.
        mutating func insertFailed(_ bundleURL: URL) {
            failedPaths.insert(bundleURL.standardizedFileURL.path)
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

        /// Why `pair` is skipped for what an earlier sample of this import
        /// did with its bundle, or nil when no earlier sample keeps it out. A
        /// bundle an earlier sample failed to write keeps it out whatever
        /// `--force` says. One an earlier sample wrote keeps it out under
        /// `--force`. Without `--force` that bundle exists, which skips the
        /// sample as before.
        func reasonToSkip(_ pair: SamplePair, in projectDirectory: URL, force: Bool) -> String? {
            let bundleURL = FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDirectory)
            if failedPaths.contains(bundleURL.standardizedFileURL.path) {
                return "An earlier sample of this import failed to write this bundle, so no later sample of the "
                    + "import writes it."
            }
            guard force, contains(bundleURL) else { return nil }
            return "Bundle already exists. An earlier sample of this import wrote it, and --force never replaces "
                + "a bundle the same import wrote."
        }
    }

    /// What an import does with a sample before any work for it.
    enum SampleStart {
        case run
        case skip(String)
        case fail(Error)
    }

    /// Decides whether `pair` runs, is skipped with a reason, or fails,
    /// before anything is allocated for it. What earlier samples of the
    /// import did with its bundle comes first, then, without `--force`, the
    /// bundle the project already holds.
    static func start(
        of pair: SamplePair,
        config: ImportConfig,
        after written: BundlesWrittenByThisImport
    ) -> SampleStart {
        if let reason = written.reasonToSkip(pair, in: config.projectDirectory, force: config.forceReimport) {
            return .skip(reason)
        }
        guard !config.forceReimport else { return .run }
        switch existingImportBundleStatus(for: pair, in: config.projectDirectory) {
        case .complete: return .skip("Bundle already exists")
        case .incomplete(let bundleURL): return .fail(BatchImportError.outputBundleAlreadyExists(bundleURL))
        case .missing: return .run
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
