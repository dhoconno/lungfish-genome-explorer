import Foundation
import LungfishCore
import LungfishIO

package enum ReferenceBundleMergeServiceError: LocalizedError {
    case requiresAtLeastTwoBundles
    case noFASTAFound(bundleName: String)
    /// One or more source bundles carry payloads the merge cannot rebase yet.
    ///
    /// `offenders` is ordered as the user selected the bundles, and each entry names the
    /// payload kinds that bundle carries, so the alert can list every blocker at once
    /// instead of only the first.
    case unsupportedPayloads(offenders: [UnsupportedPayloadReport])
    /// A source bundle's manifest could not be read, so its payloads are unknown.
    ///
    /// This fails closed on purpose: waving an unreadable manifest through would silently
    /// drop whatever the bundle actually contained.
    case unreadableManifest(bundleName: String, underlying: String)
    /// Two or more sources declare the same sequence name.
    case duplicateSequenceNames(collisions: [SequenceNameCollision])

    package var errorDescription: String? {
        switch self {
        case .requiresAtLeastTwoBundles:
            return "Select at least two reference bundles to merge."
        case .noFASTAFound(let bundleName):
            return "No FASTA file was found in \(bundleName)."
        case .unsupportedPayloads(let offenders):
            let details = offenders
                .map { "\u{2022} \($0.bundleName) carries \($0.payloadSummary)." }
                .joined(separator: "\n")
            return """
                Reference bundle merge cannot combine these bundles yet:

                \(details)

                Sequences and annotations merge today. Variant tracks, signal tracks, and \
                alignments do not, because their coordinates would have to be rebased onto the \
                merged reference. Remove those tracks from the source bundles, or merge the \
                sequence and annotation bundles on their own.
                """
        case .unreadableManifest(let bundleName, let underlying):
            return """
                The manifest in \(bundleName) could not be read, so the merge was cancelled \
                rather than risk dropping data it may contain (\(underlying)). Reimport or \
                repair that bundle and try again.
                """
        case .duplicateSequenceNames(let collisions):
            let details = collisions
                .map { "\u{2022} \"\($0.sequenceName)\" appears in \($0.bundleNames.joined(separator: ", "))." }
                .joined(separator: "\n")
            return """
                Reference bundle merge needs every sequence name to be unique across the \
                selected bundles, and these names collide:

                \(details)

                Rename the colliding records in their source bundles and try again.
                """
        }
    }
}

/// A source bundle that carries payloads the merge does not support yet.
package struct UnsupportedPayloadReport: Equatable {
    let bundleName: String
    /// Human-readable payload kinds, e.g. `["variant tracks", "alignments"]`.
    let payloads: [String]

    var payloadSummary: String {
        switch payloads.count {
        case 0:
            return "unsupported payloads"
        case 1:
            return payloads[0]
        case 2:
            return "\(payloads[0]) and \(payloads[1])"
        default:
            return payloads.dropLast().joined(separator: ", ") + ", and \(payloads[payloads.count - 1])"
        }
    }
}

/// A sequence name declared by more than one source bundle.
package struct SequenceNameCollision: Equatable {
    let sequenceName: String
    let bundleNames: [String]
}

/// Merges several `.lungfishref` bundles into one.
///
/// Sequences concatenate; annotations are re-exported from each source's annotation
/// database and rebuilt as separate, origin-attributable tracks. Variants, signal tracks,
/// and alignments are still refused because merging concatenates distinct references,
/// which would require rebasing their coordinates onto the merged sequence space.
package enum ReferenceBundleMergeService {
    #if DEBUG
    /// Test-only threading probe, fired at the FIRST statement of `mergeOffMain` -- before
    /// any `await`, so it observes the thread the merge body was *entered* on.
    ///
    /// Asserts the entry half of the off-main invariant: the heavy work must not begin on
    /// the main thread when driven from the `@MainActor` entry point.
    nonisolated(unsafe) static var threadingProbe: (@Sendable () -> Void)?

    /// Test-only probe fired inside `mergeRecordStores`, immediately after an
    /// `await reporter.report(...)` that hops *to* the main actor to touch OperationCenter.
    ///
    /// Asserts the other half of the invariant: synchronous SQLite work that follows a
    /// main-actor progress hop must not be stranded on the main thread by that hop.
    nonisolated(unsafe) static var recordStoreThreadingProbe: (@Sendable () -> Void)?
    #endif

    /// A log line the merge wants recorded in the Operations panel, with its severity.
    package struct ProgressLog: Sendable {
        package enum Level: Sendable { case info, warning }

        package let level: Level
        package let message: String

        package static func info(_ message: String) -> ProgressLog {
            ProgressLog(level: .info, message: message)
        }

        package static func warning(_ message: String) -> ProgressLog {
            ProgressLog(level: .warning, message: message)
        }
    }

    /// Progress sink that lets the detached merge report back to the main actor.
    package struct ProgressReporter: Sendable {
        /// `(fractionComplete, userVisibleDetail, optionalLogLine)`
        package let report: @Sendable (Double, String, ProgressLog?) async -> Void

        package init(report: @escaping @Sendable (Double, String, ProgressLog?) async -> Void) {
            self.report = report
        }

        package static let none = ProgressReporter { _, _, _ in }
    }

    package static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        provenanceWriter: BundleMergeProvenanceSidecarWriter
    ) async throws -> URL {
        try await runDetached(
            sourceBundleURLs: sourceBundleURLs,
            outputDirectory: outputDirectory,
            bundleName: bundleName,
            provenanceWriter: provenanceWriter,
            reporter: .none
        )
    }

    /// Merges `sourceBundleURLs` into a new bundle named `bundleName` in `outputDirectory`, writes its record
    /// beside it and reports no progress.
    package static func merge(sourceBundleURLs: [URL], outputDirectory: URL, bundleName: String) async throws -> URL {
        try await merge(
            sourceBundleURLs: sourceBundleURLs,
            outputDirectory: outputDirectory,
            bundleName: bundleName,
            provenanceWriter: .live
        )
    }

    /// Runs the merge on the cooperative thread pool, unconditionally.
    ///
    /// Note on why this is belt-and-braces rather than load-bearing. Under the Swift 6.2
    /// language mode this package builds in, a `nonisolated async` function called from
    /// `@MainActor` does NOT inherit the caller's executor -- it hops to the generic
    /// executor on entry (SE-0338) -- and a continuation resuming after `await
    /// MainActor.run { ... }` lands back on the generic executor too, not on main. Both
    /// were verified empirically for this package's toolchain, and
    /// `ReferenceBundleMergeServiceOffMainTests` asserts both from the real call path.
    ///
    /// So `mergeOffMain` would already run off-main without this wrapper. `Task.detached`
    /// is kept because it makes the guarantee structural instead of dependent on
    /// `ReferenceBundleMergeService` never gaining actor isolation: the day someone marks
    /// this enum `@MainActor` (or the isolation rules shift again), the detached hop is what
    /// keeps `mergeRecordStores`' SQLite union and `writeMergeProvenance`'s whole-bundle
    /// enumeration plus SHA256 hashing off the main thread. All captured values are
    /// `Sendable` snapshots taken at the call site.
    ///
    /// - Parameter observedArguments: The words the process was started with, when `bundle merge` runs the
    ///   merge. The record keeps them unmapped, so it names the command that ran. Nil for a run in process,
    ///   whose record states the equivalent `bundle merge` command (2.12 lane 12.14).
    package static func runDetached(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        provenanceWriter: BundleMergeProvenanceSidecarWriter,
        reporter: ProgressReporter,
        observedArguments: [String]? = nil
    ) async throws -> URL {
        let task = Task<URL, Error>.detached(priority: .userInitiated) {
            try await mergeOffMain(
                sourceBundleURLs: sourceBundleURLs,
                outputDirectory: outputDirectory,
                bundleName: bundleName,
                provenanceWriter: provenanceWriter,
                reporter: reporter,
                observedArguments: observedArguments
            )
        }
        // The task is detached, so a cancel of the caller reaches it only when it is passed on.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// - Parameter beforePublish: A test seam. It is called with the staged bundle just before the rename that
    ///   publishes it, so a test can look at what a reader would see the moment the bundle appears.
    static func mergeOffMain(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        provenanceWriter: BundleMergeProvenanceSidecarWriter,
        reporter: ProgressReporter,
        observedArguments: [String]? = nil,
        beforePublish: (@Sendable (URL) -> Void)? = nil
    ) async throws -> URL {
        #if DEBUG
        threadingProbe?()
        #endif
        guard sourceBundleURLs.count >= 2 else {
            throw ReferenceBundleMergeServiceError.requiresAtLeastTwoBundles
        }

        await reporter.report(0.02, "Inspecting source bundles\u{2026}", nil)
        let sources = try await inspectSourceBundles(sourceBundleURLs)
        try validateNoUnsupportedPayloads(in: sources)
        try validateNoSequenceNameCollisions(in: sources)
        // A refusal above leaves no folder behind (docs/contracts/ADDING-AN-OPERATION.md), so the output folder is
        // created only now (2.11 A49 review Fix 5).
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let runClock = ProvenanceRunClock()
        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "reference-merge-",
            contextURL: outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        // The bundle is built in a stage inside the temporary folder and published under its name
        // with one rename, so no reader sees a part of it (2.11 A49 M2, SC5).
        let stageDirectory = tempDirectory.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)

        // Crash-recovery sentinel. The previous implementation got this for free by routing
        // through `ReferenceBundleImportService.importAsReferenceBundle`; building through
        // `NativeBundleBuilder` directly means we own it. Without the marker, a crash or
        // force-quit mid-merge leaves the output directory looking complete.
        OperationMarker.markInProgress(outputDirectory, detail: "Merging reference bundles\u{2026}")
        defer { OperationMarker.clearInProgress(outputDirectory) }

        var createdBundleURL: URL?
        do {
            await reporter.report(
                0.1,
                "Concatenating sequences\u{2026}",
                .info("Concatenating \(sources.count) source FASTA files.")
            )
            let mergedFASTA = tempDirectory.appendingPathComponent("merged.fa")
            FileManager.default.createFile(atPath: mergedFASTA.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: mergedFASTA)
            var sourceFASTAURLs: [URL] = []
            do {
                for source in sources {
                    try Task.checkCancellation()
                    sourceFASTAURLs.append(source.fastaURL)
                    try await appendFASTAContents(from: source.fastaURL, to: outputHandle)
                }
            } catch {
                try? outputHandle.close()
                throw error
            }
            // Close explicitly (not via defer) so the bytes are flushed before the builder
            // reads `merged.fa` in the same scope.
            try outputHandle.close()

            await reporter.report(0.3, "Exporting annotations\u{2026}", nil)
            let annotationExport = try await exportAnnotationInputs(
                from: sources,
                into: tempDirectory,
                reporter: reporter
            )
            let annotationInputs = annotationExport.inputs
            if !annotationInputs.isEmpty {
                await reporter.report(
                    0.45,
                    "Exported \(annotationInputs.count) annotation tracks",
                    .info("Preserving \(annotationInputs.count) annotation tracks from \(sources.count) source bundles.")
                )
            }
            if let warning = annotationExport.warning {
                await reporter.report(
                    0.45,
                    "Some annotation tracks could not be carried across",
                    .warning(warning.message)
                )
            }

            try Task.checkCancellation()
            let mergedRecordStore = try mergeRecordStores(
                from: sources,
                into: tempDirectory
            )
            if let warning = mergedRecordStore.warning {
                await reporter.report(
                    0.5,
                    "Merging record metadata\u{2026}",
                    .warning(warning.message)
                )
            }

            await reporter.report(0.55, "Building merged bundle\u{2026}", nil)
            let resolvedBundleName = makeUniqueBundleName(base: bundleName, in: outputDirectory)
            let builder = NativeBundleBuilder()
            let configuration = BuildConfiguration(
                name: resolvedBundleName,
                identifier: "org.lungfish.merge.\(UUID().uuidString.lowercased())",
                fastaURL: mergedFASTA,
                annotationFiles: annotationInputs,
                outputDirectory: stageDirectory,
                source: mergedSourceInfo(from: sources, bundleName: resolvedBundleName),
                compressFASTA: true,
                warnings: mergedWarnings(from: sources)
                    + [annotationExport.warning, mergedRecordStore.warning].compactMap { $0 },
                referenceRecordStoreURL: mergedRecordStore.url
            )
            // `NativeBundleBuilder`'s progress handler is synchronous, so this hop cannot be
            // awaited. Progress text is advisory and idempotent, so an unordered delivery is
            // acceptable here; the ordered milestones above carry the real state.
            let builtBundleURL = try await builder.build(configuration: configuration) { _, progress, message in
                let scaled = 0.55 + (progress * 0.4)
                Task { await reporter.report(scaled, message, nil) }
            }
            // A cancel that came while the bundle was built publishes nothing, and the stage goes.
            try Task.checkCancellation()
            // The builder's own record names the stage, so it is read there before it is rewritten.
            let builderProvenance = try ProvenanceEnvelopeReader.load(from: builtBundleURL)

            // The bundle is complete in the stage, with its merge record written and no record naming the stage,
            // before the rename that publishes it. Nothing that can throw follows the rename (2.11 A49 review Fix 1).
            await reporter.report(0.96, "Writing provenance\u{2026}", nil)
            try writeMergeProvenance(
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: sourceFASTAURLs,
                bundleURL: builtBundleURL,
                outputDirectory: outputDirectory,
                requestedBundleName: bundleName,
                resolvedBundleName: resolvedBundleName,
                nestedProvenance: builderProvenance,
                mergedAnnotationTrackCount: annotationInputs.count,
                startedAt: runClock.startedAt,
                completedAt: runClock.now,
                observedArguments: observedArguments,
                provenanceWriter: provenanceWriter,
                stageRewrites: stagePathRewrites(stage: stageDirectory, output: outputDirectory)
            )
            try rewriteStagePaths(inRecordsOf: builtBundleURL, stage: stageDirectory, output: outputDirectory)
            try Task.checkCancellation()
            beforePublish?(builtBundleURL)
            let publishedBundleURL = try publish(stagedBundleURL: builtBundleURL, into: outputDirectory)
            createdBundleURL = publishedBundleURL
            await reporter.report(1.0, "Merge complete", nil)
            return publishedBundleURL
        } catch {
            if let createdBundleURL {
                try? FileManager.default.removeItem(at: createdBundleURL)
            }
            throw error
        }
    }

}
