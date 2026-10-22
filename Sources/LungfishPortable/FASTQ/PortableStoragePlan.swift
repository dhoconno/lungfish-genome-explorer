// PortableStoragePlan.swift - The plan and argv of a storage clumpify run, which need no Mac service
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the storage step of an import decides before it launches anything, the layout plan of one input file and
/// the `clumpify.sh` argv, so the Mac import and a portable executor build the same run.
public enum PortableStoragePlan {

    /// How the storage clumpify run treats one input file's records.
    ///
    /// BBTools guesses the layout of a single file from its first read names
    /// when no `interleaved=` flag is given, and both guesses go wrong on real
    /// imports (verified against the managed BBTools 2026-09-25):
    ///
    /// - Mates that share one identical name (SRA dumps such as
    ///   `@SRR12486983.1 SRR12486983.1` twice, or bare `@frag1` twice) are not
    ///   recognised, so clumpify sorts every read on its own and splits
    ///   nearly every pair.
    /// - `/1` `/2` or Casava names are recognised, and clumpify then pairs
    ///   records by position; a file with an odd record count (a mixed file
    ///   of pairs plus merged reads, for example) silently loses its last
    ///   read.
    ///
    /// So the layout is always stated, and it is decided from the records by
    /// name (``FASTQPairInterleaver/countMixed(interleaved:)``) rather than
    /// from the recorded pairing mode, which a recipe or an explicit choice
    /// may set without the records alternating.
    package enum SingleFileClumpPlan: Equatable, Sendable {
        /// No record has its mate next to it: `interleaved=f`.
        case unpaired
        /// Every record is followed by its mate: `interleaved=t`.
        case interleaved
        /// Adjacent pairs mixed with unpaired reads: the pairs run with
        /// `interleaved=t` and the unpaired reads with `interleaved=f`.
        case splitMixed
    }

    package static func singleFileClumpPlan(for counts: FASTQPairInterleaver.MixedCounts) -> SingleFileClumpPlan {
        if counts.pairs == 0 { return .unpaired }
        if counts.unpaired == 0 { return .interleaved }
        return .splitMixed
    }

    /// The argv for one storage `clumpify.sh` run.
    ///
    /// `interleaved=` is always stated (see ``SingleFileClumpPlan``). A second
    /// input is an R2 file, which always means `interleaved=t` output.
    /// `outOfMemoryFlag` is the BBTools flag that ends the JVM at once when its heap runs out. The caller names it,
    /// since the out-of-memory contract of every BBTools launch lives with the launches.
    package static func clumpifyArguments(
        input: URL,
        input2: URL? = nil,
        output: URL,
        interleaved: Bool,
        heapGB: Int,
        threads: Int,
        qualityBinning: QualityBinningScheme,
        outOfMemoryFlag: String
    ) -> [String] {
        var args = [
            "in=\(input.path)",
            "out=\(output.path)",
            "-Xmx\(heapGB)g",
            outOfMemoryFlag,
            "ow=t",
            "reorder",
            "groups=auto",
            "pigz=t",
            "zl=4",
            "threads=\(max(1, threads))"
        ]
        if let input2 {
            args.append("in2=\(input2.path)")
        }
        args.append(input2 != nil || interleaved ? "interleaved=t" : "interleaved=f")
        if let quantize = quantizeArgument(for: qualityBinning) {
            args.append(quantize)
        }
        return args
    }

    /// The `quantize=` argument clumpify.sh and reformat.sh share for a scheme.
    package static func quantizeArgument(for scheme: QualityBinningScheme) -> String? {
        switch scheme {
        case .illumina4:
            return "quantize=0,8,13,22,27,32,37"
        case .eightLevel:
            return "quantize=2"
        case .none:
            return nil
        }
    }

    /// The bytes the inputs hold once decompressed, where a gzip file counts four times its size on disk.
    package static func estimatedUncompressedInputBytes(for urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int64 ?? 0
            let multiplier: Int64 = isGzipCompressed(url) ? 4 : 1
            return total + size * multiplier
        }
    }

    /// True when the file name ends in `.gz`, `.gzip` or `.bgz`.
    package static func isGzipCompressed(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".gz") || name.hasSuffix(".gzip") || name.hasSuffix(".bgz")
    }
}
