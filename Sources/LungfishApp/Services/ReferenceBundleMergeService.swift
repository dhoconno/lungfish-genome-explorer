import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

enum ReferenceBundleMergeServiceError: LocalizedError {
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

    var errorDescription: String? {
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
struct UnsupportedPayloadReport: Equatable {
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
struct SequenceNameCollision: Equatable {
    let sequenceName: String
    let bundleNames: [String]
}

/// Merges several `.lungfishref` bundles into one.
///
/// Sequences concatenate; annotations are re-exported from each source's annotation
/// database and rebuilt as separate, origin-attributable tracks. Variants, signal tracks,
/// and alignments are still refused because merging concatenates distinct references,
/// which would require rebasing their coordinates onto the merged sequence space.
enum ReferenceBundleMergeService {
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

    @MainActor
    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String
    ) async throws -> URL {
        let operationID = OperationCenter.shared.start(
            title: "Merge Reference Bundles",
            detail: "Preparing to merge \(sourceBundleURLs.count) reference bundles\u{2026}",
            operationType: .bundleBuild
        )
        OperationCenter.shared.log(
            id: operationID,
            level: .info,
            message: "Merging \(sourceBundleURLs.count) reference bundles into \"\(bundleName)\"."
        )

        // The reporter is the ONLY thing that touches the main actor. Everything else runs
        // on the cooperative pool -- see `runDetached`.
        let reporter = ProgressReporter { progress, detail, log in
            await MainActor.run {
                _ = OperationCenter.shared.update(id: operationID, progress: progress, detail: detail)
                if let log {
                    OperationCenter.shared.log(id: operationID, level: log.level, message: log.message)
                }
            }
        }

        do {
            let mergedURL = try await runDetached(
                sourceBundleURLs: sourceBundleURLs,
                outputDirectory: outputDirectory,
                bundleName: bundleName,
                provenanceWriter: .live,
                reporter: reporter
            )
            OperationCenter.shared.log(
                id: operationID,
                level: .info,
                message: "Merged bundle written to \(mergedURL.lastPathComponent)."
            )
            OperationCenter.shared.complete(
                id: operationID,
                detail: "Merged \(sourceBundleURLs.count) reference bundles",
                bundleURLs: [mergedURL]
            )
            return mergedURL
        } catch {
            OperationCenter.shared.log(
                id: operationID,
                level: .error,
                message: "Reference bundle merge failed: \(error.localizedDescription)"
            )
            OperationCenter.shared.fail(
                id: operationID,
                detail: "Reference bundle merge failed",
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    /// A log line the merge wants recorded in the Operations panel, with its severity.
    struct ProgressLog: Sendable {
        let level: OperationLogLevel
        let message: String

        static func info(_ message: String) -> ProgressLog {
            ProgressLog(level: .info, message: message)
        }

        static func warning(_ message: String) -> ProgressLog {
            ProgressLog(level: .warning, message: message)
        }
    }

    /// Progress sink that lets the detached merge report back to the main actor.
    struct ProgressReporter: Sendable {
        /// `(fractionComplete, userVisibleDetail, optionalLogLine)`
        let report: @Sendable (Double, String, ProgressLog?) async -> Void

        init(report: @escaping @Sendable (Double, String, ProgressLog?) async -> Void) {
            self.report = report
        }

        static let none = ProgressReporter { _, _, _ in }
    }

    static func merge(
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
    private static func runDetached(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        provenanceWriter: BundleMergeProvenanceSidecarWriter,
        reporter: ProgressReporter
    ) async throws -> URL {
        let task = Task<URL, Error>.detached(priority: .userInitiated) {
            try await mergeOffMain(
                sourceBundleURLs: sourceBundleURLs,
                outputDirectory: outputDirectory,
                bundleName: bundleName,
                provenanceWriter: provenanceWriter,
                reporter: reporter
            )
        }
        return try await task.value
    }

    private static func mergeOffMain(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        provenanceWriter: BundleMergeProvenanceSidecarWriter,
        reporter: ProgressReporter
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

        let startedAt = Date()
        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "reference-merge-",
            contextURL: outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // Crash-recovery sentinel. The previous implementation got this for free by routing
        // through `ReferenceBundleImportService.importAsReferenceBundle`; building through
        // `NativeBundleBuilder` directly means we own it. Without the marker, a crash or
        // force-quit mid-merge leaves the output directory looking complete.
        OperationMarker.markInProgress(outputDirectory, detail: "Merging reference bundles\u{2026}")
        defer { OperationMarker.clearInProgress(outputDirectory) }

        // Crash-recovery sentinel. The previous implementation got this for free by routing
        // through `ReferenceBundleImportService.importAsReferenceBundle`; building through
        // `NativeBundleBuilder` directly means we own it. Without the marker, a crash or
        // force-quit mid-merge leaves the output directory looking complete.

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
                outputDirectory: outputDirectory,
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
            createdBundleURL = builtBundleURL

            await reporter.report(0.96, "Writing provenance\u{2026}", nil)
            let builderProvenance = try ProvenanceEnvelopeReader.load(from: builtBundleURL)
            try writeMergeProvenance(
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: sourceFASTAURLs,
                bundleURL: builtBundleURL,
                requestedBundleName: bundleName,
                resolvedBundleName: resolvedBundleName,
                nestedProvenance: builderProvenance,
                mergedAnnotationTrackCount: annotationInputs.count,
                startedAt: startedAt,
                completedAt: Date(),
                provenanceWriter: provenanceWriter
            )
            await reporter.report(1.0, "Merge complete", nil)
            return builtBundleURL
        } catch {
            if let createdBundleURL {
                try? FileManager.default.removeItem(at: createdBundleURL)
            }
            throw error
        }
    }

    // MARK: - Source inspection

    /// A source bundle resolved into everything the merge needs from it.
    private struct SourceBundle {
        let bundleURL: URL
        let displayName: String
        /// The rich bundle manifest, or `nil` for a legacy `ReferenceSequenceFolder` bundle.
        ///
        /// Legacy bundles carry a `ReferenceSequenceManifest` instead: a copied FASTA and
        /// nothing else. They are sequence-only by construction, so a missing rich manifest
        /// here is a known-safe shape, not an unknown one.
        let manifest: BundleManifest?
        /// Display name for the merged bundle's `SourceInfo`, from whichever manifest applies.
        let sourceName: String
        let fastaURL: URL
        /// Sequence names this bundle contributes to the merged FASTA.
        let sequenceNames: [String]
        /// Identifier stem used to namespace this bundle's annotation tracks in the output.
        let namespaceSlug: String

        var annotations: [AnnotationTrackInfo] { manifest?.annotations ?? [] }
    }

    private static func inspectSourceBundles(_ bundleURLs: [URL]) async throws -> [SourceBundle] {
        var sources: [SourceBundle] = []
        var usedSlugs: Set<String> = []
        for bundleURL in bundleURLs {
            let displayName = bundleURL.deletingPathExtension().lastPathComponent
            let fastaURL = try resolveFASTAURL(in: bundleURL)

            var manifest: BundleManifest?
            var sourceName = displayName
            var sequenceNames: [String] = []

            if FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(BundleManifest.filename).path
            ) {
                if let loaded = try? BundleManifest.load(from: bundleURL) {
                    manifest = loaded
                    sourceName = loaded.name.isEmpty ? displayName : loaded.name
                    sequenceNames = (loaded.genome?.chromosomes ?? []).map(\.name)
                } else if let legacyName = legacyReferenceManifestName(in: bundleURL) {
                    // Legacy `ReferenceSequenceFolder` bundle: a different manifest schema,
                    // sequence-only by construction. Read names straight from its FASTA.
                    sourceName = legacyName
                    sequenceNames = try await readSequenceNames(in: fastaURL)
                } else {
                    // Fail closed. A manifest we cannot read under either schema may declare
                    // variants, alignments, or annotations the merge would silently drop.
                    throw ReferenceBundleMergeServiceError.unreadableManifest(
                        bundleName: displayName,
                        underlying: "manifest.json did not decode as a Lungfish bundle manifest"
                    )
                }
            } else {
                sequenceNames = try await readSequenceNames(in: fastaURL)
            }

            var slug = slugify(sourceName)
            if !usedSlugs.insert(slug).inserted {
                var counter = 2
                while !usedSlugs.insert("\(slug)_\(counter)").inserted {
                    counter += 1
                }
                slug = "\(slug)_\(counter)"
            }
            sources.append(
                SourceBundle(
                    bundleURL: bundleURL,
                    displayName: displayName,
                    manifest: manifest,
                    sourceName: sourceName,
                    fastaURL: fastaURL,
                    sequenceNames: sequenceNames,
                    namespaceSlug: slug
                )
            )
        }
        return sources
    }

    private static let legacyManifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func legacyReferenceManifestName(in bundleURL: URL) -> String? {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        guard let data = try? Data(contentsOf: manifestURL),
              let legacy = try? Self.legacyManifestDecoder.decode(
                  ReferenceSequenceManifest.self,
                  from: data
              ) else {
            return nil
        }
        return legacy.name
    }

    /// Reads record names out of a FASTA without loading its sequence bases.
    private static func readSequenceNames(in fastaURL: URL) async throws -> [String] {
        var names: [String] = []
        for try await line in fastaURL.linesAutoDecompressing() where line.hasPrefix(">") {
            let header = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let name = header.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    private static func validateNoUnsupportedPayloads(in sources: [SourceBundle]) throws {
        var offenders: [UnsupportedPayloadReport] = []
        for source in sources {
            guard let manifest = source.manifest else { continue }
            var payloads: [String] = []
            if manifest.genome == nil {
                payloads.append("no genome sequence")
            }
            if !manifest.variants.isEmpty {
                payloads.append("variant tracks")
            }
            if !manifest.tracks.isEmpty {
                payloads.append("signal tracks")
            }
            if !manifest.alignments.isEmpty {
                payloads.append("alignments")
            }
            if !payloads.isEmpty {
                offenders.append(
                    UnsupportedPayloadReport(bundleName: source.displayName, payloads: payloads)
                )
            }
        }
        guard offenders.isEmpty else {
            throw ReferenceBundleMergeServiceError.unsupportedPayloads(offenders: offenders)
        }
    }

    /// Rejects duplicate sequence names before any bytes are written.
    ///
    /// Without this, `appendFASTAContents` concatenates blindly and `samtools faidx` fails
    /// on the duplicate record, after which `NativeBundleBuilder` silently falls back to a
    /// manual index. The output would carry an ambiguous `.fai` and annotations would bind
    /// to whichever duplicate the index happened to keep.
    private static func validateNoSequenceNameCollisions(in sources: [SourceBundle]) throws {
        var bundlesBySequenceName: [String: [String]] = [:]
        for source in sources {
            for name in source.sequenceNames {
                bundlesBySequenceName[name, default: []].append(source.displayName)
            }
        }
        let collisions = bundlesBySequenceName
            .filter { $0.value.count > 1 }
            .map { SequenceNameCollision(sequenceName: $0.key, bundleNames: $0.value) }
            .sorted { $0.sequenceName < $1.sequenceName }
        guard collisions.isEmpty else {
            throw ReferenceBundleMergeServiceError.duplicateSequenceNames(collisions: collisions)
        }
    }

    // MARK: - Annotation preservation

    /// The outcome of re-exporting source annotation tracks for the merged build.
    private struct AnnotationExport {
        let inputs: [AnnotationInput]
        /// A warning to persist in the merged manifest when tracks had to be skipped.
        let warning: BundleWarning?
    }

    /// Re-exports every source annotation track as a GFF3 the builder can reconsume.
    ///
    /// GenBank imports keep no copy of their original `.gb` inside the bundle, so the
    /// annotation SQLite database is the durable representation. Exporting it back to GFF3
    /// round-trips through a format `NativeBundleBuilder` already ingests, and keeps each
    /// track's records bound to their original sequence names.
    ///
    /// A track can be un-re-readable for three reasons: it predates `databasePath` (legacy
    /// or placeholder artifact), its declared path fails bundle-member validation, or the
    /// file is simply gone. None of those should abort a merge that can otherwise succeed,
    /// so such tracks are skipped -- but every skip is accumulated into a returned
    /// `BundleWarning` and reported at `.warning` level, so the loss is recorded in the
    /// merged manifest and visible in the Operations log rather than silent.
    private static func exportAnnotationInputs(
        from sources: [SourceBundle],
        into tempDirectory: URL,
        reporter: ProgressReporter
    ) async throws -> AnnotationExport {
        let exportDirectory = tempDirectory.appendingPathComponent("annotations", isDirectory: true)
        var inputs: [AnnotationInput] = []
        var skipped: [String] = []
        var didCreateDirectory = false
        // `namespaceSlug` (assigned in `inspectSourceBundles`) is already deduped PER SOURCE
        // BUNDLE, but does nothing to protect against two different `track.id` values within
        // the SAME bundle slugifying to the same string (e.g. "Genes v1" and "Genes-v1" both
        // collapse to "genes_v1" under `slugify`). Without this set, the second track's export
        // would silently overwrite the first's GFF3 file on disk (same `exportURL`, derived
        // directly from `trackID`) and both `AnnotationInput`s would carry the same `id`.
        // Mirrors the `usedSlugs` dedup in `inspectSourceBundles` exactly: on collision, append
        // a numeric suffix until the candidate is unique.
        var usedTrackIDs: Set<String> = []

        for source in sources {
            for track in source.annotations {
                let label = "\"\(track.name)\" in \(source.displayName)"

                guard let databasePath = track.databasePath else {
                    skipped.append("\(label) (no annotation database; predates indexed annotations)")
                    continue
                }
                let databaseURL: URL
                do {
                    databaseURL = try BundleManifest.validatedBundleMemberURL(
                        for: databasePath,
                        in: source.bundleURL,
                        field: "annotations.database_path"
                    )
                } catch {
                    skipped.append("\(label) (declared path '\(databasePath)' is not a valid bundle member)")
                    continue
                }
                guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                    skipped.append("\(label) (annotation database file '\(databasePath)' is missing)")
                    continue
                }

                if !didCreateDirectory {
                    try FileManager.default.createDirectory(
                        at: exportDirectory,
                        withIntermediateDirectories: true
                    )
                    didCreateDirectory = true
                }

                var trackID = "\(source.namespaceSlug)_\(slugify(track.id))"
                if !usedTrackIDs.insert(trackID).inserted {
                    var counter = 2
                    while !usedTrackIDs.insert("\(trackID)_\(counter)").inserted {
                        counter += 1
                    }
                    trackID = "\(trackID)_\(counter)"
                }
                let exportURL = exportDirectory.appendingPathComponent("\(trackID).gff3")
                let database = try AnnotationDatabase(url: databaseURL)
                try AnnotationDatabaseGFFExporter.export(database: database, to: exportURL)
                await reporter.report(0.3, "Exported \(track.name) from \(source.displayName)", nil)

                inputs.append(
                    AnnotationInput(
                        url: exportURL,
                        name: "\(track.name) (\(source.sourceName))",
                        description: track.description
                            ?? "Merged from \(source.displayName)",
                        id: trackID,
                        annotationType: track.annotationType
                    )
                )
            }
        }

        let warning = skipped.isEmpty ? nil : BundleWarning(
            category: "merge.annotations",
            code: "annotation_track_dropped",
            message: """
                \(skipped.count) annotation \(skipped.count == 1 ? "track was" : "tracks were") \
                not carried into the merged bundle because \
                \(skipped.count == 1 ? "it" : "they") could not be re-read: \
                \(skipped.joined(separator: "; ")).
                """
        )
        return AnnotationExport(inputs: inputs, warning: warning)
    }

    /// The outcome of trying to carry GenBank record stores across a merge.
    private struct MergedRecordStore {
        /// The unioned store, or `nil` when no store could be carried across.
        let url: URL?
        /// A warning to persist in the merged manifest when a store was dropped.
        let warning: BundleWarning?
    }

    /// Unions the GenBank record stores of every source that has one.
    ///
    /// Returns an empty result when no source carries a store, which keeps FASTA-only
    /// merges byte identical to their previous behaviour.
    private static func mergeRecordStores(
        from sources: [SourceBundle],
        into tempDirectory: URL
    ) throws -> MergedRecordStore {
        #if DEBUG
        recordStoreThreadingProbe?()
        #endif
        var storeURLs: [URL] = []
        var sourcesWithoutStore: [String] = []
        for source in sources {
            guard let recordStore = source.manifest?.recordStore,
                  recordStore.format == ReferenceRecordStoreInfo.supportedFormat,
                  recordStore.schemaVersion == GenBankRecordDatabase.schemaVersion,
                  let storeURL = try? BundleManifest.validatedBundleMemberURL(
                      for: recordStore.databasePath,
                      in: source.bundleURL,
                      field: "record_store.database_path"
                  ),
                  FileManager.default.fileExists(atPath: storeURL.path) else {
                sourcesWithoutStore.append(source.displayName)
                continue
            }
            storeURLs.append(storeURL)
        }
        guard !storeURLs.isEmpty else {
            return MergedRecordStore(url: nil, warning: nil)
        }

        // `NativeBundleBuilder.embedReferenceRecordStore` validates the store row-for-row
        // against the merged FASTA, so a store covering only some sequences would fail the
        // build outright. Carry the store across only when every source contributes one, and
        // record a warning when we cannot, so the loss is visible in the merged manifest
        // rather than silent.
        guard sourcesWithoutStore.isEmpty else {
            return MergedRecordStore(
                url: nil,
                warning: BundleWarning(
                    category: "merge.record-store",
                    code: "partial_record_store_dropped",
                    message: """
                        GenBank record metadata (LOCUS, DEFINITION, ACCESSION, and so on) was \
                        dropped because \(sourcesWithoutStore.joined(separator: ", ")) \
                        \(sourcesWithoutStore.count == 1 ? "does" : "do") not carry a record \
                        store. A record store must cover every merged sequence.
                        """
                )
            )
        }

        let mergedStoreURL = tempDirectory.appendingPathComponent("genbank_records.sqlite")
        try GenBankRecordDatabase.createByMerging(sourceURLs: storeURLs, at: mergedStoreURL)
        return MergedRecordStore(url: mergedStoreURL, warning: nil)
    }

    private static func mergedSourceInfo(from sources: [SourceBundle], bundleName: String) -> SourceInfo {
        let organisms = orderedUnique(
            sources.compactMap { $0.manifest?.source.organism }.filter { !$0.isEmpty }
        )
        let databases = orderedUnique(sources.compactMap { $0.manifest?.source.database })
        return SourceInfo(
            organism: organisms.isEmpty ? bundleName : organisms.joined(separator: "; "),
            assembly: bundleName,
            database: databases.isEmpty ? nil : databases.joined(separator: "; "),
            downloadDate: Date(),
            notes: "Merged from \(sources.map(\.displayName).joined(separator: ", "))."
        )
    }

    private static func mergedWarnings(from sources: [SourceBundle]) -> [BundleWarning] {
        var merged: [BundleWarning] = []
        for source in sources {
            for warning in source.manifest?.warnings ?? [] where !merged.contains(warning) {
                merged.append(warning)
            }
        }
        return merged
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func slugify(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "_"
        }
        let collapsed = String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "source" : collapsed
    }

    /// Mirrors `ReferenceBundleImportService`'s uniquing so a merge into a directory that
    /// already holds a bundle of the requested name gets "<name> 2" rather than colliding.
    private static func makeUniqueBundleName(base: String, in directory: URL) -> String {
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(
            atPath: bundleURL(forBundleName: candidate, in: directory).path
        ) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    private static func bundleURL(forBundleName bundleName: String, in directory: URL) -> URL {
        let safeName = bundleName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safeName).lungfishref", isDirectory: true)
    }

    private static func resolveFASTAURL(in bundleURL: URL) throws -> URL {
        if let simpleFASTA = ReferenceSequenceFolder.fastaURL(in: bundleURL) {
            return simpleFASTA
        }

        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: genomeDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ),
           let fastaURL = contents.first(where: isFASTAFileURL(_:)) {
            return fastaURL
        }

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ),
           let fastaURL = contents.first(where: isFASTAFileURL(_:)) {
            return fastaURL
        }

        throw ReferenceBundleMergeServiceError.noFASTAFound(
            bundleName: bundleURL.deletingPathExtension().lastPathComponent
        )
    }

    private static func appendFASTAContents(
        from fastaURL: URL,
        to outputHandle: FileHandle
    ) async throws {
        for try await line in fastaURL.linesAutoDecompressing() {
            outputHandle.write(Data(line.utf8))
            outputHandle.write(Data("\n".utf8))
        }
    }

    private static func writeMergeProvenance(
        sourceBundleURLs: [URL],
        inputPayloadURLs: [URL],
        bundleURL: URL,
        requestedBundleName: String,
        resolvedBundleName: String,
        nestedProvenance: ProvenanceEnvelope?,
        mergedAnnotationTrackCount: Int,
        startedAt: Date,
        completedAt: Date,
        provenanceWriter: BundleMergeProvenanceSidecarWriter
    ) throws {
        let outputPayloadURLs = try BundleMergeProvenance.regularPayloadFileURLs(in: bundleURL)
        let nestedSteps = try normalizedNestedSteps(
            from: nestedProvenance,
            inputPayloadURLs: inputPayloadURLs,
            outputPayloadURLs: outputPayloadURLs,
            bundleURL: bundleURL,
            resolvedBundleName: resolvedBundleName
        )
        try BundleMergeProvenance.write(
            request: BundleMergeProvenance.Request(
                workflowName: "lungfish reference merge",
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: inputPayloadURLs,
                outputBundleURL: bundleURL,
                outputPayloadURLs: outputPayloadURLs,
                bundleName: resolvedBundleName,
                requestedBundleName: requestedBundleName,
                mergeMode: mergedAnnotationTrackCount > 0 ? "sequence-and-annotations" : "sequence-only",
                defaults: [
                    "compressFASTA": .boolean(true),
                    "annotationMerge": .string("preserved"),
                    "variantMerge": .string("unsupported"),
                    "trackMerge": .string("unsupported"),
                ],
                resolvedDefaults: [
                    "compressFASTA": .boolean(true),
                    "annotationMerge": .string(
                        mergedAnnotationTrackCount > 0 ? "preserved" : "no-annotations-in-sources"
                    ),
                    "variantMerge": .string("unsupported"),
                    "trackMerge": .string("unsupported"),
                ],
                nestedSteps: nestedSteps,
                startedAt: startedAt,
                completedAt: completedAt
            ),
            sidecarWriter: provenanceWriter
        )
    }

    private static func normalizedNestedSteps(
        from envelope: ProvenanceEnvelope?,
        inputPayloadURLs: [URL],
        outputPayloadURLs: [URL],
        bundleURL: URL,
        resolvedBundleName: String
    ) throws -> [ProvenanceStep] {
        guard let envelope else { return [] }
        let sourceInputs = try inputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, format: .fasta, role: .input)
        }
        let outputs = try outputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, format: fileFormat(for: $0), role: .output)
        }
        let durableFASTAURL = finalGenomePayloadURL(in: bundleURL, outputPayloadURLs: outputPayloadURLs)
        let durableFASTAInput = try durableFASTAURL.map {
            try ProvenanceFileDescriptor.file(url: $0, format: .fasta, role: .input)
        }
        let inputs = uniqueDescriptors(sourceInputs + Array(durableFASTAInput.map { [$0] } ?? []))

        return envelope.steps.compactMap { step -> ProvenanceStep? in
            guard step.toolName == "NativeBundleBuilder.build" else {
                return nil
            }
            let originalArgv = step.durableReplayArgv ?? step.argv
            let argv = rewriteBuilderReplayArgv(
                originalArgv,
                tempInputPaths: step.inputs.map(\.path),
                durableFASTAURL: durableFASTAURL,
                bundleURL: bundleURL,
                resolvedBundleName: resolvedBundleName
            )
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                durableReplayArgv: argv,
                reproducibleCommand: BundleMergeProvenance.commandLine(from: argv),
                inputs: inputs,
                outputs: outputs,
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
    }

    private static func finalGenomePayloadURL(in bundleURL: URL, outputPayloadURLs: [URL]) -> URL? {
        if let manifest = try? BundleManifest.load(from: bundleURL),
           let genome = manifest.genome,
           let genomeURL = try? BundleManifest.validatedBundleMemberURL(
               for: genome.path,
               in: bundleURL,
               field: "genome.path"
           ) {
            return genomeURL.standardizedFileURL
        }
        return outputPayloadURLs.first(where: isFASTAFileURL(_:))?.standardizedFileURL
    }

    private static func rewriteBuilderReplayArgv(
        _ argv: [String],
        tempInputPaths: [String],
        durableFASTAURL: URL?,
        bundleURL: URL,
        resolvedBundleName: String
    ) -> [String] {
        let durableFASTAPath = durableFASTAURL?.standardizedFileURL.path
        let tempInputPaths = Set(tempInputPaths)
        var rewritten = argv.map { argument in
            rewriteBuilderArgument(
                argument,
                tempInputPaths: tempInputPaths,
                durableFASTAPath: durableFASTAPath
            )
        }

        if rewritten.isEmpty, let durableFASTAPath {
            rewritten = [
                "NativeBundleBuilder.build",
                "--name",
                resolvedBundleName,
                "--identifier",
                resolvedBundleIdentifier(in: bundleURL, fallbackName: resolvedBundleName),
                "--fasta",
                durableFASTAPath,
                "--output-directory",
                bundleURL.deletingLastPathComponent().standardizedFileURL.path,
                "--bundle",
                bundleURL.standardizedFileURL.path,
                "--compress-fasta",
                "true",
            ]
        }

        return rewritten
    }

    private static func resolvedBundleIdentifier(in bundleURL: URL, fallbackName: String) -> String {
        if let manifest = try? BundleManifest.load(from: bundleURL) {
            return manifest.identifier
        }
        let sanitized = fallbackName
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "." || character == "-" {
                    return character
                }
                return "-"
            }
        return "org.lungfish.\(String(sanitized))"
    }

    private static func rewriteBuilderArgument(
        _ argument: String,
        tempInputPaths: Set<String>,
        durableFASTAPath: String?
    ) -> String {
        guard let durableFASTAPath else { return argument }
        if tempInputPaths.contains(argument) {
            return durableFASTAPath
        }
        for tempInputPath in tempInputPaths where argument.contains(tempInputPath) {
            return argument.replacingOccurrences(of: tempInputPath, with: durableFASTAPath)
        }
        return argument
    }

    private static func uniqueDescriptors(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen: Set<String> = []
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue):\(descriptor.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(descriptor)
        }
        return result
    }

    private static func fileFormat(for url: URL) -> FileFormat? {
        var candidate = url
        if candidate.pathExtension.lowercased() == "gz" {
            candidate = candidate.deletingPathExtension()
        }
        switch candidate.pathExtension.lowercased() {
        case "fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn":
            return .fasta
        case "json":
            return .json
        case "csv", "tsv", "txt", "fai", "gzi":
            return .text
        default:
            return .unknown
        }
    }

    private static func isFASTAFileURL(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".fa")
            || lowercasedName.hasSuffix(".fasta")
            || lowercasedName.hasSuffix(".fna")
            || lowercasedName.hasSuffix(".fa.gz")
            || lowercasedName.hasSuffix(".fasta.gz")
            || lowercasedName.hasSuffix(".fna.gz")
    }
}
