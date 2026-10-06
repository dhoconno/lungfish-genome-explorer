// DemultiplexingPipeline+Staging.swift - A demultiplex run publishes its barcode bundles only once every one is finished
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The hidden folder inside the output folder that a run writes its
/// barcode bundles and manifest into until all of them are finished.
///
/// The bundles used to be written in place. Their folders were made before
/// the heavy work, a rebuild group's previews were written while later
/// groups still ran, and the derived manifests came last, so a run that
/// failed left barcode folders holding `preview.fastq` and no manifest. A
/// later command read such a folder as a physical bundle whose reads were
/// its 1,000-read preview (Phase 1 re-review round 2 N1). A physical run
/// left the FASTQ of a barcode that was never finished the same way. Now a
/// failed or cancelled run removes the folder, and a killed one leaves only
/// this hidden folder, which no listing shows as a bundle (L5 item 4).
struct DemultiplexStagingArea {
    static let folderPrefix = ".lungfish-demux-incomplete-"

    /// The output folder the bundles are published into.
    let publishedDirectory: URL
    /// Where the run writes them.
    let directory: URL
    /// Whether this run made the output folder, so a failed run removes it again.
    private let madePublishedDirectory: Bool

    init(publishedDirectory: URL) throws {
        let fm = FileManager.default
        self.publishedDirectory = publishedDirectory
        madePublishedDirectory = !fm.fileExists(atPath: publishedDirectory.path)
        directory = publishedDirectory.appendingPathComponent(
            "\(Self.folderPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `config` writing into the staging folder, with the output folder as
    /// the place its derived manifests' paths are relative to.
    func stagedConfig(_ config: DemultiplexConfig) -> DemultiplexConfig {
        var staged = config
        staged.outputDirectory = directory
        staged.publishedOutputDirectory = publishedDirectory
        return staged
    }

    /// Where `stagedURL`, an item of the staging folder, lands when published.
    func publishedURL(of stagedURL: URL) -> URL {
        publishedDirectory.appendingPathComponent(stagedURL.lastPathComponent, isDirectory: stagedURL.hasDirectoryPath)
    }

    /// Moves every finished item into the output folder, the demultiplex
    /// manifest last, removes the staging folder, and returns `result` with
    /// the published bundle URLs.
    ///
    /// An item of the same name already in the output folder refuses the
    /// run before anything moves, because writing in place used to merge a
    /// bundle into whatever folder held its name.
    func publish(_ result: DemultiplexResult) throws -> DemultiplexResult {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        if let taken = items.first(where: { fm.fileExists(atPath: publishedURL(of: $0).path) }) {
            throw DemultiplexError.bundleCreationFailed(
                barcode: taken.deletingPathExtension().lastPathComponent,
                underlying: "the output folder \(publishedDirectory.path) already holds \(taken.lastPathComponent)"
            )
        }
        let manifestLast = items.filter { $0.lastPathComponent != DemultiplexManifest.filename }
            + items.filter { $0.lastPathComponent == DemultiplexManifest.filename }
        for item in manifestLast {
            try fm.moveItem(at: item, to: publishedURL(of: item))
        }
        try fm.removeItem(at: directory)
        return DemultiplexResult(
            manifest: result.manifest,
            outputBundleURLs: result.outputBundleURLs.map(publishedURL(of:)),
            unassignedBundleURL: result.unassignedBundleURL.map(publishedURL(of:)),
            wallClockSeconds: result.wallClockSeconds,
            nativeCommand: result.nativeCommand
        )
    }

    /// Removes the staging folder, and the output folder too when this run
    /// made it and nothing else is in it.
    func discard() {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        if madePublishedDirectory,
           let contents = try? fm.contentsOfDirectory(atPath: publishedDirectory.path),
           contents.isEmpty {
            try? fm.removeItem(at: publishedDirectory)
        }
    }
}

extension DemultiplexingPipeline {
    /// The URL a bundle written in the staging folder has once published,
    /// which the paths in its derived manifest are relative to.
    func manifestAnchorURL(for bundleURL: URL, config: DemultiplexConfig) -> URL {
        guard let published = config.publishedOutputDirectory else { return bundleURL }
        return published.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
    }
}
