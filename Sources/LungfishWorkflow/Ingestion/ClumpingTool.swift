// ClumpingTool.swift - FASTQ storage optimization tool selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable

public enum ClumpingTool: String, Codable, Sendable, CaseIterable {
    case auto
    case bbtools
    case trimGalore = "trim-galore"
    case none

    public static var `default`: ClumpingTool { .auto }

    public var displayName: String {
        switch self {
        case .auto:
            return "Automatic"
        case .bbtools:
            return "BBTools clumpify"
        case .trimGalore:
            return "Trim Galore --clumpify"
        case .none:
            return "Skip (compress only)"
        }
    }

    /// Disclosure shown when the selected tool performs filtering in addition to clumpify.
    public var importSheetDisclosure: String? {
        self == .trimGalore
            ? "Trim Galore also performs adapter detection/removal, quality trimming, and short-read filtering."
            : nil
    }

    /// Notice recorded immediately before a resolved storage-tool invocation.
    public var operationNotice: String? {
        self == .trimGalore
            ? "Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."
            : nil
    }

    public var isClumpingEnabled: Bool {
        self != .none
    }

    // MARK: - The one rule of `auto` (C5 O49, D5, D8 B)

    /// The reason of every `auto` that names clumpify, on the Mac's import and in a plan alike, never composed per
    /// sample. "The clumpify heap" is the heap a plan pins, and in an import this Mac's heap or the one
    /// `--clumpify-heap-gb` pins.
    public static let automaticClumpifyReason = "The automatic clumping choice names BBTools clumpify for every sample of short reads, at the clumpify heap and with no size estimate, because clumpify's groups=auto compares its memory estimate for each input with the memory available in that heap and splits a large input into more groups."
    /// The reason `auto` clumps nothing for ONT and PacBio reads. BBTools names a high error rate as clumpify's limit and
    /// says nothing of read length, so the sentence cites the error rate.
    public static let automaticLongReadReason = "The automatic clumping choice skips clumping for long reads, because clumpify works well only on accurate reads and long reads usually have a high error rate, so few of their k-mers are shared and reordering them saves little space. Name a clumping tool to clump them."
    /// The reason `auto` clumps nothing when the platform is Unknown, since the reads may be long.
    public static let automaticUnknownPlatformReason = "The automatic clumping choice skips clumping when the platform is Unknown, because the reads may be long reads with a high error rate, which clumpify does not reorder well. Name the platform or a clumping tool to clump them."
    /// The reason of a tool the user named.
    public static let explicitSelectionReason = "explicit clumping tool selection"

    /// What `auto` resolves to for reads of `platform`, platform first (D8 B). Short-read platforms clump with BBTools
    /// clumpify at the clumpify heap whatever the size, since clumpify splits a large input into more groups to fit the
    /// heap (D5). ONT, PacBio and Unknown clump nothing. A nil platform names none, so the platform restricts nothing and
    /// the rule clumps. The Mac's import, the plan emitter and both sheets call this one function.
    public static func automaticChoice(
        for platform: LungfishIO.SequencingPlatform?
    ) -> (tool: ClumpingTool, reason: String) {
        guard let platform, !platform.supportsStorageClumping else {
            return (.bbtools, automaticClumpifyReason)
        }
        return platform == .unknown
            ? (ClumpingTool.none, automaticUnknownPlatformReason)
            : (ClumpingTool.none, automaticLongReadReason)
    }

    /// What an import asks of the storage step: the tool the pipeline is asked for and whether it optimizes storage.
    /// `optimizeStorage == false` (`--no-optimize-storage`) stores without clumping. A tool the user named wins on every
    /// platform. Otherwise the request is `auto`, which also stands for nothing named, and `automaticChoice(for:)` says
    /// whether the platform clumps.
    public static func storageRequest(
        optimizeStorage: Bool?,
        tool: ClumpingTool?,
        platform: LungfishIO.SequencingPlatform?
    ) -> (tool: ClumpingTool, optimizeStorage: Bool) {
        if optimizeStorage == false { return (ClumpingTool.none, false) }
        if let tool, tool != .auto { return (tool, tool.isClumpingEnabled) }
        return (.auto, automaticChoice(for: platform).tool != ClumpingTool.none)
    }

    /// The tool this request runs for reads of `platform`. A heap `--clumpify-heap-gb` pins (`pinnedHeapGB`) replaces the
    /// host's. `auto` reads neither the input's size nor a threshold, so the resolution carries neither (D5), and the plan
    /// and the Mac's import record the same tool, source and reason. A named tool wins on every platform and keeps the
    /// size the caller measured.
    public func resolve(
        estimatedInputBytes: Int64,
        physicalMemoryBytes: Int64 = Int64(clamping: ProcessInfo.processInfo.physicalMemory),
        pinnedHeapGB: Int? = nil,
        platform: LungfishIO.SequencingPlatform? = nil
    ) -> ClumpingToolResolution {
        let memoryBytes = max(0, physicalMemoryBytes)
        let heapBytes = pinnedHeapGB.map { Int64(max(1, $0)) * 1_073_741_824 }
            ?? Self.clumpifyHeapBytes(physicalMemoryBytes: memoryBytes)

        let resolved: ClumpingTool
        let reason: String
        switch self {
        case .auto:
            let choice = Self.automaticChoice(for: platform)
            resolved = choice.tool
            reason = choice.reason
        case .bbtools, .trimGalore, .none:
            resolved = self
            reason = Self.explicitSelectionReason
        }

        let readsEstimate = self != .auto
        return ClumpingToolResolution(
            requested: self,
            resolved: resolved,
            estimatedInputBytes: readsEstimate ? estimatedInputBytes : nil,
            physicalMemoryBytes: memoryBytes,
            clumpifyHeapBytes: heapBytes,
            thresholdBytes: readsEstimate ? max(0, heapBytes / 2) : nil,
            reason: reason
        )
    }

    public static func clumpifyHeapBytes(physicalMemoryBytes: Int64) -> Int64 {
        let gib: Int64 = 1_073_741_824
        // This models a host of the given size, so the debug heap pin does not move it.
        let heapGB = ManagedJavaHeapPolicy.heapGB(
            physicalMemoryBytes: UInt64(max(0, physicalMemoryBytes)),
            availableMemoryBytes: nil,
            minimumGB: 4,
            environment: [:]
        )
        return Int64(heapGB) * gib
    }
}

public struct ClumpingToolResolution: Equatable, Sendable, Codable {
    public let requested: ClumpingTool
    public let resolved: ClumpingTool
    /// The input size the caller measured, nil when the choice read none: `auto` reads no estimate, so a plan and an
    /// import record none, and a record that holds no such key decodes it as nil, never 0.
    public let estimatedInputBytes: Int64?
    public let physicalMemoryBytes: Int64
    public let clumpifyHeapBytes: Int64
    /// Half the clumpify heap for a named tool, nil for `auto`, which compares nothing with it.
    public let thresholdBytes: Int64?
    public let reason: String

    /// `default` when the request was `auto` and the rule decided, `option` when the user named the tool. The heap keeps
    /// its own source, so this one never reads `host`.
    public var resolvedSource: ImportSettingSource {
        requested == .auto ? .default : .option
    }
}
