// FASTQLengthFilterPlan.swift - The one length-filter command for the CLI and the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli fastq length-filter` ran `seqkit seq -m/-M` on whatever it
// was given, so on interleaved input it dropped mates one at a time: on
// the HG002 chr20 fixture (91,148 reads) a --min 50 filter after trimming
// left 1,856 orphaned reads, and only 20,993 adjacent records still
// formed a pair. The window's in-process filter already ran bbduk with
// `interleaved=t`, which keeps or drops both mates together
// (`removeifeitherbad=t`, its default). Both now render their command
// from this plan: bbduk for interleaved input, seqkit for single reads.

import Foundation
import LungfishPortable

public struct FASTQLengthFilterPlan: Equatable, Sendable {
    /// `bbduk` for a pair-aware run, `seqkit` for single reads.
    public let tool: NativeTool
    /// The argv without the executable.
    public let arguments: [String]

    /// seqkit worker threads (`-j`): every core.
    public static let defaultThreadCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    /// bbduk needs its BBTools environment and more time than seqkit.
    public var isPairAware: Bool { tool == .bbduk }

    /// The wall-clock limit of the run, none unless the person set one with `--time-limit`. The bbduk and the
    /// seqkit form read the one limit of the run (`AnalysisTimeLimit`).
    public var timeout: TimeInterval { AnalysisTimeLimit.launchTimeout }

    /// The command as the operation log shows it.
    public var toolCommand: String {
        ([tool.executableName] + arguments).joined(separator: " ")
    }

    /// - Parameters:
    ///   - pairAware: `true` when adjacent records are mates that must be
    ///     kept or dropped together. Only a strictly interleaved input may
    ///     ask for it: bbduk pairs by position, so a file that mixes merged
    ///     reads with pairs runs as single reads.
    public static func make(
        inputPath: String,
        outputPath: String,
        minLength: Int?,
        maxLength: Int?,
        pairAware: Bool,
        threads: Int = defaultThreadCount
    ) -> FASTQLengthFilterPlan {
        if pairAware {
            var args = [
                "in=\(inputPath)",
                "out=\(outputPath)",
                "interleaved=t",
            ]
            if let minLength {
                args.append("minlen=\(minLength)")
            }
            if let maxLength {
                args.append("maxlen=\(maxLength)")
            }
            args += BBToolsQualityArguments.keepEveryScore
            return FASTQLengthFilterPlan(tool: .bbduk, arguments: args)
        }
        var args = ["seq", "-j", String(threads)]
        if let minLength { args += ["-m", String(minLength)] }
        if let maxLength { args += ["-M", String(maxLength)] }
        args += [inputPath, "-o", outputPath]
        return FASTQLengthFilterPlan(tool: .seqkit, arguments: args)
    }
}
