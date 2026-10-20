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
