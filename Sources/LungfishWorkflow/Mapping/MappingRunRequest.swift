// MappingRunRequest.swift - Shared mapping run request for app and CLI entry points
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct MappingReadGroup: Sendable, Codable, Equatable {
    public let id: String
    public let sampleName: String
    public let library: String
    public let platform: String
    public let platformUnit: String

    public init(
        id: String,
        sampleName: String,
        library: String,
        platform: String,
        platformUnit: String
    ) {
        self.id = id
        self.sampleName = sampleName
        self.library = library
        self.platform = platform
        self.platformUnit = platformUnit
    }

    public static func resolved(
        sampleName defaultSampleName: String,
        id: String? = nil,
        readGroupSampleName: String? = nil,
        library: String? = nil,
        platform: String? = nil,
        platformUnit: String? = nil,
        defaultPlatform: String
    ) -> MappingReadGroup {
        let resolvedSample = clean(defaultSampleName, fallback: "sample")
        return MappingReadGroup(
            id: clean(id, fallback: resolvedSample),
            sampleName: clean(readGroupSampleName, fallback: resolvedSample),
            library: clean(library, fallback: resolvedSample),
            platform: clean(platform, fallback: defaultPlatform),
            platformUnit: clean(platformUnit, fallback: resolvedSample)
        )
    }

    public static func defaultPlatform(forModeID modeID: String) -> String {
        switch MappingMode(rawValue: modeID) {
        case .defaultShortRead, .bbmapStandard:
            return "ILLUMINA"
        case .minimap2Asm5:
            return "ASSEMBLY"
        case .minimap2Splice:
            return "CDNA"
        case .minimap2MapONT:
            return "ONT"
        case .minimap2MapHiFi, .minimap2MapPB, .bbmapPacBio:
            return "PACBIO"
        case nil:
            return "ILLUMINA"
        }
    }

    private static func clean(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

public struct MappingRunRequest: Sendable, Codable, Equatable {
    public let tool: MappingTool
    public let modeID: String
    public let inputFASTQURLs: [URL]
    public let referenceFASTAURL: URL
    public let sourceReferenceBundleURL: URL?
    public let projectURL: URL?
    public let outputDirectory: URL
    public let sampleName: String
    public let readGroup: MappingReadGroup?
    public let pairedEnd: Bool
    public let threads: Int
    public let includeSecondary: Bool
    public let includeSupplementary: Bool
    public let minimumMappingQuality: Int
    public let advancedArguments: [String]

    public init(
        tool: MappingTool,
        modeID: String,
        inputFASTQURLs: [URL],
        referenceFASTAURL: URL,
        sourceReferenceBundleURL: URL? = nil,
        projectURL: URL? = nil,
        outputDirectory: URL,
        sampleName: String,
        readGroup: MappingReadGroup? = nil,
        pairedEnd: Bool = false,
        threads: Int,
        includeSecondary: Bool = false,
        includeSupplementary: Bool = true,
        minimumMappingQuality: Int = 0,
        advancedArguments: [String] = []
    ) {
        self.tool = tool
        self.modeID = modeID
        self.inputFASTQURLs = inputFASTQURLs
        self.referenceFASTAURL = referenceFASTAURL
        self.sourceReferenceBundleURL = sourceReferenceBundleURL
        self.projectURL = projectURL
        self.outputDirectory = outputDirectory
        self.sampleName = sampleName
        self.readGroup = readGroup
        self.pairedEnd = pairedEnd
        self.threads = threads
        self.includeSecondary = includeSecondary
        self.includeSupplementary = includeSupplementary
        self.minimumMappingQuality = minimumMappingQuality
        self.advancedArguments = advancedArguments
    }

    public func withInputFASTQURLs(_ inputFASTQURLs: [URL]) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            referenceFASTAURL: referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: sampleName,
            readGroup: readGroup,
            pairedEnd: pairedEnd,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minimumMappingQuality,
            advancedArguments: advancedArguments
        )
    }

    public func withOutputDirectory(_ outputDirectory: URL) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            referenceFASTAURL: referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: sampleName,
            readGroup: readGroup,
            pairedEnd: pairedEnd,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minimumMappingQuality,
            advancedArguments: advancedArguments
        )
    }

    public func withSourceReferenceBundleURL(_ sourceReferenceBundleURL: URL?) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            referenceFASTAURL: referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: sampleName,
            readGroup: readGroup,
            pairedEnd: pairedEnd,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minimumMappingQuality,
            advancedArguments: advancedArguments
        )
    }

    public func resolvedReadGroup(defaultPlatform: String? = nil) -> MappingReadGroup {
        readGroup ?? MappingReadGroup.resolved(
            sampleName: sampleName,
            defaultPlatform: defaultPlatform ?? MappingReadGroup.defaultPlatform(forModeID: modeID)
        )
    }
}
