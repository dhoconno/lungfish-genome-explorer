// ViewerFigureThemeTests.swift - The figure theme as a value
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0). The comparison with the live colours is in LungfishAppWorkflowTests
// (`ViewerFigureThemeParityTests`). Scenes store role names, so these tests hold the names
// fixed and check that every role resolves to an sRGB colour in both appearances.

import CoreGraphics
import XCTest
@testable import LungfishWorkflow

final class ViewerFigureThemeTests: XCTestCase {
    func testRoleNamesStayFixed() {
        // A scene golden stores these names. Append new roles and never rename one.
        XCTAssertEqual(
            ViewerFigureColorRole.allCases.map(\.rawValue),
            [
                "textBackground", "windowBackground", "separator", "label", "secondaryLabel", "tertiaryLabel",
                "systemGray", "textOnColor", "baseA", "baseC", "baseG", "baseT", "baseN",
                // Appended by lane 13.29 for the read and variant track renderers.
                "controlBackground", "quaternarySystemFill", "forwardRead", "forwardReadStroke", "reverseRead",
                "reverseReadStroke", "forwardCoverage", "reverseCoverage", "matchDot", "insertion", "deletion",
                "softClip", "insertNormal", "insertTooSmall", "insertTooLarge", "insertInterchromosomal",
                "insertAbnormalOrientation", "firstInPair", "secondInPair", "splitRead", "coverageOutline",
                "coverageLegendStroke", "baseReadForwardBackground", "baseReadReverseBackground",
                "baseReadNeutralBackground", "baseReadNeutralStroke", "intron", "mateLink", "variantGutterBackground",
                "variantGutterSeparator", "variantDataBackground", "variantSummaryBorder", "variantRowSeparator",
                "variantLabelMargin", "variantScrollTrack", "variantScrollThumb", "readBaseA", "readBaseC",
                "readBaseG", "readBaseT", "readBaseN",
                // Appended by lane 13.29 M3 for the annotation track.
                "annotationGene", "annotationMRNA", "annotationTranscript", "annotationCDS", "annotationORF",
                "annotationTranslation", "annotationExon", "annotationIntron", "annotationUTR", "annotationTRNA",
                "annotationRRNA", "annotationRegion", "annotationPromoter", "annotationEnhancer", "annotationSilencer",
                "annotationTerminator", "annotationPolyASignal", "annotationRegulatory", "annotationNcRNA",
                "annotationPrimer", "annotationRestrictionSite", "annotationVariation", "annotationInsertion",
                "annotationDeletion", "annotationRepeatRegion", "annotationStemLoop", "annotationMiscFeature",
                "annotationPseudogene", "annotationMobileElement", "annotationMatPeptide", "annotationSigPeptide",
                "annotationTransitPeptide", "annotationMiscBinding", "annotationProteinBind", "annotationAmplicon",
                "annotationContig", "annotationGap", "annotationScaffold", "annotationSource", "annotationCustom",
                "annotationBarcode5p", "annotationBarcode3p", "annotationAdapter5p", "annotationAdapter3p",
                "annotationPrimer5p", "annotationPrimer3p", "annotationTrimQuality", "annotationTrimFixed",
                "annotationOrientMarker", "annotationUmiRegion", "annotationContaminantMatch", "text",
            ]
        )
        XCTAssertEqual(ViewerFigureAppearance.allCases.map(\.rawValue), ["light", "dark"])
    }

    func testEveryRoleResolvesToAnSRGBColourInBothAppearances() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for theme in [ViewerFigureTheme.light, ViewerFigureTheme.dark] {
            for role in ViewerFigureColorRole.allCases {
                let color = theme.color(role)
                for value in [color.red, color.green, color.blue, color.alpha] {
                    XCTAssertTrue((0...1).contains(value), "\(role.rawValue) in \(theme.appearance.rawValue)")
                }
                let cgColor = color.cgColor
                XCTAssertEqual(cgColor.colorSpace, srgb, role.rawValue)
                XCTAssertEqual(
                    cgColor.components?.map { Double($0) }, [color.red, color.green, color.blue, color.alpha], role.rawValue
                )
            }
        }
    }

    func testAppearancesDifferOnlyWhereTheLiveColoursDo() {
        let differing = ViewerFigureColorRole.allCases.filter {
            ViewerFigureTheme.light.color($0) != ViewerFigureTheme.dark.color($0)
        }
        XCTAssertEqual(
            differing,
            [
                .textBackground, .windowBackground, .separator, .label, .secondaryLabel, .tertiaryLabel, .systemGray,
                .controlBackground, .quaternarySystemFill, .text,
            ]
        )
    }

    func testWithAlphaReplacesTheAlphaAsAppKitDoes() {
        let tertiary = ViewerFigureTheme.light.color(.tertiaryLabel)
        let replaced = tertiary.withAlpha(0.6)
        XCTAssertEqual(replaced, ViewerFigureColor(red: tertiary.red, green: tertiary.green, blue: tertiary.blue, alpha: 0.6))
    }

    func testThemeRoundTripsAsItsAppearanceName() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(ViewerFigureTheme.dark), as: UTF8.self), #"{"appearance":"dark"}"#)
        let data = try encoder.encode(ViewerFigureTheme.light)
        XCTAssertEqual(try JSONDecoder().decode(ViewerFigureTheme.self, from: data), .light)
    }
}
