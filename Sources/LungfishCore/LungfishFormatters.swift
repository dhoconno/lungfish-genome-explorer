// Formatters.swift - Shared byte/count/duration formatting helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Shared human-readable formatting helpers for byte counts, integer counts,
/// and durations.
///
/// These were previously duplicated across many LungfishApp view/view-model
/// files with divergent output formats (see repo audit findings F44/F45/F46).
/// This type consolidates them into single canonical implementations so file
/// sizes, counts, and elapsed times render consistently across the app.
///
/// All members are plain, side-effect-free functions and safe to call from
/// any isolation domain (including `@Sendable` view-body closures).
public enum LungfishFormatters {
    /// Formats a byte count as a human-readable file-size string (e.g. "512 KB", "4.2 MB").
    ///
    /// This is the majority format used across the app: a thin wrapper around
    /// `ByteCountFormatter`'s `string(fromByteCount:countStyle:)` class method
    /// with `countStyle = .file`. Uses the static convenience method (round-2
    /// structural backlog, C1 test-tightening batch) rather than allocating
    /// and caching an instance: `ByteCountFormatter` is not `Sendable`, so a
    /// shared cached instance would need `nonisolated(unsafe)` (or actor
    /// isolation) to pass strict-concurrency checking under Swift 6, while
    /// the class method carries no shared mutable state and needs neither.
    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Formats a byte count as a human-readable file-size string.
    ///
    /// Convenience overload for `UInt64` byte counts (clamped to `Int64.max`).
    public static func formatBytes(_ bytes: UInt64) -> String {
        formatBytes(Int64(clamping: bytes))
    }

    /// Formats an integer count with locale-aware thousands separators (e.g. "1,234").
    public static func formatGroupedCount(_ count: Int) -> String {
        Self.groupedCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// Formats an integer count with K/M abbreviation suffixes (e.g. "1.2K", "3.4M").
    ///
    /// Values under 1,000 are rendered as plain integers.
    public static func formatAbbreviatedCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// Formats an integer count with K/M abbreviation suffixes (e.g. "1.2K", "3.4M").
    ///
    /// `Int64` convenience overload.
    public static func formatAbbreviatedCount(_ count: Int64) -> String {
        formatAbbreviatedCount(Int(clamping: count))
    }

    /// Formats a time interval into a compact human-readable elapsed-time string.
    ///
    /// Formatting tiers:
    /// - Less than 1 second: `"<1s"`
    /// - 1-59 seconds: `"42s"`
    /// - 1-59 minutes: `"3m 12s"`
    /// - 1 hour or more: `"1h 23m"`
    ///
    /// Negative intervals are clamped to zero and displayed as `"<1s"`.
    public static func formatDuration(_ interval: TimeInterval) -> String {
        let elapsed = max(0, interval)
        if elapsed < 1 { return "<1s" }
        let totalSeconds = Int(elapsed)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private static let groupedCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
