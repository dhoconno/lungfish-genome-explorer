// StorageSettingsTabTests.swift - Behavioral tests for the shared storage settings tab
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class StorageSettingsTabTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-settings-tab-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil

        try super.tearDownWithError()
    }

    @MainActor
    func testViewStateLabelsAutomaticallySharedPreviewStorage() throws {
        let root = tempHome.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ManagedStorageConfigStore(homeDirectory: tempHome, appIdentity: .debug,
            environmentProvider: { ["LUNGFISH_SHARED_PREVIEW_ROOT": root.path] })
        let state = StorageSettingsTab.makeViewState(configStore: store)
        XCTAssertEqual(state.displayPath, root.path)
        XCTAssertEqual(state.locationBadgeText, "Shared with Preview")
        XCTAssertTrue(state.locationStatusDescription.contains("Dependency pins match"))
        XCTAssertFalse(state.showsCleanupAction)
    }

    @MainActor
    func testViewStateShowsMalformedBootstrapWarningAndDefaultPath() throws {
        let store = ManagedStorageConfigStore(homeDirectory: tempHome)
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.configURL, options: [.atomic])

        let state = StorageSettingsTab.makeViewState(configStore: store, fileManager: .default)

        XCTAssertEqual(state.displayPath, store.defaultLocation.rootURL.path)
        XCTAssertEqual(state.displayState, .malformedBootstrap)
        XCTAssertEqual(state.locationBadgeText, "Needs Attention")
        XCTAssertTrue(state.showsMalformedBootstrapWarning)
        XCTAssertFalse(state.showsCleanupAction)
    }

    @MainActor
    func testViewStateShowsCleanupActionAfterCompletedMigration() throws {
        let store = ManagedStorageConfigStore(homeDirectory: tempHome)
        let activeRoot = tempHome.appendingPathComponent("managed-root", isDirectory: true)
        let previousRoot = tempHome.appendingPathComponent("old-root", isDirectory: true)
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previousRoot, withIntermediateDirectories: true)

        let config = ManagedStorageBootstrapConfig(
            activeRootPath: activeRoot.path,
            previousRootPath: previousRoot.path,
            migrationState: .completed
        )
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(config)
        try data.write(to: store.configURL, options: [.atomic])

        let state = StorageSettingsTab.makeViewState(configStore: store, fileManager: .default)

        XCTAssertEqual(state.displayPath, activeRoot.path)
        XCTAssertEqual(state.displayState, .customRoot(ManagedStorageLocation(rootURL: activeRoot)))
        XCTAssertEqual(state.previousRootPath, previousRoot.path)
        XCTAssertTrue(state.showsCleanupAction)
        XCTAssertFalse(state.showsMalformedBootstrapWarning)
    }
}
