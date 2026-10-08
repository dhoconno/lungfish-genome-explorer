// OperationPreviewView+Fonts.swift - SF Mono fonts the operation previews keep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

extension OperationPreviewView {
    /// The SF Mono fonts the previews draw text in. Each preview view looks them up once and
    /// reuses them on every draw, see `DrawingFont.keptMonospaced(ofSize:weight:)`.
    struct Fonts {
        /// Read IDs in the text search preview.
        let readID = DrawingFont.keptMonospaced(ofSize: 10, weight: .medium)
        /// Barcode labels on the demultiplex preview's input reads.
        let barcodeLabel = DrawingFont.keptMonospaced(ofSize: 7, weight: .medium)
        /// The search pattern and the demultiplex preview's output bundle names.
        let emphasizedLabel = DrawingFont.keptMonospaced(ofSize: 10, weight: .semibold)
    }
}
