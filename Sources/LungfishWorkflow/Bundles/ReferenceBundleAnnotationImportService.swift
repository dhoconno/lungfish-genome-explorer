// ReferenceBundleAnnotationImportService.swift - Attach annotation tracks to existing reference bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let annotationImportLogger = Logger(subsystem: LogSubsystem.app, category: "ReferenceAnnotationImport")

public struct ReferenceBundleChoice: Sendable, Equatable, Identifiable {
    public let url: URL
    public let displayPath: String

    public var id: String { url.standardizedFileURL.path }
}

public struct ReferenceBundleAnnotationImportResult: Sendable, Equatable {
    public let bundleURL: URL
    public let track: AnnotationTrackInfo
    public let featureCount: Int

    public init(bundleURL: URL, track: AnnotationTrackInfo, featureCount: Int) {
        self.bundleURL = bundleURL
        self.track = track
        self.featureCount = featureCount
    }
}

public enum ReferenceBundleAnnotationImportError: Error, LocalizedError {
    case unsupportedFormat(URL)
    case missingManifest(URL)
    case missingGenome(URL)
    case duplicateTrackID(String)
    case invalidTrackID(String)
    case noImportableAnnotations(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            return "\(url.lastPathComponent) is not a supported annotation format. Use GTF, GFF, GFF3, or BED."
        case .missingManifest(let url):
            return "\(url.lastPathComponent) is not a valid reference bundle."
        case .missingGenome(let url):
            return "\(url.lastPathComponent) does not contain genome sequence metadata for annotation import."
        case .duplicateTrackID(let id):
            return "This bundle already has an annotation track named \(id)."
        case .invalidTrackID(let id):
            return "Invalid annotation track ID '\(id)'. Use only letters, numbers, underscores, and hyphens."
        case .noImportableAnnotations(let url):
            return "No importable annotations were found in \(url.lastPathComponent). The file may be empty or malformed."
        }
    }
}

@MainActor
public final class ReferenceBundleAnnotationImportService {
    public init() {}

    private struct ProvenanceLayoutSnapshot {
        let rootProvenanceURL: URL
        let rootProvenanceData: Data?
        let provenanceDirectoryURL: URL
        let provenanceDirectoryBackupURL: URL
        let hadProvenanceDirectory: Bool

        static func capture(bundleURL: URL, backupRoot: URL) throws -> ProvenanceLayoutSnapshot {
            let rootProvenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            let rootProvenanceData = try? Data(contentsOf: rootProvenanceURL)
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
                rootProvenanceURL: rootProvenanceURL,
                rootProvenanceData: rootProvenanceData,
                provenanceDirectoryURL: provenanceDirectoryURL,
                provenanceDirectoryBackupURL: provenanceDirectoryBackupURL,
                hadProvenanceDirectory: hadProvenanceDirectory
            )
        }

        func restore() {
            if let rootProvenanceData {
                try? rootProvenanceData.write(to: rootProvenanceURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: rootProvenanceURL.path) {
                try? FileManager.default.removeItem(at: rootProvenanceURL)
            }
            if FileManager.default.fileExists(atPath: provenanceDirectoryURL.path) {
                try? FileManager.default.removeItem(at: provenanceDirectoryURL)
            }
            if hadProvenanceDirectory {
                try? FileManager.default.copyItem(at: provenanceDirectoryBackupURL, to: provenanceDirectoryURL)
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

    public func attachAnnotationTrack(
        sourceURL: URL,
        bundleURL: URL,
        trackID requestedTrackID: String? = nil,
        trackName requestedTrackName: String? = nil
    ) async throws -> ReferenceBundleAnnotationImportResult {
        let startedAt = Date()
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
        if featureCount == 0 {
            annotationImportLogger.warning("Attached empty annotation track for \(sourceURL.lastPathComponent, privacy: .public); no importable annotations were found")
        }

        let track = AnnotationTrackInfo(
            id: trackID,
            name: trackName,
            description: featureCount == 0
                ? "Imported from \(sourceURL.lastPathComponent) (no annotations found)"
                : "Imported from \(sourceURL.lastPathComponent)",
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
                startedAt: startedAt
            )
        } catch {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: importProvenanceURL(bundleURL: standardizedBundleURL, trackID: trackID))
            try? originalManifest.save(to: standardizedBundleURL)
            provenanceSnapshot.restore()
            throw error
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

    private func resolvedTrackID(
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

    private func makeUniqueTrackID(
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

    private func writeProvenance(
        sourceURL: URL,
        bundleURL: URL,
        manifestURL: URL,
        databaseURL: URL,
        track: AnnotationTrackInfo,
        featureCount: Int,
        format: String,
        importerName: String,
        inputManifestSnapshot: AnnotationImportFileSnapshot?,
        startedAt: Date
    ) throws {
        let completedAt = Date()
        let provenanceURL = importProvenanceURL(bundleURL: bundleURL, trackID: track.id)
        var log = try loadProvenanceLog(from: provenanceURL)
        let command = [
            "Lungfish.app",
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
            toolName: "Lungfish Genome Explorer",
            toolVersion: appVersionString(),
            argv: command,
            options: [
                "trackID": track.id,
                "trackName": track.name,
                "format": format,
                "importer": importerName,
                "rejectZeroFeatureTracks": "false",
                "emptyAnnotationManifestEntry": featureCount == 0 ? "true" : "false",
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
                app: "Lungfish Genome Explorer",
                appVersion: appVersionString(),
                condaEnvironment: nil,
                containerRuntime: nil
            ),
            featureCount: featureCount,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            recordedAt: completedAt
        )
        log.entries.append(entry)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log)
        try data.write(to: provenanceURL, options: .atomic)
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
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func importProvenanceURL(bundleURL: URL, trackID: String) -> URL {
        bundleURL.appendingPathComponent("annotations/\(trackID)-import-provenance.json")
    }

    private func writeCanonicalProvenance(
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
        completedAt: Date
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
                "reject_zero_feature_tracks": .boolean(false),
                "stored_coordinate_system": .string("0-based half-open"),
            ],
            resolved: [
                "track_id": .string(track.id),
                "track_name": .string(track.name),
                "format": .string(format),
                "importer": .string(importerName),
                "feature_count": .integer(featureCount),
                "reject_zero_feature_tracks": .boolean(false),
                "empty_annotation_manifest_entry": .boolean(featureCount == 0),
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
            mergedEnvelope = ProvenanceEnvelope(
                schemaVersion: preservingDatabaseOutput.schemaVersion,
                id: preservingDatabaseOutput.id,
                createdAt: preservingDatabaseOutput.createdAt,
                workflowName: preservingDatabaseOutput.workflowName,
                workflowVersion: preservingDatabaseOutput.workflowVersion,
                toolName: preservingDatabaseOutput.toolName,
                toolVersion: preservingDatabaseOutput.toolVersion,
                tool: preservingDatabaseOutput.tool,
                argv: preservingDatabaseOutput.argv,
                reproducibleCommand: preservingDatabaseOutput.reproducibleCommand,
                options: preservingDatabaseOutput.options,
                runtimeIdentity: preservingDatabaseOutput.runtimeIdentity,
                files: mergedProvenanceFiles(rehydrated.files, preservingDatabaseOutput.files),
                output: preservingDatabaseOutput.output,
                outputs: preservingDatabaseOutput.outputs,
                steps: rehydrated.steps + preservingDatabaseOutput.steps,
                wallTimeSeconds: preservingDatabaseOutput.wallTimeSeconds,
                exitStatus: preservingDatabaseOutput.exitStatus,
                stderr: preservingDatabaseOutput.stderr,
                signatures: [],
                legacyWorkflowRun: nil
            )
        } catch ProvenanceRehydrationError.missingSourceProvenance {
            mergedEnvelope = wrappingEnvelope
        }
        try ProvenanceWriter(signingProvider: nil).write(mergedEnvelope, to: bundleURL)
    }

    private func mergedProvenanceFiles(
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

    private func provenanceFormat(for url: URL) -> FileFormat {
        switch ReferenceBundleImportService.normalizedExtension(for: url) {
        case "bed":
            return .bed
        case "gff", "gff3", "gtf":
            return .gff3
        default:
            return .unknown
        }
    }

    private func loadProvenanceLog(from url: URL) throws -> AnnotationTrackImportProvenanceLog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AnnotationTrackImportProvenanceLog(schemaVersion: 1, entries: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnnotationTrackImportProvenanceLog.self, from: Data(contentsOf: url))
    }

    private func fileSnapshot(for url: URL) -> AnnotationImportFileSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        return AnnotationImportFileSnapshot(
            path: url.path,
            sha256: ProvenanceRecorder.sha256(of: url),
            sizeBytes: size
        )
    }

    private func appVersionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "debug"
    }
}

private extension ProvenanceEnvelope {
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

        return ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            tool: tool,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files.map(replaced),
            output: output.map(replaced),
            outputs: outputs.map(replaced),
            steps: steps.map { step in
                ProvenanceStep(
                    id: step.id,
                    toolName: step.toolName,
                    toolVersion: step.toolVersion,
                    argv: step.argv,
                    reproducibleCommand: step.reproducibleCommand,
                    inputs: step.inputs,
                    outputs: step.outputs.map(replaced),
                    exitStatus: step.exitStatus,
                    wallTimeSeconds: step.wallTimeSeconds,
                    stderr: step.stderr,
                    dependsOn: step.dependsOn,
                    startedAt: step.startedAt,
                    completedAt: step.completedAt
                )
            },
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
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
