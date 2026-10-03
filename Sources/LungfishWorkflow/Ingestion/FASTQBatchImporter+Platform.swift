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
        /// Sequencing platform. Drives default values for quality binning,
        /// storage optimisation, and compression level.
        public let platform: IngestionPlatform
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

        public init(
            projectDirectory: URL,
            platform: IngestionPlatform = .illumina,
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
            self.projectDirectory = projectDirectory
            self.pairing = pairing
            self.platform = platform
            self.recipe = recipe
            self.newRecipe = newRecipe
            // Default resolution: explicit value > recipe suggestion > platform default
            self.qualityBinning = qualityBinning ?? newRecipe?.qualityBinning ?? platform.defaultQualityBinning
            let platformSupportsClumping = Self.platformSupportsClumping(platform)
            let resolvedOptimizeStorage = platformSupportsClumping && (
                optimizeStorage
                    ?? clumpingTool.map(\.isClumpingEnabled)
                    ?? platform.defaultOptimizeStorage
            )
            self.optimizeStorage = resolvedOptimizeStorage
            self.clumpingTool = resolvedOptimizeStorage ? (clumpingTool ?? .default) : .none
            self.compressionLevel = compressionLevel ?? platform.defaultCompressionLevel
            self.threads = threads
            self.logDirectory = logDirectory
            self.forceReimport = forceReimport
        }

        private static func platformSupportsClumping(_ platform: IngestionPlatform) -> Bool {
            switch platform {
            case .illumina, .ultima:
                return true
            case .ont, .pacbio:
                return false
            }
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
}
