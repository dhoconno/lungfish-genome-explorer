// MappingTool+ReadLayout.swift - What each mapper does with interleaved, mixed, and paired input
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Verified against the installed tools on 2026-09-24 (bwa-mem2 2.2.1,
// bowtie2 2.5.5, minimap2 2.31, BBMap 40.02) with synthetic files whose mates
// were named identically, with /1 /2, and with Casava descriptions, plus a
// mixed file of merged single reads and interleaved pairs:
//
// - bwa-mem2 `-p`: pairs adjacent same-name records and leaves the rest
//   single (mixed: 40 paired + 10 single, all proper). Without `-p` every
//   record is single-end, whatever the names.
// - bowtie2 `--interleaved`: pairs records blindly by position, so a mixed
//   file mis-pairs (50 flagged paired, only 32 proper) and a single-end file
//   is flagged paired. Strict input pairs correctly for all three namings.
// - minimap2 `-x sr`: fragment mode pairs adjacent same-name records and
//   leaves the rest single, like bwa-mem2 `-p`. Other presets never pair.
// - BBMap `interleaved=auto` (the default) pairs /1 /2 and Casava names but
//   NOT identical names; `interleaved=t` pairs identical names correctly but,
//   like bowtie2, pairs a mixed or single-end file blindly by position.

import Foundation
import LungfishIO

public extension MappingTool {
    /// The mapper's declared handling for every ``FASTQInputLayout``.
    var fastqConsumerDeclaration: FASTQConsumerDeclaration {
        switch self {
        case .minimap2:
            return FASTQConsumerDeclaration(
                consumerID: "map.minimap2",
                displayName: "minimap2 (short-read preset)",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "`-x sr` fragment mode pairs adjacent same-name records and maps the merged reads as single reads; no flag is needed. Long-read and assembly presets map every record as single."
            )
        case .bwaMem2:
            return FASTQConsumerDeclaration(
                consumerID: "map.bwa-mem2",
                displayName: "BWA-MEM2",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asPairs,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "`-p` smart pairing pairs adjacent same-name records and maps the merged reads as single reads."
            )
        case .bowtie2:
            return FASTQConsumerDeclaration(
                consumerID: "map.bowtie2",
                displayName: "Bowtie2",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "`--interleaved` pairs records by position and mis-pairs a file that holds merged reads, so mixed input runs through `-U` as single reads."
            )
        case .bbmap:
            return FASTQConsumerDeclaration(
                consumerID: "map.bbmap",
                displayName: "BBMap",
                handling: [
                    .singleEnd: .asSingle,
                    .strictlyInterleaved: .asPairs,
                    .mixedMergedAndPairs: .asSingle,
                    .pairedFiles: .asPairs,
                ],
                mixedRationale: "`interleaved=t` pairs records by position and mis-pairs a file that holds merged reads, so mixed input runs with `interleaved=f` as single reads."
            )
        }
    }
}

/// The layout decision recorded for one mapping run: the resolved input
/// layout and the handling the mapper applied to it.
public struct MappingReadLayoutPlan: Sendable, Equatable {
    public let layout: FASTQInputLayout
    public let handling: FASTQReadLayoutHandling

    public init(layout: FASTQInputLayout, handling: FASTQReadLayoutHandling) {
        self.layout = layout
        self.handling = handling
    }

    /// The handling `tool` applies to `layout` in `modeID`.
    ///
    /// minimap2 only pairs adjacent records in fragment mode, which the
    /// short-read preset enables; every other preset maps single reads, so
    /// the plan says so instead of claiming pairs the BAM will not have.
    public static func resolve(tool: MappingTool, modeID: String, layout: FASTQInputLayout) -> MappingReadLayoutPlan {
        var handling = tool.fastqConsumerDeclaration.handling(for: layout)
        if tool == .minimap2, modeID != MappingMode.defaultShortRead.id, layout != .pairedFiles {
            handling = .asSingle
        }
        return MappingReadLayoutPlan(layout: layout, handling: handling)
    }

    /// Whether the mapper receives mates as pairs under this plan.
    public var pairsMates: Bool {
        layout.holdsPairs && handling != .asSingle
    }

    /// The Run Settings "Paired End" value for this plan.
    public var pairedEndDescription: String {
        switch (layout, handling) {
        case (.pairedFiles, .asSingle):
            return "No (R1/R2 files mapped as single-end)"
        case (.pairedFiles, _):
            return "Yes"
        case (.strictlyInterleaved, .asSingle):
            return "No (interleaved input mapped as single-end)"
        case (.strictlyInterleaved, _):
            return "Yes (interleaved)"
        case (.mixedMergedAndPairs, .asSingle):
            return "No (mixed merged reads and pairs mapped as single-end)"
        case (.mixedMergedAndPairs, _):
            return "Yes (interleaved; merged reads mapped as single reads)"
        case (.singleEnd, _):
            return "No"
        }
    }
}
