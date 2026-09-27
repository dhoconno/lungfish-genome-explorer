import Foundation
import LungfishCore
import LungfishIO

public struct MCMHaplotypingPreset: Codable, Equatable, Sendable {
    /// The built-in MCM MHC miSeq preset.
    ///
    /// Loaded from the packaged `mcm-mhc-miseq.preset.json`. A `lungfish-cli`
    /// built by SwiftPM outside the app bundle finds no packaged resources
    /// (see `RuntimeResourceLocator`), so the embedded copy answers instead;
    /// the preset's reference bundle and specialist prompt still resolve
    /// lazily and throw ``MCMHaplotypingPresetError`` when they are missing,
    /// which is how `--preset` reports the problem instead of crashing.
    public static let mcmMHCmiseq: MCMHaplotypingPreset = {
        (try? loadBuiltInPreset(id: embeddedMCMMHCmiseq.id)) ?? embeddedMCMMHCmiseq
    }()
    public static let builtInPresets: [MCMHaplotypingPreset] = [mcmMHCmiseq]

    /// The `mcm-mhc-miseq.preset.json` descriptor, embedded so a missing
    /// resource degrades to a thrown error rather than a crash.
    /// `MCMHaplotypingPresetTests` keeps it identical to the packaged file.
    static let embeddedMCMMHCmiseq = MCMHaplotypingPreset(
        id: "mcm-mhc-miseq",
        displayName: "MCM MHC miSeq",
        version: "2026-06-19.4",
        referenceBundleResourceName: "MCM-MHC-miSeq-20260617",
        referenceBundleResourceExtension: "lungfishmhcref",
        referenceBundleResourceSubdirectory: "MCMHaplotyping",
        referenceFASTASHA256: "13134729eba56d42479e251b53299152d823947a0bc2c64fb82a61023e1b6561",
        referenceFASTARecordCount: 189,
        haplotypeAssayID: "MHC-exon2-miSeq",
        haplotypeSpeciesCode: "MCM",
        haplotypeDefinitionSetID: "mcm-mhc-miseq-20260617",
        aiDiscoveryPromptTemplateID: "lungfish.ai-haplotyping.mcm-mhc-miseq-specialist.discovery",
        aiRefinementPromptTemplateID: "lungfish.ai-haplotyping.mcm-mhc-miseq-specialist.refinement",
        aiPromptTemplateVersion: "2026-06-19.4",
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
        return builtInPresets.first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public static func builtInPresetDescriptorURL(id: String) -> URL? {
        RuntimeResourceLocator.path(
            "MCMHaplotyping/\(id).preset.json",
            in: .workflow
        )
    }

    public static func builtInPresetDescriptorURL(id: String, bundle: Bundle) -> URL? {
        bundle.url(
            forResource: id,
            withExtension: "preset.json",
            subdirectory: "MCMHaplotyping"
        )?.standardizedFileURL
    }

    /// Loads a built-in preset descriptor from the packaged resources.
    ///
    /// - Throws: ``MCMHaplotypingPresetError/missingBundledPreset(_:)`` when
    ///   the descriptor is not packaged with this executable, or
    ///   ``MCMHaplotypingPresetError/invalidBundledPreset(_:_:)`` when it does
    ///   not decode.
    public static func loadBuiltInPreset(id: String) throws -> MCMHaplotypingPreset {
        try loadBuiltInPreset(id: id, descriptorURL: builtInPresetDescriptorURL(id: id))
    }

    static func loadBuiltInPreset(id: String, descriptorURL: URL?) throws -> MCMHaplotypingPreset {
        guard let descriptorURL else {
            throw MCMHaplotypingPresetError.missingBundledPreset(id)
        }
        do {
            return try JSONDecoder().decode(MCMHaplotypingPreset.self, from: Data(contentsOf: descriptorURL))
        } catch {
            throw MCMHaplotypingPresetError.invalidBundledPreset(id, error.localizedDescription)
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
        guard let url = RuntimeResourceLocator.path(
            "\(referenceBundleResourceSubdirectory)/\(referenceBundleResourceName).\(referenceBundleResourceExtension)",
            in: .workflow
        ) else {
            throw MCMHaplotypingPresetError.missingBundledReferenceBundle(id)
        }
        return url.standardizedFileURL
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
        guard let url = RuntimeResourceLocator.path(
            "\(aiPromptResourceSubdirectory)/\(aiPromptResourceName).\(aiPromptResourceExtension)",
            in: .workflow
        ) else {
            throw MCMHaplotypingPresetError.missingBundledSpecialistPrompt(id)
        }
        return url.standardizedFileURL
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
        try String(contentsOf: bundledSpecialistPromptURL(), encoding: .utf8)
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
            resultWorkflowKind: .miSeqAmpliconMHCGenotype,
            aiSpecialistPresetID: aiSpecialistPresetID
        )
    }
}

public typealias AmpliconGenotypingPreset = MCMHaplotypingPreset

public enum MCMHaplotypingPresetError: Error, LocalizedError, Sendable, Equatable {
    case missingBundledPreset(String)
    case invalidBundledPreset(String, String)
    case missingBundledReferenceBundle(String)
    case missingBundledSpecialistPrompt(String)
    case unknownPreset(String)
    case referenceOverrideNotAllowed(String)
    case haplotypeOverrideNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledPreset(let id):
            return "Bundled amplicon genotyping preset descriptor \(id) was not found."
        case .invalidBundledPreset(let id, let detail):
            return "Bundled amplicon genotyping preset descriptor \(id) could not be read: \(detail)"
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
