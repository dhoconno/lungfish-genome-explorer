// BestMappedReadsAnnotationService.swift - Select best mapped reads per interval as annotations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public final class BestMappedReadsAnnotationService: @unchecked Sendable {
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

    public func convertBestMappedReads(
        request: BestMappedReadsAnnotationRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> BestMappedReadsAnnotationResult {
        let sourceBundleURL = request.sourceBundleURL.standardizedFileURL
        let outputBundleURL = request.outputBundleURL.standardizedFileURL
        guard sourceBundleURL.path != outputBundleURL.path else {
            throw BestMappedReadsAnnotationServiceError.sourceAndOutputBundleMatch(outputBundleURL)
        }

        let mappingResult: MappingResult
        do {
            mappingResult = try MappingResult.load(from: request.mappingResultURL.standardizedFileURL)
        } catch MappingResultLoadError.sidecarNotFound {
            throw BestMappedReadsAnnotationServiceError.missingMappingResult(request.mappingResultURL.standardizedFileURL)
        }

        guard FileManager.default.fileExists(atPath: mappingResult.bamURL.path) else {
            throw BestMappedReadsAnnotationServiceError.missingMappingBAM(mappingResult.bamURL)
        }

        progressHandler?(0.1, "Copying source bundle...")
        try prepareOutputBundle(sourceBundleURL: sourceBundleURL, outputBundleURL: outputBundleURL, replace: request.replaceExisting)

        progressHandler?(0.25, "Reading mapped alignments...")
        let samtoolsResult = try await samtoolsRunner.runSamtools(
            arguments: ["view", "-h", mappingResult.bamURL.path],
            timeout: samtoolsTimeout(for: mappingResult.bamURL.path)
        )
        guard samtoolsResult.isSuccess else {
            throw BestMappedReadsAnnotationServiceError.samtoolsFailed(
                samtoolsResult.stderr.isEmpty ? "samtools exited with \(samtoolsResult.exitCode)" : samtoolsResult.stderr
            )
        }

        progressHandler?(0.55, "Selecting best reads per interval...")
        let selection = try selectBestRows(
            fromSAM: samtoolsResult.stdout,
            request: request,
            mappingResult: mappingResult
        )

        let outputTrackName = normalizedOutputTrackName(request.outputTrackName)
        let outputTrackID = normalizedTrackID(trackIDProvider(outputTrackName))
        let relativeDatabasePath = "annotations/\(outputTrackID).db"
        let databaseURL = outputBundleURL.appendingPathComponent(relativeDatabasePath)

        var manifest = try BundleManifest.load(from: outputBundleURL)
        let existingTracks = manifest.annotations.filter { $0.id == outputTrackID || $0.name == outputTrackName }
        if !existingTracks.isEmpty && !request.replaceExisting {
            throw BestMappedReadsAnnotationServiceError.outputTrackExists(outputTrackName)
        }
        if request.replaceExisting {
            for track in existingTracks {
                removeAnnotationArtifacts(for: track, bundleURL: outputBundleURL)
                manifest = manifest.removingAnnotationTrack(id: track.id)
            }
        }

        progressHandler?(0.75, "Writing annotation database...")
        let featureCount = try MappedReadsAnnotationDatabaseWriter.write(
            rows: selection.rows,
            to: databaseURL,
            metadata: [
                "source_bundle_path": sourceBundleURL.path,
                "mapping_result_path": request.mappingResultURL.standardizedFileURL.path,
                "source_mapping_bam": mappingResult.bamURL.path,
                "selection": "best_overlapping_interval_by_nm",
                "created_by": "best_mapped_reads_annotation_service",
            ]
        )

        let trackInfo = AnnotationTrackInfo(
            id: outputTrackID,
            name: outputTrackName,
            description: "Best mapped MiSeq reads per overlapping genomic interval",
            path: relativeDatabasePath,
            databasePath: relativeDatabasePath,
            annotationType: .custom,
            featureCount: featureCount,
            source: request.mappingResultURL.lastPathComponent,
            version: nil
        )

        progressHandler?(0.9, "Updating output bundle manifest...")
        manifest = manifest.addingAnnotationTrack(trackInfo)
        do {
            try manifest.save(to: outputBundleURL)
        } catch {
            throw BestMappedReadsAnnotationServiceError.manifestWriteFailed(error.localizedDescription)
        }

        progressHandler?(1.0, "Best mapped-read annotation track created.")
        return BestMappedReadsAnnotationResult(
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            outputBundleURL: outputBundleURL,
            annotationTrackInfo: trackInfo,
            databasePath: relativeDatabasePath,
            convertedRecordCount: featureCount,
            candidateRecordCount: selection.candidateRecordCount,
            selectedRecordCount: selection.rows.count,
            skippedUnmappedCount: selection.skippedUnmappedCount,
            skippedSecondarySupplementaryCount: selection.skippedSecondarySupplementaryCount
        )
    }

    private struct SelectionSummary {
        let rows: [MappedReadsAnnotationRow]
        let candidateRecordCount: Int
        let skippedUnmappedCount: Int
        let skippedSecondarySupplementaryCount: Int
    }

    private struct IntervalCluster {
        var chromosome: String
        var start: Int
        var end: Int
        var records: [MappedReadsSAMRecord]

        var candidateCount: Int { records.count }

        mutating func add(_ record: MappedReadsSAMRecord) {
            start = min(start, record.start0)
            end = max(end, record.end0)
            records.append(record)
        }

        func overlaps(_ record: MappedReadsSAMRecord) -> Bool {
            chromosome == record.referenceName && record.start0 <= end && record.end0 >= start
        }
    }

    private func selectBestRows(
        fromSAM sam: String,
        request: BestMappedReadsAnnotationRequest,
        mappingResult: MappingResult
    ) throws -> SelectionSummary {
        var rows: [MappedReadsAnnotationRow] = []
        var cluster: IntervalCluster?
        var candidateRecordCount = 0
        var skippedUnmappedCount = 0
        var skippedSecondarySupplementaryCount = 0

        func flushCluster() {
            guard let current = cluster,
                  let best = current.records.sorted(by: bestRecordSort).first else {
                cluster = nil
                return
            }
            rows.append(annotationRow(
                for: best,
                cluster: current,
                request: request,
                mappingResult: mappingResult
            ))
            cluster = nil
        }

        for rawLine in sam.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("@") else { continue }

            if rawSAMFlag(in: line).map({ $0 & 0x4 != 0 }) == true {
                skippedUnmappedCount += 1
                continue
            }

            guard let record = MappedReadsSAMRecord.parse(line) else {
                throw BestMappedReadsAnnotationServiceError.invalidSAMLine(line)
            }

            if request.primaryOnly && (record.isSecondary || record.isSupplementary) {
                skippedSecondarySupplementaryCount += 1
                continue
            }

            candidateRecordCount += 1
            if var current = cluster, current.overlaps(record) {
                current.add(record)
                cluster = current
            } else {
                flushCluster()
                cluster = IntervalCluster(
                    chromosome: record.referenceName,
                    start: record.start0,
                    end: record.end0,
                    records: [record]
                )
            }
        }
        flushCluster()

        return SelectionSummary(
            rows: rows,
            candidateRecordCount: candidateRecordCount,
            skippedUnmappedCount: skippedUnmappedCount,
            skippedSecondarySupplementaryCount: skippedSecondarySupplementaryCount
        )
    }

    private func bestRecordSort(_ lhs: MappedReadsSAMRecord, _ rhs: MappedReadsSAMRecord) -> Bool {
        let lhsNM = lhs.editDistance ?? Int.max
        let rhsNM = rhs.editDistance ?? Int.max
        if lhsNM != rhsNM { return lhsNM < rhsNM }
        if lhs.mapq != rhs.mapq { return lhs.mapq > rhs.mapq }
        if lhs.referenceLength != rhs.referenceLength { return lhs.referenceLength > rhs.referenceLength }
        if lhs.queryLength != rhs.queryLength { return lhs.queryLength > rhs.queryLength }
        if lhs.readName != rhs.readName { return lhs.readName < rhs.readName }
        return lhs.start0 < rhs.start0
    }

    private func annotationRow(
        for record: MappedReadsSAMRecord,
        cluster: IntervalCluster,
        request: BestMappedReadsAnnotationRequest,
        mappingResult: MappingResult
    ) -> MappedReadsAnnotationRow {
        let mappedReadsRequest = MappedReadsAnnotationRequest(
            bundleURL: request.outputBundleURL,
            sourceTrackID: "mapping-result",
            outputTrackName: request.outputTrackName,
            primaryOnly: request.primaryOnly
        )
        var row = record.annotationRow(
            sourceTrackID: "mapping-result",
            sourceTrackName: request.mappingResultURL.lastPathComponent,
            request: mappedReadsRequest
        )
        var attributes = row.attributes
        attributes["best_interval_start"] = String(cluster.start)
        attributes["best_interval_end"] = String(cluster.end)
        attributes["best_interval_candidate_count"] = String(cluster.candidateCount)
        attributes["selection_metric"] = "lowest_NM"
        attributes["mapping_result_bam"] = mappingResult.bamURL.path
        attributes["source_bundle_path"] = request.sourceBundleURL.standardizedFileURL.path
        row = MappedReadsAnnotationRow(
            name: row.name,
            type: row.type,
            chromosome: row.chromosome,
            start: row.start,
            end: row.end,
            strand: row.strand,
            attributes: attributes
        )
        return row
    }

    private func prepareOutputBundle(sourceBundleURL: URL, outputBundleURL: URL, replace: Bool) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputBundleURL.path) {
            guard replace else {
                throw BestMappedReadsAnnotationServiceError.outputBundleExists(outputBundleURL)
            }
            do {
                try fileManager.removeItem(at: outputBundleURL)
            } catch {
                throw BestMappedReadsAnnotationServiceError.bundleCopyFailed(error.localizedDescription)
            }
        }
        do {
            try fileManager.createDirectory(at: outputBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceBundleURL, to: outputBundleURL)
        } catch {
            throw BestMappedReadsAnnotationServiceError.bundleCopyFailed(error.localizedDescription)
        }
    }

    private func normalizedOutputTrackName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Best Mapped Reads" : trimmed
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
