// OutputEquivalenceTests.swift - Self-tests for the replay comparison in LungfishTestSupport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each kind docs/contracts/CLI-EQUIVALENCE.md names gets a pair of tiny
// hand-made trees that must compare as the same result, and a pair that must
// not. The BAM case needs samtools, so it lives in CLIReplayHarnessReplayTests
// in the integration tier.

import Foundation
import SQLite3
import XCTest
import LungfishTestSupport

final class OutputEquivalenceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "output-equivalence")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - files

    func testFilesMatchAfterMasksAndDecompression() throws {
        let (a, b) = try makeRoots()
        for (root, uuid, date) in [(a, UUID(), "2026-10-03T09:00:00Z"), (b, UUID(), "2026-10-04T11:30:15Z")] {
            try write("wrote \(root.path)/out/reads.fastq\n", to: root, "log.txt")
            try write(
                #"{"runID":""# + uuid.uuidString + #"","startedAt":""# + date + #"","output":""# + root.path + #"/out/reads.fasta"}"#,
                to: root,
                "out/reads.fasta.lungfish-provenance.json"
            )
            try write(">seq1\nACGT\n", to: root, "out/reads.fasta")
            try write(
                "##fileformat=VCFv4.2\n##fileDate=\(date.prefix(10))\n##bcftools_callCommand=call -o \(root.path)/x.vcf\n"
                    + "#CHROM\tPOS\tID\tREF\tALT\nchr1\t5\t.\tA\tG\n",
                to: root,
                "out/calls.vcf"
            )
        }
        // The same bytes compressed with and without the name and time header.
        try gzip("@r1\nACGT\n+\nIIII\n", to: a, "out/reads.fastq.gz", keepNameAndTime: true)
        try gzip("@r1\nACGT\n+\nIIII\n", to: b, "out/reads.fastq.gz", keepNameAndTime: false)
        XCTAssertNotEqual(
            try Data(contentsOf: a.appendingPathComponent("out/reads.fastq.gz")),
            try Data(contentsOf: b.appendingPathComponent("out/reads.fastq.gz")),
            "the fixture must differ in its gzip header"
        )

        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .files), [])
        OutputEquivalence.assertSame(a, b, kind: .files)
    }

    func testFilesDifferWhenContentOrInventoryDiffers() throws {
        let (a, b) = try makeRoots()
        try write(">seq1\nACGT\n", to: a, "reads.fasta")
        try write(">seq1\nACGA\n", to: b, "reads.fasta")
        try gzip("@r1\nACGT\n+\nIIII\n", to: a, "reads.fastq.gz", keepNameAndTime: false)
        try gzip("@r1\nACGG\n+\nIIII\n", to: b, "reads.fastq.gz", keepNameAndTime: false)
        try write("extra\n", to: a, "only-a.txt")

        let found = try OutputEquivalence.differences(a, b, kind: .files)
        XCTAssertTrue(found.contains { $0.hasPrefix("differs: reads.fasta") }, "\(found)")
        XCTAssertTrue(found.contains { $0.hasPrefix("differs: reads.fastq.gz") }, "\(found)")
        XCTAssertTrue(found.contains("only in A: only-a.txt"), "\(found)")
    }

    func testPayloadsDifferWhenOnlyADateAHostOrAReadIDDiffers() throws {
        for kind in [OutputEquivalence.Kind.files, .bundle] {
            let (a, b) = try makeRoots()
            // A quality string that reads like a date.
            try write("@r1\nACGTACGTAC\n+\n2024-01-01\n", to: a, "reads.fastq")
            try write("@r1\nACGTACGTAC\n+\n2025-01-01\n", to: b, "reads.fastq")
            // Two nanopore reads, whose IDs are UUIDs.
            try write("@\(UUID().uuidString.lowercased())\nACGT\n+\nIIII\n", to: a, "nanopore.fastq")
            try write("@\(UUID().uuidString.lowercased())\nACGT\n+\nIIII\n", to: b, "nanopore.fastq")
            let header = "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
            try write(header + "chr1\t5\t.\tA\tG\t50\tPASS\tDATE=2024-01-01\n", to: a, "calls.vcf")
            try write(header + "chr1\t5\t.\tA\tG\t50\tPASS\tDATE=2025-01-01\n", to: b, "calls.vcf")
            // Sample metadata is a payload, so its host is data.
            try write(#"{"sample":"s1","host":"Homo sapiens","collected":"2024-01-01"}"#, to: a, "samples.json")
            try write(#"{"sample":"s1","host":"Macaca mulatta","collected":"2024-01-01"}"#, to: b, "samples.json")
            let found = try OutputEquivalence.differences(a, b, kind: kind)
            for name in ["reads.fastq", "nanopore.fastq", "calls.vcf", "samples.json"] {
                XCTAssertTrue(found.contains { $0.hasPrefix("differs: \(name)") }, "\(kind) \(name): \(found)")
            }
            XCTAssertEqual(found.count, 4, "\(kind): \(found)")
            try FileManager.default.removeItem(at: a)
            try FileManager.default.removeItem(at: b)
        }
    }

    func testVCFKeepsItsRecordsAndOtherHeaderLines() throws {
        let (a, b) = try makeRoots()
        try write("##fileformat=VCFv4.2\n##INFO=<ID=DP>\n#CHROM\tPOS\nchr1\t5\n", to: a, "calls.vcf")
        try write("##fileformat=VCFv4.2\n##INFO=<ID=AF>\n#CHROM\tPOS\nchr1\t5\n", to: b, "calls.vcf")
        XCTAssertFalse(try OutputEquivalence.differences(a, b, kind: .files).isEmpty)
    }

    // MARK: - database

    func testDatabasesMatchOnSortedRowsWhateverTheInsertOrder() throws {
        let (a, b) = try makeRoots()
        try makeDatabase(a.appendingPathComponent("tracks.sqlite"), rows: [("gene1", 10), ("gene2", 20)])
        try makeDatabase(b.appendingPathComponent("tracks.sqlite"), rows: [("gene2", 20), ("gene1", 10)])
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .database), [])
    }

    func testDatabasesDifferWhenARowDiffers() throws {
        let (a, b) = try makeRoots()
        try makeDatabase(a.appendingPathComponent("tracks.sqlite"), rows: [("gene1", 10), ("gene2", 20)])
        try makeDatabase(b.appendingPathComponent("tracks.sqlite"), rows: [("gene1", 10), ("gene2", 21)])
        let found = try OutputEquivalence.differences(a, b, kind: .database)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertTrue(found[0].contains("gene2\t21") || found[0].contains("gene2\t20"), found[0])
    }

    // MARK: - bundle

    func testBundlesMatchAfterRunIDTimeAndRootMasks() throws {
        let (a, b) = try makeRoots()
        try makeBundle(at: a, trackIDs: ["aln_1a2b3c4d"], names: ["filtered"], date: "2026-10-03T09:00:00Z")
        try makeBundle(at: b, trackIDs: ["aln_9f8e7d6c"], names: ["filtered"], date: "2026-10-03T09:05:00Z")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])
    }

    func testBundlesDifferWhenATrackMapsToTheWrongRunID() throws {
        let (a, b) = try makeRoots()
        // Both trees hold two tracks. In B the manifest names swap, so the
        // track file numbered 1 carries the other name.
        try makeBundle(at: a, trackIDs: ["aln_11111111", "aln_22222222"], names: ["first", "second"], date: "2026-10-03")
        try makeBundle(at: b, trackIDs: ["aln_33333333", "aln_44444444"], names: ["second", "first"], date: "2026-10-03")
        let found = try OutputEquivalence.differences(a, b, kind: .bundle)
        XCTAssertTrue(found.contains { $0.hasPrefix("differs: manifest.json") }, "\(found)")
    }

    func testBundlesDifferWhenAnIndexIsMissing() throws {
        let (a, b) = try makeRoots()
        try makeBundle(at: a, trackIDs: ["aln_1a2b3c4d"], names: ["filtered"], date: "2026-10-03")
        try makeBundle(at: b, trackIDs: ["aln_9f8e7d6c"], names: ["filtered"], date: "2026-10-03")
        try FileManager.default.removeItem(at: b.appendingPathComponent("alignments/aln_9f8e7d6c.cram.crai"))
        let found = try OutputEquivalence.differences(a, b, kind: .bundle)
        XCTAssertEqual(found, ["only in A: alignments/<RUN-ID-1>.cram.crai"])
    }

    func testBundlesReportAnExtraUUIDNamedChild() throws {
        let (a, b) = try makeRoots()
        for root in [a, a, b] {
            let id = UUID().uuidString
            try write(#"{"id":""# + id + #""}"#, to: root, "children/\(id).lungfishfastq/manifest.json")
        }
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .bundle),
            ["only in A: children/<UUID-2>.lungfishfastq/manifest.json"]
        )
    }

    func testBundlesMatchWhicheverWayTheirChildUUIDsSort() throws {
        let (a, b) = try makeRoots()
        // Sample s1's child sorts first in A and last in B.
        let childIDs = [
            (a, ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]),
            (b, ["44444444-4444-4444-8444-444444444444", "33333333-3333-4333-8333-333333333333"]),
        ]
        for (root, ids) in childIDs {
            let children = zip(ids, ["s1", "s2"]).map { #"{"id":""# + $0 + #"","sample":""# + $1 + #""}"# }
            for (id, child) in zip(ids, children) {
                try write(child, to: root, "children/\(id).lungfishfastq/manifest.json")
            }
            try write(#"{"children":["# + children.joined(separator: ",") + "]}", to: root, "manifest.json")
        }
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // B's manifest links s1 to the child that holds s2.
        try write(
            #"{"children":[{"id":"33333333-3333-4333-8333-333333333333","sample":"s1"},"#
                + #"{"id":"44444444-4444-4444-8444-444444444444","sample":"s2"}]}"#,
            to: b,
            "manifest.json"
        )
        let found = try OutputEquivalence.differences(a, b, kind: .bundle)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertTrue(found.first?.hasPrefix("differs: manifest.json") == true, "\(found)")
    }

    // MARK: - remote request

    func testRemoteRequestsDifferWhenOnlyAHostOrADateDiffers() throws {
        let (a, b) = try makeRoots()
        try write(#"{"database":"virus","host":"Homo sapiens"}"#, to: a, "request.json")
        try write(#"{"database":"virus","host":"Macaca mulatta"}"#, to: b, "request.json")
        try write("database=virus&releasedSince=2024-01-01", to: a, "form.txt")
        try write("database=virus&releasedSince=2025-01-01", to: b, "form.txt")
        let found = try OutputEquivalence.differences(a, b, kind: .remoteRequest)
        XCTAssertEqual(found.count, 2, "\(found)")
        XCTAssertTrue(found.contains { $0.hasPrefix("differs: request.json") && $0.contains("Macaca mulatta") }, "\(found)")
        XCTAssertTrue(found.contains { $0.hasPrefix("differs: form.txt") && $0.contains("2025-01-01") }, "\(found)")
    }

    func testRemoteRequestsMatchWhateverTheKeyAndParameterOrder() throws {
        let (a, b) = try makeRoots()
        try write(#"{"program":"blastn","database":"core_nt","query":">c1\nACGT"}"#, to: a, "request.json")
        try write(#"{"query":">c1\nACGT","database":"core_nt","program":"blastn"}"#, to: b, "request.json")
        try write("CMD=Put&PROGRAM=blastn&DATABASE=core_nt", to: a, "form.txt")
        try write("DATABASE=core_nt&CMD=Put&PROGRAM=blastn", to: b, "form.txt")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .remoteRequest), [])
    }

    func testRemoteRequestsDifferWhenAParameterDiffers() throws {
        let (a, b) = try makeRoots()
        try write(#"{"program":"blastn","database":"core_nt"}"#, to: a, "request.json")
        try write(#"{"program":"megablast","database":"core_nt"}"#, to: b, "request.json")
        try write("CMD=Put&PROGRAM=blastn", to: a, "form.txt")
        try write("CMD=Put&PROGRAM=megablast", to: b, "form.txt")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .remoteRequest).count, 2)
    }

    // MARK: - managed plan

    func testManagedPlansMatchAsJSONValues() throws {
        let (a, b) = try makeRoots()
        try write(#"{"items":[{"tool":"samtools","version":"1.21"}],"createdAt":"2026-10-03T09:00:00Z"}"#, to: a, "plan.json")
        try write(#"{"createdAt":"2026-10-03T09:00:00Z","items":[{"version":"1.21","tool":"samtools"}]}"#, to: b, "plan.json")
        XCTAssertEqual(
            try OutputEquivalence.differences(
                a.appendingPathComponent("plan.json"),
                b.appendingPathComponent("plan.json"),
                kind: .managedPlan
            ),
            []
        )
    }

    func testManagedPlansDifferWhenAnItemDiffers() throws {
        let (a, b) = try makeRoots()
        try write(#"{"items":[{"tool":"samtools","version":"1.21"}]}"#, to: a, "plan.json")
        try write(#"{"items":[{"tool":"samtools","version":"1.22"}]}"#, to: b, "plan.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .managedPlan).count, 1)
    }

    func testManagedPlansDifferWhenOnlyADatabaseReleaseDateDiffers() throws {
        let (a, b) = try makeRoots()
        try write(#"{"items":[{"database":"kraken2-standard","released":"2024-01-12"}]}"#, to: a, "plan.json")
        try write(#"{"items":[{"database":"kraken2-standard","released":"2025-06-05"}]}"#, to: b, "plan.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .managedPlan).count, 1)
    }

    // MARK: - masks

    func testProvenanceRuntimeFieldsAreMaskedAndArgvIsNot() throws {
        let (a, b) = try makeRoots()
        let envelope = { (root: URL, executable: String, pid: Int, wall: Double, input: String) in
            #"{"argv":["lungfish-cli","bam","filter",""# + root.path + "/" + input + #""],"#
                + #""runtimeIdentity":{"executablePath":""# + executable + #"","processIdentifier":"# + "\(pid)"
                + #"},"wallTimeSeconds":"# + "\(wall)" + "}"
        }
        try write(envelope(a, "/Applications/Lungfish.app/Contents/MacOS/Lungfish", 101, 1.5, "in.bam"), to: a, "provenance.json")
        try write(envelope(b, "/usr/local/bin/lungfish-cli", 202, 9.25, "in.bam"), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        try write(envelope(b, "/usr/local/bin/lungfish-cli", 202, 9.25, "other.bam"), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1)
    }

    func testRecordedDigestsAreMaskedOnlyForFilesComparedByContent() throws {
        let (a, b) = try makeRoots()
        let record = { (path: String, checksum: String, size: Int) in
            #"{"files":[{"path":""# + path + #"","checksumSHA256":""# + checksum + #"","sizeBytes":"# + "\(size)}]}"
        }
        // A database present in both trees, compared by its rows.
        try write("same rows\n", to: a, "tracks/x.db")
        try write("same rows\n", to: b, "tracks/x.db")
        try write(record("tracks/x.db", "aaaa", 584), to: a, "provenance.json")
        try write(record("tracks/x.db", "bbbb", 585), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])
        // The same record under the root path.
        try write(record(a.path + "/tracks/x.db", "aaaa", 584), to: a, "provenance.json")
        try write(record(b.path + "/tracks/x.db", "bbbb", 585), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // An input BAM outside both trees keeps its checksum, so different
        // input bytes at the same path are reported, whether the input sits
        // under the temporary folder or not.
        let input = scratch.appendingPathComponent("inputs/input.bam")
        try write("input placeholder\n", to: scratch, "inputs/input.bam")
        for inputPath in [input.path, "/Users/someone/Project.lungfish/input.bam"] {
            try write(record(inputPath, "aaaa", 584), to: a, "provenance.json")
            try write(record(inputPath, "bbbb", 584), to: b, "provenance.json")
            XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1, inputPath)
        }

        // A scratch intermediate the run deleted is masked like a tree file.
        let deleted = scratch.appendingPathComponent("work-\(UUID().uuidString)/x.filtered.unsorted.bam").path
        try write(record(deleted, "aaaa", 584), to: a, "provenance.json")
        try write(record(deleted, "bbbb", 585), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        try write(record("reads.fasta", "aaaa", 584), to: a, "provenance.json")
        try write(record("reads.fasta", "bbbb", 584), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1)
    }

    // MARK: - Fixture helpers

    private func makeRoots() throws -> (URL, URL) {
        let a = scratch.appendingPathComponent("A", isDirectory: true)
        let b = scratch.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return (a, b)
    }

    private func write(_ text: String, to root: URL, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func gzip(_ text: String, to root: URL, _ relative: String, keepNameAndTime: Bool) throws {
        let plain = root.appendingPathComponent(String(relative.dropLast(3)))
        try write(text, to: root, String(relative.dropLast(3)))
        if keepNameAndTime {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: plain.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = keepNameAndTime ? ["-N", plain.path] : ["-n", plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeDatabase(_ url: URL, rows: [(String, Int)]) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE features (name TEXT, start INTEGER)", nil, nil, nil), SQLITE_OK)
        for (name, start) in rows {
            XCTAssertEqual(
                sqlite3_exec(database, "INSERT INTO features VALUES ('\(name)', \(start))", nil, nil, nil),
                SQLITE_OK
            )
        }
    }

    /// A bundle with one CRAM placeholder, index and database per track and a
    /// manifest that names each track ID with its display name.
    private func makeBundle(at root: URL, trackIDs: [String], names: [String], date: String) throws {
        var tracks: [String] = []
        for (trackID, name) in zip(trackIDs, names) {
            try write("CRAM placeholder\n", to: root, "alignments/\(trackID).cram")
            try write("index placeholder\n", to: root, "alignments/\(trackID).cram.crai")
            tracks.append(#"{"id":""# + trackID + #"","name":""# + name + #"","path":""# + root.path + "/alignments/" + trackID + #".cram"}"#)
        }
        try write(#"{"modifiedDate":""# + date + #"","alignments":["# + tracks.joined(separator: ",") + "]}", to: root, "manifest.json")
        try makeDatabase(root.appendingPathComponent("annotations.db"), rows: [("gene1", 10)])
    }
}
