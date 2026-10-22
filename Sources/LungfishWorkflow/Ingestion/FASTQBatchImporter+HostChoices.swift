// FASTQBatchImporter+HostChoices.swift - An import's record names each choice the host can make, with its source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Where an import setting's value came from: an option the command was given, the command's fixed default, this
/// host (its core count or its free memory), or the recipe that ran (its declared quality binning).
public enum ImportSettingSource: String, Sendable, Codable {
    case option
    case `default`
    case host
    case recipe
}

extension FASTQBatchImporter {
    /// The record's account of the choices a host can make, each with its source (CHTC lane L5-RECORDS M3):
    /// `threadsSource`, the clumpify heap that ran (`clumpifyHeapGB`, `clumpingHeapBytes`, null when clumpify did not
    /// run) with `clumpifyHeapSource`, the heap the automatic tool choice planned with (`clumpingPlanHeapBytes`) and
    /// `resolvedClumpingToolSource`. An automatic choice is the host's unless `--clumpify-heap-gb` pins the heap it
    /// plans with. `qualityBinningSource` says whether the binning came from the option, the recipe or the default
    /// (lane C2-BINNING).
    static func hostChoiceParameters(
        config: ImportConfig,
        ingestionResult: FASTQIngestionResult
    ) -> [String: ParameterValue] {
        let gib = 1_073_741_824
        let heapSource: ImportSettingSource = config.clumpifyHeapGB == nil ? .host : .option
        let toolSource = ingestionResult.requestedClumpingTool == .auto ? heapSource : config.clumpingToolSource
        let ranHeapGB = ingestionResult.clumpifyHeapGB
        return [
            "threadsSource": .string(config.threadsSource.rawValue),
            "clumpifyHeapGB": ranHeapGB.map(ParameterValue.integer) ?? .null,
            "clumpifyHeapSource": ranHeapGB == nil ? .null : .string(heapSource.rawValue),
            "clumpingHeapBytes": ranHeapGB.map { .integer($0 * gib) } ?? .null,
            "clumpingPlanHeapBytes": .integer(Int(ingestionResult.clumpingResolution.clumpifyHeapBytes)),
            "resolvedClumpingToolSource": .string(toolSource.rawValue),
            "qualityBinningSource": .string(config.qualityBinningSource.rawValue),
        ]
    }
}
