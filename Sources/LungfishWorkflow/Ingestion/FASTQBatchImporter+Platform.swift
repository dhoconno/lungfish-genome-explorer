// FASTQBatchImporter+Platform.swift - Import configuration and the platform a FASTQ import records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQBatchImporter {

    public struct ImportConfig: Sendable {
        public let projectDirectory: URL
        /// Pairing choice applied to every sample. Defaults to `auto`.
        public let pairing: ImportPairing
        /// What `--platform` asked for. `auto` infers each sample's platform.
        public let platformRequest: ImportPlatformRequest
        /// The platform this import records in the sidecar. For an `auto`
        /// request it is `.unknown` until ``resolved(with:)`` sets one sample's
        /// platform. Drives the storage defaults.
        public let sequencingPlatform: LungfishIO.SequencingPlatform
        /// How the platform of the sample being imported was decided.
        public let platformResolution: ImportPlatformResolution?
        /// Old-format recipe (for supported unmigrated recipes like WGS and HiFi).
        public let recipe: ProcessingRecipe?
        /// New-format declarative recipe (e.g., VSP2).
        public let newRecipe: Recipe?
        public let qualityBinning: QualityBinningScheme
        /// Whether to run clumpify for storage optimisation. Defaults to the
        /// platform default; can be overridden explicitly.
        public let optimizeStorage: Bool
        /// Storage optimization tool selection. `.auto` resolves after recipe
        /// execution against the actual files that will be bundled.
        public let clumpingTool: ClumpingTool
        /// Gzip compression level. Defaults to `.balanced`.
        public let compressionLevel: CompressionLevel
        public let threads: Int
        public let logDirectory: URL?
        /// When `true`, reimport even if a bundle already exists for the sample.
        public let forceReimport: Bool

        private let requestedQualityBinning: QualityBinningScheme?
        private let requestedOptimizeStorage: Bool?
        private let requestedClumpingTool: ClumpingTool?
        private let requestedCompressionLevel: CompressionLevel?

        public init(
            projectDirectory: URL,
            platform: ImportPlatformRequest,
            recipe: ProcessingRecipe? = nil,
            newRecipe: Recipe? = nil,
            qualityBinning: QualityBinningScheme? = nil,
            optimizeStorage: Bool? = nil,
            clumpingTool: ClumpingTool? = nil,
            compressionLevel: CompressionLevel? = nil,
            threads: Int = 4,
            logDirectory: URL? = nil,
            forceReimport: Bool = false,
            pairing: ImportPairing = .auto
        ) {
            let recorded: LungfishIO.SequencingPlatform
            if case .given(let given) = platform {
                recorded = given
            } else {
                recorded = .unknown
            }
            self.init(
                projectDirectory: projectDirectory, platformRequest: platform, sequencingPlatform: recorded,
                platformResolution: nil, recipe: recipe, newRecipe: newRecipe, qualityBinning: qualityBinning,
                optimizeStorage: optimizeStorage, clumpingTool: clumpingTool, compressionLevel: compressionLevel,
                threads: threads, logDirectory: logDirectory, forceReimport: forceReimport, pairing: pairing
            )
        }

        /// An import with a given four-case ingestion platform.
        public init(
            projectDirectory: URL,
            platform: IngestionPlatform,
            recipe: ProcessingRecipe? = nil,
            newRecipe: Recipe? = nil,
            qualityBinning: QualityBinningScheme? = nil,
            optimizeStorage: Bool? = nil,
            clumpingTool: ClumpingTool? = nil,
            compressionLevel: CompressionLevel? = nil,
            threads: Int = 4,
            logDirectory: URL? = nil,
            forceReimport: Bool = false,
            pairing: ImportPairing = .auto
        ) {
            self.init(
                projectDirectory: projectDirectory, platform: .given(platform.sequencingPlatform),
                recipe: recipe, newRecipe: newRecipe, qualityBinning: qualityBinning,
                optimizeStorage: optimizeStorage, clumpingTool: clumpingTool, compressionLevel: compressionLevel,
                threads: threads, logDirectory: logDirectory, forceReimport: forceReimport, pairing: pairing
            )
        }

        private init(
            projectDirectory: URL,
            platformRequest: ImportPlatformRequest,
            sequencingPlatform: LungfishIO.SequencingPlatform,
            platformResolution: ImportPlatformResolution?,
            recipe: ProcessingRecipe?,
            newRecipe: Recipe?,
            qualityBinning: QualityBinningScheme?,
            optimizeStorage: Bool?,
            clumpingTool: ClumpingTool?,
            compressionLevel: CompressionLevel?,
            threads: Int,
            logDirectory: URL?,
            forceReimport: Bool,
            pairing: ImportPairing
        ) {
            self.projectDirectory = projectDirectory
            self.pairing = pairing
            self.platformRequest = platformRequest
            self.sequencingPlatform = sequencingPlatform
            self.platformResolution = platformResolution
            self.recipe = recipe
            self.newRecipe = newRecipe
            self.requestedQualityBinning = qualityBinning
            self.requestedOptimizeStorage = optimizeStorage
            self.requestedClumpingTool = clumpingTool
            self.requestedCompressionLevel = compressionLevel
            // Default resolution: explicit value > recipe suggestion > platform default
            self.qualityBinning = qualityBinning ?? newRecipe?.qualityBinning ?? .none
            // Short reads are reordered for storage unless asked not to.
            // Unknown reads only when asked (optimizeStorage or a clumping
            // tool), since they may be long. Long reads never are.
            let requestedClumping = optimizeStorage ?? clumpingTool.map(\.isClumpingEnabled)
            let resolvedOptimizeStorage: Bool
            if sequencingPlatform.supportsStorageClumping {
                resolvedOptimizeStorage = requestedClumping ?? true
            } else if sequencingPlatform == .unknown {
                resolvedOptimizeStorage = requestedClumping ?? false
            } else {
                resolvedOptimizeStorage = false
            }
            self.optimizeStorage = resolvedOptimizeStorage
            self.clumpingTool = resolvedOptimizeStorage ? (clumpingTool ?? .default) : .none
            self.compressionLevel = compressionLevel ?? .balanced
            self.threads = threads
            self.logDirectory = logDirectory
            self.forceReimport = forceReimport
        }

        /// This configuration for one sample whose platform is now decided.
        /// Storage defaults follow the decided platform, explicit choices stay.
        public func resolved(with resolution: ImportPlatformResolution) -> ImportConfig {
            ImportConfig(
                projectDirectory: projectDirectory, platformRequest: platformRequest,
                sequencingPlatform: resolution.platform, platformResolution: resolution,
                recipe: recipe, newRecipe: newRecipe, qualityBinning: requestedQualityBinning,
                optimizeStorage: requestedOptimizeStorage, clumpingTool: requestedClumpingTool,
                compressionLevel: requestedCompressionLevel, threads: threads, logDirectory: logDirectory,
                forceReimport: forceReimport, pairing: pairing
            )
        }
    }

    public static func persistedSequencingPlatform(
        for platform: IngestionPlatform
    ) -> LungfishIO.SequencingPlatform? {
        platform.sequencingPlatform
    }

    public static func persistedAssemblyReadType(
        for platform: IngestionPlatform
    ) -> FASTQAssemblyReadType? {
        switch platform {
        case .illumina:
            return .illuminaShortReads
        case .ont:
            return .ontReads
        case .pacbio, .ultima:
            return nil
        }
    }

    public static func applyConfirmedPlatformMetadata(
        to metadata: inout PersistedFASTQMetadata,
        platform: IngestionPlatform
    ) {
        metadata.sequencingPlatform = persistedSequencingPlatform(for: platform)
        if let readType = persistedAssemblyReadType(for: platform) {
            metadata.assemblyReadType = readType
        }
    }

    /// Writes the platform an import decided into a new sidecar: the platform,
    /// the read type it implies or the reads show, and how it was decided.
    /// Unknown records no read type.
    static func applyPlatformMetadata(to metadata: inout PersistedFASTQMetadata, config: ImportConfig) {
        metadata.sequencingPlatform = config.sequencingPlatform
        let readType = config.platformResolution?.readClass
            ?? FASTQAssemblyReadType(sequencingPlatform: config.sequencingPlatform)
        if let readType {
            metadata.assemblyReadType = readType
        }
        metadata.platformAssignment = config.platformResolution?.assignment()
    }

    /// Resolves one sample's platform, logs the decision and any contradiction,
    /// and returns the configuration the sample is imported with.
    static func sampleConfig(
        for pair: SamplePair,
        config: ImportConfig,
        log: (@Sendable (ImportLogEvent) -> Void)?
    ) -> ImportConfig {
        let resolution = resolvePlatform(for: pair, request: config.platformRequest)
        log?(.platformResolved(
            sample: pair.sampleName,
            platform: resolution.platform.importCLIValue,
            source: resolution.source.rawValue,
            confidence: resolution.inference.confidence.rawValue,
            readClass: resolution.readClass?.rawValue,
            evidence: resolution.inference.evidence,
            message: resolution.summaryLine
        ))
        if let contradiction = resolution.contradiction {
            log?(.notice(sample: pair.sampleName, message: contradiction))
        }
        return config.resolved(with: resolution)
    }

    /// The provenance parameters that record how the platform was decided.
    static func platformProvenanceParameters(config: ImportConfig) -> [String: ParameterValue] {
        guard let resolution = config.platformResolution else {
            return ["platformSource": .string(PlatformAssignment.Source.given.rawValue)]
        }
        return [
            "platformSource": .string(resolution.source.rawValue),
            "platformConfidence": .string(resolution.inference.confidence.rawValue),
            "platformEvidence": .array(resolution.inference.evidence.map { .string($0) }),
            "platformDetectorVersion": .integer(PlatformInference.detectorVersion),
            "platformVendorDetail": resolution.inference.vendorDetail.map { .string($0) } ?? .null,
        ]
    }
}
