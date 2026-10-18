// BlastSubmitNoProjectTests.swift - A BLAST read action with no project open refuses and starts nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.08, A65-NOPROJECT and DEC Q-U8. With no project, `BlastSubmitPlan.make` used to fall back to the
// source result or a system temporary folder, so a search could land where no row named it. Each site on
// `blast submit` now refuses before it writes anything. One case a site runs that site's plan with no project.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class BlastSubmitNoProjectTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-no-project")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testANaoMgsTaxonSearchWithNoProjectRefusesAndStartsNothing() throws {
        let source = try folder("naomgs-run")
        let reads = [("read_1", "S1", "ACGTACGTACGTACGTACGT"), ("read_2", "S2", "GGCCTTAAGGCCTTAAGGCC")].map { id, sample, bases in
            NaoMgsVirusHit(
                sample: sample, seqId: id, taxId: 11320, bestAlignmentScore: 40,
                cigar: "20M", queryStart: 0, queryEnd: 20, refStart: 0, refEnd: 20,
                readSequence: bases, readQuality: String(repeating: "I", count: 20),
                subjectSeqId: "NC_026438.1", subjectTitle: "Influenza A virus", bitScore: 40, eValue: 1e-5,
                percentIdentity: 100, editDistance: 0, fragmentLength: 20, isReverseComplement: false,
                pairStatus: "CP", queryLength: 20
            )
        }
        assertRefused {
            try ViewerViewController.naoMgsBlastSubmitPlan(
                taxonName: "Influenza A virus", taxId: 11320, readCount: 2, reads: reads, projectURL: nil, sourceResultURL: source
            )
        }
    }

    func testAnAssemblyContigSearchOutsideAProjectRefusesAndStartsNothing() throws {
        let assembly = try folder("spades-run")
        assertRefused {
            try ViewerViewController.assemblyBlastSubmitPlan(
                sourceLabel: "contig_7", taxId: nil, fastaRecords: [">contig_7\nACGTACGTACGTACGTACGT"], resultURL: assembly
            )
        }
    }

    func testAFASTASelectionSearchWithNoProjectRefusesAndStartsNothing() throws {
        let file = scratch.appendingPathComponent("genome.fasta")
        try Data(">seq_1\nACGTACGTAC\n".utf8).write(to: file)
        assertRefused {
            try ViewerViewController.fastaSelectionBlastSubmitPlan(
                sourceLabel: "1 selected sequence", sequences: [(id: "seq_1", sequence: "ACGTACGTAC")], sourceURL: file, projectURL: nil
            )
        }
    }

    func testAnNvdContigSearchWithNoProjectRefusesAndStartsNothing() throws {
        let hit = BlastSubmitParity.nvdHit(qseqid: "NODE_1", taxId: 11320, name: "Influenza A virus", scientificName: "Influenza A virus")
        assertRefused {
            try ViewerViewController.nvdBlastSubmitPlan(
                hit: hit, sequence: "ACGTACGTACGTACGTACGT", classificationName: "Influenza A virus", projectURL: nil
            )
        }
    }

    // MARK: - Helpers

    /// A folder under the scratch folder, standing in for the result a search starts from.
    private func folder(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every path under the scratch folder.
    private func written() -> [String] {
        (FileManager.default.subpaths(atPath: scratch.path) ?? []).sorted()
    }

    /// Runs the site's plan with no project through the gate every site plans through. The refusal shows
    /// `No Project Open` over the BLAST words through `NoProjectPresenterSeam`, app-modal with no window, tells
    /// the drawer nothing, leaves no plan to begin a row with and writes nothing.
    private func assertRefused(
        _ makePlan: () throws -> BlastSubmitPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let before = written()
        let presenter = RecordingNoProjectPresenter()
        var failures: [String] = []
        let plan = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(presenter) {
            ViewerViewController.blastSubmitPlan(window: nil, failure: { failures.append($0) }, makePlan)
        }
        XCTAssertNil(plan, "no plan, so the site begins no row", file: file, line: line)
        XCTAssertEqual(presenter.presentations.map(\.title), ["No Project Open"], file: file, line: line)
        XCTAssertEqual(
            presenter.presentations.map(\.message), ["Open or create a project before running BLAST."], file: file, line: line
        )
        XCTAssertNil(presenter.presentations.first?.window, "app-modal with no window", file: file, line: line)
        XCTAssertEqual(failures, [], "the drawer is told nothing", file: file, line: line)
        XCTAssertEqual(written(), before, "the refusal writes nothing", file: file, line: line)
        XCTAssertThrowsError(try makePlan(), file: file, line: line) {
            XCTAssertEqual($0 as? BlastSubmitPlanError, .noProject, file: file, line: line)
        }
    }
}
