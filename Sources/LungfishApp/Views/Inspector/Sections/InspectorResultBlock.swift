// InspectorResultBlock.swift - The Summary block that belongs to one result kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// The block of the Inspector's Summary that belongs to one kind of result: a NAO-MGS result, an NVD result, or the
/// Operation Details and Source Samples of a classifier run. A block describes the result on screen and no other, so
/// the Summary holds at most one, set through ``DocumentSectionViewModel/showResultBlock(_:)``. Walk OBS-W6 found a
/// NAO-MGS block above the next Kraken2 and TaxTriage results, and row 100 found Kraken2 details above NAO-MGS.
enum InspectorResultBlock {
    case naoMgs(NaoMgsManifest)
    case nvd(NvdManifest)
    case operationDetails(OperationDetails)

    /// The Operation Details and Source Samples of a classifier run, such as Kraken2, EsViritu or TaxTriage.
    struct OperationDetails {
        /// The tool name the block shows, for example "Kraken2".
        var tool: String
        /// Key-value parameters of the run, for example the database and the confidence threshold.
        var parameters: [String: String] = [:]
        /// When the run was made, from the batch manifest or the result's sidecar.
        var timestamp: Date?
        /// Each source sample with the bundle it came from, or nil when that bundle cannot be found.
        var sourceSamples: [(sampleId: String, bundleURL: URL?)] = []
    }

    var naoMgsManifest: NaoMgsManifest? {
        guard case .naoMgs(let manifest) = self else { return nil }
        return manifest
    }

    var nvdManifest: NvdManifest? {
        guard case .nvd(let manifest) = self else { return nil }
        return manifest
    }

    var operationDetails: OperationDetails? {
        guard case .operationDetails(let details) = self else { return nil }
        return details
    }
}
