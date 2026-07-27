import Foundation
import LungfishIO

public struct MCMHaplotypingPreset: Codable, Equatable, Sendable {
    public static let mcmMHCmiseq = loadBuiltInPreset(resourceName: "mcm-mhc-miseq")
    public static let builtInPresets: [MCMHaplotypingPreset] = [mcmMHCmiseq]

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
        return builtInPresets.first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public static func builtInPresetDescriptorURL(id: String) -> URL? {
        builtInPresetDescriptorURL(id: id, bundle: .module)
    }

    public static func builtInPresetDescriptorURL(id: String, bundle: Bundle) -> URL? {
        bundle.url(
            forResource: id,
            withExtension: "preset.json",
            subdirectory: "MCMHaplotyping"
        )?.standardizedFileURL
    }

    private static func loadBuiltInPreset(resourceName: String) -> MCMHaplotypingPreset {
        do {
            guard let url = builtInPresetDescriptorURL(id: resourceName) else {
                throw MCMHaplotypingPresetError.missingBundledPreset(resourceName)
            }
            return try JSONDecoder().decode(MCMHaplotypingPreset.self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("Invalid built-in amplicon genotyping preset \(resourceName): \(error)")
        }
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
        if matches(result.manifest.presetID, expected: id) {
            return true
        }
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
        keepIntermediates: Bool = false,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        extraArguments: [String] = [],
        mode: AmpliconGenotypingMode = .auto,
        readType: AmpliconGenotypingReadType = .auto,
        includeDeterministicHaplotyping: Bool = true,
        aiSpecialistPresetID: String? = nil
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
            keepIntermediates: keepIntermediates,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: includeDeterministicHaplotyping ? haplotypeAssayID : nil,
            haplotypeSpeciesCode: includeDeterministicHaplotyping ? haplotypeSpeciesCode : nil,
            haplotypeDefinitionScope: nil,
            haplotypeDefinitionSetID: includeDeterministicHaplotyping ? haplotypeDefinitionSetID : nil,
            presetID: id,
            presetVersion: version,
            lockedReferenceSHA256: referenceFASTASHA256,
            extraArguments: extraArguments,
            mode: mode,
            readType: readType,
            aiSpecialistPresetID: aiSpecialistPresetID
        )
    }
}

public typealias AmpliconGenotypingPreset = MCMHaplotypingPreset

public enum MCMHaplotypingPresetError: Error, LocalizedError, Sendable, Equatable {
    case missingBundledPreset(String)
    case missingBundledReferenceBundle(String)
    case missingBundledSpecialistPrompt(String)
    case unknownPreset(String)
    case referenceOverrideNotAllowed(String)
    case haplotypeOverrideNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledPreset(let id):
            return "Bundled amplicon genotyping preset descriptor \(id) was not found."
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
