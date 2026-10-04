// MappingRunRequest.swift - Shared mapping run request for app and CLI entry points
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

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
    public let originalInputFASTQURLs: [URL]?
    public let inputMaterializationStartedAt: Date?
    public let inputMaterializationEndedAt: Date?
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
    public let compatibilityReadClassOverride: MappingReadClass?
    /// The resolved layout of `inputFASTQURLs`, or `nil` until the pipeline
    /// resolves it (``FASTQInputLayoutResolver``) after input materialization.
    public let inputLayout: FASTQInputLayout?
    /// The name of the alignment track the BAM is attached as in the
    /// mapping viewer bundle (`--track-name`); `nil` means
    /// ``MappingResultLayoutService/defaultTrackName(for:)``.
    public let outputTrackName: String?
    /// The mate pairs and single reads of a sample that holds both, for a
    /// mapper that takes them as separate files (bowtie2 `-1 -2 -U`, BBMap
    /// one run per read set). `nil` for every other run, so earlier requests
    /// encode and decode unchanged.
    public let readSetLayout: MappingReadSetLayout?

    public init(
        tool: MappingTool,
        modeID: String,
        inputFASTQURLs: [URL],
        originalInputFASTQURLs: [URL]? = nil,
        inputMaterializationStartedAt: Date? = nil,
        inputMaterializationEndedAt: Date? = nil,
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
        advancedArguments: [String] = [],
        compatibilityReadClassOverride: MappingReadClass? = nil,
        inputLayout: FASTQInputLayout? = nil,
        outputTrackName: String? = nil,
        readSetLayout: MappingReadSetLayout? = nil
    ) {
        self.tool = tool
        self.modeID = modeID
        self.inputFASTQURLs = inputFASTQURLs
        self.originalInputFASTQURLs = originalInputFASTQURLs
        self.inputMaterializationStartedAt = inputMaterializationStartedAt
        self.inputMaterializationEndedAt = inputMaterializationEndedAt
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
        self.compatibilityReadClassOverride = compatibilityReadClassOverride
        self.inputLayout = inputLayout
        let trimmedTrackName = outputTrackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.outputTrackName = trimmedTrackName.isEmpty ? nil : trimmedTrackName
        self.readSetLayout = readSetLayout
    }

    public func withOutputTrackName(_ outputTrackName: String?) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: originalInputFASTQURLs,
            inputMaterializationStartedAt: inputMaterializationStartedAt,
            inputMaterializationEndedAt: inputMaterializationEndedAt,
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
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }

    public func withInputFASTQURLs(_ inputFASTQURLs: [URL], pairedEnd: Bool? = nil) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: originalInputFASTQURLs,
            inputMaterializationStartedAt: inputMaterializationStartedAt,
            inputMaterializationEndedAt: inputMaterializationEndedAt,
            referenceFASTAURL: referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: sampleName,
            readGroup: readGroup,
            pairedEnd: pairedEnd ?? self.pairedEnd,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minimumMappingQuality,
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }

    public func withOutputDirectory(_ outputDirectory: URL) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: originalInputFASTQURLs,
            inputMaterializationStartedAt: inputMaterializationStartedAt,
            inputMaterializationEndedAt: inputMaterializationEndedAt,
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
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }

    public func withSourceReferenceBundleURL(_ sourceReferenceBundleURL: URL?) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: originalInputFASTQURLs,
            inputMaterializationStartedAt: inputMaterializationStartedAt,
            inputMaterializationEndedAt: inputMaterializationEndedAt,
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
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }

    public func withInputLayout(_ inputLayout: FASTQInputLayout?) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: originalInputFASTQURLs,
            inputMaterializationStartedAt: inputMaterializationStartedAt,
            inputMaterializationEndedAt: inputMaterializationEndedAt,
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
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }

    /// Records where `inputFASTQURLs` came from. Call it with the resolution
    /// that produced them (``withInputFASTQURLs(_:pairedEnd:)`` with
    /// `resolved.executionInputURLs`). `resolved.originalInputURLs` has one
    /// entry per execution file, which is how ``ManagedMappingPipeline``
    /// pairs each file with the bundle it came from when it records the
    /// bundle, its derived manifest, the root FASTQ, the payload and the
    /// materialization step.
    public func withInputLineage(_ resolved: ResolvedSequenceInputs) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: resolved.originalInputURLs,
            inputMaterializationStartedAt: resolved.materializationStartedAt,
            inputMaterializationEndedAt: resolved.materializationEndedAt,
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
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }

    /// The layout the command builder acts on: the resolved `inputLayout`,
    /// else what the `pairedEnd` flag and file count already say.
    public var effectiveInputLayout: FASTQInputLayout {
        if let inputLayout { return inputLayout }
        return pairedEnd && inputFASTQURLs.count == 2 ? .pairedFiles : .singleEnd
    }

    /// The layout decision for this run: the effective layout and the
    /// handling `tool` applies to it in `modeID`.
    public var readLayoutPlan: MappingReadLayoutPlan {
        MappingReadLayoutPlan.resolve(
            tool: tool,
            modeID: modeID,
            layout: effectiveInputLayout,
            pairsAsSeparateFiles: readSetLayout != nil
        )
    }

    /// This request with the read sets of a sample that holds pairs and
    /// single reads, handed to the mapper as separate files.
    public func withReadSetLayout(_ readSetLayout: MappingReadSetLayout?) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: originalInputFASTQURLs,
            inputMaterializationStartedAt: inputMaterializationStartedAt,
            inputMaterializationEndedAt: inputMaterializationEndedAt,
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
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }

    public func resolvedReadGroup(defaultPlatform: String? = nil) -> MappingReadGroup {
        readGroup ?? MappingReadGroup.resolved(
            sampleName: sampleName,
            defaultPlatform: defaultPlatform ?? MappingReadGroup.defaultPlatform(forModeID: modeID)
        )
    }
}

/// The mate pairs and single reads of one sample that holds both, for a
/// mapper that takes them as separate files. ``ReadSetResolver`` decides
/// them (docs/contracts/READ-PAIRING.md). R1 file `i` and R2 file `i` are one
/// set of pairs whose records correspond by position.
public struct MappingReadSetLayout: Sendable, Codable, Equatable {
    public let r1Files: [URL]
    public let r2Files: [URL]
    /// Merged, orphan and other reads without a mate, one file each.
    public let singleReadFiles: [URL]

    public init(r1Files: [URL], r2Files: [URL], singleReadFiles: [URL]) {
        self.r1Files = r1Files.map(\.standardizedFileURL)
        self.r2Files = r2Files.map(\.standardizedFileURL)
        self.singleReadFiles = singleReadFiles.map(\.standardizedFileURL)
    }

    /// Every file, R1 files first, then R2 files, then single reads.
    public var allFiles: [URL] { r1Files + r2Files + singleReadFiles }
}
