// MappedReadsAnnotationService.swift - Convert bundle alignment reads into annotation tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public final class MappedReadsAnnotationService: @unchecked Sendable {
    private let samtoolsRunner: any AlignmentSamtoolsRunning
    private let trackIDProvider: @Sendable (String) -> String

    public init(
        samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared
    ) {
        self.samtoolsRunner = samtoolsRunner
        self.trackIDProvider = { _ in
            "ann_\(String(UUID().uuidString.prefix(8)))"
        }
    }

    init(
        samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared,
        trackIDProvider: @escaping @Sendable (String) -> String
    ) {
        self.samtoolsRunner = samtoolsRunner
        self.trackIDProvider = trackIDProvider
    }

    public func convertMappedReads(
        request: MappedReadsAnnotationRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> MappedReadsAnnotationResult {
        progressHandler?(0.02, "Opening bundle...")
        let bundle = try await ReferenceBundle(url: request.bundleURL.standardizedFileURL)
        guard let sourceTrack = bundle.alignmentTrack(id: request.sourceTrackID) else {
            throw MappedReadsAnnotationServiceError.sourceTrackNotFound(request.sourceTrackID)
        }

        let sourceAlignmentPath: String
        do {
            sourceAlignmentPath = try bundle.resolveAlignmentPath(sourceTrack)
        } catch ReferenceBundleError.missingFile(let path) {
            throw MappedReadsAnnotationServiceError.missingAlignmentFile(path)
        } catch {
            throw error
        }

        let outputTrackName = normalizedOutputTrackName(request.outputTrackName)
        let outputTrackID = normalizedTrackID(trackIDProvider(outputTrackName))
        let existingTracks = bundle.manifest.annotations.filter {
            $0.id == outputTrackID || $0.name == outputTrackName
        }
        if !existingTracks.isEmpty && !request.replaceExisting {
            throw MappedReadsAnnotationServiceError.outputTrackExists(outputTrackName)
        }

        progressHandler?(0.1, "Reading mapped alignments...")
        let viewArguments = ["view", "-h", sourceAlignmentPath]
        let samtoolsResult = try await samtoolsRunner.runSamtools(arguments: viewArguments, timeout: samtoolsTimeout(for: sourceAlignmentPath))
        guard samtoolsResult.isSuccess else {
            throw MappedReadsAnnotationServiceError.samtoolsFailed(
                samtoolsResult.stderr.isEmpty ? "samtools exited with \(samtoolsResult.exitCode)" : samtoolsResult.stderr
            )
        }

        progressHandler?(0.35, "Converting reads to annotations...")
        var rows: [MappedReadsAnnotationRow] = []
        var skippedUnmappedCount = 0
        var skippedSecondarySupplementaryCount = 0

        for rawLine in samtoolsResult.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("@") else { continue }

            if rawSAMFlag(in: line).map({ $0 & 0x4 != 0 }) == true {
                skippedUnmappedCount += 1
                continue
            }

            guard let record = MappedReadsSAMRecord.parse(line) else {
                throw MappedReadsAnnotationServiceError.invalidSAMLine(line)
            }

            if request.primaryOnly && (record.isSecondary || record.isSupplementary) {
                skippedSecondarySupplementaryCount += 1
                continue
            }

            rows.append(record.annotationRow(
                sourceTrackID: request.sourceTrackID,
                sourceTrackName: sourceTrack.name,
                request: request
            ))
            if rows.count.isMultiple(of: 10_000) {
                progressHandler?(0.35, "Converted \(rows.count) reads...")
            }
        }

        let relativeDatabasePath = "annotations/\(outputTrackID).db"
        let databaseURL = request.bundleURL
            .standardizedFileURL
            .appendingPathComponent(relativeDatabasePath)

        progressHandler?(0.78, "Writing annotation database...")
        if request.replaceExisting {
            for track in existingTracks {
                removeAnnotationArtifacts(for: track, bundleURL: request.bundleURL.standardizedFileURL)
            }
        }
        let featureCount = try MappedReadsAnnotationDatabaseWriter.write(
            rows: rows,
            to: databaseURL,
            metadata: [
                "source_alignment_track_id": request.sourceTrackID,
                "source_alignment_track_name": sourceTrack.name,
                "source_alignment_path": sourceAlignmentPath,
                "include_sequence": String(request.includeSequence),
                "include_qualities": String(request.includeQualities),
                "created_by": "mapped_reads_annotation_service",
            ]
        )

        let trackInfo = AnnotationTrackInfo(
            id: outputTrackID,
            name: outputTrackName,
            description: "Mapped reads converted from alignment track \(sourceTrack.name)",
            path: relativeDatabasePath,
            databasePath: relativeDatabasePath,
            annotationType: .custom,
            featureCount: featureCount,
            source: sourceTrack.name,
            version: nil
        )

        progressHandler?(0.92, "Updating bundle manifest...")
        var updatedManifest = bundle.manifest
        if request.replaceExisting {
            for track in existingTracks {
                updatedManifest = updatedManifest.removingAnnotationTrack(id: track.id)
            }
        }
        updatedManifest = updatedManifest.addingAnnotationTrack(trackInfo)
        do {
            try updatedManifest.save(to: request.bundleURL.standardizedFileURL)
        } catch {
            throw MappedReadsAnnotationServiceError.manifestWriteFailed(error.localizedDescription)
        }

        progressHandler?(1.0, "Mapped reads annotation track created.")
        return MappedReadsAnnotationResult(
            bundleURL: request.bundleURL.standardizedFileURL,
            sourceAlignmentTrackID: request.sourceTrackID,
            sourceAlignmentTrackName: sourceTrack.name,
            annotationTrackInfo: trackInfo,
            databasePath: relativeDatabasePath,
            convertedRecordCount: featureCount,
            skippedUnmappedCount: skippedUnmappedCount,
            skippedSecondarySupplementaryCount: skippedSecondarySupplementaryCount,
            includedSequence: request.includeSequence,
            includedQualities: request.includeQualities
        )
    }

    private func normalizedOutputTrackName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mapped Reads" : trimmed
    }

    private func normalizedTrackID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScalars = trimmed.unicodeScalars.map { scalar -> UnicodeScalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                ? scalar
                : "_"
        }
        let normalized = String(String.UnicodeScalarView(normalizedScalars))
        return normalized.isEmpty ? "ann_\(String(UUID().uuidString.prefix(8)))" : normalized
    }

    private func rawSAMFlag(in line: String) -> UInt16? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        return UInt16(fields[1])
    }

    private func samtoolsTimeout(for path: String) -> TimeInterval {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return max(600.0, Double(fileSize) / 10_000_000.0)
    }

    private func removeAnnotationArtifacts(for track: AnnotationTrackInfo, bundleURL: URL) {
        removeBundleRelativeFile(track.path, bundleURL: bundleURL)
        if let databasePath = track.databasePath, databasePath != track.path {
            removeBundleRelativeFile(databasePath, bundleURL: bundleURL)
        }
    }

    private func removeBundleRelativeFile(_ path: String, bundleURL: URL) {
        let url = URL(fileURLWithPath: path).isFileURL && path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : bundleURL.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: url)
    }
}
