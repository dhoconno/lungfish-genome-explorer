import Foundation
import LungfishIO

public struct MCMHaplotypingPreset: Codable, Equatable, Sendable {
    public static let mcmMHCmiseq = MCMHaplotypingPreset(
        id: "mcm-mhc-miseq",
        displayName: "MCM MHC miSeq",
        version: "2026-06-19.1",
        referenceBundleResourceName: "MCM-MHC-miSeq-20260617",
        referenceBundleResourceExtension: MHCAmpliconReferenceBundle.directoryExtension,
        referenceBundleResourceSubdirectory: "MCMHaplotyping",
        referenceFASTASHA256: "13134729eba56d42479e251b53299152d823947a0bc2c64fb82a61023e1b6561",
        referenceFASTARecordCount: 189,
        haplotypeAssayID: "MHC-exon2-miSeq",
        haplotypeSpeciesCode: "MCM",
        haplotypeDefinitionSetID: "mcm-mhc-miseq-20260617",
        aiDiscoveryPromptTemplateID: "lungfish.ai-haplotyping.mcm-mhc-miseq-specialist.discovery",
        aiRefinementPromptTemplateID: "lungfish.ai-haplotyping.mcm-mhc-miseq-specialist.refinement",
        aiPromptTemplateVersion: "2026-06-19.1",
        aiPromptResourceName: "mcm-mhc-haplotyping-specialist-prompt",
        aiPromptResourceExtension: "md",
        aiPromptResourceSubdirectory: "MCMHaplotyping",
        aiOpenAIModel: "gpt-5.5",
        aiReasoningEffort: "medium"
    )

    public let id: String
    public let displayName: String
    public let version: String
    public let referenceBundleResourceName: String
    public let referenceBundleResourceExtension: String
    public let referenceBundleResourceSubdirectory: String
    public let referenceFASTASHA256: String
    public let referenceFASTARecordCount: Int
    public let haplotypeAssayID: String
    public let haplotypeSpeciesCode: String
    public let haplotypeDefinitionSetID: String
    public let aiDiscoveryPromptTemplateID: String
    public let aiRefinementPromptTemplateID: String
    public let aiPromptTemplateVersion: String
    public let aiPromptResourceName: String
    public let aiPromptResourceExtension: String
    public let aiPromptResourceSubdirectory: String
    public let aiOpenAIModel: String
    public let aiReasoningEffort: String

    public static func preset(id: String?) -> MCMHaplotypingPreset? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.caseInsensitiveCompare(mcmMHCmiseq.id) == .orderedSame
            ? mcmMHCmiseq
            : nil
    }

    public func aiPromptTemplateID(for mode: AIHaplotypingPromptMode) -> String {
        switch mode {
        case .aiDiscovery:
            return aiDiscoveryPromptTemplateID
        case .aiRefinement:
            return aiRefinementPromptTemplateID
        }
    }

    public func bundledReferenceBundleURL() throws -> URL {
        try bundledReferenceBundleURL(bundle: .module)
    }

    public func bundledReferenceBundleURL(bundle: Bundle) throws -> URL {
        guard let url = bundle.url(
            forResource: referenceBundleResourceName,
            withExtension: referenceBundleResourceExtension,
            subdirectory: referenceBundleResourceSubdirectory
        ) else {
            throw MCMHaplotypingPresetError.missingBundledReferenceBundle(id)
        }
        return url.standardizedFileURL
    }

    public func bundledSpecialistPromptURL() throws -> URL {
        try bundledSpecialistPromptURL(bundle: .module)
    }

    public func bundledSpecialistPromptURL(bundle: Bundle) throws -> URL {
        guard let url = bundle.url(
            forResource: aiPromptResourceName,
            withExtension: aiPromptResourceExtension,
            subdirectory: aiPromptResourceSubdirectory
        ) else {
            throw MCMHaplotypingPresetError.missingBundledSpecialistPrompt(id)
        }
        return url.standardizedFileURL
    }

    public func bundledSpecialistPromptMarkdown() throws -> String {
        try bundledSpecialistPromptMarkdown(bundle: .module)
    }

    public func bundledSpecialistPromptMarkdown(bundle: Bundle) throws -> String {
        try String(contentsOf: bundledSpecialistPromptURL(bundle: bundle), encoding: .utf8)
    }

    public func matches(result: ONTGenotypeResultBundleData) -> Bool {
        let definitionIDs = [
            result.manifest.haplotypeDefinitionSetID,
            result.haplotypeAnalysis?.definitionSetID,
        ]
        let assayIDs = [
            result.manifest.haplotypeAssayID,
            result.haplotypeAnalysis?.assayID,
        ]
        let hasDefinition = definitionIDs.contains { value in
            matches(value, expected: haplotypeDefinitionSetID)
        }
        let hasAssay = assayIDs.contains { value in
            matches(value, expected: haplotypeAssayID)
        }
        return hasDefinition && hasAssay
    }

    private func matches(_ value: String?, expected: String) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        return trimmed.caseInsensitiveCompare(expected) == .orderedSame
    }

    public func makeGenotypingRunRequest(
        inputFASTQURLs: [URL],
        barcodeDefinitionsURL: URL? = nil,
        outputDirectory: URL,
        outputName: String = "mcm-mhc-miseq",
        demuxManifestURL: URL? = nil,
        analysisName: String? = nil,
        comparisonWorkbookURL: URL? = nil,
        comparisonName: String? = "Illumina-31262",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        sortThreads: Int = 4,
        minSupport: Int = 1,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        extraArguments: [String] = [],
        mode: AmpliconGenotypingMode = .auto,
        readType: AmpliconGenotypingReadType = .auto
    ) throws -> ONTBarcodeDemuxGenotypingRunRequest {
        ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: inputFASTQURLs,
            referenceSourceURL: try bundledReferenceBundleURL(),
            barcodeDefinitionsURL: barcodeDefinitionsURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            demuxManifestURL: demuxManifestURL,
            analysisName: analysisName,
            comparisonWorkbookURL: comparisonWorkbookURL,
            comparisonName: comparisonName,
            projectURL: projectURL,
            threads: threads,
            sortThreads: sortThreads,
            minSupport: minSupport,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: haplotypeAssayID,
            haplotypeSpeciesCode: haplotypeSpeciesCode,
            haplotypeDefinitionScope: nil,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            presetID: id,
            presetVersion: version,
            lockedReferenceSHA256: referenceFASTASHA256,
            extraArguments: extraArguments,
            mode: mode,
            readType: readType
        )
    }
}

public enum MCMHaplotypingPresetError: Error, LocalizedError, Sendable, Equatable {
    case missingBundledReferenceBundle(String)
    case missingBundledSpecialistPrompt(String)
    case unknownPreset(String)
    case referenceOverrideNotAllowed(String)
    case haplotypeOverrideNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledReferenceBundle(let id):
            return "Bundled MCM MHC miSeq reference bundle for preset \(id) was not found."
        case .missingBundledSpecialistPrompt(let id):
            return "Bundled MCM MHC miSeq specialist prompt for preset \(id) was not found."
        case .unknownPreset(let id):
            return "Unknown amplicon genotyping preset: \(id)."
        case .referenceOverrideNotAllowed(let id):
            return "Preset \(id) uses a locked bundled reference; omit --reference."
        case .haplotypeOverrideNotAllowed(let id):
            return "Preset \(id) uses its bundled haplotype definition; omit explicit haplotype definition options."
        }
    }
}
