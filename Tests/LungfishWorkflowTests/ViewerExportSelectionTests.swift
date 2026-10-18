// ViewerExportSelectionTests.swift - The selection file round trip
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M2 (3), ARCH ruling 1.3. Lanes 12.34, 12.35 and 12.39 use this type, so 12.31 builds it once.

import XCTest
@testable import LungfishWorkflow

final class ViewerExportSelectionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewerExportSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let selection = ViewerExportSelection(
        identities: ["sample-A", "sample-B"],
        state: ViewerTableExportState(
            samples: ["sample-A"],
            searchText: "beta",
            sortKeys: [ViewerExportSortKey(column: "name", ascending: true)],
            filters: ColumnFilterSet(
                filters: [ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "30")],
                composition: .any
            ),
            metadataColumns: ["Group"]
        ),
        editedValues: ["sample-A": ["barcode": "BC01"]]
    )

    func testSelectionRoundTripsThroughANewInputsFolder() throws {
        let outputURL = folder.appendingPathComponent("out.tsv")
        let first = try Self.selection.write(besideOutput: outputURL)
        let second = try Self.selection.write(besideOutput: outputURL)

        XCTAssertEqual(first.lastPathComponent, "selection.json")
        let inputs = first.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(inputs.lastPathComponent, ".lungfish-export-inputs")
        XCTAssertEqual(inputs.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertNotNil(UUID(uuidString: first.deletingLastPathComponent().lastPathComponent))
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent(), "a new folder each time")

        XCTAssertEqual(try ViewerExportSelection.read(from: first), Self.selection)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second), "one selection, one digest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), "the selection file never writes output")
    }

    func testANewerSchemaIsRefused() throws {
        var newer = Self.selection
        newer.schemaVersion = ViewerExportSelection.currentSchemaVersion + 1
        let url = try newer.write(besideOutput: folder.appendingPathComponent("out.tsv"))
        XCTAssertThrowsError(try ViewerExportSelection.read(from: url)) { error in
            XCTAssertEqual(error as? ViewerExportSelection.ReadError, .unsupportedSchema(newer.schemaVersion))
        }
    }

    func testAFailedWriteLeavesNoInputsFolder() throws {
        let blocker = folder.appendingPathComponent(".lungfish-export-inputs")
        try Data("not a folder".utf8).write(to: blocker)
        XCTAssertThrowsError(try Self.selection.write(besideOutput: folder.appendingPathComponent("out.tsv")))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }
}
