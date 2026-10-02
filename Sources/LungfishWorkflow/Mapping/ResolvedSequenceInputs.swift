// ResolvedSequenceInputs.swift - Sequence inputs resolved to the files a tool reads, with their lineage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The files a tool reads for the sequence inputs a user chose, each paired
/// with the input it came from.
///
/// This is the resolution the Map Reads window applies to every input, and
/// the one `AppDelegate.resolveInputFiles` applies for the classifiers. A
/// bundle contributes every FASTQ file it holds, through
/// ``FASTQSourceResolver``, and a virtual bundle (subset, trim,
/// demultiplexed or oriented reads) is materialized into
/// `materializationDirectory` first. `lungfish-cli map` resolves one primary
/// file per input through
/// ``CLISequenceInputMaterialization/resolveExecutionInputs(for:tempDirectory:materializer:operationName:progress:)``,
/// so the two are not interchangeable for a bundle that holds several files.
///
/// `originalInputURLs` has one entry per execution file, so index `i` of
/// ``executionInputURLs`` came from index `i` of ``originalInputURLs``. That
/// is the pairing ``ManagedMappingPipeline`` records lineage by.
public struct ResolvedSequenceInputs: Sendable, Equatable {
    /// One input the user chose and the files it resolved to.
    public struct Input: Sendable, Equatable {
        /// The input as the user chose it, standardized.
        public let originalURL: URL
        /// The file or files the tool reads for it, standardized.
        public let executionURLs: [URL]
        /// Whether `executionURLs` were written by the materializer rather
        /// than found on disk.
        public let wasMaterialized: Bool

        public init(originalURL: URL, executionURLs: [URL], wasMaterialized: Bool) {
            self.originalURL = originalURL.standardizedFileURL
            self.executionURLs = executionURLs.map(\.standardizedFileURL)
            self.wasMaterialized = wasMaterialized
        }
    }

    public let inputs: [Input]
    /// When the first materialization began, or nil when nothing was materialized.
    public let materializationStartedAt: Date?
    /// When the last materialization ended, or nil when nothing was materialized.
    public let materializationEndedAt: Date?

    public init(inputs: [Input], materializationStartedAt: Date?, materializationEndedAt: Date?) {
        self.inputs = inputs
        self.materializationStartedAt = materializationStartedAt
        self.materializationEndedAt = materializationEndedAt
    }

    /// The files the tool reads, in input order.
    public var executionInputURLs: [URL] {
        inputs.flatMap(\.executionURLs)
    }

    /// The input each execution file came from, one entry per execution file.
    public var originalInputURLs: [URL] {
        inputs.flatMap { input in input.executionURLs.map { _ in input.originalURL } }
    }

    /// The execution files the materializer wrote.
    public var materializedExecutionURLs: [URL] {
        inputs.filter(\.wasMaterialized).flatMap(\.executionURLs)
    }

    public var didMaterialize: Bool {
        inputs.contains(where: \.wasMaterialized)
    }

    /// Resolves `inputURLs` to the files a tool reads.
    ///
    /// A URL inside a `.lungfishfastq` bundle, or the bundle itself, resolves
    /// through ``FASTQSourceResolver`` to every file of the bundle, with a
    /// virtual bundle materialized by `materializer` into
    /// `materializationDirectory`, which is created when first needed. A URL
    /// outside a bundle resolves to its primary sequence file, or passes
    /// through unchanged when it has none. On an error, every file this call
    /// materialized is removed, and so is the directory when it did not exist
    /// before. Cancellation is checked before each input.
    public static func resolve(
        inputURLs: [URL],
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResolvedSequenceInputs {
        let fileManager = FileManager.default
        let directory = materializationDirectory.standardizedFileURL
        var directoryWasDirectory = ObjCBool(false)
        let directoryExisted = fileManager.fileExists(atPath: directory.path, isDirectory: &directoryWasDirectory)
        let preexistingEntries: Set<String>? = directoryExisted && directoryWasDirectory.boolValue
            ? (try? fileManager.contentsOfDirectory(atPath: directory.path)).map(Set.init)
            : nil

        let resolver = FASTQSourceResolver()
        resolver.materializer = { bundleURL, outputDirectory, progressCallback in
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            return try await materializer.materialize(
                bundleURL: bundleURL,
                tempDirectory: outputDirectory,
                progress: progressCallback
            )
        }

        var inputs: [Input] = []
        var materializationStartedAt: Date?
        var materializationEndedAt: Date?
        do {
            for inputURL in inputURLs {
                try Task.checkCancellation()
                let originalURL = inputURL.standardizedFileURL

                if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: originalURL) {
                    // A fullFASTA derivative stores its whole FASTA in place.
                    // FASTQSourceResolver finds no FASTQ file in it and would
                    // have the materializer copy the FASTA, so the file is
                    // used where it is, as lungfish-cli map does.
                    if let fastaURL = inPlaceFASTA(of: bundleURL) {
                        inputs.append(Input(originalURL: originalURL, executionURLs: [fastaURL], wasMaterialized: false))
                        continue
                    }
                    let began = Date()
                    let urls = try await resolver.resolve(
                        bundleURL: bundleURL,
                        tempDirectory: directory,
                        progress: { _, message in progress?(message) }
                    )
                    let ended = Date()
                    let wasMaterialized = urls.contains { isInside(directory, $0) }
                    if wasMaterialized {
                        materializationStartedAt = materializationStartedAt ?? began
                        materializationEndedAt = ended
                    }
                    inputs.append(Input(originalURL: originalURL, executionURLs: urls, wasMaterialized: wasMaterialized))
                    continue
                }

                if let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: originalURL) {
                    inputs.append(Input(originalURL: originalURL, executionURLs: [resolvedURL], wasMaterialized: false))
                    continue
                }

                inputs.append(Input(originalURL: originalURL, executionURLs: [originalURL], wasMaterialized: false))
            }
        } catch {
            removeMaterializedOutputs(
                in: directory,
                directoryExisted: directoryExisted,
                preexistingEntries: preexistingEntries
            )
            throw error
        }

        return ResolvedSequenceInputs(
            inputs: inputs,
            materializationStartedAt: materializationStartedAt,
            materializationEndedAt: materializationEndedAt
        )
    }

    private static func isInside(_ directory: URL, _ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.path + "/")
    }

    /// The FASTA a `fullFASTA` derivative stores, when it exists.
    private static func inPlaceFASTA(of bundleURL: URL) -> URL? {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL),
              case .fullFASTA = manifest.payload else {
            return nil
        }
        return SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL)
    }

    /// Removes what this call wrote into the materialization directory: the
    /// whole directory when it did not exist before, otherwise every entry
    /// that was not there before (a failed materialization can leave a
    /// partial file behind).
    private static func removeMaterializedOutputs(
        in directory: URL,
        directoryExisted: Bool,
        preexistingEntries: Set<String>?
    ) {
        let fileManager = FileManager.default
        guard directoryExisted else {
            try? fileManager.removeItem(at: directory)
            return
        }
        guard let preexistingEntries,
              let currentEntries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for entry in currentEntries where !preexistingEntries.contains(entry) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry))
        }
    }
}
