// ClumpingTool.swift - FASTQ storage optimization tool selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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

    public func resolve(
        estimatedInputBytes: Int64,
        physicalMemoryBytes: Int64 = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    ) -> ClumpingToolResolution {
        let memoryBytes = max(0, physicalMemoryBytes)
        let heapBytes = Self.clumpifyHeapBytes(physicalMemoryBytes: memoryBytes)
        let thresholdBytes = max(0, heapBytes / 2)

        let resolved: ClumpingTool
        let reason: String
        switch self {
        case .auto:
            if estimatedInputBytes <= thresholdBytes {
                resolved = .bbtools
                reason = "estimated input is within the BBTools clumpify memory budget"
            } else {
                resolved = .trimGalore
                reason = "estimated input may cause BBTools clumpify memory pressure"
            }
        case .bbtools, .trimGalore, .none:
            resolved = self
            reason = "explicit clumping tool selection"
        }

        return ClumpingToolResolution(
            requested: self,
            resolved: resolved,
            estimatedInputBytes: estimatedInputBytes,
            physicalMemoryBytes: memoryBytes,
            clumpifyHeapBytes: heapBytes,
            thresholdBytes: thresholdBytes,
            reason: reason
        )
    }

    public static func clumpifyHeapBytes(physicalMemoryBytes: Int64) -> Int64 {
        let gib: Int64 = 1_073_741_824
        let physicalMemoryGB = max(0, physicalMemoryBytes / gib)
        let heapGB = max(4, min(31, physicalMemoryGB * 60 / 100))
        return heapGB * gib
    }
}

public struct ClumpingToolResolution: Equatable, Sendable, Codable {
    public let requested: ClumpingTool
    public let resolved: ClumpingTool
    public let estimatedInputBytes: Int64
    public let physicalMemoryBytes: Int64
    public let clumpifyHeapBytes: Int64
    public let thresholdBytes: Int64
    public let reason: String
}
