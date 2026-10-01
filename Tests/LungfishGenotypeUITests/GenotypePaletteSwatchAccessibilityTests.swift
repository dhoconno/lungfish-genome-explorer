import AppKit
import LungfishCore
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishGenotypeUI

/// Palette swatches name their color and report the selected state to AX
/// clients, so no swatch is identified by color alone.
@MainActor
final class GenotypePaletteSwatchAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    func testDescriptiveNamesSeparateHuesAndShades() {
        XCTAssertEqual(AnnotationColor(red: 1, green: 0, blue: 0).descriptiveName, "Red")
        XCTAssertEqual(AnnotationColor(red: 0.7, green: 0.85, blue: 1).descriptiveName, "Light Blue")
        XCTAssertEqual(AnnotationColor(red: 0.87, green: 0.87, blue: 0.87).descriptiveName, "Light Gray")
        XCTAssertEqual(AnnotationColor(red: 0.1, green: 0.4, blue: 0.1).descriptiveName, "Dark Green")
    }

    func testSwatchesAreLabelledButtonsAndTheSelectedOneSaysSo() throws {
        let red = AnnotationColor(red: 1, green: 0, blue: 0)
        let blue = AnnotationColor(red: 0, green: 0, blue: 1)
        var applied: [AnnotationColor] = []
        let window = AccessibilityTreeProbe.host(
            GenotypePaletteSwatchGrid(
                swatches: [
                    GenotypePaletteSwatch(name: "M1", color: red),
                    GenotypePaletteSwatch(name: "M2", color: blue),
                ],
                columns: 2,
                selected: blue,
                apply: { applied.append($0) }
            ),
            size: CGSize(width: 200, height: 100)
        )
        windows.append(window)
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "genotype-swatch-M2") != nil
        }
        let first = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: "genotype-swatch-M1"))
        let second = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: "genotype-swatch-M2"))
        XCTAssertEqual(AccessibilityTreeProbe.role(first), NSAccessibility.Role.button.rawValue)
        XCTAssertEqual(AccessibilityTreeProbe.label(first), "M1, Red")
        XCTAssertEqual(AccessibilityTreeProbe.label(second), "M2, Blue")
        XCTAssertFalse(AccessibilityTreeProbe.isSelected(first))
        XCTAssertTrue(AccessibilityTreeProbe.isSelected(second))
        XCTAssertTrue(AccessibilityTreeProbe.press(first))
        XCTAssertEqual(applied, [red])
    }
}
