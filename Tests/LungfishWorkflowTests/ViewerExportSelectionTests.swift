// ViewerExportSelectionTests.swift - The selection file round trip
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M2 (3), ARCH ruling 1.3. Lanes 12.34, 12.35 and 12.39 use this type, so 12.31 builds it once.

import XCTest
import LungfishCore
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

    /// ARCH ruling on 12.39 R2, the schema rule. A selection with no family field writes schema 1 and the bytes it
    /// wrote at 37c824189, so no other lane's selection digest moves when the family fields arrive.
    func testSelectionWithoutFamilyFieldsKeepsSchemaOneBytes() throws {
        let selection = ViewerExportSelection(
            identities: ["variant:7", "variant:3"],
            state: ViewerTableExportState(sortKeys: [ViewerExportSortKey(column: "position", ascending: false)]),
            editedValues: ["variant:7": ["displayName": "Sample 7"]]
        )
        XCTAssertEqual(selection.schemaVersion, 1)
        XCTAssertEqual(String(decoding: try selection.encoded(), as: UTF8.self), Self.schemaOneLiteral)
    }

    private static let schemaOneLiteral = """
    {
      "editedValues" : {
        "variant:7" : {
          "displayName" : "Sample 7"
        }
      },
      "identities" : [
        "variant:7",
        "variant:3"
      ],
      "schemaVersion" : 1,
      "state" : {
        "columns" : [

        ],
        "filters" : {
          "composition" : "all",
          "filters" : [

          ]
        },
        "metadataColumns" : [

        ],
        "samples" : [

        ],
        "sortKeys" : [
          {
            "ascending" : false,
            "column" : "position"
          }
        ]
      }
    }
    """

    /// V1-1 of Phase 2.13 (lane 13.38 M2). A region selection writes schema 2 and the bytes it wrote before the
    /// bundle-wide field arrived, with no `bundleCodingFeatureTrackIDs` key, so a record made by 2.12 or by 2.13 before
    /// M2 keeps its selection digest (BIO ruling on M854 item 8).
    func testRegionSelectionKeepsItsSchemaTwoBytes() throws {
        let selection = ViewerExportSelection(
            identities: ["ivar:5"],
            annotationTable: AnnotationTableExportSelection(
                scope: "selected",
                columns: [ScientificTableColumn(id: "aa_change", title: "AA Change")],
                query: ["sort": "position:descending"],
                codingFeatureRegion: AnnotationTableFeatureRegion(chromosome: "chr1", start: 0, end: 120, trackIDs: ["cds2", "cds"])
            )
        )
        XCTAssertEqual(selection.schemaVersion, 2)
        let text = String(decoding: try selection.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("bundleCodingFeatureTrackIDs"), text)
        XCTAssertEqual(text, Self.schemaTwoRegionLiteral)
    }

    private static let schemaTwoRegionLiteral = """
    {
      "annotationTable" : {
        "codingFeatureRegion" : {
          "chromosome" : "chr1",
          "end" : 120,
          "start" : 0,
          "trackIDs" : [
            "cds",
            "cds2"
          ]
        },
        "columns" : [
          {
            "id" : "aa_change",
            "title" : "AA Change"
          }
        ],
        "integerColumnIDs" : [

        ],
        "numericColumnIDs" : [

        ],
        "query" : {
          "sort" : "position:descending"
        },
        "scope" : "selected",
        "variantChromosomeAliases" : {

        }
      },
      "editedValues" : {

      },
      "identities" : [
        "ivar:5"
      ],
      "schemaVersion" : 2,
      "state" : {
        "columns" : [

        ],
        "filters" : {
          "composition" : "all",
          "filters" : [

          ]
        },
        "metadataColumns" : [

        ],
        "samples" : [

        ],
        "sortKeys" : [

        ]
      }
    }
    """

    /// ARCH ruling on 12.39 R2. Each family field alone writes schema 2 and reads back equal, a field set after the
    /// init writes 2 too, and a nil field writes no key.
    func testFamilyFieldWritesSchemaTwoAndRoundTrips() throws {
        let table = ViewerExportSelection(
            identities: ["variant:7"],
            annotationTable: AnnotationTableExportSelection(
                scope: "allMatchingRows",
                columns: [ScientificTableColumn(id: "chromosome", title: "Chromosome")],
                numericColumnIDs: ["quality", "position"],
                integerColumnIDs: ["position"],
                query: ["tab": "variants"],
                variantChromosomeAliases: ["chr1": "1"],
                codingFeatureRegion: AnnotationTableFeatureRegion(chromosome: "chr1", start: 0, end: 500, trackIDs: ["genes"])
            )
        )
        let annotations = [SequenceAnnotation(type: .gene, name: "unsaved", chromosome: "chr1", start: 1, end: 9)]
        let document = ViewerExportSelection(documentAnnotations: AnnotationExportDocumentSelection(
            sourceName: "Edited document", sourcePath: "/tmp/edited.gb", annotations: annotations
        ))
        for (name, selection) in [("annotationTable", table), ("documentAnnotations", document)] {
            XCTAssertEqual(selection.schemaVersion, 2, name)
            let url = try selection.write(besideOutput: folder.appendingPathComponent("out.tsv"))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(object["schemaVersion"] as? Int, 2, name)
            XCTAssertEqual(Set(object.keys).subtracting(["editedValues", "identities", "schemaVersion", "state"]), [name])
            XCTAssertEqual(try ViewerExportSelection.read(from: url), selection, name)
        }
        XCTAssertEqual(table.annotationTable?.numericColumnIDs, ["position", "quality"], "sorted for one digest")

        var late = ViewerExportSelection(identities: ["a"])
        XCTAssertEqual(late.schemaVersion, 1)
        late.documentAnnotations = document.documentAnnotations
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: late.encoded()) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
    }

    /// ARCH ruling on 12.39 R2, moved by V1-1 of Phase 2.13. A file newer than schema 3 is refused.
    func testSchemaFourIsRefused() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Self.selection.encoded()) as? [String: Any]
        )
        object["schemaVersion"] = 4
        let url = folder.appendingPathComponent("selection.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try ViewerExportSelection.read(from: url)) { error in
            XCTAssertEqual(error as? ViewerExportSelection.ReadError, .unsupportedSchema(4))
        }
    }

    /// V1-1 of Phase 2.13 (lane 13.38 M2). A selection naming the bundle-wide CDS tracks writes schema 3 with the ids
    /// sorted, and reads back equal. A field set after the init writes 3 too.
    func testBundleCodingFeatureSelectionWritesSchemaThree() throws {
        let table = AnnotationTableExportSelection(
            scope: "selected", columns: [ScientificTableColumn(id: "aa_change", title: "AA Change")],
            bundleCodingFeatureTrackIDs: ["cds2", "cds"]
        )
        let selection = ViewerExportSelection(identities: ["ivar:5"], annotationTable: table)
        XCTAssertEqual(selection.schemaVersion, 3)
        let url = try selection.write(besideOutput: folder.appendingPathComponent("out.tsv"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        let written = try XCTUnwrap(object["annotationTable"] as? [String: Any])
        XCTAssertEqual(written["bundleCodingFeatureTrackIDs"] as? [String], ["cds", "cds2"])
        XCTAssertNil(written["codingFeatureRegion"], "a new selection names no region")
        XCTAssertEqual(try ViewerExportSelection.read(from: url), selection)

        var late = ViewerExportSelection(
            identities: ["ivar:5"], annotationTable: AnnotationTableExportSelection(scope: "selected", columns: [])
        )
        XCTAssertEqual(late.schemaVersion, 2)
        late.annotationTable?.bundleCodingFeatureTrackIDs = []
        let lateObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: late.encoded()) as? [String: Any])
        XCTAssertEqual(lateObject["schemaVersion"] as? Int, 3, "an empty list is valid and still writes 3")
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
