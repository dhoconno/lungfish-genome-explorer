// OperationCenterLockingTests.swift - Bundle mutation lock invariants
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishKit

@MainActor
final class OperationCenterLockingTests: XCTestCase {
    func testStartWithLockedBundleRecordsBlockedOperationWithoutReplacingLockHolder() throws {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/locked-reference.lungfishref", isDirectory: true)

        let firstID = center.start(
            title: "Annotation Import A",
            detail: "Importing first track",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        )
        let secondID = center.start(
            title: "Annotation Import B",
            detail: "Importing second track",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        )

        XCTAssertEqual(center.activeLockHolder(for: bundleURL)?.id, firstID)
        XCTAssertFalse(center.canStartOperation(on: bundleURL))

        let second = try XCTUnwrap(center.items.first { $0.id == secondID })
        XCTAssertEqual(second.state, .failed)
        XCTAssertEqual(second.targetBundleURL?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(second.errorMessage, "Bundle is busy")
        XCTAssertTrue(second.detail.contains("Annotation Import A"))

        center.complete(id: firstID, detail: "Complete")
        XCTAssertTrue(center.canStartOperation(on: bundleURL))
        XCTAssertNil(center.activeLockHolder(for: bundleURL))
    }

    func testAnnotationImportCallSitesPassTargetBundleURLForLocking() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sidebarSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift"
            ),
            encoding: .utf8
        )
        let importCenterSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/LungfishApp/App/AppDelegate+ImportCenter.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            Self.operationStartBlock(titled: "Annotation Import", in: sidebarSource)
                .contains("targetBundleURL: bundleURL"),
            "Sidebar/drop annotation imports must acquire a bundle mutation lock."
        )
        XCTAssertTrue(
            Self.operationStartBlock(titled: "Annotation Import", in: importCenterSource)
                .contains("targetBundleURL: bundleURL"),
            "Import Center annotation imports must acquire a bundle mutation lock."
        )
    }

    private static func operationStartBlock(titled title: String, in source: String) -> String {
        guard let titleRange = source.range(of: #"title: "\#(title)""#),
              let startRange = source[..<titleRange.lowerBound].range(of: "OperationCenter.shared.start(", options: .backwards),
              let endRange = source[titleRange.upperBound...].range(of: "\n        )") else {
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }
}
