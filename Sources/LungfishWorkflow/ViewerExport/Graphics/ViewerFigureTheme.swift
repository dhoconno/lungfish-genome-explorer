// ViewerFigureTheme.swift - Fixed sRGB colours for viewer figures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import LungfishCore

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

    /// An sRGB `HexColor` of LungfishCore, such as a `SemanticColors` entry.
    public init(_ hex: HexColor) {
        self.init(red: hex.red, green: hex.green, blue: hex.blue, alpha: hex.alpha)
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

    // Roles of the read and variant track renderers (lane 13.29). The fixed ones carry the name
    // of the renderer constant they replace and hold one value in both appearances.

    /// `NSColor.controlBackgroundColor`, the masked-column veil of the read track.
    case controlBackground
    /// `NSColor.quaternarySystemFill`, the read overflow bar.
    case quaternarySystemFill
    /// `ReadTrackRenderer.forwardReadColor`.
    case forwardRead
    /// `ReadTrackRenderer.forwardReadStroke`.
    case forwardReadStroke
    /// `ReadTrackRenderer.reverseReadColor`.
    case reverseRead
    /// `ReadTrackRenderer.reverseReadStroke`.
    case reverseReadStroke
    /// `ReadTrackRenderer.forwardCoverageColor`, also the depth area and legend key.
    case forwardCoverage
    /// `ReadTrackRenderer.reverseCoverageColor`.
    case reverseCoverage
    /// `ReadTrackRenderer.matchDotColor`.
    case matchDot
    /// `ReadTrackRenderer.insertionColor`, ticks and insertion labels.
    case insertion
    /// `ReadTrackRenderer.deletionColor`, `NSColor.gray`.
    case deletion
    /// `ReadTrackRenderer.softClipColor`.
    case softClip
    /// `ReadTrackRenderer.insertNormalColor`.
    case insertNormal
    /// `ReadTrackRenderer.insertTooSmallColor`.
    case insertTooSmall
    /// `ReadTrackRenderer.insertTooLargeColor`.
    case insertTooLarge
    /// `ReadTrackRenderer.insertInterchromosomalColor`.
    case insertInterchromosomal
    /// `ReadTrackRenderer.insertAbnormalOrientationColor`.
    case insertAbnormalOrientation
    /// `ReadTrackRenderer.firstInPairColor`.
    case firstInPair
    /// `ReadTrackRenderer.secondInPairColor`.
    case secondInPair
    /// `ReadTrackRenderer.splitReadColor`.
    case splitRead
    /// `NSColor(white: 0.33, alpha: 1)`, the coverage outline.
    case coverageOutline
    /// `NSColor(white: 0.25, alpha: 1)`, the depth legend key's border.
    case coverageLegendStroke
    /// The forward read background of the base tier, `NSColor(red: 0.84, green: 0.89, blue: 0.95)`.
    case baseReadForwardBackground
    /// The reverse read background of the base tier, `NSColor(red: 0.95, green: 0.86, blue: 0.86)`.
    case baseReadReverseBackground
    /// The neutral read background of the base tier, `NSColor(red: 0.90, green: 0.90, blue: 0.90)`.
    case baseReadNeutralBackground
    /// The neutral read border of the base tier, `NSColor(red: 0.72, green: 0.72, blue: 0.72)`.
    case baseReadNeutralStroke
    /// `ReadTrackRenderer.intronColor`.
    case intron
    /// `NSColor(white: 0.6, alpha: 0.4)`, the line between mates.
    case mateLink
    /// `VariantTrackRenderer.gutterBackgroundColor`.
    case variantGutterBackground
    /// `VariantTrackRenderer.gutterSeparatorColor`.
    case variantGutterSeparator
    /// `VariantTrackRenderer.dataAreaBackgroundColor`.
    case variantDataBackground
    /// `VariantTrackRenderer.summaryBorderColor`.
    case variantSummaryBorder
    /// `VariantTrackRenderer.rowSeparatorColor`.
    case variantRowSeparator
    /// `VariantTrackRenderer.labelMarginColor`.
    case variantLabelMargin
    /// `VariantTrackRenderer.scrollTrackColor`.
    case variantScrollTrack
    /// `VariantTrackRenderer.scrollThumbColor`.
    case variantScrollThumb
    /// `SemanticColors.DNA.baseA`, a read mismatch, which is not `baseA` (`BaseColors.A`).
    case readBaseA
    /// `SemanticColors.DNA.baseC`, a read mismatch.
    case readBaseC
    /// `SemanticColors.DNA.baseG`, a read mismatch.
    case readBaseG
    /// `SemanticColors.DNA.baseT`, a read mismatch, also used for U.
    case readBaseT
    /// `SemanticColors.DNA.baseN`, a read mismatch at any other letter.
    case readBaseN
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
        case .controlBackground: ViewerFigureColor(white: 1)
        case .quaternarySystemFill: ViewerFigureColor(white: 0, alpha: 0.0275)
        case .forwardRead, .forwardReadStroke, .reverseRead, .reverseReadStroke, .forwardCoverage, .reverseCoverage,
             .matchDot, .insertion, .deletion, .softClip, .insertNormal, .insertTooSmall, .insertTooLarge,
             .insertInterchromosomal, .insertAbnormalOrientation, .firstInPair, .secondInPair, .splitRead,
             .coverageOutline, .coverageLegendStroke, .baseReadForwardBackground, .baseReadReverseBackground,
             .baseReadNeutralBackground, .baseReadNeutralStroke, .intron, .mateLink, .variantGutterBackground,
             .variantGutterSeparator, .variantDataBackground, .variantSummaryBorder, .variantRowSeparator,
             .variantLabelMargin, .variantScrollTrack, .variantScrollThumb, .readBaseA, .readBaseC, .readBaseG,
             .readBaseT, .readBaseN:
            Self.trackColor(role)
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
        case .controlBackground: ViewerFigureColor(white: 0.1176)
        case .quaternarySystemFill: ViewerFigureColor(white: 1, alpha: 0.0275)
        case .forwardRead, .forwardReadStroke, .reverseRead, .reverseReadStroke, .forwardCoverage, .reverseCoverage,
             .matchDot, .insertion, .deletion, .softClip, .insertNormal, .insertTooSmall, .insertTooLarge,
             .insertInterchromosomal, .insertAbnormalOrientation, .firstInPair, .secondInPair, .splitRead,
             .coverageOutline, .coverageLegendStroke, .baseReadForwardBackground, .baseReadReverseBackground,
             .baseReadNeutralBackground, .baseReadNeutralStroke, .intron, .mateLink, .variantGutterBackground,
             .variantGutterSeparator, .variantDataBackground, .variantSummaryBorder, .variantRowSeparator,
             .variantLabelMargin, .variantScrollTrack, .variantScrollThumb, .readBaseA, .readBaseC, .readBaseG,
             .readBaseT, .readBaseN:
            Self.trackColor(role)
        }
    }

    /// The track colours that are the same in both appearances, as the renderers fixed them.
    private static func trackColor(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        trackColors[role] ?? ViewerFigureColor(white: 0, alpha: 0)
    }

    private static let trackColors: [ViewerFigureColorRole: ViewerFigureColor] = [
        .forwardRead: ViewerFigureColor(red: 0.69, green: 0.77, blue: 0.87),
        .forwardReadStroke: ViewerFigureColor(red: 0.55, green: 0.65, blue: 0.77),
        .reverseRead: ViewerFigureColor(red: 0.87, green: 0.69, blue: 0.69),
        .reverseReadStroke: ViewerFigureColor(red: 0.77, green: 0.55, blue: 0.55),
        .forwardCoverage: ViewerFigureColor(red: 0.42, green: 0.60, blue: 0.77, alpha: 0.7),
        .reverseCoverage: ViewerFigureColor(red: 0.77, green: 0.42, blue: 0.42, alpha: 0.7),
        .matchDot: ViewerFigureColor(white: 0.48, alpha: 0.82),
        .insertion: ViewerFigureColor(red: 0.8, green: 0, blue: 0.8),
        .deletion: ViewerFigureColor(white: 0.5),
        .softClip: ViewerFigureColor(red: 0.5, green: 0.6, blue: 0.75, alpha: 0.6),
        .insertNormal: ViewerFigureColor(white: 0.75),
        .insertTooSmall: ViewerFigureColor(red: 0, green: 0, blue: 0.85),
        .insertTooLarge: ViewerFigureColor(red: 0.85, green: 0, blue: 0),
        .insertInterchromosomal: ViewerFigureColor(red: 0.6, green: 0, blue: 0.85),
        .insertAbnormalOrientation: ViewerFigureColor(red: 0, green: 0.75, blue: 0.75),
        .firstInPair: ViewerFigureColor(red: 0.45, green: 0.45, blue: 0.85),
        .secondInPair: ViewerFigureColor(red: 0.85, green: 0.45, blue: 0.45),
        .splitRead: ViewerFigureColor(red: 1, green: 0.5, blue: 0, alpha: 0.8),
        .coverageOutline: ViewerFigureColor(white: 0.33),
        .coverageLegendStroke: ViewerFigureColor(white: 0.25),
        .baseReadForwardBackground: ViewerFigureColor(red: 0.84, green: 0.89, blue: 0.95),
        .baseReadReverseBackground: ViewerFigureColor(red: 0.95, green: 0.86, blue: 0.86),
        .baseReadNeutralBackground: ViewerFigureColor(white: 0.90),
        .baseReadNeutralStroke: ViewerFigureColor(white: 0.72),
        .intron: ViewerFigureColor(white: 0.5, alpha: 0.7),
        .mateLink: ViewerFigureColor(white: 0.6, alpha: 0.4),
        // The variant constants are `CGColor(red:green:blue:alpha:)`, generic RGB, so their sRGB
        // values are lighter than their components (0.96 is 0.9682).
        .variantGutterBackground: ViewerFigureColor(white: 0.9682),
        .variantGutterSeparator: ViewerFigureColor(white: 0.8541),
        .variantDataBackground: ViewerFigureColor(white: 0.9602),
        .variantSummaryBorder: ViewerFigureColor(white: 0.8374),
        .variantRowSeparator: ViewerFigureColor(white: 0.9198),
        .variantLabelMargin: ViewerFigureColor(white: 1),
        .variantScrollTrack: ViewerFigureColor(white: 0, alpha: 0.05),
        .variantScrollThumb: ViewerFigureColor(white: 0, alpha: 0.25),
        .readBaseA: ViewerFigureColor(SemanticColors.DNA.baseA),
        .readBaseC: ViewerFigureColor(SemanticColors.DNA.baseC),
        .readBaseG: ViewerFigureColor(SemanticColors.DNA.baseG),
        .readBaseT: ViewerFigureColor(SemanticColors.DNA.baseT),
        .readBaseN: ViewerFigureColor(SemanticColors.DNA.baseN),
    ]

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
