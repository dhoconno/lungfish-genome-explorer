// MappedReadsAnnotationModels.swift - Shared models for mapped-read annotation conversion
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public struct MappedReadsAnnotationRequest: Sendable, Equatable {
    public let bundleURL: URL
    public let sourceTrackID: String
    public let outputTrackName: String
    public let primaryOnly: Bool
    public let includeSequence: Bool
    public let includeQualities: Bool
    public let replaceExisting: Bool

    public init(
        bundleURL: URL,
        sourceTrackID: String,
        outputTrackName: String,
        primaryOnly: Bool = false,
        includeSequence: Bool = false,
        includeQualities: Bool = false,
        replaceExisting: Bool = false
    ) {
        self.bundleURL = bundleURL
        self.sourceTrackID = sourceTrackID
        self.outputTrackName = outputTrackName
        self.primaryOnly = primaryOnly
        self.includeSequence = includeSequence
        self.includeQualities = includeQualities
        self.replaceExisting = replaceExisting
    }
}

public struct MappedReadsAnnotationRow: Sendable, Equatable {
    public let name: String
    public let type: String
    public let chromosome: String
    public let start: Int
    public let end: Int
    public let strand: String
    public let attributes: [String: String]

    public init(
        name: String,
        type: String,
        chromosome: String,
        start: Int,
        end: Int,
        strand: String,
        attributes: [String: String]
    ) {
        self.name = name
        self.type = type
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.strand = strand
        self.attributes = attributes
    }
}

public struct MappedReadsAnnotationResult: Sendable, Equatable {
    public let bundleURL: URL
    public let sourceAlignmentTrackID: String
    public let sourceAlignmentTrackName: String
    public let annotationTrackInfo: AnnotationTrackInfo
    public let databasePath: String
    public let convertedRecordCount: Int
    public let skippedUnmappedCount: Int
    public let skippedSecondarySupplementaryCount: Int
    public let includedSequence: Bool
    public let includedQualities: Bool

    public init(
        bundleURL: URL,
        sourceAlignmentTrackID: String,
        sourceAlignmentTrackName: String,
        annotationTrackInfo: AnnotationTrackInfo,
        databasePath: String,
        convertedRecordCount: Int,
        skippedUnmappedCount: Int,
        skippedSecondarySupplementaryCount: Int,
        includedSequence: Bool,
        includedQualities: Bool
    ) {
        self.bundleURL = bundleURL
        self.sourceAlignmentTrackID = sourceAlignmentTrackID
        self.sourceAlignmentTrackName = sourceAlignmentTrackName
        self.annotationTrackInfo = annotationTrackInfo
        self.databasePath = databasePath
        self.convertedRecordCount = convertedRecordCount
        self.skippedUnmappedCount = skippedUnmappedCount
        self.skippedSecondarySupplementaryCount = skippedSecondarySupplementaryCount
        self.includedSequence = includedSequence
        self.includedQualities = includedQualities
    }
}

public struct BestMappedReadsAnnotationRequest: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let mappingResultURL: URL
    public let outputBundleURL: URL
    public let outputTrackName: String
    public let primaryOnly: Bool
    public let replaceExisting: Bool

    public init(
        sourceBundleURL: URL,
        mappingResultURL: URL,
        outputBundleURL: URL,
        outputTrackName: String,
        primaryOnly: Bool = true,
        replaceExisting: Bool = false
    ) {
        self.sourceBundleURL = sourceBundleURL
        self.mappingResultURL = mappingResultURL
        self.outputBundleURL = outputBundleURL
        self.outputTrackName = outputTrackName
        self.primaryOnly = primaryOnly
        self.replaceExisting = replaceExisting
    }
}

public struct BestMappedReadsAnnotationResult: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let mappingResultURL: URL
    public let outputBundleURL: URL
    public let annotationTrackInfo: AnnotationTrackInfo
    public let databasePath: String
    public let convertedRecordCount: Int
    public let candidateRecordCount: Int
    public let selectedRecordCount: Int
    public let skippedUnmappedCount: Int
    public let skippedSecondarySupplementaryCount: Int

    public init(
        sourceBundleURL: URL,
        mappingResultURL: URL,
        outputBundleURL: URL,
        annotationTrackInfo: AnnotationTrackInfo,
        databasePath: String,
        convertedRecordCount: Int,
        candidateRecordCount: Int,
        selectedRecordCount: Int,
        skippedUnmappedCount: Int,
        skippedSecondarySupplementaryCount: Int
    ) {
        self.sourceBundleURL = sourceBundleURL
        self.mappingResultURL = mappingResultURL
        self.outputBundleURL = outputBundleURL
        self.annotationTrackInfo = annotationTrackInfo
        self.databasePath = databasePath
        self.convertedRecordCount = convertedRecordCount
        self.candidateRecordCount = candidateRecordCount
        self.selectedRecordCount = selectedRecordCount
        self.skippedUnmappedCount = skippedUnmappedCount
        self.skippedSecondarySupplementaryCount = skippedSecondarySupplementaryCount
    }
}

public struct CDSBestAnnotationRequest: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let mappingResultURL: URL
    public let outputBundleURL: URL
    public let outputTrackName: String
    public let includeSecondary: Bool
    public let includeSupplementary: Bool
    public let minimumQueryCoverage: Double
    public let replaceExisting: Bool

    public init(
        sourceBundleURL: URL,
        mappingResultURL: URL,
        outputBundleURL: URL,
        outputTrackName: String,
        includeSecondary: Bool = true,
        includeSupplementary: Bool = false,
        minimumQueryCoverage: Double = 0.5,
        replaceExisting: Bool = false
    ) {
        self.sourceBundleURL = sourceBundleURL
        self.mappingResultURL = mappingResultURL
        self.outputBundleURL = outputBundleURL
        self.outputTrackName = outputTrackName
        self.includeSecondary = includeSecondary
        self.includeSupplementary = includeSupplementary
        self.minimumQueryCoverage = minimumQueryCoverage
        self.replaceExisting = replaceExisting
    }
}

public struct CDSBestAnnotationResult: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let mappingResultURL: URL
    public let outputBundleURL: URL
    public let annotationTrackInfo: AnnotationTrackInfo
    public let databasePath: String
    public let geneCount: Int
    public let cdsCount: Int
    public let candidateRecordCount: Int
    public let selectedLocusCount: Int
    public let skippedUnmappedCount: Int
    public let skippedSecondaryCount: Int
    public let skippedSupplementaryCount: Int

    public init(
        sourceBundleURL: URL,
        mappingResultURL: URL,
        outputBundleURL: URL,
        annotationTrackInfo: AnnotationTrackInfo,
        databasePath: String,
        geneCount: Int,
        cdsCount: Int,
        candidateRecordCount: Int,
        selectedLocusCount: Int,
        skippedUnmappedCount: Int,
        skippedSecondaryCount: Int,
        skippedSupplementaryCount: Int
    ) {
        self.sourceBundleURL = sourceBundleURL
        self.mappingResultURL = mappingResultURL
        self.outputBundleURL = outputBundleURL
        self.annotationTrackInfo = annotationTrackInfo
        self.databasePath = databasePath
        self.geneCount = geneCount
        self.cdsCount = cdsCount
        self.candidateRecordCount = candidateRecordCount
        self.selectedLocusCount = selectedLocusCount
        self.skippedUnmappedCount = skippedUnmappedCount
        self.skippedSecondaryCount = skippedSecondaryCount
        self.skippedSupplementaryCount = skippedSupplementaryCount
    }
}

public enum MappedReadsAnnotationServiceError: Error, LocalizedError, Sendable, Equatable {
    case sourceTrackNotFound(String)
    case outputTrackExists(String)
    case missingAlignmentFile(String)
    case samtoolsFailed(String)
    case invalidSAMLine(String)
    case manifestWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceTrackNotFound(let id):
            return "Could not find alignment track '\(id)' in the bundle."
        case .outputTrackExists(let name):
            return "An annotation track named '\(name)' already exists. Use --replace to overwrite it."
        case .missingAlignmentFile(let path):
            return "Alignment file not found: \(path)"
        case .samtoolsFailed(let message):
            return "samtools mapped-read annotation export failed: \(message)"
        case .invalidSAMLine(let line):
            return "Could not parse SAM alignment line: \(line)"
        case .manifestWriteFailed(let message):
            return "Failed to update bundle manifest: \(message)"
        }
    }
}

public enum BestMappedReadsAnnotationServiceError: Error, LocalizedError, Sendable, Equatable {
    case outputBundleExists(URL)
    case sourceAndOutputBundleMatch(URL)
    case missingMappingResult(URL)
    case missingMappingBAM(URL)
    case samtoolsFailed(String)
    case invalidSAMLine(String)
    case outputTrackExists(String)
    case bundleCopyFailed(String)
    case manifestWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .outputBundleExists(let url):
            return "Output bundle already exists: \(url.path). Use --replace to overwrite it."
        case .sourceAndOutputBundleMatch(let url):
            return "Output bundle must be different from the source bundle: \(url.path)"
        case .missingMappingResult(let url):
            return "No saved mapping result found in \(url.path)"
        case .missingMappingBAM(let url):
            return "Mapped BAM not found: \(url.path)"
        case .samtoolsFailed(let message):
            return "samtools best-mapped-read annotation export failed: \(message)"
        case .invalidSAMLine(let line):
            return "Could not parse SAM alignment line: \(line)"
        case .outputTrackExists(let name):
            return "An annotation track named '\(name)' already exists. Use --replace to overwrite it."
        case .bundleCopyFailed(let message):
            return "Failed to create output bundle: \(message)"
        case .manifestWriteFailed(let message):
            return "Failed to update output bundle manifest: \(message)"
        }
    }
}

public enum CDSBestAnnotationServiceError: Error, LocalizedError, Sendable, Equatable {
    case outputBundleExists(URL)
    case sourceAndOutputBundleMatch(URL)
    case missingMappingResult(URL)
    case missingMappingBAM(URL)
    case samtoolsFailed(String)
    case invalidSAMLine(String)
    case outputTrackExists(String)
    case bundleCopyFailed(String)
    case manifestWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .outputBundleExists(let url):
            return "Output bundle already exists: \(url.path). Use --replace to overwrite it."
        case .sourceAndOutputBundleMatch(let url):
            return "Output bundle must be different from the source bundle: \(url.path)"
        case .missingMappingResult(let url):
            return "No saved mapping result found in \(url.path)"
        case .missingMappingBAM(let url):
            return "Mapped BAM not found: \(url.path)"
        case .samtoolsFailed(let message):
            return "samtools CDS annotation export failed: \(message)"
        case .invalidSAMLine(let line):
            return "Could not parse SAM alignment line: \(line)"
        case .outputTrackExists(let name):
            return "An annotation track named '\(name)' already exists. Use --replace to overwrite it."
        case .bundleCopyFailed(let message):
            return "Failed to create output bundle: \(message)"
        case .manifestWriteFailed(let message):
            return "Failed to update output bundle manifest: \(message)"
        }
    }
}
