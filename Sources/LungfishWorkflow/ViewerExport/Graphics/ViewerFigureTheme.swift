// ViewerFigureTheme.swift - Fixed sRGB colours for viewer figures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// The appearance a figure is drawn in.
public enum ViewerFigureAppearance: String, Sendable, Hashable, Codable, CaseIterable {
    case light
    case dark
}

/// One colour as sRGB components from 0 to 1.
public struct ViewerFigureColor: Sendable, Hashable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// The same colour with its alpha replaced, as `NSColor.withAlphaComponent(_:)` replaces it.
    public func withAlpha(_ alpha: Double) -> ViewerFigureColor {
        ViewerFigureColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The colour in the sRGB space, the one space a figure draws in.
    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// What a colour is for. A scene names a role and never a colour, so one scene draws in either
/// appearance.
///
/// The system roles carry the name of the AppKit colour the live viewer draws with, so code that
/// moves into this folder swaps `NSColor.secondaryLabelColor` for `.secondaryLabel`. Add a role
/// with its two values below and its live colour in `ViewerFigureThemeParityTests`, and never
/// change the value of a role a figure already uses.
public enum ViewerFigureColorRole: String, Sendable, Hashable, Codable, CaseIterable {
    /// `NSColor.textBackgroundColor`, the track area of the sequence viewer.
    case textBackground
    /// `NSColor.windowBackgroundColor`, the ruler band.
    case windowBackground
    /// `NSColor.separatorColor`, borders and the ruler's bottom line.
    case separator
    /// `NSColor.labelColor`, ruler labels and primary text.
    case label
    /// `NSColor.secondaryLabelColor`, major ticks and secondary text.
    case secondaryLabel
    /// `NSColor.tertiaryLabelColor`, minor ticks and faint text.
    case tertiaryLabel
    /// `NSColor.systemGray`, the sequence line when bases are too small to draw.
    case systemGray
    /// `NSColor.white`, letters drawn on a coloured base or feature.
    case textOnColor
    /// `BaseColors.A` of the live viewer.
    case baseA
    /// `BaseColors.C` of the live viewer.
    case baseC
    /// `BaseColors.G` of the live viewer.
    case baseG
    /// `BaseColors.T` of the live viewer, also used for U.
    case baseT
    /// `BaseColors.N` of the live viewer, also used for any other letter.
    case baseN
}

/// The colours of a figure in one appearance, fixed sRGB values and never a dynamic colour.
///
/// The values were measured from the live viewer's colours on macOS 26, resolved under the Aqua
/// and Dark Aqua appearances and converted to sRGB, and rounded to four places.
/// `ViewerFigureThemeParityTests` in LungfishAppWorkflowTests measures them again. The base
/// colours are the live `NSColor(calibratedRed:...)` values converted to sRGB, which is what the
/// viewer shows, rather than the calibrated components themselves.
public struct ViewerFigureTheme: Sendable, Hashable, Codable {
    public let appearance: ViewerFigureAppearance

    public init(appearance: ViewerFigureAppearance) {
        self.appearance = appearance
    }

    public static let light = ViewerFigureTheme(appearance: .light)
    public static let dark = ViewerFigureTheme(appearance: .dark)

    /// The colour of a role in this theme's appearance.
    public func color(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        switch appearance {
        case .light: Self.lightColor(role)
        case .dark: Self.darkColor(role)
        }
    }

    private static func lightColor(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        switch role {
        case .textBackground: ViewerFigureColor(white: 1)
        case .windowBackground: ViewerFigureColor(white: 1)
        case .separator: ViewerFigureColor(white: 0, alpha: 0.098)
        case .label: ViewerFigureColor(white: 0, alpha: 0.8471)
        case .secondaryLabel: ViewerFigureColor(white: 0, alpha: 0.498)
        case .tertiaryLabel: ViewerFigureColor(white: 0, alpha: 0.2588)
        case .systemGray: ViewerFigureColor(red: 0.5569, green: 0.5569, blue: 0.5765)
        case .textOnColor: Self.white
        case .baseA: Self.baseA
        case .baseC: Self.baseC
        case .baseG: Self.baseG
        case .baseT: Self.baseT
        case .baseN: Self.baseN
        }
    }

    private static func darkColor(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        switch role {
        case .textBackground: ViewerFigureColor(white: 0.1176)
        case .windowBackground: ViewerFigureColor(white: 0.1176)
        case .separator: ViewerFigureColor(white: 1, alpha: 0.098)
        case .label: ViewerFigureColor(white: 1, alpha: 0.8471)
        case .secondaryLabel: ViewerFigureColor(white: 1, alpha: 0.549)
        case .tertiaryLabel: ViewerFigureColor(white: 1, alpha: 0.2471)
        case .systemGray: ViewerFigureColor(red: 0.5961, green: 0.5961, blue: 0.6157)
        case .textOnColor: Self.white
        case .baseA: Self.baseA
        case .baseC: Self.baseC
        case .baseG: Self.baseG
        case .baseT: Self.baseT
        case .baseN: Self.baseN
        }
    }

    // Colours that are the same in both appearances.
    private static let white = ViewerFigureColor(white: 1)
    private static let baseA = ViewerFigureColor(red: 0, green: 0.8178, blue: 0)
    private static let baseC = ViewerFigureColor(red: 0.0113, green: 0.1593, blue: 0.8386)
    private static let baseG = ViewerFigureColor(red: 1, green: 0.7473, blue: 0)
    private static let baseT = ViewerFigureColor(red: 0.8467, green: 0.1176, blue: 0)
    private static let baseN = ViewerFigureColor(white: 0.6003)

    /// The colour role of a base letter, as `BaseColors.color(for:)` picks it.
    public static func baseRole(for base: Character) -> ViewerFigureColorRole {
        switch base.uppercased().first {
        case "A": .baseA
        case "C": .baseC
        case "G": .baseG
        case "T", "U": .baseT
        default: .baseN
        }
    }
}
