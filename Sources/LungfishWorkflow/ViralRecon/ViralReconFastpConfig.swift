// ViralReconFastpConfig.swift - The fastp arguments LGE gives viralrecon's FASTP step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The fastp arguments of viralrecon's FASTP step for a single-end sample (ruling BIO-THREE-ROWS, items 8-11).
package enum ViralReconFastpConfig {
    /// viralrecon 3.0.0's own FASTP `ext.args`, `conf/modules_illumina.config:75` at the pinned revision, word for word.
    package static let viralReconArguments = "--cut_front --cut_tail --trim_poly_x --cut_mean_quality 30 "
        + "--qualified_quality_phred 30 --unqualified_percent_limit 10 --length_required 50"

    /// The words of `ext.args` for a single-end sample.
    package static func singleEndArguments(adapters: FastpPairedRunner.SingleReadAdapters) -> [String] {
        viralReconArguments.split(separator: " ").map(String.init)
    }
}
