// BlastServiceSourcesTests.swift - A BLAST verification reads every source file of a Kraken2 result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 1.5 lane A3, defect D8. A Kraken2 result of pairs plus merged reads
// keeps its reads in an R1 file, an R2 file and a file of merged reads. The
// verification used to read one file, so a fragment whose evidence sits on
// mate 2 was submitted as mate 1, and a merged fragment was never found.
// No test here touches the network.

import XCTest
@testable import LungfishCore

final class BlastServiceSourcesTests: XCTestCase {

    private var service: BlastService!
    private var directory: URL!

    private let taxId = 10298
    private let clade: Set<Int> = [10298]

    // Every mate has its own sequence, so the test can tell which was sent.
    private let r1Sequences = ["f1": String(repeating: "A", count: 20), "f2": String(repeating: "T", count: 20)]
    private let r2Sequences = ["f1": String(repeating: "C", count: 20), "f2": String(repeating: "G", count: 20)]
    private let mergedSequence = String(repeating: "AC", count: 15)

    override func setUp() async throws {
        try await super.setUp()
        service = BlastService()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlastServiceSourcesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        service = nil
        try await super.tearDown()
    }

    /// f1 carries the taxon's k-mers on mate 2 and f2 on mate 1. Both mates
    /// share one name with no /1 or /2, so only the file says which is which.
    func testAFragmentWhoseEvidenceIsOnMate2IsSubmittedFromTheR2File() async throws {
        let files = try writeSources(merged: false)
        let kraken = try writeKraken([
            "C\tf1\t\(taxId)\t20|20\t0:16 |:| \(taxId):16",
            "C\tf2\t\(taxId)\t20|20\t\(taxId):16 |:| 0:16",
        ])

        for request in try await bothRequests(ids: ["f1", "f2"], sources: files, kraken: kraken) {
            XCTAssertEqual(sequence(of: "f1", in: request), r2Sequences["f1"], "f1 is sent from the R2 file")
            XCTAssertEqual(request.sequenceMates["f1"], 2)
            XCTAssertEqual(sequence(of: "f2", in: request), r1Sequences["f2"], "f2 is sent from the R1 file")
            XCTAssertEqual(request.sequenceMates["f2"], 1)
        }
    }

    /// x1 is a merged read, classified with an empty mate 2. It sits only in
    /// the file of merged reads.
    func testAMergedFragmentIsFoundInTheMergedFile() async throws {
        let files = try writeSources(merged: true)
        let kraken = try writeKraken([
            "C\tf1\t\(taxId)\t20|20\t0:16 |:| \(taxId):16",
            "C\tx1\t\(taxId)\t30|0\t\(taxId):26 |:| ",
        ])

        for request in try await bothRequests(ids: ["f1", "x1"], sources: files, kraken: kraken) {
            XCTAssertEqual(request.sequences.count, 2)
            XCTAssertEqual(sequence(of: "x1", in: request), mergedSequence, "x1 is read from the merged file")
            XCTAssertEqual(sequence(of: "f1", in: request), r2Sequences["f1"])
        }
    }

    // MARK: - Helpers

    /// The request from the Kraken2 scan and from pre-fetched read IDs, the
    /// app's two routes. They must agree.
    private func bothRequests(ids: Set<String>, sources: [BlastReadSource], kraken: URL) async throws -> [BlastVerificationRequest] {
        let scanned = try await service.buildVerificationRequest(
            taxonName: "Human alphaherpesvirus 1",
            taxId: taxId,
            targetTaxIds: clade,
            classificationOutputURL: kraken,
            sources: sources,
            readCount: 10
        )
        let indexed = try await service.buildVerificationRequestFromReadIds(
            taxonName: "Human alphaherpesvirus 1",
            taxId: taxId,
            matchingReadIds: ids,
            sources: sources,
            readCount: 10,
            targetTaxIds: clade,
            classificationOutputURL: kraken
        )
        XCTAssertEqual(scanned.sequences.map(\.id), indexed.sequences.map(\.id))
        XCTAssertEqual(scanned.sequences.map(\.sequence), indexed.sequences.map(\.sequence))
        XCTAssertEqual(scanned.sequenceMates, indexed.sequenceMates)
        return [scanned, indexed]
    }

    private func writeSources(merged: Bool) throws -> [BlastReadSource] {
        let r1 = directory.appendingPathComponent("sample_R1.fastq")
        let r2 = directory.appendingPathComponent("sample_R2.fastq")
        try ["f1", "f2"].map { record($0, r1Sequences[$0]!) }.joined().write(to: r1, atomically: true, encoding: .utf8)
        try ["f1", "f2"].map { record($0, r2Sequences[$0]!) }.joined().write(to: r2, atomically: true, encoding: .utf8)
        var sources = [BlastReadSource(url: r1, unmarkedMate: 1), BlastReadSource(url: r2, unmarkedMate: 2)]
        if merged {
            let mergedFile = directory.appendingPathComponent("merged.fastq")
            try (record("x0", String(repeating: "G", count: 30)) + record("x1", mergedSequence))
                .write(to: mergedFile, atomically: true, encoding: .utf8)
            sources.append(BlastReadSource(url: mergedFile))
        }
        return sources
    }

    private func writeKraken(_ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent("classification.kraken")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func record(_ name: String, _ sequence: String) -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    private func sequence(of id: String, in request: BlastVerificationRequest) -> String? {
        request.sequences.first { $0.id == id }?.sequence
    }
}
