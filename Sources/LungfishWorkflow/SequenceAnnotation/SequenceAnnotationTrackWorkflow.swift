// SequenceAnnotationTrackWorkflow.swift - CLI-backed sequence annotation tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public enum SequenceAnnotationTrackWorkflow {
    public enum TrackKind: Sendable, Equatable {
        case orf(minLength: Int, includePartial: Bool, allowAlternativeStarts: Bool)

        var annotationType: AnnotationTrackType {
            switch self {
            case .orf: return .orf
            }
        }

        var featureType: String {
            switch self {
            case .orf: return AnnotationType.orf.rawValue
            }
        }

        var defaultTrackID: String {
            switch self {
            case .orf: return "orfs"
            }
        }

        var defaultTrackName: String {
            switch self {
            case .orf: return "ORFs"
            }
        }

        var workflowName: String {
            switch self {
            case .orf: return "lungfish sequence annotate-orfs"
            }
        }
    }

    public struct Request: Sendable {
        public let bundleURL: URL
        public let sequenceName: String?
        public let start: Int?
        public let end: Int?
        public let frames: [ReadingFrame]
        public let tableID: Int
        public let trackID: String?
        public let trackName: String?
        public let kind: TrackKind
        public let command: [String]
        public let explicitOptions: [String: ParameterValue]
        public let defaultOptions: [String: ParameterValue]
        public let resolvedOptions: [String: ParameterValue]
        public let toolVersion: String

        public init(
            bundleURL: URL,
            sequenceName: String?,
            start: Int?,
            end: Int?,
            frames: [ReadingFrame],
            tableID: Int,
            trackID: String?,
            trackName: String?,
            kind: TrackKind,
            command: [String],
            explicitOptions: [String: ParameterValue],
            defaultOptions: [String: ParameterValue],
            resolvedOptions: [String: ParameterValue],
            toolVersion: String
        ) {
            self.bundleURL = bundleURL
            self.sequenceName = sequenceName
            self.start = start
            self.end = end
            self.frames = frames
            self.tableID = tableID
            self.trackID = trackID
            self.trackName = trackName
            self.kind = kind
            self.command = command
            self.explicitOptions = explicitOptions
            self.defaultOptions = defaultOptions
            self.resolvedOptions = resolvedOptions
            self.toolVersion = toolVersion
        }
    }

    public struct Result: Sendable {
        public let track: AnnotationTrackInfo
        public let bedURL: URL
        public let databaseURL: URL
        public let manifestURL: URL
        public let featureCount: Int
        public let provenanceURL: URL
    }

    public struct DeleteTrackRequest: Sendable {
        public let bundleURL: URL
        public let trackID: String
        public let command: [String]
        public let explicitOptions: [String: ParameterValue]
        public let defaultOptions: [String: ParameterValue]
        public let resolvedOptions: [String: ParameterValue]
        public let toolVersion: String

        public init(
            bundleURL: URL,
            trackID: String,
            command: [String],
            explicitOptions: [String: ParameterValue],
            defaultOptions: [String: ParameterValue],
            resolvedOptions: [String: ParameterValue],
            toolVersion: String
        ) {
            self.bundleURL = bundleURL
            self.trackID = trackID
            self.command = command
            self.explicitOptions = explicitOptions
            self.defaultOptions = defaultOptions
            self.resolvedOptions = resolvedOptions
            self.toolVersion = toolVersion
        }
    }

    public struct DeleteTrackResult: Sendable {
        public let trackID: String
        public let trackName: String
        public let manifestURL: URL
        public let removedURLs: [URL]
        public let provenanceURL: URL
    }

    public struct DeleteAnnotationsRequest: Sendable {
        public let bundleURL: URL
        public let trackID: String
        public let rowIDs: [Int64]
        public let command: [String]
        public let explicitOptions: [String: ParameterValue]
        public let defaultOptions: [String: ParameterValue]
        public let resolvedOptions: [String: ParameterValue]
        public let toolVersion: String

        public init(
            bundleURL: URL,
            trackID: String,
            rowIDs: [Int64],
            command: [String],
            explicitOptions: [String: ParameterValue],
            defaultOptions: [String: ParameterValue],
            resolvedOptions: [String: ParameterValue],
            toolVersion: String
        ) {
            self.bundleURL = bundleURL
            self.trackID = trackID
            self.rowIDs = rowIDs
            self.command = command
            self.explicitOptions = explicitOptions
            self.defaultOptions = defaultOptions
            self.resolvedOptions = resolvedOptions
            self.toolVersion = toolVersion
        }
    }

    public struct DeleteAnnotationsResult: Sendable {
        public let trackID: String
        public let trackName: String
        public let deletedCount: Int
        public let removedTrack: Bool
        public let manifestURL: URL
        public let provenanceURL: URL
    }

    private struct BEDFeature {
        let chromosome: String
        let start: Int
        let end: Int
        let name: String
        let strand: Strand
        let type: String
        let attributes: [String: String]
    }

    private struct TrackPayloadURLs {
        let bedURL: URL
        let databaseURL: URL?
    }

    private struct FileBackup {
        let original: URL
        let backup: URL
    }

    private struct ProvenanceSnapshot {
        let rootProvenanceURL: URL
        let originalRootProvenanceData: Data?
        let provenanceDirectoryURL: URL
        let provenanceDirectoryBackupURL: URL
        let hadProvenanceDirectory: Bool

        static func capture(bundleURL: URL, backupRoot: URL) throws -> ProvenanceSnapshot {
            let rootProvenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            let originalRootProvenanceData = try? Data(contentsOf: rootProvenanceURL)
            let provenanceDirectoryURL = bundleURL.appendingPathComponent(
                ProvenanceWriter.bundleProvenanceDirectoryName,
                isDirectory: true
            )
            let provenanceDirectoryBackupURL = backupRoot.appendingPathComponent("provenance-backup")
            let hadProvenanceDirectory = FileManager.default.fileExists(atPath: provenanceDirectoryURL.path)
            if hadProvenanceDirectory {
                try FileManager.default.copyItem(at: provenanceDirectoryURL, to: provenanceDirectoryBackupURL)
            }
            return ProvenanceSnapshot(
                rootProvenanceURL: rootProvenanceURL,
                originalRootProvenanceData: originalRootProvenanceData,
                provenanceDirectoryURL: provenanceDirectoryURL,
                provenanceDirectoryBackupURL: provenanceDirectoryBackupURL,
                hadProvenanceDirectory: hadProvenanceDirectory
            )
        }

        func restore() {
            if let originalRootProvenanceData {
                try? originalRootProvenanceData.write(to: rootProvenanceURL, options: .atomic)
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

    public static func run(_ request: Request) async throws -> Result {
        let startedAt = Date()
        let bundle = try await ReferenceBundle(url: request.bundleURL)
        let manifest = bundle.manifest
        guard let genome = manifest.genome else {
            throw SequenceAnnotationWorkflowError.missingGenome
        }
        guard let table = CodonTable.table(id: request.tableID) else {
            throw SequenceAnnotationWorkflowError.unknownCodonTable(request.tableID)
        }

        let chromosome = try resolvedChromosome(request.sequenceName, bundle: bundle, genome: genome)
        let rangeStart = request.start ?? 0
        let rangeEnd = request.end ?? Int(chromosome.length)
        guard rangeStart >= 0, rangeEnd >= rangeStart, rangeEnd <= chromosome.length else {
            throw SequenceAnnotationWorkflowError.invalidRange(rangeStart, rangeEnd, Int(chromosome.length))
        }
        guard !request.frames.isEmpty else {
            throw SequenceAnnotationWorkflowError.noFrames
        }

        let region = GenomicRegion(chromosome: chromosome.name, start: rangeStart, end: rangeEnd)
        let sequence = try await bundle.fetchSequence(region: region).uppercased()
        let trackID = try validatedTrackID(request.trackID ?? request.kind.defaultTrackID)
        guard !manifest.annotations.contains(where: { $0.id.caseInsensitiveCompare(trackID) == .orderedSame }) else {
            throw SequenceAnnotationWorkflowError.trackAlreadyExists(trackID)
        }
        let trackName = normalizedTrackName(request.trackName, defaultName: request.kind.defaultTrackName)

        let annotationsDirectory = request.bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDirectory, withIntermediateDirectories: true)
        let bedURL = annotationsDirectory.appendingPathComponent("\(trackID).bed")
        let databaseURL = annotationsDirectory.appendingPathComponent("\(trackID).db")
        try ensureNewBundleArtifactAvailable(relativePath: "annotations/\(trackID).bed", bundleURL: request.bundleURL)
        try ensureNewBundleArtifactAvailable(relativePath: "annotations/\(trackID).db", bundleURL: request.bundleURL)
        let manifestURL = request.bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try? Data(contentsOf: manifestURL)
        let rollbackRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-annotate-orfs-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rollbackRoot) }
        let provenanceSnapshot = try ProvenanceSnapshot.capture(bundleURL: request.bundleURL, backupRoot: rollbackRoot)

        let features: [BEDFeature]
        switch request.kind {
        case .orf(let minLength, let includePartial, let allowAlternativeStarts):
            features = findORFs(
                sequence: sequence,
                chromosome: chromosome.name,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                frames: request.frames,
                table: table,
                minLength: minLength,
                includePartial: includePartial,
                allowAlternativeStarts: allowAlternativeStarts
            )
        }

        do {
            try writeBED(features, to: bedURL)
            let featureCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: databaseURL)
            let track = AnnotationTrackInfo(
                id: trackID,
                name: trackName,
                path: "annotations/\(trackID).bed",
                databasePath: "annotations/\(trackID).db",
                annotationType: request.kind.annotationType,
                featureCount: featureCount,
                source: request.kind.workflowName,
                version: request.toolVersion
            )
            var inputURLs = [
                manifestURL,
                request.bundleURL.appendingPathComponent(genome.path),
                request.bundleURL.appendingPathComponent(genome.indexPath)
            ]
            if let gzipIndexPath = genome.gzipIndexPath {
                inputURLs.append(request.bundleURL.appendingPathComponent(gzipIndexPath))
            }
            let inputDescriptors = try provenanceInputDescriptors(for: inputURLs)

            try manifest.addingAnnotationTrack(track).save(to: request.bundleURL)

            let completedAt = Date()

            let provenanceURL = try writeProvenance(
                request: request,
                table: table,
                inputs: inputDescriptors,
                outputs: [bedURL, databaseURL, manifestURL],
                startedAt: startedAt,
                completedAt: completedAt
            )

            return Result(
                track: track,
                bedURL: bedURL,
                databaseURL: databaseURL,
                manifestURL: manifestURL,
                featureCount: featureCount,
                provenanceURL: provenanceURL
            )
        } catch {
            try? FileManager.default.removeItem(at: bedURL)
            try? FileManager.default.removeItem(at: databaseURL)
            if let originalManifestData {
                try? originalManifestData.write(to: manifestURL, options: .atomic)
            }
            provenanceSnapshot.restore()
            throw error
        }
    }

    public static func deleteTrack(_ request: DeleteTrackRequest) async throws -> DeleteTrackResult {
        let startedAt = Date()
        let trackID = try validatedTrackID(request.trackID)
        let manifest = try BundleManifest.load(from: request.bundleURL)
        guard let track = manifest.annotations.first(where: { $0.id == trackID }) else {
            throw SequenceAnnotationWorkflowError.trackNotFound(trackID)
        }

        let manifestURL = request.bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try Data(contentsOf: manifestURL)
        let payloadURLs = try validatedTrackPayloadURLs(track: track, bundleURL: request.bundleURL)
        let removedPayloadURLs = uniqueURLs([payloadURLs.bedURL] + (payloadURLs.databaseURL.map { [$0] } ?? []))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let removedProvenanceURLs = uniqueURLs(removedPayloadURLs.compactMap {
            ProvenanceWriter.bundleOutputSidecarURL(for: $0, inBundle: request.bundleURL)
        }).filter { FileManager.default.fileExists(atPath: $0.path) }
        let removedURLs = removedPayloadURLs + removedProvenanceURLs
        let inputDescriptors = try provenanceInputDescriptors(for: uniqueURLs([manifestURL] + removedPayloadURLs))

        let backupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-delete-annotation-track-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupRoot) }

        var backups: [FileBackup] = []
        for url in removedURLs {
            let backupURL = backupRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backupURL)
            backups.append(FileBackup(original: url, backup: backupURL))
        }
        let provenanceSnapshot = try ProvenanceSnapshot.capture(bundleURL: request.bundleURL, backupRoot: backupRoot)

        do {
            try manifest.removingAnnotationTrack(id: trackID).save(to: request.bundleURL)
            for url in removedURLs where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let completedAt = Date()
            let provenanceURL = try writeDeletionProvenance(
                request: request,
                track: track,
                inputs: inputDescriptors,
                outputs: [manifestURL],
                removedURLs: removedPayloadURLs,
                startedAt: startedAt,
                completedAt: completedAt
            )
            return DeleteTrackResult(
                trackID: trackID,
                trackName: track.name,
                manifestURL: manifestURL,
                removedURLs: removedPayloadURLs,
                provenanceURL: provenanceURL
            )
        } catch {
            try? originalManifestData.write(to: manifestURL, options: .atomic)
            for backup in backups {
                try? FileManager.default.createDirectory(
                    at: backup.original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: backup.original.path) {
                    try? FileManager.default.removeItem(at: backup.original)
                }
                try? FileManager.default.copyItem(at: backup.backup, to: backup.original)
            }
            provenanceSnapshot.restore()
            throw error
        }
    }

    public static func deleteAnnotations(_ request: DeleteAnnotationsRequest) async throws -> DeleteAnnotationsResult {
        let startedAt = Date()
        let trackID = try validatedTrackID(request.trackID)
        let rowIDs = Array(Set(request.rowIDs)).sorted()
        guard !rowIDs.isEmpty else {
            throw SequenceAnnotationWorkflowError.noAnnotationRowsRequested
        }

        let manifest = try BundleManifest.load(from: request.bundleURL)
        guard let track = manifest.annotations.first(where: { $0.id == trackID }) else {
            throw SequenceAnnotationWorkflowError.trackNotFound(trackID)
        }
        guard track.databasePath != nil else {
            throw SequenceAnnotationWorkflowError.missingAnnotationDatabase(trackID)
        }

        let manifestURL = request.bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try Data(contentsOf: manifestURL)
        let payloadURLs = try validatedTrackPayloadURLs(track: track, bundleURL: request.bundleURL)
        guard let databaseURL = payloadURLs.databaseURL else {
            throw SequenceAnnotationWorkflowError.missingAnnotationDatabase(trackID)
        }
        let hasDistinctBEDPayload = payloadURLs.bedURL.standardizedFileURL.path != databaseURL.standardizedFileURL.path

        let database = try AnnotationDatabase(url: databaseURL)
        let originalRecords = database.queryForTable(limit: Int.max)
        let rowIDSet = Set(rowIDs)
        let deletedRecords = originalRecords.filter { record in
            guard let rowID = record.rowID else { return false }
            return rowIDSet.contains(rowID)
        }
        guard !deletedRecords.isEmpty else {
            throw SequenceAnnotationWorkflowError.annotationRowsNotFound(rowIDs)
        }
        let remainingRecords = originalRecords.filter { record in
            guard let rowID = record.rowID else { return true }
            return !rowIDSet.contains(rowID)
        }

        let removedTrack = remainingRecords.isEmpty
        let trackPayloadURLs = uniqueURLs([payloadURLs.bedURL, databaseURL])
        let payloadsToBackup = uniqueURLs(trackPayloadURLs + provenanceSidecars(for: trackPayloadURLs, bundleURL: request.bundleURL))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let backupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-delete-annotations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupRoot) }
        let payloadBackups = try backupFiles(payloadsToBackup, backupRoot: backupRoot)
        let provenanceSnapshot = try ProvenanceSnapshot.capture(bundleURL: request.bundleURL, backupRoot: backupRoot)
        let inputDescriptors = try provenanceInputDescriptors(for: uniqueURLs([manifestURL] + trackPayloadURLs))

        do {
            let completedAt: Date
            let outputURLs: [URL]
            if removedTrack {
                try manifest.removingAnnotationTrack(id: trackID).save(to: request.bundleURL)
                for url in payloadsToBackup where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                completedAt = Date()
                outputURLs = [manifestURL]
            } else {
                let rewriteBEDURL = hasDistinctBEDPayload
                    ? payloadURLs.bedURL
                    : backupRoot.appendingPathComponent("\(trackID)-remaining.bed")
                try writeBED(records: remainingRecords, to: rewriteBEDURL)
                let featureCount = try AnnotationDatabase.createFromBED(bedURL: rewriteBEDURL, outputURL: databaseURL)
                let updatedTrack = AnnotationTrackInfo(
                    id: track.id,
                    name: track.name,
                    description: track.description,
                    path: track.path,
                    databasePath: track.databasePath,
                    annotationType: track.annotationType,
                    featureCount: featureCount,
                    source: track.source,
                    version: track.version
                )
                try manifest.replacingAnnotationTrack(updatedTrack).save(to: request.bundleURL)
                completedAt = Date()
                outputURLs = hasDistinctBEDPayload
                    ? [payloadURLs.bedURL, databaseURL, manifestURL]
                    : [databaseURL, manifestURL]
            }

            let provenanceURL = try writeDeleteAnnotationsProvenance(
                request: request,
                track: track,
                deletedCount: deletedRecords.count,
                removedTrack: removedTrack,
                inputs: inputDescriptors,
                outputs: outputURLs,
                removedURLs: removedTrack ? trackPayloadURLs : [],
                startedAt: startedAt,
                completedAt: completedAt
            )
            return DeleteAnnotationsResult(
                trackID: trackID,
                trackName: track.name,
                deletedCount: deletedRecords.count,
                removedTrack: removedTrack,
                manifestURL: manifestURL,
                provenanceURL: provenanceURL
            )
        } catch {
            try? originalManifestData.write(to: manifestURL, options: .atomic)
            restoreFiles(payloadBackups)
            provenanceSnapshot.restore()
            throw error
        }
    }

    private static func resolvedChromosome(
        _ sequenceName: String?,
        bundle: ReferenceBundle,
        genome: GenomeInfo
    ) throws -> ChromosomeInfo {
        if let sequenceName {
            guard let chromosome = bundle.chromosome(named: sequenceName) else {
                throw SequenceAnnotationWorkflowError.sequenceNotFound(sequenceName)
            }
            return chromosome
        }
        guard let first = genome.chromosomes.first else {
            throw SequenceAnnotationWorkflowError.missingGenome
        }
        return first
    }

    private static func findORFs(
        sequence: String,
        chromosome: String,
        rangeStart: Int,
        rangeEnd: Int,
        frames: [ReadingFrame],
        table: CodonTable,
        minLength: Int,
        includePartial: Bool,
        allowAlternativeStarts: Bool
    ) -> [BEDFeature] {
        let chars = Array(sequence)
        var features: [BEDFeature] = []
        for frame in frames {
            let working = Array(frame.isReverse ? TranslationEngine.reverseComplement(sequence).uppercased() : sequence)
            var openStart: Int?
            var position = frame.offset
            while position + 3 <= working.count {
                let codon = String(working[position..<(position + 3)])
                if openStart == nil, isStart(codon, table: table, allowAlternativeStarts: allowAlternativeStarts) {
                    openStart = position
                }
                if table.isStopCodon(codon), let start = openStart {
                    appendORF(
                        start: start,
                        end: position + 3,
                        frame: frame,
                        chromosome: chromosome,
                        rangeStart: rangeStart,
                        rangeEnd: rangeEnd,
                        chars: chars,
                        table: table,
                        minLength: minLength,
                        isPartial: false,
                        features: &features
                    )
                    openStart = nil
                }
                position += 3
            }
            if includePartial, let start = openStart {
                appendORF(
                    start: start,
                    end: position,
                    frame: frame,
                    chromosome: chromosome,
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd,
                    chars: chars,
                    table: table,
                    minLength: minLength,
                    isPartial: true,
                    features: &features
                )
            }
        }
        return features.sorted {
            if $0.chromosome != $1.chromosome { return $0.chromosome < $1.chromosome }
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.name < $1.name
        }
    }

    private static func validatedTrackID(_ rawTrackID: String) throws -> String {
        let trackID = rawTrackID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackID.isEmpty else {
            throw SequenceAnnotationWorkflowError.invalidTrackID(rawTrackID)
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard trackID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SequenceAnnotationWorkflowError.invalidTrackID(rawTrackID)
        }
        return trackID
    }

    private static func normalizedTrackName(_ value: String?, defaultName: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private static func ensureNewBundleArtifactAvailable(relativePath: String, bundleURL: URL) throws {
        let url = try validatedBundleRelativeArtifactURL(relativePath, bundleURL: bundleURL)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            throw SequenceAnnotationWorkflowError.trackPayloadAlreadyExists(relativePath)
        }
        let parent = url.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let desiredName = url.lastPathComponent.lowercased()
        if entries.contains(where: { $0.lastPathComponent.lowercased() == desiredName }) {
            throw SequenceAnnotationWorkflowError.trackPayloadAlreadyExists(relativePath)
        }
    }

    private static func validatedTrackPayloadURLs(track: AnnotationTrackInfo, bundleURL: URL) throws -> TrackPayloadURLs {
        TrackPayloadURLs(
            bedURL: try validatedBundleRelativeArtifactURL(track.path, bundleURL: bundleURL),
            databaseURL: try track.databasePath.map {
                try validatedBundleRelativeArtifactURL($0, bundleURL: bundleURL)
            }
        )
    }

    private static func validatedBundleRelativeArtifactURL(_ relativePath: String, bundleURL: URL) throws -> URL {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path == relativePath, !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw SequenceAnnotationWorkflowError.invalidTrackPath(relativePath)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SequenceAnnotationWorkflowError.invalidTrackPath(relativePath)
        }
        guard path != BundleManifest.filename,
              path != ProvenanceWriter.provenanceFilename,
              path != ProvenanceWriter.bundleProvenanceDirectoryName,
              !path.hasPrefix("\(ProvenanceWriter.bundleProvenanceDirectoryName)/") else {
            throw SequenceAnnotationWorkflowError.invalidTrackPath(relativePath)
        }

        let standardizedBundle = bundleURL.standardizedFileURL
        let resolved = standardizedBundle.appendingPathComponent(path).standardizedFileURL
        let bundlePath = standardizedBundle.path.hasSuffix("/") ? standardizedBundle.path : standardizedBundle.path + "/"
        guard resolved.path.hasPrefix(bundlePath) else {
            throw SequenceAnnotationWorkflowError.invalidTrackPath(relativePath)
        }
        return resolved
    }

    private static func appendORF(
        start: Int,
        end: Int,
        frame: ReadingFrame,
        chromosome: String,
        rangeStart: Int,
        rangeEnd: Int,
        chars: [Character],
        table: CodonTable,
        minLength: Int,
        isPartial: Bool,
        features: inout [BEDFeature]
    ) {
        guard end > start, end - start >= minLength else { return }
        let coordinates = originalCoordinates(start: start, end: end, rangeStart: rangeStart, rangeEnd: rangeEnd, frame: frame)
        let coding: String
        if frame.isReverse {
            let reverseComplementChars = Array(TranslationEngine.reverseComplement(String(chars)).uppercased())
            coding = String(reverseComplementChars[start..<end])
        } else {
            coding = String(chars[start..<end])
        }
        let peptide = TranslationEngine.translate(coding, table: table)
        features.append(BEDFeature(
            chromosome: chromosome,
            start: coordinates.start,
            end: coordinates.end,
            name: "ORF_\(frame.rawValue)_\(coordinates.start)_\(coordinates.end)",
            strand: frame.isReverse ? .reverse : .forward,
            type: AnnotationType.orf.rawValue,
            attributes: [
                "frame": frame.rawValue,
                "length_nt": String(end - start),
                "length_aa": String(peptide.count),
                "translation": peptide,
                "genetic_code_table": String(table.id),
                "sequence": chromosome,
                "range_start": String(rangeStart),
                "range_end": String(rangeEnd),
                "partial": String(isPartial)
            ]
        ))
    }

    private static func isStart(_ codon: String, table: CodonTable, allowAlternativeStarts: Bool) -> Bool {
        table.isStartCodon(codon) || (allowAlternativeStarts && ["GTG", "TTG", "CTG"].contains(codon.uppercased()))
    }

    private static func originalCoordinates(
        start: Int,
        end: Int,
        rangeStart: Int,
        rangeEnd: Int,
        frame: ReadingFrame
    ) -> (start: Int, end: Int) {
        if frame.isReverse {
            return (rangeEnd - end, rangeEnd - start)
        }
        return (rangeStart + start, rangeStart + end)
    }

    private static func writeBED(_ features: [BEDFeature], to url: URL) throws {
        let rows = features.map { feature in
            [
                feature.chromosome,
                String(feature.start),
                String(feature.end),
                feature.name,
                "0",
                feature.strand.rawValue,
                String(feature.start),
                String(feature.end),
                "0,0,0",
                "1",
                "\(feature.end - feature.start),",
                "0,",
                feature.type,
                encodeAttributes(feature.attributes)
            ].joined(separator: "\t")
        }
        let content = rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeBED(records: [AnnotationDatabaseRecord], to url: URL) throws {
        let content = records.isEmpty
            ? ""
            : records.map { $0.toBED12PlusLine() }.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func provenanceSidecars(for urls: [URL], bundleURL: URL) -> [URL] {
        urls.compactMap { ProvenanceWriter.bundleOutputSidecarURL(for: $0, inBundle: bundleURL) }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            unique.append(url)
        }
        return unique
    }

    private static func backupFiles(_ urls: [URL], backupRoot: URL) throws -> [FileBackup] {
        try urls.map { url in
            let backupURL = backupRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: backupURL)
            return FileBackup(original: url, backup: backupURL)
        }
    }

    private static func restoreFiles(_ backups: [FileBackup]) {
        for backup in backups {
            try? FileManager.default.createDirectory(
                at: backup.original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: backup.original.path) {
                try? FileManager.default.removeItem(at: backup.original)
            }
            try? FileManager.default.copyItem(at: backup.backup, to: backup.original)
        }
    }

    private static func encodeAttributes(_ attributes: [String: String]) -> String {
        attributes.keys.sorted().map { key in
            "\(key)=\(encodeAttributeValue(attributes[key] ?? ""))"
        }.joined(separator: ";")
    }

    private static func encodeAttributeValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";&=\t\n\r")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func writeProvenance(
        request: Request,
        table: CodonTable,
        inputs: [ProvenanceFileDescriptor],
        outputs: [URL],
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let outputDescriptors = try outputs.map {
            try ProvenanceFileDescriptor.file(url: $0, format: provenanceFormat(for: $0), role: .output)
        }
        let step = ProvenanceStep(
            toolName: request.kind.workflowName,
            toolVersion: request.toolVersion,
            argv: request.command,
            inputs: inputs,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = try ProvenanceRunBuilder(
            workflowName: request.kind.workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: request.kind.workflowName,
            toolVersion: request.toolVersion
        )
        .argv(request.command)
        .options(
            explicit: request.explicitOptions,
            defaults: request.defaultOptions,
            resolved: request.resolvedOptions.merging([
                "codon_table_name": .string(table.name)
            ], uniquingKeysWith: { current, _ in current })
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        return try ProvenanceWriter(signingProvider: nil).write(envelope, to: request.bundleURL)
    }

    private static func writeDeletionProvenance(
        request: DeleteTrackRequest,
        track: AnnotationTrackInfo,
        inputs: [ProvenanceFileDescriptor],
        outputs: [URL],
        removedURLs: [URL],
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let outputDescriptors = try outputs.map {
            try ProvenanceFileDescriptor.file(url: $0, format: provenanceFormat(for: $0), role: .output)
        }
        var resolved = request.resolvedOptions
        resolved["track_id"] = .string(track.id)
        resolved["track_name"] = .string(track.name)
        resolved["removed_payloads"] = .array(removedURLs.map { .file($0) })
        let step = ProvenanceStep(
            toolName: "lungfish sequence delete-annotation-track",
            toolVersion: request.toolVersion,
            argv: request.command,
            inputs: inputs,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish sequence delete-annotation-track",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish sequence delete-annotation-track",
            toolVersion: request.toolVersion
        )
        .argv(request.command)
        .options(
            explicit: request.explicitOptions,
            defaults: request.defaultOptions,
            resolved: resolved
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        return try ProvenanceWriter(signingProvider: nil).write(envelope, to: request.bundleURL)
    }

    private static func writeDeleteAnnotationsProvenance(
        request: DeleteAnnotationsRequest,
        track: AnnotationTrackInfo,
        deletedCount: Int,
        removedTrack: Bool,
        inputs: [ProvenanceFileDescriptor],
        outputs: [URL],
        removedURLs: [URL],
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let outputDescriptors = try outputs.map {
            try ProvenanceFileDescriptor.file(url: $0, format: provenanceFormat(for: $0), role: .output)
        }
        var resolved = request.resolvedOptions
        resolved["track_id"] = .string(track.id)
        resolved["track_name"] = .string(track.name)
        resolved["row_ids"] = .array(request.rowIDs.sorted().map { .integer(Int($0)) })
        resolved["deleted_count"] = .integer(deletedCount)
        resolved["removed_track"] = .boolean(removedTrack)
        resolved["removed_payloads"] = .array(removedURLs.map { .file($0) })

        let step = ProvenanceStep(
            toolName: "lungfish sequence delete-annotations",
            toolVersion: request.toolVersion,
            argv: request.command,
            inputs: inputs,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish sequence delete-annotations",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish sequence delete-annotations",
            toolVersion: request.toolVersion
        )
        .argv(request.command)
        .options(
            explicit: request.explicitOptions,
            defaults: request.defaultOptions,
            resolved: resolved
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        return try ProvenanceWriter(signingProvider: nil).write(envelope, to: request.bundleURL)
    }

    private static func provenanceInputDescriptors(for inputs: [URL]) throws -> [ProvenanceFileDescriptor] {
        try inputs.map {
            try ProvenanceFileDescriptor.file(
                url: $0,
                format: provenanceFormat(for: $0),
                role: provenanceInputRole(for: $0)
            )
        }
    }

    private static func provenanceInputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "gzi":
            return .index
        default:
            return .input
        }
    }

    private static func provenanceFormat(for url: URL) -> FileFormat {
        let filename = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "bed":
            return .bed
        case "json":
            return .json
        case "fai", "gzi", "txt":
            return .text
        case "fa", "fasta", "fna", "ffn", "faa", "fas":
            return .fasta
        case "gz" where filename.hasSuffix(".fa.gz")
            || filename.hasSuffix(".fasta.gz")
            || filename.hasSuffix(".fna.gz")
            || filename.hasSuffix(".ffn.gz")
            || filename.hasSuffix(".faa.gz")
            || filename.hasSuffix(".fas.gz"):
            return .fasta
        default:
            return .unknown
        }
    }
}

public enum SequenceAnnotationWorkflowError: Error, LocalizedError, Sendable, Equatable {
    case missingGenome
    case sequenceNotFound(String)
    case invalidRange(Int, Int, Int)
    case unknownCodonTable(Int)
    case noFrames
    case invalidTrackID(String)
    case invalidTrackPath(String)
    case trackPayloadAlreadyExists(String)
    case trackAlreadyExists(String)
    case trackNotFound(String)
    case missingAnnotationDatabase(String)
    case noAnnotationRowsRequested
    case annotationRowsNotFound([Int64])

    public var errorDescription: String? {
        switch self {
        case .missingGenome:
            return "Reference bundle does not contain genome sequence data."
        case .sequenceNotFound(let sequence):
            return "Sequence not found in reference bundle: \(sequence)"
        case .invalidRange(let start, let end, let length):
            return "Invalid sequence range \(start)-\(end); expected 0 <= start <= end <= \(length)."
        case .unknownCodonTable(let id):
            return "Unknown genetic code table ID \(id)."
        case .noFrames:
            return "At least one reading frame must be requested."
        case .invalidTrackID(let id):
            return "Invalid annotation track ID '\(id)'. Use only letters, numbers, underscores, and hyphens."
        case .invalidTrackPath(let path):
            return "Invalid annotation track payload path '\(path)'. Track payloads must be safe bundle-relative paths."
        case .trackPayloadAlreadyExists(let path):
            return "Annotation track payload already exists: \(path)"
        case .trackAlreadyExists(let id):
            return "Annotation track already exists: \(id)"
        case .trackNotFound(let id):
            return "Annotation track not found: \(id)"
        case .missingAnnotationDatabase(let id):
            return "Annotation track '\(id)' does not have an editable annotation database."
        case .noAnnotationRowsRequested:
            return "At least one annotation row ID must be provided."
        case .annotationRowsNotFound(let rowIDs):
            return "Annotation row ID(s) not found: \(rowIDs.map(String.init).joined(separator: ", "))"
        }
    }
}
