// OperationCenterMappingTypeTests.swift - Mapping runs carry their own operation type
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit
import LungfishKitTestSupport

@MainActor
final class OperationCenterMappingTypeTests: XCTestCase {
    func testMappingItemReportsMappingOperationType() {
        let center = OperationCenter()
        let id = center.begin(
            title: "Map Reads (minimap2): sample",
            detail: "Mapping 1 file(s) to reference.fasta",
            operationType: .mapping,
            cliCommand: nil
        ).rowID

        let item = center.items.first(where: { $0.id == id })
        XCTAssertEqual(item?.operationType, .mapping)
        XCTAssertEqual(item?.operationType.rawValue, "Mapping")
    }
}
