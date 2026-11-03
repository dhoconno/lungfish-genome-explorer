// BlastSavedSearchSelectionPlanTests.swift - An Assembly or 12S selection's saved-search key is what its plan records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN2. The plans sit in the App and the viewers cannot reach them. These tests build both for one
// selection and compare them, and they pin the folder each viewer scans to the folder its plan saves under.

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp

final class BlastSavedSearchSelectionPlanTests: XCTestCase {
    private var folder: URL!
    private var project: URL!
    private var result: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = try TestTempDirectory.make(prefix: "blast-selection-plan")
        project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        result = project.appendingPathComponent("Analyses/run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
        try super.tearDownWithError()
    }

    private func lineage(of plan: BlastSubmitPlan) -> BlastSubmissionRecord.Lineage {
        .init(
            sourceResult: plan.request.sourceResultURL?.path, sample: plan.request.sample,
            taxId: plan.request.taxId, contig: plan.request.contig
        )
    }

    func testAnAssemblySelectionsKeyIsItsPlansLineageAndBasesInAnyOrder() throws {
        let records = [">contig_9 second header\nATAT\n", ">contig_7 annotated header\nAACC\n"]
        let plan = try ViewerViewController.assemblyBlastSubmitPlan(
            sourceLabel: "2 contigs", taxId: nil, fastaRecords: records, resultURL: result
        )
        XCTAssertEqual(plan.request.contig, "contig_9,contig_7", "the record keeps the contigs in the order they were sent")
        let held = folder.appendingPathComponent("held-assembly", isDirectory: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try plan.queryData.write(to: held.appendingPathComponent(BlastSubmissionRecord.queryFileName))
        let recordURL = held.appendingPathComponent(BlastSubmissionRecord.recordFileName)

        // The pane reads each contig's FASTA, and the key holds the sequences of those texts.
        let bases = BlastSavedSearchRow.sequences(ofFASTA: records.joined())
        let key = try XCTUnwrap(BlastSavedSearchRow.assemblySelection(
            contigs: ["contig_7", "contig_9"], sequences: bases.reversed(), resultURL: result
        ))
        XCTAssertTrue(key.isSource(of: lineage(of: plan), recordAt: recordURL))
        let other = try XCTUnwrap(BlastSavedSearchRow.assemblySelection(contigs: ["contig_7"], sequences: [bases[1]], resultURL: result))
        XCTAssertFalse(other.isSource(of: lineage(of: plan), recordAt: recordURL))
        let changed = [bases[0], BlastSavedSearchRow.QuerySequence(id: "contig_7", sequence: "TTTT")]
        let changedKey = try XCTUnwrap(BlastSavedSearchRow.assemblySelection(
            contigs: ["contig_7", "contig_9"], sequences: changed, resultURL: result
        ))
        XCTAssertFalse(changedKey.isSource(of: lineage(of: plan), recordAt: recordURL), "the same names over other bases are another search")
        XCTAssertNil(BlastSavedSearchRow.assemblySelection(contigs: [], sequences: [], resultURL: result))
        XCTAssertNil(
            BlastSavedSearchRow.assemblySelection(contigs: ["contig_7", "contig_9"], sequences: [bases[1]], resultURL: result),
            "a selection with fewer sequences than contigs cannot be shown to be the same search"
        )

        XCTAssertEqual(
            plan.request.outputURL.deletingLastPathComponent().path,
            result.appendingPathComponent(BlastSubmitPlan.resultsFolderName).path,
            "the Assembly viewer scans the result folder because its plan saves there"
        )
    }

    func testATwelveSSelectionsKeyIsItsPlansLineageAndQuery() throws {
        let sequences: [(id: String, sequence: String)] = [(id: "unresolved_1", sequence: "ACGT"), (id: "unresolved_2", sequence: "TGCA")]
        let plan = try ViewerViewController.twelveSUnresolvedBlastSubmitPlan(
            sequences: sequences, bundleURL: result, projectURL: project
        )
        XCTAssertNil(plan.request.contig, "a 12S search names no contig, so its query tells selections apart")
        XCTAssertNil(plan.request.sample)
        XCTAssertNil(plan.request.taxId)

        let held = folder.appendingPathComponent("held", isDirectory: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try plan.queryData.write(to: held.appendingPathComponent(BlastSubmissionRecord.queryFileName))
        let recordURL = held.appendingPathComponent(BlastSubmissionRecord.recordFileName)

        func key(_ pairs: [(id: String, sequence: String)]) throws -> BlastSavedSearchRow {
            try XCTUnwrap(BlastSavedSearchRow.twelveSSelection(
                sequences: pairs.map { BlastSavedSearchRow.QuerySequence(id: $0.id, sequence: $0.sequence) }, bundleURL: result
            ))
        }
        XCTAssertTrue(try key(sequences.reversed()).isSource(of: lineage(of: plan), recordAt: recordURL))
        XCTAssertFalse(try key([sequences[0]]).isSource(of: lineage(of: plan), recordAt: recordURL), "one row of the two")
        XCTAssertFalse(
            try key([sequences[0], (id: "unresolved_2", sequence: "TTTT")]).isSource(of: lineage(of: plan), recordAt: recordURL),
            "the same IDs with one sequence changed are another search"
        )
        XCTAssertNil(BlastSavedSearchRow.twelveSSelection(sequences: [], bundleURL: result))

        XCTAssertEqual(
            plan.request.outputURL.deletingLastPathComponent().path,
            project.appendingPathComponent(BlastSubmitPlan.resultsFolderName).path,
            "the 12S viewer scans the project because its plan saves there"
        )
    }
}
