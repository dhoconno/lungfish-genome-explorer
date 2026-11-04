// BlastConsentLineTests.swift - Every BLAST route says what leaves this Mac before it sends anything
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishAssemblyUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishNvdUI
import LungfishTwelveSUI
import XCTest
@testable import LungfishApp

/// Phase 3.2 lane BLASTNET N5 (UX-BLAST-WORDS Q4). A search NCBI holds goes out up to three times, and a person is told
/// so before the first send. The five sheet sites show the line through `BlastConfigPopoverView`. The other four routes
/// start on one click, so they ask on a sheet, and these tests fire each one with the sheet held open.
@MainActor
final class BlastConsentLineTests: XCTestCase {
    private var shown: [String] = []
    private var held: [@MainActor () -> Void] = []

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        BlastConsentSheet.presenterForTesting = { [weak self] line, send in
            self?.shown.append(line)
            self?.held.append(send)
        }
    }

    override func tearDown() async throws {
        BlastConsentSheet.presenterForTesting = nil
        try await super.tearDown()
    }

    private func line(noun: String, database: String) -> String {
        "Sends the selected \(noun) to NCBI BLASTN \(database), so they leave this Mac. "
            + "If NCBI is slow, LGE sends the same \(noun) again, at most three sends in all. The record lists every send."
    }

    private func viewer() -> ViewerViewController {
        let viewer = ViewerViewController()
        _ = viewer.view
        return viewer
    }

    private func nvdHit() -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-1", blastTask: "blastn", sampleId: "sample1", qseqid: "contig_1",
            qlen: 8, sseqid: "NC_000001.1", stitle: "Reference", taxRank: "species", length: 8, pident: 100, evalue: 0,
            bitscore: 50, sscinames: "Example virus", staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
            mappedReads: 1_000, totalReads: 1_000, statDbVersion: "stats-1", adjustedTaxid: "1234",
            adjustmentMethod: "dominant", adjustedTaxidName: "Example virus", adjustedTaxidRank: "species",
            hitRank: 1, readsPerBillion: 10_000
        )
    }

    func testEveryBlastRouteShowsTheConsentLine() throws {
        // Kraken2, EsViritu, TaxTriage (two sites) and NAO-MGS, each of which builds `BlastConfigPopoverView`.
        XCTAssertEqual(BlastConfigPopoverView.submissionCaption(database: "nt"), line(noun: "reads", database: "nt"))
        XCTAssertEqual(BlastConfigPopoverView.submissionCaption(database: "core_nt"), line(noun: "reads", database: "core_nt"))

        let nvdViewer = viewer()
        let nvd = NvdResultViewController()
        try nvdViewer.displayNvdResult(nvd)
        nvd.onBlastVerification?(nvdHit(), "")
        XCTAssertEqual(shown, [line(noun: "contigs", database: "core_nt")], "NVD")
        shown = []

        let assemblyViewer = viewer()
        assemblyViewer.displayAssemblyResult(try makeAssemblyResult())
        assemblyViewer.assemblyResultController?.onBlastVerification?(
            BlastRequest(taxId: nil, sequences: [], readCount: 0, sourceLabel: "selected contigs")
        )
        XCTAssertEqual(shown, [line(noun: "contigs", database: "core_nt")], "Assembly")
        shown = []

        let twelveSViewer = viewer()
        let twelveS = TwelveSAmpliconResultViewController()
        twelveSViewer.wireTwelveSUnresolvedBlast(twelveS)
        twelveS.onUnresolvedBlastRequested?(
            TwelveSUnresolvedBlastRequest(bundleURL: URL(fileURLWithPath: "/nonexistent.lungfish12s"), minimumReads: 0, sequences: [])
        )
        XCTAssertEqual(shown, [line(noun: "sequences", database: "core_nt")], "12S")
        shown = []

        let fastaViewer = viewer()
        fastaViewer.fastaBlastVerificationRunner = { _, _ in throw CancellationError() }
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")
        fastaViewer.displayFASTACollection(sequences: [sequence], annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(fastaViewer.children.compactMap { $0 as? FASTACollectionViewController }.first)
        collection.onBlastRequested?([sequence])
        XCTAssertEqual(shown, [line(noun: "sequences", database: "core_nt")], "FASTA selection")
    }

    /// The line stands before the send, so nothing goes out until the person answers it, and Cancel sends nothing.
    func testNothingGoesOutBeforeThePersonRunsIt() async throws {
        let ran = expectation(description: "the search ran after Run BLAST")
        let fastaViewer = viewer()
        var runs = 0
        fastaViewer.fastaBlastVerificationRunner = { _, _ in
            runs += 1
            ran.fulfill()
            throw CancellationError()
        }
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")
        fastaViewer.displayFASTACollection(sequences: [sequence], annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(fastaViewer.children.compactMap { $0 as? FASTACollectionViewController }.first)

        collection.onBlastRequested?([sequence])
        await Task.yield()
        XCTAssertEqual(runs, 0, "nothing is sent while the sheet is open")
        XCTAssertEqual(held.count, 1)

        held[0]()
        await fulfillment(of: [ran], timeout: 30)
        XCTAssertEqual(runs, 1)
    }
}
