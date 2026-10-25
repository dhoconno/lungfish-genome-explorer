// FASTQBatchImporter+HostChoices.swift - An import's record names each choice the host can make, with its source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQBatchImporter {
    /// The record's account of the clumping choice and of the choices a host can make, each with its source (CHTC lane
    /// L5-RECORDS M3, C5 lane MOS1): `threadsSource`, the clumpify heap that ran (`clumpifyHeapGB`, `clumpingHeapBytes`,
    /// null when clumpify did not run) with `clumpifyHeapSource`, the heap the automatic tool choice planned with
    /// (`clumpingPlanHeapBytes`) and `resolvedClumpingToolSource`. The tool's source is the rule's, `default` for `auto`
    /// and `option` for a named tool, and the heap keeps its own source: the host's unless `--clumpify-heap-gb` pins it.
    /// `auto` reads no input size and compares no threshold, as a plan has none, so `clumpingEstimatedInputBytes` and
    /// `clumpingThresholdBytes` are null for it, and `clumpingResolutionReason` is the plan's sentence. A named tool keeps
    /// the size measured on this Mac. `qualityBinningSource` says whether the binning came from the option, the recipe or
    /// the default (lane C2-BINNING).
    static func hostChoiceParameters(
        config: ImportConfig,
        ingestionResult: FASTQIngestionResult
    ) -> [String: ParameterValue] {
        let gib = 1_073_741_824
        let heapSource: ImportSettingSource = config.clumpifyHeapGB == nil ? .host : .option
        let resolution = ingestionResult.clumpingResolution
        let ranHeapGB = ingestionResult.clumpifyHeapGB
        return [
            "threadsSource": .string(config.threadsSource.rawValue),
            "clumpifyHeapGB": ranHeapGB.map(ParameterValue.integer) ?? .null,
            "clumpifyHeapSource": ranHeapGB == nil ? .null : .string(heapSource.rawValue),
            "clumpingHeapBytes": ranHeapGB.map { .integer($0 * gib) } ?? .null,
            "clumpingPlanHeapBytes": .integer(Int(resolution.clumpifyHeapBytes)),
            "resolvedClumpingToolSource": .string(resolution.resolvedSource.rawValue),
            "qualityBinningSource": .string(config.qualityBinningSource.rawValue),
            "clumpingEstimatedInputBytes": resolution.estimatedInputBytes.map { ParameterValue.integer(Int($0)) } ?? .null,
            "clumpingPhysicalMemoryBytes": .integer(Int(resolution.physicalMemoryBytes)),
            "clumpingThresholdBytes": resolution.thresholdBytes.map { ParameterValue.integer(Int($0)) } ?? .null,
            "clumpingResolutionReason": .string(resolution.reason),
        ]
    }
}
