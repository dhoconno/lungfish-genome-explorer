// SalmonIndexNeed.swift - What one salmon index build asks of the Mac, and its fixed options (Phase 5.1 lane RS-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Every figure of a salmon index build, so a ruling changes one line. The memory and disk figures and the scaled need are
/// ADJ-SPIKE-ARCH items 1, 2 and 5, measured in SPIKE-SALMON. The memory figure is the footprint of the build at
/// `--ramLimit 16`, which bounds the build at 4 (15,681,106,880 bytes there), and its basis line says so. The options are
/// ADJ-SPIKE-ARCH item 6 and ADJ-SPIKE-BIO item 2: every build passes `-p 8 --ramLimit 4`, never chosen by the host's
/// memory or by the person, and neither is part of the cache key, since neither changes a byte of the index.
enum SalmonIndexNeed {
    /// `-p`. ADJ-SPIKE-BIO item 10: another thread count needs its three-build test first.
    static let threads = 8
    /// `--ramLimit`, in GiB. ADJ-SPIKE-BIO item 1: 1 and 16 gave byte-equal index files and `quant.sf`.
    static let ramLimitGiB = 4

    static let peakMemoryBytes: Int64 = 17_780_281_048
    static let memoryBasis = "peak memory footprint of salmon 2.11.0 index -k 31 -p 8 on GRCh38 with ERCC92 measured at "
        + "--ramLimit 16, which bounds the build at --ramLimit 4, SPIKE-SALMON 2026-11-14"
    static let freeDiskBytes: Int64 = 63_897_293_195
    static let diskBasis = "free-disk drop of that build plus its gentrome and the finished index, SPIKE-SALMON 2026-11-14"

    /// The gentrome of that build. A larger one is checked again once it is written, with the scaled need below.
    static let measuredGentromeBytes: Int64 = 3_522_342_234

    /// The need before any write, the same for every set.
    static func need(diskFolder: URL) -> RunFitNeed {
        RunFitNeed(
            peakMemoryBytes: peakMemoryBytes, memoryBasis: memoryBasis,
            freeDiskBytes: freeDiskBytes, diskBasis: diskBasis, diskFolder: diskFolder)
    }

    /// The need once the gentrome is written, nil when it is no larger than the measured one (ADJ-SPIKE-ARCH item 5).
    static func scaledNeed(gentromeBytes: Int64, diskFolder: URL) -> RunFitNeed? {
        guard gentromeBytes > measuredGentromeBytes else { return nil }
        return RunFitNeed(
            peakMemoryBytes: max(peakMemoryBytes, RunFitNeed.bytes(gentromeBytes, times: 5, plus: 168_569_878)),
            memoryBasis: memoryBasis + ", scaled as 5 times the gentrome plus 168,569,878 bytes",
            freeDiskBytes: max(freeDiskBytes, RunFitNeed.bytes(gentromeBytes, times: 18, plus: 495_132_983)),
            diskBasis: diskBasis + ", scaled as 18 times the gentrome plus 495,132,983 bytes",
            diskFolder: diskFolder)
    }
}
