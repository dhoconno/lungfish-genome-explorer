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

    func testAnAssemblySelectionsKeyIsItsPlansLineageInAnyOrder() throws {
        let plan = try ViewerViewController.assemblyBlastSubmitPlan(
            sourceLabel: "2 contigs", taxId: nil,
            fastaRecords: [">contig_9 second header\nATAT\n", ">contig_7 annotated header\nAACC\n"], resultURL: result
        )
        let recordURL = plan.request.outputURL.appendingPathComponent(BlastSubmissionRecord.recordFileName)

        let key = try XCTUnwrap(BlastSavedSearchRow.assemblySelection(contigs: ["contig_7", "contig_9"], resultURL: result))
        XCTAssertTrue(key.isSource(of: lineage(of: plan), recordAt: recordURL))
        let other = try XCTUnwrap(BlastSavedSearchRow.assemblySelection(contigs: ["contig_7"], resultURL: result))
        XCTAssertFalse(other.isSource(of: lineage(of: plan), recordAt: recordURL))
        XCTAssertNil(BlastSavedSearchRow.assemblySelection(contigs: [], resultURL: result))

        XCTAssertEqual(
            plan.request.outputURL.deletingLastPathComponent().path,
            result.appendingPathComponent(BlastSubmitPlan.resultsFolderName).path,
            "the Assembly viewer scans the result folder because its plan saves there"
        )
    }

    func testATwelveSSelectionsKeyIsItsPlansLineageAndQuery() throws {
        let plan = try ViewerViewController.twelveSUnresolvedBlastSubmitPlan(
            sequences: [(id: "unresolved_1", sequence: "ACGT"), (id: "unresolved_2", sequence: "TGCA")],
            bundleURL: result, projectURL: project
        )
        XCTAssertNil(plan.request.contig, "a 12S search names no contig, so its query tells selections apart")
        XCTAssertNil(plan.request.sample)
        XCTAssertNil(plan.request.taxId)

        let held = folder.appendingPathComponent("held", isDirectory: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try plan.queryData.write(to: held.appendingPathComponent(BlastSubmissionRecord.queryFileName))
        let recordURL = held.appendingPathComponent(BlastSubmissionRecord.recordFileName)

        let key = try XCTUnwrap(BlastSavedSearchRow.twelveSSelection(sequenceIDs: ["unresolved_2", "unresolved_1"], bundleURL: result))
        XCTAssertTrue(key.isSource(of: lineage(of: plan), recordAt: recordURL))
        let other = try XCTUnwrap(BlastSavedSearchRow.twelveSSelection(sequenceIDs: ["unresolved_1"], bundleURL: result))
        XCTAssertFalse(other.isSource(of: lineage(of: plan), recordAt: recordURL))
        XCTAssertNil(BlastSavedSearchRow.twelveSSelection(sequenceIDs: [], bundleURL: result))

        XCTAssertEqual(
            plan.request.outputURL.deletingLastPathComponent().path,
            project.appendingPathComponent(BlastSubmitPlan.resultsFolderName).path,
            "the 12S viewer scans the project because its plan saves there"
        )
    }
}
