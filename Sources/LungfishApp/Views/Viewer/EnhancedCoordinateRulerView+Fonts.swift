// EnhancedCoordinateRulerView+Fonts.swift - Font lookup for the coordinate ruler
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

private let rulerFontLogger = Logger(subsystem: LogSubsystem.app, category: "EnhancedRuler")

extension EnhancedCoordinateRulerView {

    /// SF Mono at `size` and `weight`, for a font the ruler looks up once and keeps.
    ///
    /// `NSFont.monospacedSystemFont(ofSize:weight:)` is annotated non-null but
    /// can return nil. NSFont caches each typeface with only a weak reference
    /// to its font descriptor. The ruler used to make its SF Mono Medium fonts
    /// on every draw and drop them, so that descriptor kept going away, and on
    /// macOS 26 under heavy load the cached typeface outlived it for up to
    /// 220 ms. Every lookup in that window returned nil, and a nil font in a
    /// string drawing attribute dictionary makes CoreText raise
    /// NSInvalidArgumentException. In those windows the failable
    /// `NSFont(descriptor:size:)`, given a descriptor made here, still returned
    /// the font, and it reports a failure as nil instead. The user's
    /// fixed-pitch font then stands in for the life of the view.
    static func monospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.monospaced),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        rulerFontLogger.error(
            "SF Mono lookup failed for \(Double(size)) pt weight \(Double(weight.rawValue)), using the fixed-pitch user font"
        )
        return NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
}
