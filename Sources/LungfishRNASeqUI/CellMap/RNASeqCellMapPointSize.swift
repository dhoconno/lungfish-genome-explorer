// RNASeqCellMapPointSize.swift - The point size control of the cell-map view, LungfishKit's shared slider in a hosting view (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The point size is presentation that the cell map's view memory keeps, clamped to 1 to 8 pt, and gives back on any
// data key (VS-RNA, `RNASeqCellMapViewController+ViewMemory.swift`). Every slider in LGE is the shared control of
// LungfishKit (the shared-slider-control ratchet), so the size is an InlineNumericSliderField, a slider with a number
// field for a typed size, in a hosting view in the control row. The model holds the one value that SwiftUI observes.
// What the slider or the field writes goes to the controller's `choosePointSize(_:)`, which clamps it, shows it here and
// draws the cells again, so a size set from code reaches the slider and the field the same way.

import LungfishKit
import SwiftUI

@MainActor @Observable
final class RNASeqCellMapPointSizeModel {
    /// The size on show. The controller reads it for the raster and SwiftUI observes it.
    private(set) var value = RNASeqCellMapViewController.defaultPointSize
    private let choose: @MainActor (Double) -> Void

    init(choose: @escaping @MainActor (Double) -> Void) { self.choose = choose }

    /// What the slider and the number field write. A size already on show is not chosen again.
    var written: Double {
        get { value }
        set { if newValue != value { choose(newValue) } }
    }

    /// Shows a size that the controller has taken.
    func show(_ size: Double) { value = size }
}

/// The slider and the number field of the point size, 1 to 8 pt. The step is a whole point, since a half point draws no
/// disc that a whole point does not.
struct RNASeqCellMapPointSizeControl: View {
    static let title = "Point size"
    static let accessibilityID = "rnaseq-cell-map-point-size"
    @Bindable var model: RNASeqCellMapPointSizeModel

    var body: some View {
        InlineNumericSliderField(
            accessibilityTitle: Self.title, value: $model.written, in: RNASeqCellMapViewController.pointSizes, step: 1,
            suffix: "pt", sliderIdentifier: Self.accessibilityID, sliderMaxWidth: 140)
    }
}
