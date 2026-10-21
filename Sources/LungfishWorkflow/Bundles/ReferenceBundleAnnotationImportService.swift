// ReferenceBundleAnnotationImportService.swift - Attach annotation tracks to existing reference bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log
import Synchronization

private let annotationImportLogger = Logger(subsystem: LogSubsystem.app, category: "ReferenceAnnotationImport")

/// Attaches an annotation track (GFF/GFF3/GTF/BED) to an existing reference bundle.
///
/// Deliberately not `@MainActor`, and `attachAnnotationTrack` deliberately hops onto
/// `Task.detached` before doing any work: the method does GFF/BED parsing
/// (`AnnotationDatabase.createFromBED`/`createFromGFF3`), full-file SHA256 hashing
/// (`ProvenanceRecorder.sha256(of:)`), directory-tree copies for rollback, and JSON
/// provenance encode/decode + atomic writes -- none of which touch UI state, and none
/// of which is preceded by any `await` of its own. A nonisolated `async` function with
/// no suspension point before its synchronous work *inherits the caller's thread* --
/// removing `@MainActor` alone would NOT move this work off the main thread for the
/// real call sites, which all `await` from `@MainActor` context. The explicit
/// `Task.detached` in `attachAnnotationTrack` is what actually forces the executor hop,
/// for both the BED path (fully synchronous, no internal awaits at all) and the GFF3
/// path (whose internal suspension via `.lines` is not something callers should have to
/// rely on for main-thread safety). Every dependency is already off-main-safe:
/// `AnnotationDatabase` is `@unchecked Sendable`, `BundleManifest`/`ProvenanceWriter`
/// are `Sendable` value types, `ProvenanceRecorder` is an `actor` (its `sha256(of:)`
/// helper is a plain `static func`), and `ProvenanceRehydrator` is a stateless `enum`
/// of static functions -- so nothing blocks running the whole body detached. Callers
/// already `await` construction and `attachAnnotationTrack(...)` (see
/// `lungfish-cli sequence attach-track`
/// (`Sources/LungfishCLI/Commands/SequenceAnnotationEditSubcommands.swift`), which the
/// Import Center and sidebar rows launch, `ViewerViewController.swift`,
/// `GeneiousImportCollectionService.swift`); no call site
/// needs to change. Callers that want MainActor UI updates from the returned
/// `ReferenceBundleAnnotationImportResult` continue to hop themselves after `await`,
/// exactly as before.
public final class ReferenceBundleAnnotationImportService {
    public init() {}

    #if DEBUG
    /// Test-only threading probe. When set, invoked once at the start of the heavy
    /// parse/hash/provenance work inside `performAttach`'s `Task.detached` body -- i.e.
    /// after the executor hop this class relies on for main-thread safety, and before
    /// any of `createFromBED`/`createFromGFF3`/`ProvenanceRecorder.sha256(of:)` runs.
    /// Exists solely so `ReferenceBundleAnnotationImportServiceOffMainTests` can assert
    /// `!Thread.isMainThread` from inside the real call path when driven from a
    /// `@MainActor` caller, without depending on `AnnotationDatabase` internals. Not
    /// compiled into release builds.
    nonisolated(unsafe) static var threadingProbe: (@Sendable () -> Void)?
    #endif

    private struct ProvenanceLayoutSnapshot {
        /// The root record, its signature and its public key, each with the bytes it held, or nil when it did not exist.
        let rootArtifacts: [(url: URL, data: Data?)]
        let provenanceDirectoryURL: URL
        let provenanceDirectoryBackupURL: URL
        let hadProvenanceDirectory: Bool

        static func capture(bundleURL: URL, backupRoot: URL) throws -> ProvenanceLayoutSnapshot {
            let rootProvenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            let rootArtifacts = ProvenancePublicationArtifacts.sidecarArtifacts(for: rootProvenanceURL)
                .map { (url: $0, data: try? Data(contentsOf: $0)) }
            let provenanceDirectoryURL = bundleURL.appendingPathComponent(
                ProvenanceWriter.bundleProvenanceDirectoryName,
                isDirectory: true
            )
            let provenanceDirectoryBackupURL = backupRoot.appendingPathComponent("provenance-backup", isDirectory: true)
            let hadProvenanceDirectory = FileManager.default.fileExists(atPath: provenanceDirectoryURL.path)
            if hadProvenanceDirectory {
                try FileManager.default.copyItem(at: provenanceDirectoryURL, to: provenanceDirectoryBackupURL)
            }
            return ProvenanceLayoutSnapshot(
                rootArtifacts: rootArtifacts,
                provenanceDirectoryURL: provenanceDirectoryURL,
                provenanceDirectoryBackupURL: provenanceDirectoryBackupURL,
                hadProvenanceDirectory: hadProvenanceDirectory
            )
        }

        func restore() throws {
            for (url, data) in rootArtifacts {
                if let data {
                    try data.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            if FileManager.default.fileExists(atPath: provenanceDirectoryURL.path) {
                try FileManager.default.removeItem(at: provenanceDirectoryURL)
            }
            if hadProvenanceDirectory {
                try FileManager.default.copyItem(at: provenanceDirectoryBackupURL, to: provenanceDirectoryURL)
            }
        }
    }

    public static func discoverReferenceBundles(
        in projectURL: URL,
        fileManager: FileManager = .default
    ) throws -> [ReferenceBundleChoice] {
        var choices: [ReferenceBundleChoice] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "lungfishref" else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard (try? BundleManifest.load(from: url).genome) != nil else { continue }
            choices.append(
                ReferenceBundleChoice(
                    url: url.standardizedFileURL,
                    displayPath: projectRelativePath(from: projectURL, to: url)
                )
            )
            enumerator.skipDescendants()
        }

        return choices.sorted {
            $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending
        }
    }

    /// Attaches an annotation track to a reference bundle.
    ///
    /// The entire body -- GFF/BED parsing, SHA256 hashing, provenance directory
    /// copy/restore, and JSON encode/decode + atomic writes -- runs inside
    /// `Task.detached`, which unconditionally hops execution to the cooperative
    /// thread pool regardless of the caller's actor. This is deliberate and load-bearing:
    /// `attachAnnotationTrack` has no `await` of its own between entry and the
    /// `Task.detached` call, so without the detached hop a nonisolated `async` func
    /// called from `@MainActor` (as every in-process call site of the app does -- see
    /// `ViewerViewController.swift`; the Import Center and sidebar rows launch
    /// `lungfish-cli sequence attach-track`
    /// (`Sources/LungfishCLI/Commands/SequenceAnnotationEditSubcommands.swift`) instead)
    /// would simply inherit the caller's thread and run
    /// every synchronous step (including the fully-synchronous `createFromBED` path)
    /// on the main thread until the first real suspension point. `Task.detached`
    /// guarantees the executor hop happens up front, for both the GFF3 and BED
    /// formats, independent of whatever suspension behavior `createFromGFF3`'s
    /// internal `for try await line in gffURL.lines` happens to have.
    ///
    /// The manifest read-modify-write inside `performAttach` is additionally
    /// routed through `BundleManifestMutationSerializer`, keyed by
    /// `bundleURL`, so two concurrent attaches to the SAME bundle (e.g. one
    /// from the Import Center and one from a sidebar drop, landing at the
    /// same moment) never interleave their `BundleManifest.load` ->
    /// `.addingAnnotationTrack` -> `.save` sequences. Attaches to different
    /// bundles are unaffected and continue to run fully concurrently
    /// off-main.
    ///
    /// Cancelling the calling task cancels the attach before it writes, or
    /// once the file is parsed, before it changes the manifest. Either way the
    /// bundle is left as it was and the call throws `CancellationError`. The
    /// parse itself runs to its end. The serializer runs the work in a task
    /// of its own, so the cancel travels in a flag, not as task cancellation.
    public func attachAnnotationTrack(
        sourceURL: URL,
        bundleURL: URL,
        trackID requestedTrackID: String? = nil,
        trackName requestedTrackName: String? = nil,
        invocationArgv: [String]? = nil
    ) async throws -> ReferenceBundleAnnotationImportResult {
        let cancelled = AttachCancelFlag()
        let task = Task<ReferenceBundleAnnotationImportResult, Error>.detached(priority: .userInitiated) {
            try await BundleManifestMutationSerializer.shared.run(bundleURL: bundleURL) {
                try await ReferenceBundleAnnotationImportService.performAttach(
                    sourceURL: sourceURL,
                    bundleURL: bundleURL,
                    requestedTrackID: requestedTrackID,
                    requestedTrackName: requestedTrackName,
                    invocationArgv: invocationArgv,
                    isCancelled: { cancelled.isSet }
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancelled.set()
        }
    }

    /// The `lungfish-cli` argv, from the `sequence attach-track` words on,
    /// that attaches `sourceURL` to the bundle as
    /// ``attachAnnotationTrack(sourceURL:bundleURL:trackID:trackName:invocationArgv:)``
    /// does. The Import Center and sidebar rows run and record it, and the
    /// command records it when it runs inside another process. The track ID
    /// and name are joined to their options, so a hyphen-leading value
    /// replays. The builder touches no state, so any isolation can call it.
    package static func attachTrackArguments(
        sourceURL: URL,
        bundleURL: URL,
        trackID: String?,
        trackName: String?
    ) -> [String] {
        var arguments = ["sequence", "attach-track", bundleURL.path, sourceURL.path]
        if let trackID { arguments.append("--track-id=\(trackID)") }
        if let trackName { arguments.append("--track-name=\(trackName)") }
        return arguments
    }

    private static func performAttach(
        sourceURL: URL,
        bundleURL: URL,
        requestedTrackID: String?,
        requestedTrackName: String?,
        invocationArgv: [String]?,
        isCancelled: @Sendable () -> Bool
    ) async throws -> ReferenceBundleAnnotationImportResult {
        #if DEBUG
        threadingProbe?()
        #endif
        if isCancelled() { throw CancellationError() }
        let runClock = ProvenanceRunClock()
        guard ReferenceBundleImportService.classify(sourceURL) == .annotationTrack else {
            throw ReferenceBundleAnnotationImportError.unsupportedFormat(sourceURL)
        }

        var manifest: BundleManifest
        let standardizedBundleURL = bundleURL.standardizedFileURL
        let manifestURL = standardizedBundleURL.appendingPathComponent(BundleManifest.filename)
        let inputManifestSnapshot = fileSnapshot(for: manifestURL)
        do {
            manifest = try BundleManifest.load(from: standardizedBundleURL)
        } catch {
            throw ReferenceBundleAnnotationImportError.missingManifest(standardizedBundleURL)
        }
        guard let genome = manifest.genome else {
            throw ReferenceBundleAnnotationImportError.missingGenome(standardizedBundleURL)
        }

        let annotationsDir = standardizedBundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        let existingIDs = Set(manifest.annotations.map(\.id))
        let trackID = try resolvedTrackID(
            requestedTrackID,
            sourceURL: sourceURL,
            existingIDs: existingIDs,
            annotationsDir: annotationsDir
        )
        let trackName = Self.defaultTrackName(for: sourceURL, requestedName: requestedTrackName)
        let databasePath = "annotations/\(trackID).db"
        let databaseURL = standardizedBundleURL.appendingPathComponent(databasePath)
        let chromosomeSizes = genome.chromosomes.map { ($0.name, $0.length) }

        let featureCount: Int
        let ext = ReferenceBundleImportService.normalizedExtension(for: sourceURL)
        let importerName: String
        if ["gff", "gff3", "gtf"].contains(ext) {
            importerName = "AnnotationDatabase.createFromGFF3"
            featureCount = try await AnnotationDatabase.createFromGFF3(
                gffURL: sourceURL,
                outputURL: databaseURL,
                chromosomeSizes: chromosomeSizes
            )
        } else if ext == "bed" {
            importerName = "AnnotationDatabase.createFromBED"
            featureCount = try AnnotationDatabase.createFromBED(bedURL: sourceURL, outputURL: databaseURL)
        } else {
            throw ReferenceBundleAnnotationImportError.unsupportedFormat(sourceURL)
        }
        // A cancel that came during the parse ends the attach here, before the manifest changes.
        if isCancelled() {
            try removeAnnotationDatabaseArtifacts(at: databaseURL)
            throw CancellationError()
        }
        if featureCount == 0 {
            try removeAnnotationDatabaseArtifacts(at: databaseURL)
            throw ReferenceBundleAnnotationImportError.noImportableAnnotations(sourceURL)
        }

        let track = AnnotationTrackInfo(
            id: trackID,
            name: trackName,
            description: "Imported from \(sourceURL.lastPathComponent)",
            path: databasePath,
            databasePath: databasePath,
            annotationType: .custom,
            featureCount: featureCount,
            source: sourceURL.path
        )

        let originalManifest = manifest
        let rollbackRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-annotation-import-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rollbackRoot) }
        let provenanceSnapshot = try ProvenanceLayoutSnapshot.capture(
            bundleURL: standardizedBundleURL,
            backupRoot: rollbackRoot
        )
        do {
            manifest = manifest.addingAnnotationTrack(track)
            try manifest.save(to: standardizedBundleURL)
            try writeProvenance(
                sourceURL: sourceURL,
                bundleURL: standardizedBundleURL,
                manifestURL: manifestURL,
                databaseURL: databaseURL,
                track: track,
                featureCount: featureCount,
                format: ext,
                importerName: importerName,
                inputManifestSnapshot: inputManifestSnapshot,
                runClock: runClock,
                invocationArgv: invocationArgv
            )
        } catch {
            try throwAfterProvenancePublicationFailure(error) {
                try removeAnnotationDatabaseArtifacts(at: databaseURL)
                let legacyProvenanceURL = importProvenanceURL(bundleURL: standardizedBundleURL, trackID: trackID)
                if FileManager.default.fileExists(atPath: legacyProvenanceURL.path) {
                    try FileManager.default.removeItem(at: legacyProvenanceURL)
                }
                try originalManifest.save(to: standardizedBundleURL)
                try provenanceSnapshot.restore()
            }
        }
        annotationImportLogger.info("Attached annotation track \(trackID, privacy: .public) to \(standardizedBundleURL.lastPathComponent, privacy: .public)")

        return ReferenceBundleAnnotationImportResult(bundleURL: standardizedBundleURL, track: track, featureCount: featureCount)
    }

    public static func defaultTrackID(for sourceURL: URL) -> String {
        sanitizedTrackID(for: sourceURL)
    }

    public static func defaultTrackName(for sourceURL: URL, requestedName: String? = nil) -> String {
        if let requestedName {
            let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var baseURL = sourceURL
        if ReferenceBundleImportService.compressionExtensions.contains(baseURL.pathExtension.lowercased()) {
            baseURL = baseURL.deletingPathExtension()
        }
        return baseURL.deletingPathExtension().lastPathComponent
    }

    private static func sanitizedTrackID(for sourceURL: URL) -> String {
        var baseURL = sourceURL
        if ReferenceBundleImportService.compressionExtensions.contains(baseURL.pathExtension.lowercased()) {
            baseURL = baseURL.deletingPathExtension()
        }
        let raw = baseURL.deletingPathExtension().lastPathComponent.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let collapsed = String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return collapsed.isEmpty ? "annotations" : collapsed
    }

    private static func resolvedTrackID(
        _ requestedTrackID: String?,
        sourceURL: URL,
        existingIDs: Set<String>,
        annotationsDir: URL
    ) throws -> String {
        if let requestedTrackID {
            let trimmed = requestedTrackID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard Self.isPortableTrackID(trimmed) else {
                    throw ReferenceBundleAnnotationImportError.invalidTrackID(trimmed)
                }
                guard !Self.containsTrackID(existingIDs, matching: trimmed),
                      !Self.bundleArtifactExistsCaseInsensitive(annotationsDir.appendingPathComponent("\(trimmed).db")) else {
                    throw ReferenceBundleAnnotationImportError.duplicateTrackID(trimmed)
                }
                return trimmed
            }
        }
        return makeUniqueTrackID(
            base: Self.sanitizedTrackID(for: sourceURL),
            existingIDs: existingIDs,
            annotationsDir: annotationsDir
        )
    }

    private static func isPortableTrackID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func makeUniqueTrackID(
        base: String,
        existingIDs: Set<String>,
        annotationsDir: URL
    ) -> String {
        var candidate = base
        var index = 2
        while Self.containsTrackID(existingIDs, matching: candidate)
            || Self.bundleArtifactExistsCaseInsensitive(annotationsDir.appendingPathComponent("\(candidate).db")) {
            candidate = "\(base)_\(index)"
            index += 1
        }
        return candidate
    }

    private static func containsTrackID(_ existingIDs: Set<String>, matching candidate: String) -> Bool {
        existingIDs.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }

    private static func bundleArtifactExistsCaseInsensitive(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { return true }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let desiredName = url.lastPathComponent.lowercased()
        return entries.contains { $0.lastPathComponent.lowercased() == desiredName }
    }

    private static func projectRelativePath(from projectURL: URL, to targetURL: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard targetPath.hasPrefix(normalizedProjectPath) else { return targetPath }
        return String(targetPath.dropFirst(normalizedProjectPath.count))
    }

    private static func writeProvenance(
        sourceURL: URL,
        bundleURL: URL,
        manifestURL: URL,
        databaseURL: URL,
        track: AnnotationTrackInfo,
        featureCount: Int,
        format: String,
        importerName: String,
        inputManifestSnapshot: AnnotationImportFileSnapshot?,
        runClock: ProvenanceRunClock,
        invocationArgv: [String]?
    ) throws {
        let completedAt = runClock.now
        let provenanceURL = importProvenanceURL(bundleURL: bundleURL, trackID: track.id)
        var log = try loadProvenanceLog(from: provenanceURL)
        let command = invocationArgv ?? [
            LungfishAppIdentity.recordedToolName,
            "annotation-import",
            "--bundle", bundleURL.path,
            "--source", sourceURL.path,
            "--track-id", track.id,
            "--track-name", track.name,
            "--format", format,
        ]
        let outputSnapshots = [
            fileSnapshot(for: manifestURL),
            fileSnapshot(for: databaseURL),
        ].compactMap { $0 }
        let inputSnapshots = [
            fileSnapshot(for: sourceURL),
            inputManifestSnapshot,
        ].compactMap { $0 }
        let entry = AnnotationTrackImportProvenanceEntry(
            workflowName: "lungfish annotation track import",
            workflowVersion: appVersionString(),
            toolName: LungfishAppIdentity.recordedToolName,
            toolVersion: appVersionString(),
            argv: command,
            options: [
                "trackID": track.id,
                "trackName": track.name,
                "format": format,
                "importer": importerName,
                "rejectZeroFeatureTracks": "true",
                "storedCoordinateSystem": "0-based half-open",
            ],
            inputPaths: inputSnapshots.map(\.path),
            outputPaths: [
                manifestURL.path,
                databaseURL.path,
                provenanceURL.path,
            ],
            inputFileInfo: inputSnapshots,
            outputFileInfo: outputSnapshots,
            runtime: AnnotationTrackImportRuntime(
                app: LungfishAppIdentity.recordedToolName,
                appVersion: appVersionString(),
                condaEnvironment: nil,
                containerRuntime: nil
            ),
            featureCount: featureCount,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(runClock.startedAt),
            stderr: nil,
            recordedAt: completedAt
        )
        log.entries.append(entry)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log)
        try data.write(to: provenanceURL, options: .atomic)
        let writer = ProvenanceWriter()
        try writeCanonicalProvenance(
            command: command,
            sourceURL: sourceURL,
            bundleURL: bundleURL,
            manifestURL: manifestURL,
            databaseURL: databaseURL,
            importProvenanceURL: provenanceURL,
            track: track,
            featureCount: featureCount,
            format: format,
            importerName: importerName,
            inputManifestSnapshot: inputManifestSnapshot,
            startedAt: runClock.startedAt,
            completedAt: completedAt,
            writer: writer
        )
    }

    private static func importProvenanceURL(bundleURL: URL, trackID: String) -> URL {
        bundleURL.appendingPathComponent("annotations/\(trackID)-import-provenance.json")
    }

    private static func removeAnnotationDatabaseArtifacts(at databaseURL: URL) throws {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func writeCanonicalProvenance(
        command: [String],
        sourceURL: URL,
        bundleURL: URL,
        manifestURL: URL,
        databaseURL: URL,
        importProvenanceURL: URL,
        track: AnnotationTrackInfo,
        featureCount: Int,
        format: String,
        importerName: String,
        inputManifestSnapshot: AnnotationImportFileSnapshot?,
        startedAt: Date,
        completedAt: Date,
        writer: ProvenanceWriter
    ) throws {
        let appVersion = appVersionString()
        let sourceDescriptor = try ProvenanceFileDescriptor.file(
            url: sourceURL,
            format: provenanceFormat(for: sourceURL),
            role: .input
        )
        let manifestInputDescriptor = inputManifestSnapshot.map {
            ProvenanceFileDescriptor(
                path: manifestURL.path,
                checksumSHA256: $0.sha256,
                fileSize: $0.sizeBytes,
                format: .json,
                role: .input
            )
        }
        let inputDescriptors = [sourceDescriptor] + (manifestInputDescriptor.map { [$0] } ?? [])
        let outputDescriptors = try [
            ProvenanceFileDescriptor.file(url: databaseURL, format: .unknown, role: .output),
            ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output),
            ProvenanceFileDescriptor.file(url: importProvenanceURL, format: .json, role: .log),
        ]
        let step = ProvenanceStep(
            toolName: "lungfish annotation track import",
            toolVersion: appVersion,
            argv: command,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let wrappingEnvelope = try ProvenanceRunBuilder(
            workflowName: "lungfish annotation track import",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish annotation track import",
            toolVersion: appVersion
        )
        .argv(command)
        .options(
            explicit: [
                "track_id": .string(track.id),
                "track_name": .string(track.name),
                "format": .string(format),
            ],
            defaults: [
                "reject_zero_feature_tracks": .boolean(true),
                "stored_coordinate_system": .string("0-based half-open"),
            ],
            resolved: [
                "track_id": .string(track.id),
                "track_name": .string(track.name),
                "format": .string(format),
                "importer": .string(importerName),
                "feature_count": .integer(featureCount),
                "reject_zero_feature_tracks": .boolean(true),
                "stored_coordinate_system": .string("0-based half-open"),
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        let mergedEnvelope: ProvenanceEnvelope
        do {
            let rehydrated = try ProvenanceRehydrator.rehydrateSelectedOutputs(
                sourceDirectory: sourceURL.deletingLastPathComponent(),
                finalDirectory: bundleURL,
                pathMap: [sourceURL.path: databaseURL.path]
            )
            let preservingDatabaseOutput = wrappingEnvelope.replacingOutputDescriptor(
                rehydrated.outputDescriptor(matchingPath: databaseURL.path),
                matchingPath: databaseURL.path
            )
            mergedEnvelope = preservingDatabaseOutput.with {
                $0.files = mergedProvenanceFiles(rehydrated.files, preservingDatabaseOutput.files)
                $0.steps = rehydrated.steps + preservingDatabaseOutput.steps
            }
        } catch ProvenanceRehydrationError.missingSourceProvenance {
            mergedEnvelope = wrappingEnvelope
        }
        try writer.write(mergedEnvelope, to: bundleURL)
    }

    private static func mergedProvenanceFiles(
        _ primary: [ProvenanceFileDescriptor],
        _ additional: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen: Set<String> = []
        var merged: [ProvenanceFileDescriptor] = []
        for descriptor in primary + additional {
            let key = [
                descriptor.role.rawValue,
                descriptor.path,
                descriptor.originPath ?? "",
                descriptor.sourceProvenancePath ?? "",
            ].joined(separator: "\u{0}")
            guard seen.insert(key).inserted else { continue }
            merged.append(descriptor)
        }
        return merged
    }

    private static func provenanceFormat(for url: URL) -> FileFormat {
        switch ReferenceBundleImportService.normalizedExtension(for: url) {
        case "bed":
            return .bed
        case "gff", "gff3", "gtf":
            return .gff3
        default:
            return .unknown
        }
    }

    private static func loadProvenanceLog(from url: URL) throws -> AnnotationTrackImportProvenanceLog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AnnotationTrackImportProvenanceLog(schemaVersion: 1, entries: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnnotationTrackImportProvenanceLog.self, from: Data(contentsOf: url))
    }

    private static func fileSnapshot(for url: URL) -> AnnotationImportFileSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        return AnnotationImportFileSnapshot(
            path: url.path,
            sha256: ProvenanceRecorder.sha256(of: url),
            sizeBytes: size
        )
    }

    /// The version this service's records name, the one the `lungfish-cli sequence` leaves
    /// record. In the app it is the app's own version.
    private static func appVersionString() -> String {
        LungfishAppVersion.short
    }
}

extension ProvenanceEnvelope {
    func outputDescriptor(matchingPath path: String) -> ProvenanceFileDescriptor? {
        let descriptors = steps.flatMap(\.outputs)
            + (output.map { [$0] } ?? [])
            + outputs
            + files
        return descriptors.first { $0.path == path && $0.role == .output }
    }

    func replacingOutputDescriptor(
        _ replacement: ProvenanceFileDescriptor?,
        matchingPath path: String
    ) -> ProvenanceEnvelope {
        guard let replacement else { return self }

        func replaced(_ descriptor: ProvenanceFileDescriptor) -> ProvenanceFileDescriptor {
            guard descriptor.path == path, descriptor.role == .output else { return descriptor }
            return replacement
        }

        return with { copy in
            copy.files = files.map(replaced)
            copy.output = output.map(replaced)
            copy.outputs = outputs.map(replaced)
            copy.steps = steps.map { step in
                step.with { stepCopy in
                    stepCopy.outputs = step.outputs.map(replaced)
                }
            }
        }
    }
}

private struct AnnotationTrackImportProvenanceLog: Codable {
    let schemaVersion: Int
    var entries: [AnnotationTrackImportProvenanceEntry]
}

private struct AnnotationTrackImportProvenanceEntry: Codable {
    let workflowName: String
    let workflowVersion: String
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let options: [String: String]
    let inputPaths: [String]
    let outputPaths: [String]
    let inputFileInfo: [AnnotationImportFileSnapshot]
    let outputFileInfo: [AnnotationImportFileSnapshot]
    let runtime: AnnotationTrackImportRuntime
    let featureCount: Int
    let exitStatus: Int
    let wallTimeSeconds: TimeInterval
    let stderr: String?
    let recordedAt: Date
}

private struct AnnotationImportFileSnapshot: Codable {
    let path: String
    let sha256: String?
    let sizeBytes: UInt64?
}

private struct AnnotationTrackImportRuntime: Codable {
    let app: String
    let appVersion: String
    let condaEnvironment: String?
    let containerRuntime: String?
}

/// Whether the caller of one attach cancelled it. The attach reads it from the serializer's task,
/// which the caller's cancellation does not reach.
private final class AttachCancelFlag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }
}
