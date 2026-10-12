// FASTQDerivativeService+FastpTrim.swift - Fastp trim operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Fastp Trim Operations

    /// The fastp operation a derivative request asks for, or nil when the
    /// request is not a fastp trim. The window renders it through
    /// ``FastpTrimOptions`` exactly as `lungfish-cli fastq trim` and its
    /// siblings do, which the parity tests assert.
    static func fastpTrimOperation(
        for request: FASTQDerivativeRequest,
        sourceBundleURL: URL
    ) throws -> FastpTrimOperation? {
        switch request {
        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            return try combinedTrimOperation(
                threshold: threshold,
                windowSize: windowSize,
                mode: mode,
                adapterMode: adapterMode,
                adapterSequence: adapterSequence
            )
        case .qualityTrim(let threshold, let windowSize, let mode, _):
            return .quality(threshold: threshold, window: windowSize, mode: mode)
        case .adapterTrim(let adapterMode, let sequence, let sequenceR2, let fastaFilename):
            return try adapterTrimOperation(
                mode: adapterMode,
                sequence: sequence,
                sequenceR2: sequenceR2,
                fastaFilename: fastaFilename,
                sourceBundleURL: sourceBundleURL
            )
        case .fixedTrim(let from5Prime, let from3Prime):
            return .fixed(front: from5Prime, tail: from3Prime)
        default:
            return nil
        }
    }

}
