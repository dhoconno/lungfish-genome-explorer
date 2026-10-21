// AnnotationDatabaseGFFExporterPhaseTests.swift - Column 8 and the shared ID of a multi-block CDS export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (V1-2, BIO ruling on 13.65 R5 and R7, QA Q5, Q-B3 of the 13.20 ruling). Each case writes a
// database through the leaf exporter (`AnnotationDatabaseGFFExporter.export`) and reads its lines back.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AnnotationDatabaseGFFExporterPhaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationDatabaseGFFExporterPhase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A database built by `createFromBED` from `lines`.
    private func bedDatabase(_ lines: String) throws -> AnnotationDatabase {
        let bed = folder.appendingPathComponent("rows.bed")
        try lines.write(to: bed, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("bed-\(UUID().uuidString).db")
        try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: url)
        return try AnnotationDatabase(url: url)
    }

    /// The feature lines of the leaf's export of `database`, each split into its nine columns.
    private func exportedLines(_ database: AnnotationDatabase) throws -> [[String]] {
        let url = folder.appendingPathComponent("export-\(UUID().uuidString).gff3")
        try AnnotationDatabaseGFFExporter.export(database: database, to: url)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Pin 10 (Q-B3). A one-block row whose stored pairs hold no `ID` is one feature on one line, so it writes its
    /// pairs unchanged and claims no ID.
    func testASingleLineRowWithoutAnIDKeepsItsPairs() throws {
        let database = try bedDatabase("chrB\t9\t60\torf1\t0\t+\t9\t60\t0\t1\t51\t0\tCDS\tgene=g;product=p\n")

        let lines = try exportedLines(database)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?[3], "10")
        XCTAssertEqual(lines.first?[4], "60")
        XCTAssertEqual(lines.first?[8], "gene=g;product=p")
    }
}
