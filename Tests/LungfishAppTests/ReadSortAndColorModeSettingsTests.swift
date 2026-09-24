// ReadSortAndColorModeSettingsTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FEA-08: ReadTrackRenderer implements every ReadSortMode and ReadColorMode,
// but every production call site hard-coded .position/.strand — there was no
// UI control or settings plumbing that reached the others. This proves the
// Inspector's read-style settings notification path (applyReadDisplaySettings,
// the same mechanism showStrandColors/showMismatches/etc. already use) now
// carries the sort and color mode through to SequenceViewerView, which feeds
// both the ReadPackCacheKey (so a mode change actually triggers a repack) and
// ReadTrackRenderer.DisplaySettings.colorMode (so a color mode change reaches
// the packed-read draw path).

import XCTest
import AppKit
@testable import LungfishApp
import LungfishCore

final class ReadSortAndColorModeSettingsTests: XCTestCase {
    @MainActor func testApplyReadDisplaySettingsUpdatesSortModeAndPosition() {
        let viewer = ViewerViewController()
        _ = viewer.view

        XCTAssertEqual(viewer.viewerView.readSortModeSetting, .position, "default should match every pre-existing hard-coded call site")

        viewer.applyReadDisplaySettings([
            NotificationUserInfoKey.readSortMode: ReadSortMode.baseAtPosition.rawValue,
            NotificationUserInfoKey.readSortPosition: 12345,
        ])

        XCTAssertEqual(viewer.viewerView.readSortModeSetting, .baseAtPosition)
        XCTAssertEqual(viewer.viewerView.readSortPositionSetting, 12345)
    }

    @MainActor func testApplyReadDisplaySettingsUpdatesColorMode() {
        let viewer = ViewerViewController()
        _ = viewer.view

        XCTAssertEqual(viewer.viewerView.readColorModeSetting, .strand, "default should match every pre-existing hard-coded call site")

        viewer.applyReadDisplaySettings([
            NotificationUserInfoKey.readColorMode: ReadColorMode.insertSize.rawValue,
        ])

        XCTAssertEqual(viewer.viewerView.readColorModeSetting, .insertSize)
    }

    @MainActor func testInvalidRawValuesAreIgnoredRatherThanCrashingOrResetting() {
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.applyReadDisplaySettings([
            NotificationUserInfoKey.readColorMode: ReadColorMode.mappingQuality.rawValue,
        ])
        XCTAssertEqual(viewer.viewerView.readColorModeSetting, .mappingQuality)

        // An unrecognized raw value must not silently reset the mode.
        viewer.applyReadDisplaySettings([
            NotificationUserInfoKey.readColorMode: "not-a-real-mode",
        ])
        XCTAssertEqual(viewer.viewerView.readColorModeSetting, .mappingQuality)
    }

    @MainActor func testDisplaySettingsColorModeDefaultsToStrandReproducingPreexistingBehavior() {
        // ReadTrackRenderer.DisplaySettings.colorMode must default to .strand
        // so that every existing call site that builds DisplaySettings
        // without specifying colorMode keeps its exact prior pixel output.
        let settings = ReadTrackRenderer.DisplaySettings()
        XCTAssertEqual(settings.colorMode, .strand)
    }
}
