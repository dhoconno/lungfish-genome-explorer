// LungfishColors.swift - Brand color definitions for Lungfish
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

// MARK: - SwiftUI Color Extensions

extension Color {
    /// Lungfish Orange — the primary brand accent color.
    ///
    /// Use this for tool icons, card icon backgrounds, branded UI elements,
    /// and any place where the app's identity should be visible. Do NOT use
    /// `Color.accentColor` for branded elements — that follows the user's
    /// system-wide accent preference.
    ///
    /// System controls (buttons, checkboxes, segmented controls) should
    /// continue to use `.borderedProminent` / `Color.accentColor` to
    /// respect macOS HIG and user preferences.
    ///
    /// - Light mode: `#D47B3A` (RGB 212, 123, 58)
    /// - Dark mode: `#E8A06A` (RGB 232, 160, 106)
    public static let lungfishOrange = Color("LungfishOrange", bundle: .main)

    /// Fallback Lungfish Orange that works without an Asset Catalog entry.
    /// Uses adaptive NSColor for automatic light/dark mode switching.
    public static let lungfishOrangeFallback = Color(nsColor: .lungfishOrange)

    public static let lungfishCreamsicleFallback = Color(nsColor: .lungfishCreamsicle)
    public static let lungfishPeachFallback = Color(nsColor: .lungfishPeach)
    public static let lungfishDeepInkFallback = Color(nsColor: .lungfishDeepInk)
    public static let lungfishCreamFallback = Color(nsColor: .lungfishCream)
    public static let lungfishWarmGreyFallback = Color(nsColor: .lungfishWarmGrey)
    public static let lungfishSageFallback = Color(nsColor: .lungfishSage)

    public static let lungfishCanvasBackground = Color(nsColor: .lungfishCanvasBackground)
    public static let lungfishCardBackground = Color(nsColor: .lungfishCardBackground)
    public static let lungfishSidebarBackground = Color(nsColor: .lungfishSidebarBackground)
    public static let lungfishStroke = Color(nsColor: .lungfishStroke)
    public static let lungfishSecondaryText = Color(nsColor: .lungfishSecondaryText)
    public static let lungfishMutedFill = Color(nsColor: .lungfishMutedFill)
    public static let lungfishAttentionFill = Color(nsColor: .lungfishAttentionFill)
    public static let lungfishSuccessFill = Color(nsColor: .lungfishSuccessFill)
    public static let lungfishDangerFallback = Color(nsColor: .lungfishDanger)
    public static let lungfishDangerFill = Color(nsColor: .lungfishDangerFill)

    public static let lungfishWelcomeBackground = Color(nsColor: .lungfishWelcomeBackground)
    public static let lungfishWelcomeCardBackground = Color(nsColor: .lungfishWelcomeCardBackground)
    public static let lungfishWelcomeSidebarBackground = Color(nsColor: .lungfishWelcomeSidebarBackground)
    public static let lungfishWelcomeSelectionFill = Color(nsColor: .lungfishWelcomeSelectionFill)
    public static let lungfishWelcomeStroke = Color(nsColor: .lungfishWelcomeStroke)
    public static let lungfishWelcomeSecondaryText = Color(nsColor: .lungfishWelcomeSecondaryText)
    public static let lungfishWelcomeIconBackground = Color(nsColor: .lungfishWelcomeIconBackground)
}

// MARK: - NSColor Extensions

extension NSColor {
    /// Lungfish Orange — the primary brand accent color for AppKit usage.
    ///
    /// Automatically adapts between light mode (#D47B3A) and dark mode (#E8A06A).
    public static let lungfishOrange: NSColor = NSColor(name: "LungfishOrange") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            // Dark mode: lighter orange for contrast
            return NSColor(red: 0.910, green: 0.627, blue: 0.416, alpha: 1.0)
        } else {
            // Light mode: standard Lungfish Orange
            return NSColor(red: 0.831, green: 0.482, blue: 0.227, alpha: 1.0)
        }
    }

    public static let lungfishCreamsicle: NSColor = NSColor(name: "LungfishCreamsicle") { _ in
        NSColor(red: 0.933, green: 0.545, blue: 0.310, alpha: 1.0) // #EE8B4F
    }

    public static let lungfishPeach: NSColor = NSColor(name: "LungfishPeach") { _ in
        NSColor(red: 0.965, green: 0.690, blue: 0.533, alpha: 1.0) // #F6B088
    }

    public static let lungfishDeepInk: NSColor = NSColor(name: "LungfishDeepInk") { _ in
        NSColor(red: 0.122, green: 0.102, blue: 0.090, alpha: 1.0) // #1F1A17
    }

    public static let lungfishCream: NSColor = NSColor(name: "LungfishCream") { _ in
        NSColor(red: 0.980, green: 0.957, blue: 0.918, alpha: 1.0) // #FAF4EA
    }

    public static let lungfishWarmGrey: NSColor = NSColor(name: "LungfishWarmGrey") { _ in
        NSColor(red: 0.541, green: 0.518, blue: 0.478, alpha: 1.0) // #8A847A
    }

    public static let lungfishSage: NSColor = NSColor(name: "LungfishSage") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(red: 0.576, green: 0.671, blue: 0.490, alpha: 1.0) // #93AB7D
        } else {
            return NSColor(red: 0.478, green: 0.576, blue: 0.392, alpha: 1.0) // #7A9364
        }
    }

    public static let lungfishCanvasBackground: NSColor = NSColor(name: "LungfishCanvasBackground") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return blend(.lungfishDeepInk, with: .white, fraction: 0.04)
        } else {
            return .lungfishCream
        }
    }

    public static let lungfishCardBackground: NSColor = NSColor(name: "LungfishCardBackground") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return blend(.lungfishDeepInk, with: .white, fraction: 0.12)
        } else {
            return .white
        }
    }

    public static let lungfishSidebarBackground: NSColor = NSColor(name: "LungfishSidebarBackground") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return blend(.lungfishDeepInk, with: .lungfishPeach, fraction: 0.16)
        } else {
            return blend(.lungfishCream, with: .lungfishPeach, fraction: 0.42)
        }
    }

    public static let lungfishStroke: NSColor = NSColor(name: "LungfishStroke") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.10)
        } else {
            return NSColor.lungfishWarmGrey.withAlphaComponent(0.22)
        }
    }

    public static let lungfishSecondaryText: NSColor = NSColor(name: "LungfishSecondaryText") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.lungfishCream.withAlphaComponent(0.78)
        } else {
            return NSColor.lungfishWarmGrey
        }
    }

    public static let lungfishMutedFill: NSColor = NSColor(name: "LungfishMutedFill") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.lungfishPeach.withAlphaComponent(0.12)
        } else {
            return NSColor.lungfishPeach.withAlphaComponent(0.16)
        }
    }

    public static let lungfishAttentionFill: NSColor = NSColor(name: "LungfishAttentionFill") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.lungfishCreamsicle.withAlphaComponent(0.22)
        } else {
            return NSColor.lungfishCreamsicle.withAlphaComponent(0.14)
        }
    }

    public static let lungfishSuccessFill: NSColor = NSColor(name: "LungfishSuccessFill") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.lungfishSage.withAlphaComponent(0.24)
        } else {
            return NSColor.lungfishSage.withAlphaComponent(0.14)
        }
    }

    /// Palette-aligned danger color for destructive actions and error states.
    ///
    /// This is deliberately a muted clay/copper tone instead of system red so
    /// warnings remain legible without clashing with the Lungfish warm palette.
    public static let lungfishDanger: NSColor = NSColor(name: "LungfishDanger") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(red: 0.816, green: 0.541, blue: 0.392, alpha: 1.0) // #D08A64
        } else {
            return NSColor(red: 0.651, green: 0.373, blue: 0.227, alpha: 1.0) // #A65F3A
        }
    }

    public static let lungfishDangerFill: NSColor = NSColor(name: "LungfishDangerFill") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.lungfishDanger.withAlphaComponent(0.24)
        } else {
            return NSColor.lungfishDanger.withAlphaComponent(0.16)
        }
    }

    public static let lungfishWelcomeBackground: NSColor = NSColor(name: "LungfishWelcomeBackground") { appearance in
        .lungfishCanvasBackground
    }

    public static let lungfishWelcomeCardBackground: NSColor = NSColor(name: "LungfishWelcomeCardBackground") { appearance in
        .lungfishCardBackground
    }

    public static let lungfishWelcomeSidebarBackground: NSColor = NSColor(name: "LungfishWelcomeSidebarBackground") { appearance in
        .lungfishSidebarBackground
    }

    public static let lungfishWelcomeSelectionFill: NSColor = NSColor(name: "LungfishWelcomeSelectionFill") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.lungfishCreamsicle.withAlphaComponent(0.22)
        } else {
            return NSColor.lungfishCreamsicle.withAlphaComponent(0.15)
        }
    }

    public static let lungfishWelcomeStroke: NSColor = NSColor(name: "LungfishWelcomeStroke") { appearance in
        .lungfishStroke
    }

    public static let lungfishWelcomeSecondaryText: NSColor = NSColor(name: "LungfishWelcomeSecondaryText") { appearance in
        .lungfishSecondaryText
    }

    public static let lungfishWelcomeIconBackground: NSColor = NSColor(name: "LungfishWelcomeIconBackground") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.lungfishPeach.withAlphaComponent(0.14)
        } else {
            return NSColor.lungfishPeach.withAlphaComponent(0.24)
        }
    }

    private static func blend(_ base: NSColor, with overlay: NSColor, fraction: CGFloat) -> NSColor {
        base.blended(withFraction: fraction, of: overlay) ?? base
    }
}

extension NSButton {
    public func applyLungfishDestructiveStyle() {
        hasDestructiveAction = true
        contentTintColor = .lungfishDanger
        bezelColor = .lungfishDangerFill
    }
}
