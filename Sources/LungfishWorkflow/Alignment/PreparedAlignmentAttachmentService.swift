// PreparedAlignmentAttachmentService.swift - Attach prepared BAM artifacts into bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public struct PreparedAlignmentAttachmentRequest: Sendable {
    public let bundleURL: URL
    public let stagedBAMURL: URL
    public let stagedIndexURL: URL
    public let outputTrackID: String
    public let outputTrackName: String
    public let relativeDirectory: String
    public let format: AlignmentFormat

    public init(
        bundleURL: URL,
        stagedBAMURL: URL,
        stagedIndexURL: URL,
        outputTrackID: String,
        outputTrackName: String,
        relativeDirectory: String,
        format: AlignmentFormat = .bam
    ) {
        self.bundleURL = bundleURL
        self.stagedBAMURL = stagedBAMURL
        self.stagedIndexURL = stagedIndexURL
        self.outputTrackID = outputTrackID
        self.outputTrackName = outputTrackName
        self.relativeDirectory = relativeDirectory
        self.format = format
    }
}

public struct PreparedAlignmentAttachmentResult: Sendable {
    public let trackInfo: AlignmentTrackInfo
    public let bamURL: URL
    public let indexURL: URL
    public let metadataDBURL: URL
    public let mappedReads: Int64
    public let unmappedReads: Int64
    public let sampleNames: [String]

    public init(
        trackInfo: AlignmentTrackInfo,
        bamURL: URL,
        indexURL: URL,
        metadataDBURL: URL,
        mappedReads: Int64,
        unmappedReads: Int64,
        sampleNames: [String]
    ) {
        self.trackInfo = trackInfo
        self.bamURL = bamURL
        self.indexURL = indexURL
        self.metadataDBURL = metadataDBURL
        self.mappedReads = mappedReads
        self.unmappedReads = unmappedReads
        self.sampleNames = sampleNames
    }
}

public enum PreparedAlignmentAttachmentError: Error, LocalizedError, Sendable, Equatable {
    case duplicateTrackID(String)
    case invalidRelativeDirectory(String)
    case missingArtifact(URL)

    public var errorDescription: String? {
        switch self {
        case .duplicateTrackID(let trackID):
            return "Alignment track ID already exists in bundle manifest: \(trackID)"
        case .invalidRelativeDirectory(let path):
            return "Alignment attachment directory must be bundle-relative: \(path)"
        case .missingArtifact(let url):
            return "Required staged artifact is missing: \(url.path)"
        }
    }
}

struct PreparedAlignmentMetadataSnapshot: Sendable, Equatable {
    let idxstatsOutput: String
    let flagstatOutput: String
    let headerText: String
}

protocol PreparedAlignmentMetadataCollecting: Sendable {
    func collectMetadata(
        bamURL: URL,
        indexURL: URL,
        format: AlignmentFormat,
        referenceFastaPath: String?
    ) async throws -> PreparedAlignmentMetadataSnapshot
}

private struct AlignmentDataProviderPreparedAlignmentMetadataCollector: PreparedAlignmentMetadataCollecting {
    func collectMetadata(
        bamURL: URL,
        indexURL: URL,
        format: AlignmentFormat,
        referenceFastaPath: String?
    ) async throws -> PreparedAlignmentMetadataSnapshot {
        let provider = AlignmentDataProvider(
            alignmentPath: bamURL.path,
            indexPath: indexURL.path,
            format: format,
            referenceFastaPath: referenceFastaPath
        )
        return PreparedAlignmentMetadataSnapshot(
            idxstatsOutput: try await provider.fetchIdxstats(),
            flagstatOutput: try await provider.fetchFlagstat(),
            headerText: try await provider.fetchHeader()
        )
    }
}

public actor PreparedAlignmentAttachmentService {
    public typealias ManifestSaver = @Sendable (BundleManifest, URL) throws -> Void
    public typealias DateProvider = @Sendable () -> Date

    private let fileManager: FileManager
    private let metadataCollector: any PreparedAlignmentMetadataCollecting
    private let manifestSaver: ManifestSaver
    private let dateProvider: DateProvider

    public init(
        fileManager: FileManager = .default,
        manifestSaver: @escaping ManifestSaver = PreparedAlignmentAttachmentService.atomicManifestSave(manifest:bundleURL:),
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.fileManager = fileManager
        self.metadataCollector = AlignmentDataProviderPreparedAlignmentMetadataCollector()
        self.manifestSaver = manifestSaver
        self.dateProvider = dateProvider
    }

    init(
        fileManager: FileManager = .default,
        metadataCollector: any PreparedAlignmentMetadataCollecting,
        manifestSaver: @escaping ManifestSaver = PreparedAlignmentAttachmentService.atomicManifestSave(manifest:bundleURL:),
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.fileManager = fileManager
        self.metadataCollector = metadataCollector
        self.manifestSaver = manifestSaver
        self.dateProvider = dateProvider
    }

    public func attach(
        request: PreparedAlignmentAttachmentRequest
    ) async throws -> PreparedAlignmentAttachmentResult {
        let relativeDirectory = try normalizedRelativeDirectory(request.relativeDirectory)
        let manifest = try BundleManifest.load(from: request.bundleURL)
        guard !manifest.alignments.contains(where: { $0.id == request.outputTrackID }) else {
            throw PreparedAlignmentAttachmentError.duplicateTrackID(request.outputTrackID)
        }

        for artifactURL in [request.stagedBAMURL, request.stagedIndexURL] {
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw PreparedAlignmentAttachmentError.missingArtifact(artifactURL)
            }
        }

        let manifestURL = request.bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try Data(contentsOf: manifestURL)

        let targetDirectoryURL = request.bundleURL.appendingPathComponent(relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: targetDirectoryURL, withIntermediateDirectories: true)

        let filenames = artifactFilenames(for: request)
        let bamRelativePath = "\(relativeDirectory)/\(filenames.bam)"
        let indexRelativePath = "\(relativeDirectory)/\(filenames.index)"
        let metadataRelativePath = "\(relativeDirectory)/\(request.outputTrackID).stats.db"

        let bamURL = request.bundleURL.appendingPathComponent(bamRelativePath)
        let indexURL = request.bundleURL.appendingPathComponent(indexRelativePath)
        let metadataDBURL = request.bundleURL.appendingPathComponent(metadataRelativePath)

        var promotedURLs: [URL] = []
        do {
            try promoteArtifact(from: request.stagedBAMURL, to: bamURL)
            promotedURLs.append(bamURL)
            try promoteArtifact(from: request.stagedIndexURL, to: indexURL)
            promotedURLs.append(indexURL)

            let metadataSnapshot = try await metadataCollector.collectMetadata(
                bamURL: bamURL,
                indexURL: indexURL,
                format: request.format,
                referenceFastaPath: referenceFASTAPath(in: request.bundleURL)
            )

            let metadataDB = try AlignmentMetadataDatabase.create(at: metadataDBURL)
            promotedURLs.append(metadataDBURL)
            let sampleNames = try populateMetadataDatabase(
                metadataDB,
                snapshot: metadataSnapshot,
                bamURL: bamURL,
                bamRelativePath: bamRelativePath,
                format: request.format
            )

            let mappedReads = metadataDB.totalMappedReads()
            let unmappedReads = metadataDB.totalUnmappedReads()
            let fileSize = try? fileSizeOfItem(at: bamURL)
            let trackInfo = AlignmentTrackInfo(
                id: request.outputTrackID,
                name: request.outputTrackName,
                format: request.format,
                sourcePath: bamRelativePath,
                indexPath: indexRelativePath,
                metadataDBPath: metadataRelativePath,
                fileSizeBytes: fileSize,
                addedDate: dateProvider(),
                mappedReadCount: mappedReads,
                unmappedReadCount: unmappedReads,
                sampleNames: sampleNames
            )

            try manifestSaver(manifest.addingAlignmentTrack(trackInfo), request.bundleURL)

            return PreparedAlignmentAttachmentResult(
                trackInfo: trackInfo,
                bamURL: bamURL,
                indexURL: indexURL,
                metadataDBURL: metadataDBURL,
                mappedReads: mappedReads,
                unmappedReads: unmappedReads,
                sampleNames: sampleNames
            )
        } catch {
            for url in promotedURLs.reversed() {
                try? fileManager.removeItem(at: url)
            }
            try? originalManifestData.write(to: manifestURL, options: .atomic)
            throw error
        }
    }

    public static func atomicManifestSave(
        manifest: BundleManifest,
        bundleURL: URL
    ) throws {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func normalizedRelativeDirectory(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty,
              !trimmed.hasPrefix("/"),
              !normalized.contains("../"),
              normalized != ".." else {
            throw PreparedAlignmentAttachmentError.invalidRelativeDirectory(path)
        }
        return normalized
    }

    private func artifactFilenames(for request: PreparedAlignmentAttachmentRequest) -> (bam: String, index: String) {
        switch request.format {
        case .bam:
            return ("\(request.outputTrackID).bam", "\(request.outputTrackID).bam.bai")
        case .cram:
            return ("\(request.outputTrackID).cram", "\(request.outputTrackID).cram.crai")
        case .sam:
            return ("\(request.outputTrackID).sam", "\(request.outputTrackID).sam.bai")
        }
    }

    private func promoteArtifact(from sourceURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func populateMetadataDatabase(
        _ metadataDB: AlignmentMetadataDatabase,
        snapshot: PreparedAlignmentMetadataSnapshot,
        bamURL: URL,
        bamRelativePath: String,
        format: AlignmentFormat
    ) throws -> [String] {
        metadataDB.setFileInfo("source_path", value: bamURL.path)
        metadataDB.setFileInfo("source_path_in_bundle", value: bamRelativePath)
        metadataDB.setFileInfo("format", value: format.rawValue)
        metadataDB.setFileInfo("import_date", value: ISO8601DateFormatter().string(from: dateProvider()))
        metadataDB.setFileInfo("file_name", value: bamURL.lastPathComponent)

        metadataDB.populateFromIdxstats(snapshot.idxstatsOutput)
        metadataDB.populateFromFlagstat(snapshot.flagstatOutput)

        let readGroups = SAMParser.parseReadGroups(from: snapshot.headerText)
        metadataDB.populateFromReadGroups(readGroups)
        let sampleNames = Array(Set(readGroups.compactMap(\.sample))).sorted()

        let programRecords = SAMParser.parseProgramRecords(from: snapshot.headerText)
        metadataDB.populateFromProgramRecords(programRecords)

        if let headerRecord = SAMParser.parseHeaderRecord(from: snapshot.headerText) {
            if let version = headerRecord.version {
                metadataDB.setFileInfo("sam_version", value: version)
            }
            if let sortOrder = headerRecord.sortOrder {
                metadataDB.setFileInfo("sort_order", value: sortOrder)
            }
            if let groupOrder = headerRecord.groupOrder {
                metadataDB.setFileInfo("group_order", value: groupOrder)
            }
        }

        let referenceSequences = SAMParser.parseReferenceSequences(from: snapshot.headerText)
        metadataDB.setFileInfo("reference_sequence_count", value: "\(SAMParser.referenceSequenceCount(from: snapshot.headerText))")

        let inferredReference = ReferenceInference.infer(from: referenceSequences)
        if let assembly = inferredReference.assembly {
            metadataDB.setFileInfo("inferred_assembly", value: assembly)
        }
        if let organism = inferredReference.organism {
            metadataDB.setFileInfo("inferred_organism", value: organism)
        }
        if let namingConvention = inferredReference.namingConvention {
            metadataDB.setFileInfo("naming_convention", value: namingConvention)
        }
        metadataDB.setFileInfo("inference_confidence", value: "\(inferredReference.confidence)")
        metadataDB.setFileInfo("genome_size", value: "\(inferredReference.totalLength)")

        let mappedReads = metadataDB.totalMappedReads()
        let unmappedReads = metadataDB.totalUnmappedReads()
        metadataDB.setFileInfo("total_reads", value: "\(mappedReads + unmappedReads)")
        metadataDB.setFileInfo("mapped_reads", value: "\(mappedReads)")
        metadataDB.setFileInfo("unmapped_reads", value: "\(unmappedReads)")

        return sampleNames
    }

    private func referenceFASTAPath(in bundleURL: URL) -> String? {
        let manifest = try? BundleManifest.load(from: bundleURL)
        guard let path = manifest?.genome?.path else { return nil }
        let fastaURL = bundleURL.appendingPathComponent(path)
        return fileManager.fileExists(atPath: fastaURL.path) ? fastaURL.path : nil
    }

    private func fileSizeOfItem(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
