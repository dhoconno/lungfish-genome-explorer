// ProjectItemCopyRecordTests+SchemaOne.swift - A schema 1 copy record still loads (BIO ruling on 12.18, answer 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

extension ProjectItemCopyRecordTests {
    /// A record written before lane 12.18, frozen as text, with none of the source fields.
    private static let frozenSchemaOneRecord = """
    {
      "copiedAt" : "2026-09-24T10:00:00Z",
      "links" : [
        {
          "file" : "classification-result.json",
          "keyPath" : "config.inputFiles[0]",
          "originalPath" : "file:///Users/example/Source.lungfish/Imports/HG002.lungfishfastq/reads.fastq",
          "role" : "Input reads"
        }
      ],
      "schemaVersion" : 1,
      "sourceItemPath" : "/Users/example/Source.lungfish/Analyses/kraken2-2026-09-24T10-00-00",
      "sourceProjectPath" : "/Users/example/Source.lungfish",
      "targetProjectPath" : "/Users/example/Target.lungfish"
    }
    """

    func testSchemaOneRecordStillLoads() throws {
        let item = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectItemCopyRecordSchemaOne-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: item) }
        try Data(Self.frozenSchemaOneRecord.utf8).write(to: item.appendingPathComponent(ProjectItemCopyRecord.filename))

        let record = try XCTUnwrap(ProjectItemCopyRecord.load(from: item))

        XCTAssertEqual(record.schemaVersion, 1)
        XCTAssertEqual(record.missingSourceSummaryLines, [
            "Source data not in this project: reads.fastq (was /Users/example/Source.lungfish/Imports/HG002.lungfishfastq/reads.fastq)",
        ])
        XCTAssertNil(record.sourceItemRelativePath)
        XCTAssertNil(record.sourceItemFiles)
        XCTAssertNil(record.sourceItemDigest)
    }
}
