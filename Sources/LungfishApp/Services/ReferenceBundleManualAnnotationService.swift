// ReferenceBundleManualAnnotationService.swift - persist user-authored reference annotations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

public struct ReferenceBundleManualAnnotationResult: Sendable, Equatable {
    public let bundleURL: URL
    public let track: AnnotationTrackInfo
    public let featureCount: Int
}

public final class ReferenceBundleManualAnnotationService {
    private let trackID = "manual_annotations"
    private let trackName = "Manual Annotations"
    private let databasePath = "annotations/manual_annotations.db"
    private let provenancePath = "annotations/manual-annotation-provenance.json"

    public init() {}

    public func addAnnotation(
        _ annotation: SequenceAnnotation,
        toBundleAt bundleURL: URL
    ) async throws -> ReferenceBundleManualAnnotationResult {
        let startedAt = Date()
        let standardizedBundleURL = bundleURL.standardizedFileURL
        var manifest = try BundleManifest.load(from: standardizedBundleURL)
        guard manifest.genome != nil else {
            throw ReferenceBundleAnnotationImportError.missingGenome(standardizedBundleURL)
        }
        guard let chromosome = annotation.chromosome ?? manifest.genome?.chromosomes.first?.name else {
            throw ReferenceBundleAnnotationImportError.missingGenome(standardizedBundleURL)
        }

        let annotationsDir = standardizedBundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        let existingTrack = manifest.annotations.first { $0.id == trackID }
        let resolvedDatabasePath = existingTrack?.databasePath ?? databasePath
        let databaseURL = standardizedBundleURL.appendingPathComponent(resolvedDatabasePath)
        let featureCount: Int

        if existingTrack != nil,
           FileManager.default.fileExists(atPath: databaseURL.path) {
            let database = try AnnotationDatabase(url: databaseURL, readWrite: true)
            try insert(annotation: annotation, chromosome: chromosome, into: database)
            featureCount = database.queryCount()
        } else {
            featureCount = try createManualTrackDatabase(
                annotation: annotation,
                chromosome: chromosome,
                databaseURL: databaseURL,
                annotationsDir: annotationsDir
            )
        }

        let updatedTrack = AnnotationTrackInfo(
            id: trackID,
            name: trackName,
            description: "Annotations authored in Lungfish Genome Explorer",
            path: resolvedDatabasePath,
            databasePath: resolvedDatabasePath,
            annotationType: .custom,
            featureCount: featureCount,
            source: "Lungfish manual annotation",
            version: appVersionString()
        )

        manifest = manifest.removingAnnotationTrack(id: trackID).addingAnnotationTrack(updatedTrack)
        try manifest.save(to: standardizedBundleURL)

        try writeProvenance(
            annotation: annotation,
            chromosome: chromosome,
            bundleURL: standardizedBundleURL,
            manifestURL: standardizedBundleURL.appendingPathComponent(BundleManifest.filename),
            databaseURL: databaseURL,
            startedAt: startedAt
        )

        return ReferenceBundleManualAnnotationResult(
            bundleURL: standardizedBundleURL,
            track: updatedTrack,
            featureCount: featureCount
        )
    }

    private func createManualTrackDatabase(
        annotation: SequenceAnnotation,
        chromosome: String,
        databaseURL: URL,
        annotationsDir: URL
    ) throws -> Int {
        let seedURL = annotationsDir.appendingPathComponent("manual_annotations.seed.bed")
        try bedLine(annotation: annotation, chromosome: chromosome).write(
            to: seedURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: seedURL) }
        return try AnnotationDatabase.createFromBED(bedURL: seedURL, outputURL: databaseURL)
    }

    private func insert(
        annotation: SequenceAnnotation,
        chromosome: String,
        into database: AnnotationDatabase
    ) throws {
        let region = annotation.boundingRegion
        try database.insertAnnotation(
            name: bedField(annotation.name),
            type: annotation.type.rawValue,
            chromosome: chromosome,
            start: region.start,
            end: region.end,
            strand: annotation.strand.rawValue,
            attributes: attributes(for: annotation),
            geneName: nil
        )
    }

    private func bedLine(annotation: SequenceAnnotation, chromosome: String) -> String {
        let region = annotation.boundingRegion
        let name = bedField(annotation.name)
        let type = annotation.type.rawValue
        let strand = annotation.strand.rawValue
        let attrs = attributes(for: annotation) ?? ""
        return [
            chromosome,
            String(region.start),
            String(region.end),
            name,
            "0",
            strand,
            String(region.start),
            String(region.end),
            "0,0,0",
            "1",
            String(region.end - region.start),
            "0",
            type,
            attrs,
        ].joined(separator: "\t") + "\n"
    }

    private func attributes(for annotation: SequenceAnnotation) -> String? {
        let id = annotation.id.uuidString
        let source = "Lungfish manual annotation".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? "Lungfish%20manual%20annotation"
        let note = annotation.note?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        var pairs = [
            "ID=\(id)",
            "source=\(source)",
        ]
        if let note, !note.isEmpty {
            pairs.append("Note=\(note)")
        }
        return pairs.joined(separator: ";")
    }

    private func bedField(_ value: String) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Annotation" : trimmed
    }

    private func writeProvenance(
        annotation: SequenceAnnotation,
        chromosome: String,
        bundleURL: URL,
        manifestURL: URL,
        databaseURL: URL,
        startedAt: Date
    ) throws {
        let provenanceURL = bundleURL.appendingPathComponent(provenancePath)
        let completedAt = Date()
        var log = try loadProvenanceLog(from: provenanceURL)
        let region = annotation.boundingRegion
        let command = [
            "Lungfish.app",
            "manual-annotation",
            "--bundle", bundleURL.path,
            "--chromosome", chromosome,
            "--start", String(region.start),
            "--end", String(region.end),
            "--name", annotation.name,
            "--type", annotation.type.rawValue,
            "--strand", annotation.strand.rawValue,
        ]
        let entry = ManualAnnotationProvenanceEntry(
            workflowName: "lungfish manual annotation",
            workflowVersion: appVersionString(),
            argv: command,
            options: [
                "trackID": trackID,
                "trackName": trackName,
                "coordinateSystem": "0-based half-open",
            ],
            inputPaths: [bundleURL.path],
            outputPaths: [
                manifestURL.path,
                databaseURL.path,
                provenanceURL.path,
            ],
            outputFileInfo: [
                fileSnapshot(for: manifestURL),
                fileSnapshot(for: databaseURL),
            ].compactMap { $0 },
            annotation: ManualAnnotationProvenanceAnnotation(
                id: annotation.id.uuidString,
                name: annotation.name,
                type: annotation.type.rawValue,
                chromosome: chromosome,
                start: region.start,
                end: region.end,
                strand: annotation.strand.rawValue
            ),
            runtime: ManualAnnotationRuntime(
                app: "Lungfish Genome Explorer",
                appVersion: appVersionString(),
                condaEnvironment: nil,
                containerRuntime: nil
            ),
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

    private func loadProvenanceLog(from url: URL) throws -> ManualAnnotationProvenanceLog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ManualAnnotationProvenanceLog(schemaVersion: 1, entries: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ManualAnnotationProvenanceLog.self, from: Data(contentsOf: url))
    }

    private func fileSnapshot(for url: URL) -> ManualAnnotationFileSnapshot? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? UInt64
        return ManualAnnotationFileSnapshot(
            path: url.path,
            sha256: ProvenanceRecorder.sha256(of: url),
            sizeBytes: size
        )
    }

    private func appVersionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "debug"
    }
}

private struct ManualAnnotationProvenanceLog: Codable {
    let schemaVersion: Int
    var entries: [ManualAnnotationProvenanceEntry]
}

private struct ManualAnnotationProvenanceEntry: Codable {
    let workflowName: String
    let workflowVersion: String
    let argv: [String]
    let options: [String: String]
    let inputPaths: [String]
    let outputPaths: [String]
    let outputFileInfo: [ManualAnnotationFileSnapshot]
    let annotation: ManualAnnotationProvenanceAnnotation
    let runtime: ManualAnnotationRuntime
    let exitStatus: Int
    let wallTimeSeconds: TimeInterval
    let stderr: String?
    let recordedAt: Date
}

private struct ManualAnnotationFileSnapshot: Codable {
    let path: String
    let sha256: String?
    let sizeBytes: UInt64?
}

private struct ManualAnnotationProvenanceAnnotation: Codable {
    let id: String
    let name: String
    let type: String
    let chromosome: String
    let start: Int
    let end: Int
    let strand: String
}

private struct ManualAnnotationRuntime: Codable {
    let app: String
    let appVersion: String
    let condaEnvironment: String?
    let containerRuntime: String?
}
