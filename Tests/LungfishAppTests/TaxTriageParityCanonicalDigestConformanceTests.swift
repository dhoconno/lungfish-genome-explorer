// TaxTriageParityCanonicalDigestConformanceTests.swift - The canonical digest of a BAM and its index, with real samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane Q32, BIO's ruling on window 1's X1 run, fix F2. The BAM that build-db's duplicate marking leaves holds
// the command lines of its samtools calls in four @PG lines, with the absolute paths of the side's own folders and a
// random scratch folder, so no two runs give the same bytes. The real engine's compare reads a BAM by its header without
// those command lines plus its records, and an index by `samtools idxstats` (TaxTriageParityPayloads.canonicalDigest).
// These tests run the managed samtools, so the class name holds Conformance and the unit tier never selects it.
// LUNGFISH_REQUIRE_TOOLS=1 turns a missing samtools into a failure.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageParityCanonicalDigestConformanceTests: XCTestCase {
    /// A BAM compares by its header without the `CL:` field of each @PG line plus its records. Only a differing
    /// record, header line or @PG ID, PN, PP or VN is a difference, and an index compares by its BAM's `idxstats`.
    func testTheCanonicalBAMDigestIgnoresOnlyPGCommandLines() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let folder = try TestTempDirectory.make(prefix: "TaxTriageParityCanonical")
        defer { TestTempDirectory.cleanup(folder) }
        let a = try Self.makeBAM("a", sam: Self.sam(), in: folder, samtools: samtools)
        let b = try Self.makeBAM(
            "b", sam: Self.sam(command: "samtools markdup /private/tmp/run-b/minimap2/S1.bam /private/tmp/run-b/.markdup-2222/out.bam"),
            in: folder, samtools: samtools
        )
        let c = try Self.makeBAM("c", sam: Self.sam(secondReadPosition: 31), in: folder, samtools: samtools)
        let e = try Self.makeBAM("e", sam: Self.sam(version: "1.25"), in: folder, samtools: samtools)
        func canonical(_ file: URL) throws -> String { try TaxTriageParityPayloads.canonicalDigest(of: file, samtools: samtools) }

        let digestA = try canonical(a)
        XCTAssertEqual(digestA, try canonical(b), "another @PG command line is no difference")
        XCTAssertNotEqual(digestA, try canonical(c), "a read that moved is a difference")
        XCTAssertNotEqual(digestA, try canonical(e), "another @PG version is a difference")
        XCTAssertNotEqual(try ClassifierParityFixtures.sha256(of: a), try ClassifierParityFixtures.sha256(of: b), "the raw bytes differ")

        let indexA = try Self.index(a, samtools: samtools)
        let indexB = try Self.index(b, samtools: samtools)
        XCTAssertEqual(try canonical(indexA), try canonical(indexB), "the indexes of two BAMs with equal reads compare by their idxstats")

        // Any other file keeps its SHA-256, an index with no BAM beside it too, and a samtools exit other than 0 throws.
        let text = folder.appendingPathComponent("a.sam")
        XCTAssertEqual(try canonical(text), try ClassifierParityFixtures.sha256(of: text))
        let lonely = folder.appendingPathComponent("lonely.bam.bai")
        try Data("an index with no BAM\n".utf8).write(to: lonely)
        XCTAssertEqual(try canonical(lonely), try ClassifierParityFixtures.sha256(of: lonely))
        let broken = folder.appendingPathComponent("broken.bam")
        try Data("not a BAM\n".utf8).write(to: broken)
        XCTAssertThrowsError(try canonical(broken))
        XCTAssertEqual(
            TaxTriageParityPayloads.withoutCommandLines("@PG\tID:x\tCL:a b\tVN:1\n@CO\tCL:kept\nr\t0\n"),
            "@PG\tID:x\tVN:1\n@CO\tCL:kept\nr\t0\n", "only the CL: field of a @PG line goes"
        )
    }

    /// The baseline reader (F2c). A row of an earlier run's 7-field table that names a BAM or an index gets the
    /// canonical digest of the copy that the evidence kept, a row of another file keeps its digest, and a copy that
    /// is not there is a difference from any file.
    func testTheBaselineReaderGivesAnAlignmentRowItsCanonicalDigest() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let folder = try TestTempDirectory.make(prefix: "TaxTriageParityBaseline")
        defer { TestTempDirectory.cleanup(folder) }
        let a = try Self.makeBAM("a", sam: Self.sam(), in: folder, samtools: samtools)
        let b = try Self.makeBAM("b", sam: Self.sam(command: "samtools markdup /private/tmp/run-b/S1.bam"), in: folder, samtools: samtools)
        let indexA = try Self.index(a, samtools: samtools)
        let indexB = try Self.index(b, samtools: samtools)

        let key = "minimap2/S1.S1.dwnld.references.bam"
        let caseFolder = folder.appendingPathComponent("X1", isDirectory: true)
        var table = ["side\tsample\tkind\tkey\tsha256\tsize\tpath"]
        for (side, bam, index) in [("A", a, indexA), ("C'", b, indexB)] {
            let copies = caseFolder.appendingPathComponent("payloads/\(TaxTriageParitySide(rawValue: side)!.folderName)/S1/minimap2", isDirectory: true)
            try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bam, to: copies.appendingPathComponent("S1.S1.dwnld.references.bam"))
            try FileManager.default.copyItem(at: index, to: copies.appendingPathComponent("S1.S1.dwnld.references.bam.bai"))
            for (name, file) in [(key, bam), (key + ".bai", index)] {
                table.append("\(side)\tS1\tkept reads\t\(name)\t\(try ClassifierParityFixtures.sha256(of: file))\t1\tx/\(name)")
            }
        }
        table.append("C\tS1\tkept reads\t\(key)\t\(String(repeating: "b", count: 64))\t1\tx/\(key)")
        table.append("C\tS1\treport\treport/S1.odr.txt\t\(String(repeating: "c", count: 64))\t1\tx/report")
        try FileManager.default.createDirectory(at: caseFolder, withIntermediateDirectories: true)
        try Data((table.joined(separator: "\n") + "\n").utf8)
            .write(to: caseFolder.appendingPathComponent(TaxTriageParityEvidence.payloadFileName))

        let rows = try TaxTriageParityEvidence.payloadRows(in: caseFolder, samtools: samtools).map(\.payload)
        XCTAssertEqual(rows[0].sha256, rows[2].sha256, "the BAMs of A and C' differ only in a @PG command line")
        XCTAssertEqual(rows[1].sha256, rows[3].sha256, "so do their indexes")
        XCTAssertNotEqual(rows[0].sha256, rows[0].rawSHA256)
        XCTAssertEqual(rows[0].rawSHA256, try ClassifierParityFixtures.sha256(of: a), "field 4 of a 7-field row is the raw digest")
        XCTAssertNotEqual(rows[0].rawSHA256, rows[2].rawSHA256)
        XCTAssertEqual(rows[5].sha256, String(repeating: "c", count: 64), "a row of another kind keeps its digest")
        let missing = TaxTriageParityPayloads.differences(reference: [rows[0]], .a, candidate: [rows[4]], .c)
        XCTAssertEqual(missing.map(\.id), ["kept reads: S1: differs: \(key)"], "a copy that is not there is a finding")
        XCTAssertTrue(missing.first?.detail.contains("no copy of this file in the baseline") == true, missing.description)
        let plain = try TaxTriageParityEvidence.payloadRows(in: caseFolder).map(\.payload)
        XCTAssertEqual(plain.map(\.sha256), plain.map(\.rawSHA256), "without samtools the rows keep their digests")
    }

    /// F2 on the copies a real pass kept. `LUNGFISH_PARITY_BASELINE` names the evidence of an earlier pass, such as
    /// window 1's. Every side of its X1 holds a BAM and an index of the sample whose bytes differ, and they must share
    /// one canonical digest. The log shows each side's canonical and raw digest.
    func testTheBaselineAlignmentsOfEverySideShareACanonicalDigest() async throws {
        guard let baseline = try TaxTriageParityEvidence.baselineFolder() else {
            throw XCTSkip("Set \(TaxTriageParityEvidence.baselineVariable) to the evidence folder of an earlier real pass.")
        }
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let rows = try TaxTriageParityEvidence.payloadRows(
            in: baseline.appendingPathComponent(TaxTriageParityCase.x1.rawValue, isDirectory: true), samtools: samtools
        )
        let alignments = rows.filter { row in
            row.kind == .keptReads && [".bam", ".bai", ".csi"].contains { row.key.lowercased().hasSuffix($0) }
        }
        XCTAssertFalse(alignments.isEmpty, "the baseline's X1 holds no BAM or index")
        for row in alignments {
            print("[live-nextflow] baseline \(row.side) \(row.sample) \(row.key) canonical \(row.payload.sha256.prefix(16)) raw \(row.payload.rawSHA256.prefix(16))")
        }
        for (name, group) in Dictionary(grouping: alignments, by: { "\($0.sample) \($0.key)" }).sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(Set(group.map(\.payload.sha256)).count, 1, "\(name) has one canonical digest on sides \(group.map(\.side))")
        }
    }

    // MARK: - Fixtures

    /// The SAM text of a small BAM sorted by coordinate, with two @PG lines that each carry a command line.
    private static func sam(
        command: String = "samtools markdup -@ 4 /private/tmp/run-a/minimap2/S1.bam /private/tmp/run-a/minimap2/.markdup-1111/out.bam",
        version: String = "1.24",
        secondReadPosition: Int = 30
    ) -> String {
        [
            "@HD\tVN:1.6\tSO:coordinate",
            "@SQ\tSN:ref1\tLN:200",
            "@SQ\tSN:ref2\tLN:100",
            "@PG\tID:minimap2\tPN:minimap2\tVN:2.30\tCL:minimap2 -ax sr ref.fa reads.fq",
            "@PG\tID:samtools\tPN:samtools\tPP:minimap2\tVN:\(version)\tCL:\(command)",
            "read1\t0\tref1\t10\t60\t10M\t*\t0\t0\tACGTACGTAC\tIIIIIIIIII",
            "read2\t16\tref1\t\(secondReadPosition)\t60\t10M\t*\t0\t0\tTTGCATTGCA\tIIIIIIIIII",
            "read3\t0\tref2\t5\t60\t10M\t*\t0\t0\tGGGAAATTTC\tIIIIIIIIII",
        ].joined(separator: "\n") + "\n"
    }

    /// `<name>.bam` made from `sam` with `samtools view -b --no-PG`, which adds no @PG line of its own.
    private static func makeBAM(_ name: String, sam: String, in folder: URL, samtools: URL) throws -> URL {
        let text = folder.appendingPathComponent("\(name).sam")
        try Data(sam.utf8).write(to: text)
        let bam = folder.appendingPathComponent("\(name).bam")
        let result = try ProcessRunner.run(samtools, ["view", "-b", "--no-PG", "-o", bam.path, text.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        return bam
    }

    /// The `.bai` that `samtools index` writes beside `bam`.
    private static func index(_ bam: URL, samtools: URL) throws -> URL {
        let result = try ProcessRunner.run(samtools, ["index", bam.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        return URL(fileURLWithPath: bam.path + ".bai")
    }
}
