// ClassifierSamplePickerState+ViewMemory.swift - What a sample picker remembers, by sample id
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A sample choice saved as ids (VS B5).
///
/// The picker state holds only the selection, so a caller names every sample when it captures,
/// and the memory keeps whether the choice was every sample. A choice of every sample then
/// follows the samples that exist at the next visit, and a later sample is not hidden.
public struct SamplePickerMemory: Codable, Sendable, Equatable {
    /// The selected sample ids, sorted so equal choices encode alike.
    public var selectedSampleIDs: [String]
    /// True when every sample was selected.
    public var wasAllSamples: Bool

    public init(selectedSampleIDs: [String], wasAllSamples: Bool) {
        self.selectedSampleIDs = selectedSampleIDs
        self.wasAllSamples = wasAllSamples
    }
}

extension ClassifierSamplePickerState {
    /// Copies the selection as sample ids. `allSampleIDs` are the samples on show now.
    public func captureViewMemory(allSampleIDs: Set<String>) -> SamplePickerMemory {
        let selected = selectedSamples
        return SamplePickerMemory(
            selectedSampleIDs: selected.sorted(),
            wasAllSamples: !allSampleIDs.isEmpty && selected.isSuperset(of: allSampleIDs)
        )
    }

    /// Intersects the saved choice with `currentSampleIDs` and selects the result.
    ///
    /// An empty intersection selects every sample, never an empty set (VS B5). The result tells
    /// the adopter whether some saved samples are gone (`droppedCount`, `fellBackToAll`) and
    /// whether the picker now acts as a filter (`isSubset`), which a viewport that shows the
    /// picker only in the Inspector must show in view (word 5).
    @discardableResult
    public func applyViewMemory(
        _ memory: SamplePickerMemory,
        currentSampleIDs: Set<String>
    ) -> ViewMemorySampleRestore {
        let restore = ViewMemoryRules.restoreSamples(
            saved: memory.selectedSampleIDs,
            savedWasAllSamples: memory.wasAllSamples,
            current: currentSampleIDs
        )
        selectedSamples = restore.selected
        return restore
    }
}
