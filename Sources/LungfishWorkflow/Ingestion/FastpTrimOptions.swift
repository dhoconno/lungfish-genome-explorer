// FastpTrimOptions.swift - The one fastp argv for a trim, shared by the CLI and the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli fastq trim` (which the Reads menu launches) and the
// in-process trims the window runs for import recipes and batch
// derivatives used to build their fastp arguments separately: the window
// added `-w <cores>` and disabled adapter trimming for a FASTA adapter
// list, the CLI did neither. The four operations are described once here
// and rendered by one function, so the same request gives the same argv
// on both paths, which the parity tests assert.

import Foundation
import LungfishIO

/// One of the four fastp trims, with the settings that reach fastp.
public enum FastpTrimOperation: Equatable, Sendable {
    /// Adapter and sliding-window quality trimming in one pass
    /// (`lungfish-cli fastq trim`, the window's fastpTrim).
    case combined(threshold: Int, window: Int, mode: FASTQQualityTrimMode, adapterTrimming: Bool, adapterSequence: String?)
    /// Sliding-window quality trimming only.
    case quality(threshold: Int, window: Int, mode: FASTQQualityTrimMode)
    /// Adapter trimming only: auto-detected when every field is nil.
    case adapter(sequence: String?, sequenceR2: String?, adapterFastaPath: String?)
    /// A fixed number of bases off each end.
    case fixed(front: Int, tail: Int)

    /// Whether a paired run should add `--detect_adapter_for_pe`, so paired
    /// input gets the adapter auto-detection single-end input gets by
    /// default, on top of overlap analysis.
    public var detectsPairedAdapters: Bool {
        switch self {
        case .combined(_, _, _, let adapterTrimming, let adapterSequence):
            return adapterTrimming && adapterSequence == nil
        case .adapter(let sequence, let sequenceR2, let adapterFastaPath):
            return sequence == nil && sequenceR2 == nil && adapterFastaPath == nil
        case .quality, .fixed:
            return false
        }
    }

    /// The label the failure message and provenance steps carry.
    public var failureLabel: String {
        switch self {
        case .combined: return "fastp combined trim"
        case .quality: return "fastp quality trim"
        case .adapter: return "fastp adapter trim"
        case .fixed: return "fastp fixed trim"
        }
    }

    /// The `lungfish fastq` subcommand that runs this operation.
    public var subcommandName: String {
        switch self {
        case .combined: return "trim"
        case .quality: return "quality-trim"
        case .adapter: return "adapter-trim"
        case .fixed: return "fixed-trim"
        }
    }
}

public enum FastpTrimOptions {
    /// fastp worker threads: every core, capped at fastp's own maximum of 16.
    public static let defaultThreadCount = min(max(1, ProcessInfo.processInfo.activeProcessorCount), 16)

    /// The fastp arguments other than the input and output flags, in the
    /// order both the CLI and the window pass them.
    public static func options(
        for operation: FastpTrimOperation,
        threads: Int = defaultThreadCount,
        extraArguments: [String] = []
    ) -> [String] {
        var args = ["-w", String(threads)]
        switch operation {
        case .combined(let threshold, let window, let mode, let adapterTrimming, let adapterSequence):
            args += ["-W", String(window), "-M", String(threshold)]
            args += reportSuppression
            if !adapterTrimming {
                args.append("--disable_adapter_trimming")
            } else if let adapterSequence {
                args += ["--adapter_sequence", adapterSequence]
            }
            args += cutFlags(for: mode)
        case .quality(let threshold, let window, let mode):
            args += ["-W", String(window), "-M", String(threshold), "--disable_adapter_trimming"]
            args += reportSuppression
            args += cutFlags(for: mode)
        case .adapter(let sequence, let sequenceR2, let adapterFastaPath):
            args += reportSuppression
            if let sequence {
                args += ["--adapter_sequence", sequence]
            }
            if let sequenceR2 {
                args += ["--adapter_sequence_r2", sequenceR2]
            }
            if let adapterFastaPath {
                args += ["--adapter_fasta", adapterFastaPath]
            }
        case .fixed(let front, let tail):
            args.append("--disable_adapter_trimming")
            args += reportSuppression
            if front > 0 { args += ["--trim_front1", String(front)] }
            if tail > 0 { args += ["--trim_tail1", String(tail)] }
        }
        return args + extraArguments
    }

    /// Quality and length filtering stay off (a trim changes bases, never
    /// drops reads by its own rules) and the reports go nowhere.
    private static let reportSuppression = [
        "--disable_quality_filtering",
        "--disable_length_filtering",
        "--json", "/dev/null",
        "--html", "/dev/null",
    ]

    private static func cutFlags(for mode: FASTQQualityTrimMode) -> [String] {
        switch mode {
        case .cutRight: return ["--cut_right"]
        case .cutFront: return ["--cut_front"]
        case .cutTail: return ["--cut_tail"]
        case .cutBoth: return ["--cut_front", "--cut_right"]
        }
    }
}

extension FASTQQualityTrimMode {
    /// The `--mode` spelling of the CLI (`cut-right`, `cut-front`,
    /// `cut-tail`, `cut-both`).
    public var cliToken: String {
        switch self {
        case .cutRight: return "cut-right"
        case .cutFront: return "cut-front"
        case .cutTail: return "cut-tail"
        case .cutBoth: return "cut-both"
        }
    }

    public init?(cliToken: String) {
        guard let mode = Self.allCases.first(where: { $0.cliToken == cliToken }) else { return nil }
        self = mode
    }

    public static var cliTokens: [String] {
        allCases.map(\.cliToken)
    }
}
