// SequenceViewerView+Fonts.swift - SF Mono fonts the sequence viewer keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

extension SequenceViewerView {
    /// The SF Mono fonts the viewer draws base letters in. Each viewer looks them up once and
    /// reuses them on every draw, see `DrawingFont.keptMonospaced(ofSize:weight:)`.
    struct Fonts {
        /// Base letters on a bundle's reference and consensus rows.
        let bundleLetter = DrawingFont.keptMonospaced(ofSize: 12, weight: .medium)
        /// Base letters on loaded sequences, in one track or stacked, sized to the cell.
        let sequenceLetter = DrawingFont.KeptMonospacedFace(weight: .bold)
    }
}
