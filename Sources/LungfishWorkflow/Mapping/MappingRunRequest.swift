// MappingRunRequest.swift - Shared mapping run request for app and CLI entry points
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct MappingRunRequest: Sendable, Codable, Equatable {
    public let tool: MappingTool
    public let modeID: String
    public let inputFASTQURLs: [URL]
    public let referenceFASTAURL: URL
    public let sourceReferenceBundleURL: URL?
    public let projectURL: URL?
    public let outputDirectory: URL
    public let sampleName: String
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
            pairedEnd: pairedEnd,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minimumMappingQuality,
            advancedArguments: advancedArguments
        )
    }
}
