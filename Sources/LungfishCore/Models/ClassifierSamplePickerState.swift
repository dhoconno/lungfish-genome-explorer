// ClassifierSamplePickerState.swift — Unified picker state for all classifiers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Protocol for classifier-specific sample entries in the unified picker.
///
/// Each classifier provides a concrete type with its own metric (hit count,
/// read count, TASS score, etc.). The picker view renders `metricValue`
/// right-aligned next to each sample name.
public protocol ClassifierSampleEntry: Identifiable, Sendable where ID == String {
    var id: String { get }
    var displayName: String { get }
    /// Short label for the metric column header (e.g., "hits", "reads", "TASS").
    var metricLabel: String { get }
    /// Formatted metric value (e.g., "1,234").
    var metricValue: String { get }
    /// Optional secondary metric (e.g., NVD shows "contigs / hits").
    var secondaryMetric: String? { get }
}

/// Default implementation: no secondary metric.
extension ClassifierSampleEntry {
    public var secondaryMetric: String? { nil }
}

/// Observable state shared between the sample picker view, toolbar popover,
/// and Inspector embedding.
///
/// Uses `@Observable` instead of raw `Binding<Set<String>>` to ensure
/// SwiftUI views inside `NSHostingController` popovers correctly reflect
/// selection changes across the AppKit/SwiftUI boundary.
@Observable
public final class ClassifierSamplePickerState: @unchecked Sendable {
    public var selectedSamples: Set<String>

    public init(allSamples: Set<String>) {
        self.selectedSamples = allSamples
    }
}
