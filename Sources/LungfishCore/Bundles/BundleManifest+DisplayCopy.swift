// BundleManifest+DisplayCopy.swift - A manifest copy for output that shows different alignment tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension BundleManifest {
    /// A copy for output with the given alignment tracks. It keeps the modified date and drops the cached browser summary,
    /// whose totals come from the stored track counts and would disagree with the tracks given. It is not for saving.
    public func displayingAlignments(_ tracks: [AlignmentTrackInfo]) -> BundleManifest {
        copy(alignments: tracks, browserSummary: .some(nil))
    }
}
