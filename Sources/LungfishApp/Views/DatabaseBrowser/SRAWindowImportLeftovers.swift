// SRAWindowImportLeftovers.swift - What a cancelled CLI import of one SRA run left in the project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import os

/// What the CLI reported for one run: the bundle it made, or its error.
private final class SRAWindowImportResult: Sendable {
    private let state = OSAllocatedUnfairLock<(bundle: URL?, error: String?)>(initialState: (nil, nil))
    var bundle: URL? { state.withLock { $0.bundle } }
    var error: String? { state.withLock { $0.error } }
    func setBundle(_ url: URL) { state.withLock { $0.bundle = url } }
    func setError(_ message: String) { state.withLock { $0.error = message } }
}

/// What one run's `lungfish-cli import fastq` published in `<project>/Imports/`,
/// told apart from everything else there by name and by time.
///
/// `lungfish-cli` removes its own hidden `.<sample>.building-<UUID>/` staging
/// folder when a cancel reaches it. The window never removes such a folder,
/// because it cannot tell one from a concurrent import's in-progress folder.
/// A published bundle is this run's only when all of these hold:
/// - it was not in `Imports/` before the CLI launched,
/// - its name carries one of the run's sample names,
/// - it was created after the CLI launched.
struct SRAWindowImportLeftovers {
    let importsFolder: URL
    let sampleNames: Set<String>
    let launchedAt: Date
    let entriesBefore: Set<String>

    /// Notes what `Imports/` holds before the CLI launches.
    ///
    /// - Parameters:
    ///   - accession: The run, whose files are named after it.
    ///   - files: The files the CLI imports. Their sample names are worked
    ///     out the way `import fastq` works them out.
    init(projectDirectory: URL, accession: String, files: [URL], launchedAt: Date = Date()) {
        importsFolder = projectDirectory.appendingPathComponent("Imports", isDirectory: true)
        sampleNames = Set(FASTQBatchImporter.detectPairs(from: files).map(\.sampleName) + [accession])
        self.launchedAt = launchedAt
        entriesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: importsFolder.path)) ?? [])
    }

    /// The bundle this run's import published, when there is exactly one.
    ///
    /// A cancel can land after the CLI published the bundle but before it
    /// said so. The bundle is then complete, so the window keeps it and
    /// records the run's SRA metadata in it, as for any finished run.
    func publishedBundle() -> URL? {
        let bundles = newEntries { name in
            sampleNames.contains { name == "\($0).\(FASTQBundle.directoryExtension)" }
        }
        return bundles.count == 1 ? bundles[0] : nil
    }

    /// Imports one staged run with `lungfish-cli import fastq` and returns
    /// the bundle it made.
    ///
    /// A cancel before the launch throws before the CLI runs. After a cancel
    /// during the import, a bundle the CLI published before the cancel
    /// reached it is returned so the window records its SRA metadata.
    /// Staging folders are left to the CLI. The operation row is left to the
    /// caller, which ends it once its own cleanup has run.
    static func importRun(
        arguments: [String],
        operationID: UUID,
        projectDirectory: URL,
        accession: String,
        files: [URL],
        launchedAt: Date = Date()
    ) async throws -> URL {
        try Task.checkCancellation()
        let tracker = SRAWindowImportResult()
        let leftovers = SRAWindowImportLeftovers(
            projectDirectory: projectDirectory, accession: accession, files: files, launchedAt: launchedAt
        )
        await CLIImportRunner().run(
            arguments: arguments,
            operationID: operationID,
            projectDirectory: projectDirectory,
            onBundleCreated: { tracker.setBundle($0) },
            onError: { tracker.setError($0) }
        )
        var bundleURL = tracker.bundle
        if Task.isCancelled {
            bundleURL = bundleURL ?? leftovers.publishedBundle()
        }
        if let bundleURL { return bundleURL }
        if Task.isCancelled { throw CancellationError() }
        throw NSError(
            domain: "DatabaseBrowser.SRAImport", code: tracker.error == nil ? 2 : 1,
            userInfo: [NSLocalizedDescriptionKey: tracker.error ?? "CLI import produced no output bundle for \(accession)"]
        )
    }

    private func newEntries(named matches: (String) -> Bool) -> [URL] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: importsFolder.path)) ?? []
        return names.sorted().compactMap { name in
            guard !entriesBefore.contains(name), matches(name) else { return nil }
            let url = importsFolder.appendingPathComponent(name, isDirectory: true)
            guard let created = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate] as? Date,
                  created >= launchedAt else { return nil }
            return url
        }
    }
}
