// GenotypeExportSettingsBlockPinTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishGenotypeUI

/// The settings block an Excel export records. The export keeps the viewed
/// sidecar under the name `annotations.json`, so its settings are the
/// settings of the bundle's file, the view fields of an older sidecar
/// included. Plan decision S11 moves those view fields to app state for new
/// writes, and this pin shows that an existing sidecar still exports the
/// same block.
@MainActor
final class GenotypeExportSettingsBlockPinTests: GenotypeResultViewportTestCase {
    static let expectedSettings: [String: Any] = [
        "cardDensity": "auto",
        "cardDensityThreshold": 30,
        "dropoutAbsolute": 50,
        "dropoutLocusFraction": 0.01,
        "genotypeLocusDisplayOrder": ["MHC-B", "MHC-A"],
        "mhcCandidateDisplay": [
            "showKnown": true,
            "showSharedCandidates": true,
            "showSingletonCandidates": true,
        ],
        "panelLayout": "aLeading",
        "preferredSummaryViewMode": "matrix",
        "viewMode": "outline",
    ]

    func testTheExportRecordsTheSettingsBlockOfTheBundleFile() throws {
        let scenario = try makeThresholdedMiSeqScenario()
        defer { scenario.cleanup() }
        let fileSettings = try Self.settingsBlock(of: Data(contentsOf: scenario.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )))

        let snapshot = try scenario.withAquaDrawingAppearance { try scenario.controller.captureExcelExportSnapshot() }

        let viewed = try Self.settingsBlock(of: XCTUnwrap(snapshot.annotationSidecarData))
        let frozen = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(snapshot.excelSnapshotData)
        )
        let captured = try Self.settingsBlock(of: XCTUnwrap(frozen.capturedScientificInputs?["annotations.json"]))
        for block in [viewed, captured] {
            XCTAssertEqual(block, fileSettings, "the export records the settings the file holds")
            XCTAssertEqual(block.allKeys, Self.expectedSettings.keys.sorted())
            for (key, value) in Self.expectedSettings where key != "mhcCandidateDisplay" {
                XCTAssertEqual(block.values[key], Self.canonical(value), key)
            }
            let display = try XCTUnwrap(block.object["mhcCandidateDisplay"] as? [String: Any])
            for (key, value) in try XCTUnwrap(Self.expectedSettings["mhcCandidateDisplay"] as? [String: Bool]) {
                XCTAssertEqual(display[key] as? Bool, value, key)
            }
        }
    }

    // MARK: - Helpers

    struct SettingsBlock: Equatable {
        let object: [String: Any]
        let values: [String: String]

        var allKeys: [String] { object.keys.sorted() }

        static func == (lhs: SettingsBlock, rhs: SettingsBlock) -> Bool {
            lhs.values == rhs.values
        }
    }

    static func settingsBlock(of sidecarData: Data) throws -> SettingsBlock {
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecarData) as? [String: Any])
        let settings = try XCTUnwrap(sidecar["settings"] as? [String: Any])
        return SettingsBlock(
            object: settings,
            values: settings.mapValues(canonical)
        )
    }

    /// One text per JSON value, with sorted keys, so two blocks compare whole.
    static func canonical(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
