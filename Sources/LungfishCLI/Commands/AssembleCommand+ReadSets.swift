// AssembleCommand+ReadSets.swift - How `lungfish-cli assemble` states and reports the layout of its reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

extension AssembleCommand {

    /// The `--read-layout` values, mirroring `FASTQInputLayout` for one file
    /// (the same spellings `map --read-layout` accepts).
    enum AssembleReadLayoutArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
        case auto
        case singleEnd = "single-end"
        case interleaved
        case mixed

        /// The layout the caller stated, or `nil` for auto detection.
        var explicitLayout: FASTQInputLayout? {
            switch self {
            case .auto: return nil
            case .singleEnd: return .singleEnd
            case .interleaved: return .strictlyInterleaved
            case .mixed: return .mixedMergedAndPairs
            }
        }
    }

    /// Why an explicit `--read-layout` cannot apply, or `nil` when it can.
    static func validateReadLayoutOption(
        _ readLayout: AssembleReadLayoutArgument,
        tool: AssemblyTool,
        pairedEnd: Bool,
        inputCount: Int
    ) -> String? {
        guard readLayout != .auto else { return nil }
        if pairedEnd || inputCount != 1 {
            return "--read-layout describes one input file; use --paired for two R1/R2 files."
        }
        if !Self.shortReadTools.contains(tool), readLayout != .singleEnd {
            return "--read-layout \(readLayout.rawValue) applies to the short-read assemblers (spades, megahit, skesa); \(tool.displayName) assembles every record as a single read."
        }
        return nil
    }

    private static let shortReadTools: Set<AssemblyTool> = [.spades, .megahit, .skesa]

    /// The `Read layout` table row: the layout and where the answer came from.
    static func readLayoutDescription(
        for request: AssemblyRunRequest,
        resolution: FASTQInputLayoutResolution?
    ) -> String {
        guard let resolution else {
            return request.effectiveInputLayout.displayName
        }
        return "\(resolution.layout.displayName) (\(resolution.source.rawValue))"
    }

    /// A warning when the records hold mates the assembler will not pair.
    static func readLayoutWarning(
        for request: AssemblyRunRequest,
        resolution: FASTQInputLayoutResolution?
    ) -> String? {
        guard let resolution, resolution.layout == .mixedMergedAndPairs,
              request.readLayoutHandling == .asSingle,
              let inputURL = request.inputURLs.first else {
            return nil
        }
        return "\(inputURL.lastPathComponent) holds merged reads and pairs (\(resolution.reason)) "
            + "Every record is assembled as a single read so that mates are not paired by position."
    }
}
