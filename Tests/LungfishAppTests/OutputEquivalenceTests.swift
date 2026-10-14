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

    func testBundlesReportTwoNamesThatMaskToOne() throws {
        let (a, b) = try makeRoots()
        try write("first\n", to: a, "reports/2026-10-03.txt")
        try write("second\n", to: a, "reports/2026-10-04.txt")
        try write("first\n", to: b, "reports/2026-10-05.txt")
        // The standard name masks keep dates, so a policy that also masks
        // them in names can merge two names.
        var masks = OutputEquivalence.MaskPolicy.standard
        masks.names.append(OutputEquivalence.Masks.isoTimestamps)
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .bundle, masks: masks),
            ["collides in A: reports/<TIMESTAMP>.txt names reports/2026-10-03.txt, reports/2026-10-04.txt"]
        )
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .bundle),
            [
                "only in A: reports/2026-10-03.txt",
                "only in A: reports/2026-10-04.txt",
                "only in B: reports/2026-10-05.txt",
            ]
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

    /// An assembler writes its wall time as `wall_time_seconds` in `provenance.json` and as
    /// `wallTimeSeconds` in `assembly-result.json`, a payload. Two runs never take the same time, so
    /// the contract masks both. Every fact beside them is still compared.
    func testTheAssemblerWallTimeIsMaskedAndNothingBesideIt() throws {
        let (a, b) = try makeRoots()
        let run = { (root: URL, hostOS: String, n50: Int, duration: Int, wall: Double) throws in
            try self.write(#"{"host_os":""# + hostOS + #"","wall_time_seconds":"# + "\(wall)" + "}", to: root, "provenance.json")
            try self.write(#"{"n50":"# + "\(n50)" + #","wallTimeSeconds":"# + "\(wall)" + "}", to: root, "assembly-result.json")
            try self.write(#"{"durationSeconds":"# + "\(duration)" + "}", to: root, "reads.json")
        }
        try run(a, "macOS", 100, 4, 1.25)
        try run(b, "macOS", 100, 4, 7.5)
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .files), [])

        try run(b, "Linux", 101, 5, 7.5)
        let found = try OutputEquivalence.differences(a, b, kind: .files)
        XCTAssertEqual(found.count, 3, "\(found)")
        for file in ["provenance.json", "assembly-result.json", "reads.json"] {
            XCTAssertTrue(found.contains { $0.hasPrefix("differs: \(file)\n") }, "\(file) must differ: \(found)")
        }
    }

    /// The mask knows three keys and matches each whole. A fact a run records beside its wall time, in
    /// a provenance envelope or in a payload, still fails the comparison when the routes disagree on
    /// it, including a key that holds the name of a wall time key, and a payload keeps the other
    /// wall-clock keys that only a provenance envelope masks.
    func testNoFactBesideTheWallTimeIsMaskedWithIt() throws {
        let (a, b) = try makeRoots()
        let beside: [(key: String, a: String, b: String)] = [
            ("host_os", #""macOS""#, #""Linux""#),
            ("n50", "100", "101"),
            ("commandLine", #""spades.py -t 4""#, #""spades.py -t 8""#),
            ("duration", "4", "5"),
            ("runtime", #""4s""#, #""5s""#),
            ("total_wall_time_seconds", "4", "5"),
            ("wallTimeSecondsTotal", "4", "5"),
            ("wallClockSecondsTotal", "4", "5"),
        ]
        let payloadOnly: [(key: String, a: String, b: String)] = [
            ("wallTime", "4", "5"),
            ("durationSeconds", "4", "5"),
            ("elapsedSeconds", "4", "5"),
        ]
        for file in ["provenance.json", "assembly-result.json"] {
            for wallKey in ["wallTimeSeconds", "wall_time_seconds", "wallClockSeconds"] {
                let facts = file == "provenance.json" ? beside : beside + payloadOnly
                for fact in facts {
                    let label = "\(file) with \(wallKey) beside \(fact.key)"
                    let record = { (value: String, wall: Double) in "{\"\(fact.key)\":\(value),\"\(wallKey)\":\(wall)}" }
                    try empty(a, b)
                    try write(record(fact.a, 1.25), to: a, file)
                    try write(record(fact.a, 7.5), to: b, file)
                    XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .files), [], "only the wall time differs in \(label)")

                    try write(record(fact.b, 7.5), to: b, file)
                    let found = try OutputEquivalence.differences(a, b, kind: .files)
                    XCTAssertEqual(found.count, 1, "the fact differs in \(label): \(found)")
                    XCTAssertTrue(found.first?.hasPrefix("differs: \(file)\n") == true, "\(label): \(found)")
                }
            }
        }
    }

    /// A FASTQ metadata sidecar (`<file>.lungfish-meta.json`) records three wall-clock times, when the
    /// FASTQ was downloaded, when it was imported and when its platform was assigned. Two runs never
    /// stamp the same second, so the contract masks the values of the top-level `downloadDate`, of
    /// `ingestion.ingestionDate` and of `platformAssignment.recordedAt` in a JSON payload. Every other
    /// date, the same keys at any other path, a key's absence and every statistic are still compared
    /// (BIO ruling on lane A45 M3c, item 1).
    func testTheFASTQSidecarClocksAreMaskedAndNothingBesideIt() throws {
        let (a, b) = try makeRoots()
        let name = "S.fastq.gz.lungfish-meta.json"
        let found = { try OutputEquivalence.differences(a, b, kind: .files) }
        let template = #"{"computedStatistics":{"qualityScoreHistogram":[14,1,15,5],"readCount":53},"#
            + #""downloadDate":@CLOCK@,"downloadSource":"SRA Toolkit","#
            + #""enaReadRecord":{"first_public":"2022-08-01","run_accession":"ERR10019355"},"#
            + #""ingestion":{"ingestionDate":@CLOCK@,"pairingMode":"single_end"},"#
            + #""platformAssignment":{"platform":"unknown","recordedAt":@CLOCK@}}"#
        let withClock = { (text: String, clock: String) in text.replacingOccurrences(of: "@CLOCK@", with: "\"\(clock)\"") }
        let clockA = "2026-10-14T14:22:00Z"
        let clockB = "2026-10-14T14:22:04Z"

        try write(withClock(template, clockA), to: a, name)
        try write(withClock(template, clockB), to: b, name)
        XCTAssertEqual(try found(), [], "only the three clocks differ")

        // Each change differs in one file on top of the clocks. The last two put the clock keys at other
        // paths on both sides, with each side's own time.
        let cases: [(label: String, both: Bool, edit: (String) -> String)] = [
            ("downloadSource", false, { $0.replacingOccurrences(of: #""SRA Toolkit""#, with: #""ENA""#) }),
            ("first_public", false, { $0.replacingOccurrences(of: "2022-08-01", with: "2022-08-02") }),
            ("pairingMode", false, { $0.replacingOccurrences(of: "single_end", with: "paired_end") }),
            ("platform", false, { $0.replacingOccurrences(of: #""platform":"unknown""#, with: #""platform":"illumina""#) }),
            ("the histogram's order", false, { $0.replacingOccurrences(of: "[14,1,15,5]", with: "[15,5,14,1]") }),
            ("no downloadDate", false, { $0.replacingOccurrences(of: #""downloadDate":@CLOCK@,"#, with: "") }),
            ("enaReadRecord.downloadDate", true, {
                $0.replacingOccurrences(of: #""first_public":"#, with: #""downloadDate":@CLOCK@,"first_public":"#)
            }),
            ("ingestion.recordedAt", true, {
                $0.replacingOccurrences(of: #""pairingMode":"#, with: #""recordedAt":@CLOCK@,"pairingMode":"#)
            }),
        ]
        for (label, both, edit) in cases {
            try write(withClock(both ? edit(template) : template, clockA), to: a, name)
            try write(withClock(edit(template), clockB), to: b, name)
            let result = try found()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: \(name)") == true, "\(label): \(result)")
        }
    }

    /// An assembly bundle's manifest lists the run's parameters as display items, a label and a value
    /// in a metadata group, and one of them is `Wall Time`. Two runs never take the same time, so the
    /// contract masks that item's value in a manifest. Every other item, the item's place, any other
    /// label and the same pair in a payload are still compared (lane A46 M3, D3 of its QA ruling).
    func testAManifestWallTimeItemIsMaskedAndNothingBesideIt() throws {
        let (a, b) = try makeRoots()
        let item = { (label: String, value: String) in #"{"label":"\#(label)","value":"\#(value)"}"# }
        let manifest = { (items: [String]) in #"{"metadata":[{"items":["# + items.joined(separator: ",") + "]}]}" }
        let found = { try OutputEquivalence.differences(a, b, kind: .files) }
        try write(manifest([item("Threads", "1"), item("Wall Time", "1s")]), to: a, "manifest.json")
        try write(manifest([item("Threads", "1"), item("Wall Time", "0s")]), to: b, "manifest.json")
        XCTAssertEqual(try found(), [])

        // The shape LGE writes, each group and item with a random id, and a time with minutes.
        let written = { (wall: String) in
            #"{"metadata":[{"id":"\#(UUID().uuidString)","name":"Assembly Parameters","items":["#
                + #"{"id":"\#(UUID().uuidString)","label":"Threads","value":"1"},"#
                + #"{"id":"\#(UUID().uuidString)","label":"Wall Time","value":"\#(wall)"}]}]}"#
        }
        try write(written("2m 5s"), to: a, "manifest.json")
        try write(written("0s"), to: b, "manifest.json")
        XCTAssertEqual(try found(), [])

        // Every other item is compared.
        try write(manifest([item("Threads", "1"), item("Wall Time", "1s")]), to: a, "manifest.json")
        try write(manifest([item("Threads", "2"), item("Wall Time", "0s")]), to: b, "manifest.json")
        XCTAssertEqual(try found().count, 1, "Threads differs")

        // The item's place is compared, and so is its absence.
        try write(manifest([item("Wall Time", "0s"), item("Threads", "1")]), to: b, "manifest.json")
        XCTAssertEqual(try found().count, 1, "the item moved")
        try write(manifest([item("Threads", "1")]), to: b, "manifest.json")
        XCTAssertEqual(try found().count, 1, "the item is gone")

        // The label is matched whole and as written, so any other label keeps its value.
        for label in ["Wall time", "wall time", "WallTime", "Wall Time (s)", "Wall Time ", "Runtime"] {
            try write(manifest([item("Threads", "1"), item(label, "1s")]), to: a, "manifest.json")
            try write(manifest([item("Threads", "1"), item(label, "0s")]), to: b, "manifest.json")
            XCTAssertEqual(try found().count, 1, "the label \(label)")
        }

        // The same pair in a payload is compared as written.
        try empty(a, b)
        try write(manifest([item("Threads", "1"), item("Wall Time", "1s")]), to: a, "assembly-result.json")
        try write(manifest([item("Threads", "1"), item("Wall Time", "0s")]), to: b, "assembly-result.json")
        XCTAssertEqual(try found().count, 1, "a payload")
        XCTAssertTrue(try found().first?.hasPrefix("differs: assembly-result.json\n") == true)
    }

    /// A provenance envelope keeps each step's stderr, and minimap2 prints its run times there, so two
    /// runs never print the same figures. The contract masks the figures of the `[M::<function>::<seconds>*<ratio>]`
    /// stamps and of the `Real time` line in a provenance `stderr`. The version, the command, the index
    /// statistics, the reads mapped, a function name, a line added or lost and the same text anywhere else
    /// are still compared (lane A46 M3, D5 of its QA ruling).
    func testMinimap2RunTimesInAStderrAreMaskedAndNothingBesideThem() throws {
        let (a, b) = try makeRoots()
        let found = { try OutputEquivalence.differences(a, b, kind: .files) }
        let record = "x.lungfish-provenance.json"
        // The ruling's text, with the figures of one run on A and of another on B.
        try write(
            #"{"stderr":"[M::mm_idx_gen::0.001*10.53] mapped 200 sequences\n"#
                + #"[M::main] Real time: 0.006 sec; CPU: 0.018 sec; Peak RSS: 0.004 GB\n"}"#,
            to: a, record
        )
        try write(
            #"{"stderr":"[M::mm_idx_gen::0.002*7.25] mapped 200 sequences\n"#
                + #"[M::main] Real time: 0.011 sec; CPU: 0.031 sec; Peak RSS: 0.005 GB\n"}"#,
            to: b, record
        )
        XCTAssertEqual(try found(), [])

        // minimap2's lines in order, with the figures of run 0 or of run 1.
        let lines = { (run: Int) -> [String] in
            let s = run == 0 ? ("0.001", "10.53", "0.006", "0.018", "0.004") : ("0.002", "7.25", "0.011", "0.031", "0.005")
            return [
                "[M::mm_idx_gen::\(s.0)*\(s.1)] collected minimizers",
                "[M::mm_idx_stat] kmer size: 15; skip: 10; is_hpc: 0; #seq: 1",
                "[M::mm_idx_stat::\(s.0)*\(s.1)] distinct minimizers: 5005 (100.00% are singletons); average spacing: 5.997",
                "[M::worker_pipeline::\(s.0)*\(s.1)] mapped 200 sequences",
                "[M::main] Version: 2.28-r1209",
                "[M::main] CMD: minimap2 -a -x sr ref.fa reads.fq",
                "[M::main] Real time: \(s.2) sec; CPU: \(s.3) sec; Peak RSS: \(s.4) GB",
            ]
        }
        let text = { (lines: [String]) in lines.joined(separator: "\n") + "\n" }
        let json = { (object: Any) throws in String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        try write(try json(["stderr": text(lines(0))]), to: a, record)
        try write(try json(["stderr": text(lines(1))]), to: b, record)
        XCTAssertEqual(try found(), [], "only the figures differ")

        // A step's stderr, where the envelope keeps it.
        let step = { (run: Int) throws in try json(["steps": [["name": "minimap2", "stderr": text(lines(run))]]]) }
        try write(try step(0), to: a, record)
        try write(try step(1), to: b, record)
        XCTAssertEqual(try found(), [], "a step's stderr")

        // Everything else in the text is compared, with the figures masked on both sides.
        let edits: [(name: String, apply: ([String]) -> [String])] = [
            ("the version", { $0.map { $0.replacingOccurrences(of: "2.28-r1209", with: "2.30-r1287") } }),
            ("the command", { $0.map { $0.replacingOccurrences(of: "-x sr", with: "-x map-ont") } }),
            ("the index statistics", { $0.map { $0.replacingOccurrences(of: "5005", with: "5006") } }),
            ("the reads mapped", { $0.map { $0.replacingOccurrences(of: "mapped 200", with: "mapped 201") } }),
            ("a function name", { $0.map { $0.replacingOccurrences(of: "mm_idx_gen", with: "mm_idx_stat") } }),
            ("a line added", { $0 + ["[M::main] Extra line"] }),
            ("a line lost", { Array($0.dropFirst()) }),
        ]
        for edit in edits {
            try write(try json(["stderr": text(edit.apply(lines(1)))]), to: b, record)
            try write(try json(["stderr": text(lines(0))]), to: a, record)
            XCTAssertEqual(try found().count, 1, edit.name)
        }

        // The same text under another key of the envelope, and the same text in a payload.
        for key in ["stdout", "message"] {
            try write(try json([key: text(lines(0))]), to: a, record)
            try write(try json([key: text(lines(1))]), to: b, record)
            XCTAssertEqual(try found().count, 1, "under \(key)")
        }
        try empty(a, b)
        try write(text(lines(0)), to: a, "minimap2.log")
        try write(text(lines(1)), to: b, "minimap2.log")
        XCTAssertEqual(try found().count, 1, "minimap2.log")
        try empty(a, b)
        try write(try json(["stderr": text(lines(0))]), to: a, "result.json")
        try write(try json(["stderr": text(lines(1))]), to: b, "result.json")
        XCTAssertEqual(try found().count, 1, "a payload that holds a stderr")
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

        // So is a SAM the run deleted, the text a mapper writes before it sorts to a BAM (lane A46 M3, D6).
        let deletedSAM = scratch.appendingPathComponent("work-\(UUID().uuidString)/x.raw.sam").path
        try write(record(deletedSAM, "aaaa", 584), to: a, "provenance.json")
        try write(record(deletedSAM, "bbbb", 585), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // A SAM that exists, or that lies outside the temporary folder, keeps its digest.
        try write("input placeholder\n", to: scratch, "inputs/input.sam")
        let inputSAM = scratch.appendingPathComponent("inputs/input.sam").path
        for samPath in [inputSAM, "/Users/someone/Project.lungfish/x.raw.sam"] {
            try write(record(samPath, "aaaa", 584), to: a, "provenance.json")
            try write(record(samPath, "bbbb", 584), to: b, "provenance.json")
            XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1, samPath)
        }

        // A SAM both trees keep is compared byte for byte, so the digest a record states for it is compared too.
        try write("@HD\tVN:1.6\n", to: a, "tracks/x.sam")
        try write("@HD\tVN:1.6\n", to: b, "tracks/x.sam")
        try write(record("tracks/x.sam", "aaaa", 584), to: a, "provenance.json")
        try write(record("tracks/x.sam", "bbbb", 584), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1)

        try write(record("reads.fasta", "aaaa", 584), to: a, "provenance.json")
        try write(record("reads.fasta", "bbbb", 584), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1)
    }

    /// Root A's path is a string prefix of root B's, as `C` is of `C-prime`. Every spelling of
    /// either root becomes `<ROOT>`, so root B's paths do not read `<ROOT>-prime` (lane Q30, R1).
    func testRootsMatchWhenOneRootPathIsAPrefixOfTheOther() throws {
        let a = scratch.appendingPathComponent("C", isDirectory: true)
        let b = scratch.appendingPathComponent("C-prime", isDirectory: true)
        for root in [a, b] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "wrote \(root.path)/out/reads.fasta\n"
                .write(to: root.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .files), [])
    }

    /// A record's checksum and size of a folder that holds a file in each tree are masked, since every
    /// file in it is compared on its own. A changed file in the folder is still found, and a folder
    /// one tree lacks keeps its digest (lane Q30 M2 finding 1).
    func testRecordedDigestsOfASharedFolderAreMaskedAndItsFilesStillCompared() throws {
        let (a, b) = try makeRoots()
        let record = { (root: URL, folder: String, checksum: String, size: Int) in
            #"{"output":{"path":"\#(root.path)/\#(folder)","checksumSHA256":"\#(checksum)","fileSize":\#(size)}}"#
        }
        let firstLines = { try OutputEquivalence.differences(a, b, kind: .bundle).map { $0.components(separatedBy: "\n")[0] } }
        // Each tree's folder holds a JSON file that names its own root, so the folder's bytes differ.
        for root in [a, b] {
            try write(#"{"source":"\#(root.path)/rows.fasta"}"#, to: root, "out.bundle/rows.json")
        }
        try write(record(a, "out.bundle", String(repeating: "a", count: 64), 100), to: a, "run.lungfish-provenance.json")
        try write(record(b, "out.bundle", String(repeating: "b", count: 64), 101), to: b, "run.lungfish-provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // A changed file in the folder is found on its own, beside the masked record.
        try write(#"{"source":"\#(b.path)/other.fasta"}"#, to: b, "out.bundle/rows.json")
        XCTAssertEqual(try firstLines(), ["differs: out.bundle/rows.json"])

        // A folder only one tree holds keeps its stated digest.
        try write(#"{"source":"\#(b.path)/rows.fasta"}"#, to: b, "out.bundle/rows.json")
        try write("x\n", to: a, "only-a.bundle/x.txt")
        try write(record(a, "only-a.bundle", String(repeating: "a", count: 64), 2), to: a, "run.lungfish-provenance.json")
        try write(record(b, "only-a.bundle", String(repeating: "b", count: 64), 2), to: b, "run.lungfish-provenance.json")
        XCTAssertEqual(try firstLines(), ["only in A: only-a.bundle/x.txt", "differs: run.lungfish-provenance.json"])
    }

    /// A manifest's `checksums` and `fileSizes` maps, keyed by paths from the manifest's folder, are
    /// masked for a content-compared file both trees hold. A key for a file compared byte for byte, a
    /// key read from the tree root and a key for a file one tree lacks keep their values (lane Q30 M2
    /// finding 1).
    func testRecordedDigestMapsAreMaskedOnlyForSharedContentComparedFiles() throws {
        let (a, b) = try makeRoots()
        func manifest(_ checksums: [String: String], _ sizes: [String: Int]) throws -> String {
            let object: [String: Any] = ["checksums": checksums, "fileSizes": sizes]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let firstLines = { try OutputEquivalence.differences(a, b, kind: .bundle).map { $0.components(separatedBy: "\n")[0] } }
        let (rowMap, fasta) = ("metadata/source-row-map.json", "alignment/primary.aligned.fasta")
        let (digestA, digestB, digestF) = (String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "f", count: 64))
        // Each tree's row map names its own root, so its bytes differ, and the FASTA is the same.
        for root in [a, b] {
            try write(#"[{"sourceFilePath":"\#(root.path)/rows.fasta"}]"#, to: root, "rows.lungfishmsa/\(rowMap)")
            try write(">row\nACGT\n", to: root, "rows.lungfishmsa/\(fasta)")
        }
        try write(try manifest([rowMap: digestA, fasta: digestF], [rowMap: 870, fasta: 10]), to: a, "rows.lungfishmsa/manifest.json")
        try write(try manifest([rowMap: digestB, fasta: digestF], [rowMap: 872, fasta: 10]), to: b, "rows.lungfishmsa/manifest.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // The FASTA is compared byte for byte, so its stated checksum is compared too.
        try write(try manifest([rowMap: digestB, fasta: digestA], [rowMap: 872, fasta: 10]), to: b, "rows.lungfishmsa/manifest.json")
        XCTAssertEqual(try firstLines(), ["differs: rows.lungfishmsa/manifest.json"])

        // A key is read from the manifest's folder, so a path from the tree root names no file.
        try write(try manifest(["rows.lungfishmsa/\(rowMap)": digestA], [:]), to: a, "rows.lungfishmsa/manifest.json")
        try write(try manifest(["rows.lungfishmsa/\(rowMap)": digestB], [:]), to: b, "rows.lungfishmsa/manifest.json")
        XCTAssertEqual(try firstLines(), ["differs: rows.lungfishmsa/manifest.json"])

        // A key for a file only one tree holds keeps its value.
        try write("{}\n", to: a, "rows.lungfishmsa/metadata/extra.json")
        try write(try manifest(["metadata/extra.json": digestA], [:]), to: a, "rows.lungfishmsa/manifest.json")
        try write(try manifest(["metadata/extra.json": digestB], [:]), to: b, "rows.lungfishmsa/manifest.json")
        XCTAssertEqual(try firstLines(), ["only in A: rows.lungfishmsa/metadata/extra.json", "differs: rows.lungfishmsa/manifest.json"])
    }

    /// A record inside a project names its outputs as `@/` paths, read from the `.lungfish` project
    /// that holds the record. The digest it states for a content-compared file both trees hold is
    /// masked, and a file compared byte for byte keeps its digest (lane A44 M2c P1, its QA ruling).
    func testARecordReadsAnAtSlashPathFromItsProject() throws {
        let (a, b) = try makeRoots()
        let bundle = "Project.lungfish/Downloads/out.lungfishref"
        let record = { (manifestDigest: String, reportDigest: String) in
            #"{"outputs":[{"path":"@/Downloads/out.lungfishref/manifest.json","checksumSHA256":"\#(manifestDigest)"},"#
                + #"{"path":"@/Downloads/out.lungfishref/report.txt","checksumSHA256":"\#(reportDigest)"}]}"#
        }
        let (digestA, digestB, digestF) = (String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "f", count: 64))
        // Each manifest holds its own random id, so the two raw manifests, and their digests, differ.
        for (root, digest) in [(a, digestA), (b, digestB)] {
            try write(#"{"id":"\#(UUID().uuidString)"}"#, to: root, "\(bundle)/manifest.json")
            try write("report\n", to: root, "\(bundle)/report.txt")
            try write(record(digest, digestF), to: root, "\(bundle)/.lungfish-provenance.json")
            try write(record(digest, digestF), to: root, "\(bundle)/provenance/bundle.lungfish-provenance.json")
        }
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // The report is compared byte for byte, so the digest a record states for it is compared too.
        try write(record(digestB, String(repeating: "e", count: 64)), to: b, "\(bundle)/.lungfish-provenance.json")
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .bundle).map { $0.components(separatedBy: "\n")[0] },
            ["differs: \(bundle)/.lungfish-provenance.json"]
        )
    }

    /// UUIDs are numbered per tree, the files both trees hold first, so a file only one tree holds,
    /// here A's batch folder marker and B's record with two ids, moves no number in a shared file
    /// (lane A44 M2c P2, its QA ruling).
    func testAFileOnlyOneTreeHoldsMovesNoNumberInASharedFile() throws {
        let (a, b) = try makeRoots()
        for root in [a, b] {
            try write(#"{"id":"\#(UUID().uuidString)"}"#, to: root, "p/out.bundle/manifest.json")
        }
        try write("{}\n", to: a, "p/.tmp/batch-\(UUID().uuidString)/marker.json")
        try write(
            #"{"runID":"\#(UUID().uuidString)","operationID":"\#(UUID().uuidString)"}"#,
            to: b,
            "p/out.bundle/.lungfish-provenance.json"
        )
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .bundle),
            ["only in A: p/.tmp/batch-<UUID-2>/marker.json", "only in B: p/out.bundle/.lungfish-provenance.json"]
        )
    }

    /// A `@/` path lies inside the project, never under the system temporary folder, so the digest
    /// a record states for a file neither tree holds is kept and compared (FXP review, BIO's question).
    func testAnAtSlashPathToAFileNeitherTreeHoldsKeepsItsDigest() throws {
        let (a, b) = try makeRoots()
        let bundle = "Project.lungfish/Downloads/out.lungfishref"
        for (root, digest) in [(a, String(repeating: "c", count: 64)), (b, String(repeating: "d", count: 64))] {
            try write(
                #"{"outputs":[{"path":"@/Downloads/out.lungfishref/gone.json","checksumSHA256":"\#(digest)"}]}"#,
                to: root,
                "\(bundle)/.lungfish-provenance.json"
            )
        }
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .bundle).map { $0.components(separatedBy: "\n")[0] },
            ["differs: \(bundle)/.lungfish-provenance.json"]
        )
    }

    /// Map Reads writes a raw SAM and a filtered BAM in its analysis folder and deletes them at the end of the
    /// run. A SAM or BAM in the folder that holds the record, which one step wrote, a later step read and the
    /// run deleted, has the digest and size the record states for it masked. Nothing beside it is (lane A46 M3c,
    /// its QA ruling on D6b).
    func testADeletedStepIntermediateInTheRunFolderIsMaskedAndNothingBesideIt() throws {
        let (a, b) = try makeRoots()
        let run = "Project.lungfish/Analyses/run"
        let (sam, bam) = ("@/Analyses/run/x.raw.sam", "@/Analyses/run/x.filtered.bam")
        let sides = [(a, String(repeating: "a", count: 64), 1), (b, String(repeating: "b", count: 64), 2)]
        // Each step reads some files and writes some. The record states a checksum and size at every use of a
        // file, `a` and 1 in A and `b` and 2 in B.
        func put(_ steps: [(reads: [String], writes: [String])], at path: String? = nil) throws {
            for (root, digest, size) in sides {
                let file = { (name: String) in #"{"path":"\#(name)","checksumSHA256":"\#(digest)","fileSize":\#(size)}"# }
                let items = steps.map { step -> String in
                    let reads = step.reads.map(file).joined(separator: ",")
                    let writes = step.writes.map(file).joined(separator: ",")
                    return #"{"toolName":"tool","inputs":[\#(reads)],"outputs":[\#(writes)]}"#
                }
                let joined = items.joined(separator: ",")
                try write(#"{"steps":[\#(joined)]}"#, to: root, path ?? "\(run)/.lungfish-provenance.json")
            }
        }
        let found = { try OutputEquivalence.differences(a, b, kind: .bundle) }
        let firstLines = { try found().map { $0.components(separatedBy: "\n")[0] } }
        let recordDiffers = "differs: \(run)/.lungfish-provenance.json"
        let samBody = "@HD\tVN:1.6\n"

        // The first step writes the SAM, the second reads it and writes the BAM, the third reads the BAM.
        // Neither tree holds either file, so the run deleted both and their digests are masked.
        let chain: [(reads: [String], writes: [String])] = [([], [sam]), ([sam], [bam]), ([bam], [])]
        try put(chain)
        XCTAssertEqual(try found(), [])

        // A alone holds the SAM, so A's record keeps its digests and B's are masked.
        try write(samBody, to: a, "\(run)/x.raw.sam")
        XCTAssertEqual(try firstLines(), ["only in A: \(run)/x.raw.sam", recordDiffers])

        // Both hold the same SAM, so the run did not delete it and the digests are compared.
        try write(samBody, to: b, "\(run)/x.raw.sam")
        XCTAssertEqual(try firstLines(), [recordDiffers])

        // A SAM outside the run's folder keeps its digests, whether both trees hold it or neither does.
        try empty(a, b)
        for root in [a, b] {
            try write(samBody, to: root, "Project.lungfish/inputs/input.sam")
        }
        let input = "@/inputs/input.sam"
        try put([([], [input]), ([input], [bam]), ([bam], [])])
        XCTAssertEqual(try firstLines(), [recordDiffers])
        try empty(a, b)
        let outsideRun = "@/inputs/x.raw.sam"
        try put([([], [outsideRun]), ([outsideRun], [bam]), ([bam], [])])
        XCTAssertEqual(try firstLines(), [recordDiffers])

        // No step reads the SAM, so it is no intermediate.
        try put([([], [sam]), ([], [bam]), ([bam], [])])
        XCTAssertEqual(try firstLines(), [recordDiffers])

        // Beside the ruled cases. A file that is neither a SAM nor a BAM, a SAM that a step reads before
        // another writes it, and a path outside both trees, in a record at the root that has no folder to
        // read it from, each keep their digests.
        let fastq = "@/Analyses/run/x.reads.fastq"
        try put([([], [fastq]), ([fastq], [])])
        XCTAssertEqual(try firstLines(), [recordDiffers])
        try put([([sam], []), ([], [sam])])
        XCTAssertEqual(try firstLines(), [recordDiffers])
        try empty(a, b)
        let outsideTrees = "/Users/someone/Project.lungfish/Analyses/run/x.raw.sam"
        try put([([], [outsideTrees]), ([outsideTrees], [])], at: ".lungfish-provenance.json")
        XCTAssertEqual(try firstLines(), ["differs: .lungfish-provenance.json"])
    }

    /// The BAM filter works in `lungfish-bam-filter-<UUID>` under the system temporary folder and deletes it. A
    /// record writes that folder as `<workspace>/` (`PortablePath`), and the digest and size it states for a
    /// scratch BAM there are masked as if it named the absolute path. A file of another kind, a `<bundle>/` path
    /// and a file the temporary folder still holds keep theirs (lane A54 M3 finding 1, its QA ruling).
    func testAWorkspaceScratchIntermediateIsMaskedAndNothingBesideIt() throws {
        let (a, b) = try makeRoots()
        let record = { (path: String, checksum: String, size: Int) in
            #"{"files":[{"path":""# + path + #"","checksumSHA256":""# + checksum + #"","sizeBytes":"# + "\(size)}]}"
        }
        let (digestA, digestB) = (String(repeating: "a", count: 64), String(repeating: "b", count: 64))
        let firstLines = { try OutputEquivalence.differences(a, b, kind: .bundle).map { $0.components(separatedBy: "\n")[0] } }
        // Each run has its own workspace, so the two records name different folders.
        let (folderA, folderB) = ("lungfish-bam-filter-\(UUID().uuidString)", "lungfish-bam-filter-\(UUID().uuidString)")
        try write(record("<workspace>/\(folderA)/x.sorted.bam", digestA, 1), to: a, "provenance.json")
        try write(record("<workspace>/\(folderB)/x.sorted.bam", digestB, 2), to: b, "provenance.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // A file of another kind in the same folder keeps its digest.
        try write(record("<workspace>/\(folderA)/x.fastq", digestA, 1), to: a, "provenance.json")
        try write(record("<workspace>/\(folderB)/x.fastq", digestB, 2), to: b, "provenance.json")
        XCTAssertEqual(try firstLines(), ["differs: provenance.json"])

        // A `<bundle>/` path is never read.
        try write(record("<bundle>/x.bam", digestA, 1), to: a, "provenance.json")
        try write(record("<bundle>/x.bam", digestB, 2), to: b, "provenance.json")
        XCTAssertEqual(try firstLines(), ["differs: provenance.json"])

        // A file the temporary folder still holds is a leaked scratch folder, so its digest is compared.
        let leaked = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-bam-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leaked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: leaked) }
        try Data("bam placeholder\n".utf8).write(to: leaked.appendingPathComponent("x.sorted.bam"))
        for (root, digest, size) in [(a, digestA, 1), (b, digestB, 2)] {
            try write(record("<workspace>/\(leaked.lastPathComponent)/x.sorted.bam", digest, size), to: root, "provenance.json")
        }
        XCTAssertEqual(try firstLines(), ["differs: provenance.json"])
    }

    /// A manifest entry names a file by its path from the manifest's folder, as a `source_path` value, the way
    /// a checksum map names it by a key. The size it states for a content-compared file both trees hold is
    /// masked. The size it states for a file compared byte for byte, or for one only a tree holds, is kept (lane
    /// A54 M3 finding 1, its QA ruling).
    func testAManifestReadsAnEntrysPathFromItsFolder() throws {
        let (a, b) = try makeRoots()
        let manifest = { (path: String, size: Int) in
            #"{"alignments":[{"source_path":""# + path + #"","file_size_bytes":"# + "\(size)}]}"
        }
        let firstLines = { try OutputEquivalence.differences(a, b, kind: .bundle).map { $0.components(separatedBy: "\n")[0] } }
        for root in [a, b] {
            try write("same rows\n", to: root, "S.lungfishref/tracks/x.db")
            try write(">row\nACGT\n", to: root, "S.lungfishref/reads.fasta")
        }
        try write(manifest("tracks/x.db", 1), to: a, "S.lungfishref/manifest.json")
        try write(manifest("tracks/x.db", 2), to: b, "S.lungfishref/manifest.json")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [])

        // The FASTA is compared byte for byte, so the size a manifest states for it is compared too.
        try write(manifest("reads.fasta", 1), to: a, "S.lungfishref/manifest.json")
        try write(manifest("reads.fasta", 2), to: b, "S.lungfishref/manifest.json")
        XCTAssertEqual(try firstLines(), ["differs: S.lungfishref/manifest.json"])

        // A database only A holds keeps its stated size, and is reported on its own.
        try write("only A\n", to: a, "S.lungfishref/tracks/only-a.db")
        try write(manifest("tracks/only-a.db", 1), to: a, "S.lungfishref/manifest.json")
        try write(manifest("tracks/only-a.db", 2), to: b, "S.lungfishref/manifest.json")
        XCTAssertEqual(
            try firstLines(),
            ["only in A: S.lungfishref/tracks/only-a.db", "differs: S.lungfishref/manifest.json"]
        )
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

    /// Removes everything under each root, so a case in a loop starts from empty trees.
    private func empty(_ roots: URL...) throws {
        for root in roots {
            for item in try FileManager.default.contentsOfDirectory(atPath: root.path) {
                try FileManager.default.removeItem(at: root.appendingPathComponent(item))
            }
        }
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
