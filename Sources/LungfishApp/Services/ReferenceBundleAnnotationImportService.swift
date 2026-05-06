// ReferenceBundleAnnotationImportService.swift - Attach annotation tracks to existing reference bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
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
}

public enum ReferenceBundleAnnotationImportError: Error, LocalizedError {
    case unsupportedFormat(URL)
    case missingManifest(URL)
    case missingGenome(URL)
    case duplicateTrackID(String)
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
        case .noImportableAnnotations(let url):
            return "No importable annotations were found in \(url.lastPathComponent). The file may be empty or malformed."
        }
    }
}

@MainActor
public final class ReferenceBundleAnnotationImportService {
    public init() {}

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
        bundleURL: URL
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

        let trackID = makeUniqueTrackID(
            base: sanitizedTrackID(for: sourceURL),
            existingIDs: Set(manifest.annotations.map(\.id)),
            annotationsDir: annotationsDir
        )
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
        guard featureCount > 0 else {
            try? FileManager.default.removeItem(at: databaseURL)
            throw ReferenceBundleAnnotationImportError.noImportableAnnotations(sourceURL)
        }

        let track = AnnotationTrackInfo(
            id: trackID,
            name: sourceURL.deletingPathExtension().lastPathComponent,
            description: "Imported from \(sourceURL.lastPathComponent)",
            path: databasePath,
            databasePath: databasePath,
            annotationType: .custom,
            featureCount: featureCount,
            source: sourceURL.path
        )

        let originalManifest = manifest
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
            try? originalManifest.save(to: standardizedBundleURL)
            throw error
        }
        annotationImportLogger.info("Attached annotation track \(trackID, privacy: .public) to \(standardizedBundleURL.lastPathComponent, privacy: .public)")

        return ReferenceBundleAnnotationImportResult(bundleURL: standardizedBundleURL, track: track, featureCount: featureCount)
    }

    private func sanitizedTrackID(for sourceURL: URL) -> String {
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

    private func makeUniqueTrackID(
        base: String,
        existingIDs: Set<String>,
        annotationsDir: URL
    ) -> String {
        var candidate = base
        var index = 2
        while existingIDs.contains(candidate)
            || FileManager.default.fileExists(atPath: annotationsDir.appendingPathComponent("\(candidate).db").path) {
            candidate = "\(base)_\(index)"
            index += 1
        }
        return candidate
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
        let provenanceURL = bundleURL
            .appendingPathComponent("annotations/\(track.id)-import-provenance.json")
        var log = try loadProvenanceLog(from: provenanceURL)
        let command = [
            "Lungfish.app",
            "annotation-import",
            "--bundle", bundleURL.path,
            "--source", sourceURL.path,
            "--track-id", track.id,
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
