// ReferenceBundleViewportController+Removal.swift - What a viewport stops when the surface host takes it away
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReferenceBundleViewportController {
    /// Runs on every removal, whatever replaces the viewport. A person's filter may still reach this viewport through the
    /// Inspector's last block, and `deinit` runs only once nothing holds it, so the refresh and its samtools children stop here.
    /// This touches only state the viewport owns, sets no flag and cancels no `OperationCenter` row, so a running job
    /// (Extract Reads, variant calling, mark duplicates) keeps running and reports as before.
    func stopWorkForRemoval() {
        alignmentTrackSummaryRefreshID = UUID()
        mappingRowsRefreshTask?.cancel()
        mappingRowsRefreshTask = nil
        openProgress.pendingViewerOpen = nil
        clearAlignmentActionContext()
        installSampleMetadataPresentation(nil)
    }
}
