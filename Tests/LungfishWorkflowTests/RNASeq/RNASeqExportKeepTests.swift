// RNASeqExportKeepTests.swift - Writes one export folder for the R checks of the lane (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// The R parse of both templates and the not-host run read a folder that `RNASeqExport.run` wrote. The case is skipped
/// unless `RS_HANDOFF_KEEP` names a new folder, so a plain test run writes nothing outside its own temporary folder.
final class RNASeqExportKeepTests: RNASeqExportTestCase {
    func testWritesAnExportFolderForTheRChecksWhenAskedTo() throws {
        guard let path = ProcessInfo.processInfo.environment["RS_HANDOFF_KEEP"], !path.isEmpty else {
            throw XCTSkip("RS_HANDOFF_KEEP names no folder")
        }
        let genes = (1...40).map { "G\($0)" }
        let samples = (1...8).map { "S\($0)" }
        var groups: [String: String] = [:]
        for (index, sample) in samples.enumerated() { groups[sample] = index < 4 ? "TB" : "HIV" }
        let result = try make(.init(name: "keep", samples: samples, genes: genes, notHost: ["G39", "G40"], groups: groups, noise: 0.4))
        // RS_HANDOFF_KEEP_BATCH set to combat-seq or sva writes the batch block, with a batch X or Y that crosses the group.
        let step = ProcessInfo.processInfo.environment["RS_HANDOFF_KEEP_BATCH"].flatMap(RNASeqExportSettings.BatchCorrection.init(rawValue:)) ?? .none
        var sheet: URL?
        if step != .none {
            let url = root.appendingPathComponent("batch-sheet.tsv")
            try ("sample\tbatch\n" + samples.enumerated().map { "\($1)\t\($0 % 2 == 0 ? "X" : "Y")\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
            sheet = url
        }
        let settings = RNASeqExportSettings(
            design: ["group"], contrasts: [.init(factor: "group", numerator: "TB", denominator: "HIV")], padjCutoff: 0.1, lfcBar: 1.4,
            batch: step == .none ? nil : "batch", batchCorrection: step)
        try RNASeqExport.run(
            results: [result], sheet: sheet, settings: settings, output: URL(fileURLWithPath: path),
            argv: ["lungfish-cli", "rnaseq", "export"], checkpoint: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("deseq2.R").path))
    }
}
