// ViewerFigureThemeParityTests.swift - The figure theme against the live viewer's colours
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0, ruling section 2.2 of ARCH-B10-graphics). `ViewerFigureTheme` holds
// fixed sRGB values. Each role stands for one colour the live viewer draws with, and this
// test resolves that colour under Aqua and Dark Aqua, converts it to sRGB and compares.
// A macOS update that moves a system colour fails here, and the theme moves by prediction.

import AppKit
import XCTest
import LungfishApp
import LungfishCore
import LungfishWorkflow

@MainActor
final class ViewerFigureThemeParityTests: XCTestCase {
    /// The live colour each role stands for. A new role names its live colour here.
    private func liveColor(_ role: ViewerFigureColorRole) -> NSColor {
        switch role {
        case .textBackground: .textBackgroundColor
        case .windowBackground: .windowBackgroundColor
        case .separator: .separatorColor
        case .label: .labelColor
        case .secondaryLabel: .secondaryLabelColor
        case .tertiaryLabel: .tertiaryLabelColor
        case .systemGray: .systemGray
        case .textOnColor: .white
        case .baseA: BaseColors.A
        case .baseC: BaseColors.C
        case .baseG: BaseColors.G
        case .baseT: BaseColors.T
        case .baseN: BaseColors.N
        // The read and variant track renderers (lane 13.29), as their constants were at 2cf5a3dd5.
        case .controlBackground: .controlBackgroundColor
        case .quaternarySystemFill: .quaternarySystemFill
        case .forwardRead: NSColor(red: 0.69, green: 0.77, blue: 0.87, alpha: 1.0)
        case .forwardReadStroke: NSColor(red: 0.55, green: 0.65, blue: 0.77, alpha: 1.0)
        case .reverseRead: NSColor(red: 0.87, green: 0.69, blue: 0.69, alpha: 1.0)
        case .reverseReadStroke: NSColor(red: 0.77, green: 0.55, blue: 0.55, alpha: 1.0)
        case .forwardCoverage: NSColor(red: 0.42, green: 0.60, blue: 0.77, alpha: 0.7)
        case .reverseCoverage: NSColor(red: 0.77, green: 0.42, blue: 0.42, alpha: 0.7)
        case .matchDot: NSColor(white: 0.48, alpha: 0.82)
        case .insertion: NSColor(red: 0.8, green: 0, blue: 0.8, alpha: 1.0)
        case .deletion: NSColor.gray
        case .softClip: NSColor(red: 0.5, green: 0.6, blue: 0.75, alpha: 0.6)
        case .insertNormal: NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)
        case .insertTooSmall: NSColor(red: 0.0, green: 0.0, blue: 0.85, alpha: 1.0)
        case .insertTooLarge: NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)
        case .insertInterchromosomal: NSColor(red: 0.6, green: 0.0, blue: 0.85, alpha: 1.0)
        case .insertAbnormalOrientation: NSColor(red: 0.0, green: 0.75, blue: 0.75, alpha: 1.0)
        case .firstInPair: NSColor(red: 0.45, green: 0.45, blue: 0.85, alpha: 1.0)
        case .secondInPair: NSColor(red: 0.85, green: 0.45, blue: 0.45, alpha: 1.0)
        case .splitRead: NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.8)
        case .coverageOutline: NSColor(white: 0.33, alpha: 1)
        case .coverageLegendStroke: NSColor(white: 0.25, alpha: 1)
        case .baseReadForwardBackground: NSColor(red: 0.84, green: 0.89, blue: 0.95, alpha: 1.0)
        case .baseReadReverseBackground: NSColor(red: 0.95, green: 0.86, blue: 0.86, alpha: 1.0)
        case .baseReadNeutralBackground: NSColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1.0)
        case .baseReadNeutralStroke: NSColor(red: 0.72, green: 0.72, blue: 0.72, alpha: 1.0)
        case .intron: NSColor(white: 0.5, alpha: 0.7)
        case .mateLink: NSColor(white: 0.6, alpha: 0.4)
        case .variantGutterBackground: NSColor(cgColor: CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1.0))!
        case .variantGutterSeparator: NSColor(cgColor: CGColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1.0))!
        case .variantDataBackground: NSColor(cgColor: CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0))!
        case .variantSummaryBorder: NSColor(cgColor: CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0))!
        case .variantRowSeparator: NSColor(cgColor: CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0))!
        case .variantLabelMargin: NSColor(cgColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))!
        case .variantScrollTrack: NSColor(cgColor: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.05))!
        case .variantScrollThumb: NSColor(cgColor: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.25))!
        case .readBaseA: Self.srgb(SemanticColors.DNA.baseA)
        case .readBaseC: Self.srgb(SemanticColors.DNA.baseC)
        case .readBaseG: Self.srgb(SemanticColors.DNA.baseG)
        case .readBaseT: Self.srgb(SemanticColors.DNA.baseT)
        case .readBaseN: Self.srgb(SemanticColors.DNA.baseN)
        }
    }

    private static func srgb(_ hex: HexColor) -> NSColor {
        NSColor(srgbRed: CGFloat(hex.red), green: CGFloat(hex.green), blue: CGFloat(hex.blue), alpha: CGFloat(hex.alpha))
    }

    /// The read renderer draws mismatches in `SemanticColors.DNA` through `HexColor.cgColor`, an
    /// sRGB colour, while the base roles hold the calibrated `BaseColors` (A is 0.8178 green in
    /// sRGB against 0.8). So the read renderer gets its own five roles (lane 13.29), and this pins
    /// that the two sets differ, so neither is swapped for the other.
    func testTheReadRendererBaseColoursAreNotTheSequenceBaseRoles() {
        let pairs: [(ViewerFigureColorRole, ViewerFigureColorRole)] = [
            (.readBaseA, .baseA), (.readBaseC, .baseC), (.readBaseG, .baseG), (.readBaseT, .baseT),
        ]
        for (read, sequence) in pairs {
            XCTAssertNotEqual(ViewerFigureTheme.light.color(read), ViewerFigureTheme.light.color(sequence), read.rawValue)
        }
    }

    private func measured(_ role: ViewerFigureColorRole, in name: NSAppearance.Name) throws -> [Double] {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var components: [Double] = []
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = liveColor(role).usingColorSpace(.sRGB) {
                components = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
                    .map { Double($0) }
            }
        }
        return components
    }

    func testEveryRoleMatchesTheLiveColourInBothAppearances() throws {
        let appearances: [(ViewerFigureAppearance, NSAppearance.Name)] = [(.light, .aqua), (.dark, .darkAqua)]
        for (appearance, name) in appearances {
            let theme = ViewerFigureTheme(appearance: appearance)
            for role in ViewerFigureColorRole.allCases {
                let live = try measured(role, in: name)
                XCTAssertEqual(live.count, 4, "\(role.rawValue) has no sRGB form")
                let color = theme.color(role)
                for (value, liveValue) in zip([color.red, color.green, color.blue, color.alpha], live) {
                    XCTAssertEqual(value, liveValue, accuracy: 0.0001, "\(role.rawValue) in \(appearance.rawValue)")
                }
            }
        }
    }

    func testBaseRolesFollowTheLiveBaseColourChoice() {
        for base in Array("AaCcGgTtUuNnRYX-*") {
            let live = BaseColors.color(for: base)
            let expected: NSColor = switch ViewerFigureTheme.baseRole(for: base) {
            case .baseA: BaseColors.A
            case .baseC: BaseColors.C
            case .baseG: BaseColors.G
            case .baseT: BaseColors.T
            default: BaseColors.N
            }
            XCTAssertTrue(live === expected, "base \(base)")
        }
    }
}
