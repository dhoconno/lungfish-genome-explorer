// TaxonomyFragmentPresentation.swift - What the Kraken2 summary bar says about fragments and read pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// How the Kraken2 summary bar presents a result's count (owner decisions 1
/// and 2, manager ruling 3 of 2026-10-03).
///
/// A run that held read pairs counts fragments. Its line says how many came
/// from pairs and how many from merged or single reads, and is shown only
/// when the two add up to the report's root plus unclassified count. An older
/// result with no read-pairing contract, not run as pairs, may have counted
/// each mate as its own read. It is labelled once its original inputs are
/// found to hold pairs. The sidecar is never rewritten.
struct TaxonomyFragmentPresentation: Equatable {
    static let countedPerReadLabel = "Counted per read, each mate on its own (made before read pairing)"

    let countsFragments: Bool
    let fragmentLine: String?
    /// Whether the result may have counted each mate as a read, which holds
    /// when its original inputs hold pairs.
    let mayHaveCountedPerRead: Bool
    let originalInputs: [URL]

    init(result: ClassificationResult) {
        let config = result.config
        let reportTotal = result.tree.classifiedReads + result.tree.unclassifiedReads
        if let composition = result.fragmentComposition {
            countsFragments = true
            fragmentLine = composition.fragmentCount == reportTotal ? composition.summaryLine : nil
        } else {
            countsFragments = false
            fragmentLine = nil
        }
        mayHaveCountedPerRead = result.readPairingContract == nil
            && result.fragmentComposition == nil
            && !config.isPairedEnd
            && !config.interleavedInput
        originalInputs = config.originalInputFiles ?? config.inputFiles
    }

    /// Whether the "counted per read" label shows, given whether the original
    /// inputs hold pairs (nil when they are gone or cannot be read).
    func showsCountedPerRead(inputsHoldPairs: Bool?) -> Bool {
        mayHaveCountedPerRead && inputsHoldPairs == true
    }
}
