// MappingDocumentCommandDisplayTests+Rehydration.swift - What the path rehydrator does with a renamed mapping record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishOperations
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.45 (SW2 R-REPLAY), M2b, the open fact of ARCH-13.45. The renamed mapping fixture of
/// `testARenamedMappingResultsDocumentTabShowsTheCommandMappedByTheRelocation`, with `ProvenancePathRehydrator.rehydrate`
/// called directly in place of the sidebar. The record of 12.25's fixture names the folder only inside `argv`, which
/// the rehydrator keeps as it ran, so its bytes stay. A record with an output descriptor, as `ManagedMappingPipeline`
/// writes one, has that path moved and its commands kept.
extension MappingDocumentCommandDisplayTests {

    func testThePathRehydratorRewritesTheMappingRecordsPathsAndKeepsItsCommands() throws {
        let bare = try renamedMappingRecord(outputFiles: { _ in [] })
        XCTAssertEqual(bare.after, bare.before, "the record names the folder only in its commands")
        XCTAssertEqual(bare.failures, [])

        let described = try renamedMappingRecord(outputFiles: { [FileRecord(path: $0.path, role: .output)] })
        XCTAssertEqual(described.failures, [])
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: described.after) as? [String: Any])
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: described.before) as? [String: Any])
        XCTAssertEqual(
            (record["outputFiles"] as? [[String: Any]])?.compactMap { $0["path"] as? String },
            ["@/Analyses/minimap2-run renamed/sample.sorted.bam"]
        )
        for key in ["mapperInvocation", "normalizationInvocations"] {
            XCTAssertEqual(
                try JSONSerialization.data(withJSONObject: XCTUnwrap(record[key]), options: .sortedKeys),
                try JSONSerialization.data(withJSONObject: XCTUnwrap(before[key]), options: .sortedKeys),
                "\(key) keeps the commands as they ran"
            )
        }
    }

    /// The saved mapping result with `outputFiles`, its folder renamed to `minimap2-run renamed` and the path rehydrator
    /// run on it, with the record's bytes before and after and any failure the rehydrator logged.
    private func renamedMappingRecord(
        outputFiles: @escaping (URL) -> [FileRecord]
    ) throws -> (before: Data, after: Data, failures: [String]) {
        let saved = try savedResult(outputFiles: outputFiles)
        let before = try Data(contentsOf: saved.folder.appendingPathComponent(MappingProvenance.filename))
        let renamed = saved.folder.deletingLastPathComponent().appendingPathComponent("minimap2-run renamed", isDirectory: true)
        try FileManager.default.moveItem(at: saved.folder, to: renamed)
        var failures: [String] = []
        ProvenancePathRehydrator.rehydrate(from: saved.folder, to: renamed, signingProvider: nil) { failures.append($0) }
        return (before, try Data(contentsOf: renamed.appendingPathComponent(MappingProvenance.filename)), failures)
    }
}
