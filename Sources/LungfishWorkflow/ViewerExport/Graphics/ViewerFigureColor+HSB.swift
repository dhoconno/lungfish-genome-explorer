// ViewerFigureColor+HSB.swift - Hue, saturation and brightness as an sRGB figure colour
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ViewerFigureColor {
    /// The sRGB colour of a hue, saturation and brightness, each from 0 to 1, as
    /// `NSColor(hue:saturation:brightness:alpha:)` gives it. The read track colours its read
    /// groups with evenly spaced hues, and `ReadGroupHueParityTests` checks the values against
    /// AppKit.
    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let scaled = (hue - hue.rounded(.down)) * 6
        let sector = Int(scaled.rounded(.down)) % 6
        let fraction = scaled - scaled.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let components: (Double, Double, Double)
        switch sector {
        case 0: components = (brightness, t, p)
        case 1: components = (q, brightness, p)
        case 2: components = (p, brightness, t)
        case 3: components = (p, q, brightness)
        case 4: components = (t, p, brightness)
        default: components = (brightness, p, q)
        }
        self.init(red: components.0, green: components.1, blue: components.2, alpha: alpha)
    }
}
