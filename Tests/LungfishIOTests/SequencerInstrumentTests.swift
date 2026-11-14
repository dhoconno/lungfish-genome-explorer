// SequencerInstrumentTests.swift - The instrument facts one pass over the read names gives (row RS-INSTRUMENT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Names of three families (Illumina CASAVA 1.8, Illumina before 1.8 and MGI) give their instrument facts, a name
/// SRA rewrote reads Not recorded, and an instrument id the table does not list reads Unknown.
final class SequencerInstrumentTests: XCTestCase {

    private func instrument(ofFixture name: String) throws -> SequencerInstrument {
        try FASTQReadLayoutClassifier.scanMates(in: PlatformHeaderFixtures.url(name)).instrument
    }

    func testCasava18NamesGiveInstrumentRunFlowcellAndLane() throws {
        let novaSeq = try instrument(ofFixture: "illumina-novaseq6000.fastq")
        XCTAssertEqual(novaSeq.nameForm, .casava18)
        XCTAssertEqual(novaSeq.instrumentIDs, ["A00488"])
        XCTAssertEqual(novaSeq.runNumbers, [61])
        XCTAssertEqual(novaSeq.flowcells, ["HMLGNDSXX"])
        XCTAssertEqual(novaSeq.lanes, [4])
        XCTAssertEqual(novaSeq.models, ["NovaSeq 6000"])
        XCTAssertTrue(novaSeq.modelsAreInferred, "A model read from a table is never recorded as read from the run")
        XCTAssertFalse(novaSeq.modelSource.isEmpty, "The table cites its source")

        let miSeq = try instrument(ofFixture: "illumina-miseq-dash-flowcell.fastq")
        XCTAssertEqual(miSeq.instrumentIDs, ["M00123"])
        XCTAssertEqual(miSeq.runNumbers, [45])
        XCTAssertEqual(miSeq.flowcells, ["000000000-A1B2C"])
        XCTAssertEqual(miSeq.lanes, [1])
        XCTAssertEqual(miSeq.models, ["MiSeq"])
    }

    func testAnOriginalNameBehindAnAccessionIsRead() throws {
        let ena = try instrument(ofFixture: "ena-renamed-illumina.fastq")
        XCTAssertEqual(ena.nameForm, .casava18)
        XCTAssertEqual(ena.instrumentIDs, ["NS500628"])
        XCTAssertEqual(ena.runNumbers, [121])
        XCTAssertEqual(ena.flowcells, ["HK3MMAFX2"])
        XCTAssertEqual(ena.lanes, [2])
        XCTAssertEqual(ena.models, ["NextSeq 500"])
    }

    func testNamesBeforeCasava18GiveInstrumentAndLaneOnly() throws {
        let old = try instrument(ofFixture: "illumina-pre18.fastq")
        XCTAssertEqual(old.nameForm, .illuminaBeforeCasava18)
        XCTAssertEqual(old.instrumentIDs, ["HWUSI-EAS100R"])
        XCTAssertEqual(old.lanes, [6])
        XCTAssertEqual(old.runNumbers, [], "These names carry no run")
        XCTAssertEqual(old.flowcells, [], "These names carry no flow cell")
        XCTAssertEqual(old.models, ["Genome Analyzer"])
    }

    func testMGINamesGiveFlowcellAndLaneAndNoInstrumentModel() throws {
        let mgi = try instrument(ofFixture: "mgi-dnbseq.fastq")
        XCTAssertEqual(mgi.nameForm, .mgi)
        XCTAssertEqual(mgi.flowcells, ["V300012345"])
        XCTAssertEqual(mgi.lanes, [1])
        XCTAssertEqual(mgi.instrumentIDs, [], "An MGI name carries no instrument id")
        XCTAssertEqual(mgi.summary, "Unknown")
    }

    func testANameSRARewroteReadsNotRecorded() throws {
        let sra = try instrument(ofFixture: "sra-renamed-short.fastq")
        XCTAssertEqual(sra.nameForm, .notRecorded)
        XCTAssertEqual(sra.instrumentIDs, [])
        XCTAssertEqual(sra.namedRecords, 0)
        XCTAssertEqual(sra.unnamedRecords, 4)
        XCTAssertEqual(sra.summary, "Not recorded")
    }

    func testAnUnlistedInstrumentIdReadsUnknownAndEveryLaneIsKept() throws {
        let root = try TestTempDirectory.make(prefix: "instrument")
        defer { TestTempDirectory.cleanup(root) }
        // Lane 1, then lane 10, then lane 2. The cache of the scan must not take lane 10 for lane 1.
        let names = ["ZZ99999:7:FLOWCELL1:1:1101:10:20 1:N:0:ACGT", "ZZ99999:7:FLOWCELL1:10:1101:10:21 1:N:0:ACGT",
                     "ZZ99999:7:FLOWCELL1:2:1101:10:22 1:N:0:ACGT"]
        let text = names.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
        let url = root.appendingPathComponent("lanes.fastq")
        try Data(text.utf8).write(to: url)
        let found = try FASTQReadLayoutClassifier.scanMates(in: url).instrument
        XCTAssertEqual(found.instrumentIDs, ["ZZ99999"])
        XCTAssertEqual(found.lanes, [1, 2, 10])
        XCTAssertEqual(found.models, ["Unknown"])
        XCTAssertEqual(found.summary, "Unknown (instrument id ZZ99999)")
    }
}
