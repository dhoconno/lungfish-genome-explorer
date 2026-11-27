// BuildDbTaxTriageStrainGroupTests.swift - A TaxTriage row counts on every strain it sums, and each read in one row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// TT-STRAIN-GROUP (S1, O75 meeting 2026-11-23, folds TT-ACCESSION-IN-TWO-ORGANISMS). TaxTriage sums the strains of an
// organism into one report row (`match_paths.py:2733`), and its gcfmap names each strain apart, so the row
// `Influenza A virus` covers `Influenza A virus (A/one(H1N1))` on ACC1 and `Influenza A virus (A/two(H3N2))` on ACC2.
// `build-db taxtriage` gave a row the references of the first gcfmap organism its name matched, so Unique Reads,
// Extract Reads, BLAST Verify and the alignment pane reached ACC1 alone. An accession the gcfmap lists under two
// organism names was counted in both rows.
//
// The stand-in samtools answers `view -c -F <flag> <bam> <reference>...` by counting, as samtools does, the records of
// the SAM text each test writes beside the BAM path. The same records as a sorted, indexed BAM gave these counts with
// samtools 1.24 (lane TT-m2 report):
// - `samtools view -c -F 0xD04 strain.bam ACC1 ACC2` printed 5, and `... ACC1` printed 3.
// - `samtools view -c -F 0xD04 shared.bam ACC3 ACC4` printed 5, `... ACC5` printed 1, and `... ACC5 ACC3` printed 5.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbTaxTriageStrainGroupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageStrainGroup")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, where the row read 3 unique reads and reached ACC1 alone.
    func testRowCountsUniqueReadsOnEveryStrainItSums() async throws {
        let result = try Self.stage(
            in: root,
            rows: [("Influenza A virus", 11320, 5)],
            gcfmap: [("ACC1", "Influenza A virus (A/one(H1N1))"), ("ACC2", "Influenza A virus (A/two(H3N2))")],
            reads: [("ACC1", 3), ("ACC2", 2)]
        )
        let database = try await Self.build(result)

        let flu = try Self.row("Influenza A virus", in: database)
        XCTAssertEqual(
            flu.uniqueReads, 5,
            "samtools view -c -F 0xD04 prints 5 over ACC1 ACC2, the two strains the row sums, and 3 over ACC1 alone"
        )
        XCTAssertEqual(
            try Self.references(of: flu, in: database), ["ACC1", "ACC2"],
            "Extract Reads, BLAST Verify and the pane reach both strains"
        )
    }

    /// Red at the base, where `Human mastadenovirus C` counted the 4 reads of ACC3 too, so its 5 exceeded its Reads of 1
    /// and read a dash, and its references held ACC3. ACC3 belongs to the first organism the gcfmap lists it under.
    func testAccessionUnderTwoOrganismNamesCountsInOneRowOnly() async throws {
        let result = try Self.stage(
            in: root,
            rows: [("Human mastadenovirus B", 108098, 5), ("Human mastadenovirus C", 129951, 1)],
            gcfmap: [
                ("ACC3", "Human mastadenovirus B"), ("ACC4", "Human mastadenovirus B"),
                ("ACC5", "Human mastadenovirus C"), ("ACC3", "Human mastadenovirus C"),
            ],
            reads: [("ACC3", 4), ("ACC4", 1), ("ACC5", 1)]
        )
        let database = try await Self.build(result)

        let first = try Self.row("Human mastadenovirus B", in: database)
        let second = try Self.row("Human mastadenovirus C", in: database)
        XCTAssertEqual(first.uniqueReads, 5, "samtools prints 5 over ACC3 ACC4")
        XCTAssertEqual(second.uniqueReads, 1, "samtools prints 1 over ACC5, and 5 over ACC5 ACC3")
        XCTAssertEqual(try Self.references(of: first, in: database), ["ACC3", "ACC4"])
        XCTAssertEqual(try Self.references(of: second, in: database), ["ACC5"], "ACC3's reads count in one row only")
    }

    /// Red at the base, where the first organism the gcfmap lists for ACC3, `Human adenovirus 5`, has no report row, so
    /// ACC3 landed in no row, and `Human mastadenovirus C` read 1 unique read and held ACC4 alone, though TaxTriage
    /// counted ACC3 in it (TT-m2 BIO S-1). ACC3 belongs to the first organism that lists it and has a row. samtools
    /// prints 5 over ACC3 ACC4, the same records as the case above (lane TT-m2 report).
    func testSharedAccessionGoesToTheOrganismThatHasARow() async throws {
        let result = try Self.stage(
            in: root,
            rows: [("Human mastadenovirus C", 129951, 5)],
            gcfmap: [
                ("ACC3", "Human adenovirus 5"), ("ACC3", "Human mastadenovirus C"), ("ACC4", "Human mastadenovirus C"),
            ],
            reads: [("ACC3", 4), ("ACC4", 1)]
        )
        let database = try await Self.build(result)

        let row = try Self.row("Human mastadenovirus C", in: database)
        XCTAssertEqual(row.uniqueReads, 5, "samtools prints 5 over ACC3 ACC4, the two references the row owns")
        XCTAssertEqual(
            try Self.references(of: row, in: database), ["ACC3", "ACC4"],
            "ACC3 is listed first under an organism with no row, so it goes to the organism that has one"
        )
    }

    /// Green at the base too. When the report has a row for a strain as well as for its organism, the strain's
    /// references stay with the strain's own row, so no read counts in both.
    func testStrainWithItsOwnRowStaysInThatRow() async throws {
        let result = try Self.stage(
            in: root,
            rows: [("Influenza A virus", 11320, 3), ("Influenza A virus (A/two(H3N2))", 41857, 2)],
            gcfmap: [("ACC1", "Influenza A virus (A/one(H1N1))"), ("ACC2", "Influenza A virus (A/two(H3N2))")],
            reads: [("ACC1", 3), ("ACC2", 2)]
        )
        let database = try await Self.build(result)

        let organism = try Self.row("Influenza A virus", in: database)
        let strain = try Self.row("Influenza A virus (A/two(H3N2))", in: database)
        XCTAssertEqual(organism.uniqueReads, 3)
        XCTAssertEqual(strain.uniqueReads, 2)
        XCTAssertEqual(try Self.references(of: organism, in: database), ["ACC1"])
        XCTAssertEqual(try Self.references(of: strain, in: database), ["ACC2"])
    }

    // MARK: - Fixture

    private static let sample = "sample1"

    /// Writes a single-sample TaxTriage result: `report/<sample>.odr.txt` with `rows`, the gcfmap, a BAM path with an
    /// index, and beside it the SAM text the stand-in counts, one primary record per read on each named reference.
    private static func stage(
        in root: URL,
        rows: [(organism: String, taxID: Int, reads: Int)],
        gcfmap: [(accession: String, organism: String)],
        reads: [(reference: String, count: Int)]
    ) throws -> URL {
        let result = root.appendingPathComponent("taxtriage-strain-group", isDirectory: true)
        let fm = FileManager.default
        for folder in ["report", "combine", "minimap2"] {
            try fm.createDirectory(at: result.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try odr(rows: rows).write(
            to: result.appendingPathComponent("report/\(sample).odr.txt"), atomically: true, encoding: .utf8
        )
        let gcfmapText = gcfmap.map { "\($0.accession)\tGCF_000000000.1\t\($0.organism)\t\($0.organism) segment" }
        try (gcfmapText.joined(separator: "\n") + "\n").write(
            to: result.appendingPathComponent("combine/\(sample).combined.gcfmap.tsv"), atomically: true, encoding: .utf8
        )
        let bam = result.appendingPathComponent("minimap2/\(sample).\(sample).dwnld.references.bam")
        try Data("stand-in".utf8).write(to: bam)
        try Data().write(to: URL(fileURLWithPath: bam.path + ".bai"))
        try sam(reads: reads).write(to: URL(fileURLWithPath: bam.path + ".sam"), atomically: true, encoding: .utf8)
        return result
    }

    /// The SAM text: a header that names `samtools markdup`, so the count pass trusts the duplicate flags, then one
    /// mapped primary record a read.
    static func sam(reads: [(reference: String, count: Int)]) -> String {
        var lines = ["@HD\tVN:1.6\tSO:coordinate"]
        lines += reads.map { "@SQ\tSN:\($0.reference)\tLN:1000" }
        lines.append("@PG\tID:samtools.markdup\tPN:samtools\tCL:samtools markdup")
        for (reference, count) in reads {
            for n in 1...count {
                lines.append("\(reference)_r\(n)\t0\t\(reference)\t\(n * 10)\t60\t10M\t*\t0\t0\tACGTACGTAC\tIIIIIIIIII")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The header and one row of the NTC-P fixture's patient report, with organism, sample, Reads and tax ID set for
    /// each of `rows`.
    private static func odr(rows: [(organism: String, taxID: Int, reads: Int)]) throws -> String {
        let template = try String(
            contentsOf: BuildDbStreamCapture.fixturesFolder.appendingPathComponent("taxtriage-ntc-p/patient/report/patient.odr.txt"),
            encoding: .utf8
        )
        let lines = template.split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let cells = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        func column(_ name: String) throws -> Int { try XCTUnwrap(header.firstIndex(of: name), name) }
        var out = [lines[0]]
        for (index, row) in rows.enumerated() {
            var line = cells
            line[try column("Index")] = "\(index)"
            line[try column("index")] = "\(index)"
            line[try column("Detected Organism")] = row.organism
            line[try column("Specimen ID")] = sample
            line[try column("# Reads Aligned")] = "\(row.reads)"
            line[try column("Reads Aligned")] = "\(row.reads)"
            line[try column("Taxonomic ID #")] = "\(row.taxID)"
            out.append(line.joined(separator: "\t"))
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func build(_ result: URL) async throws -> TaxTriageDatabase {
        let home = try ManagedSamtoolsHome.makeStub(
            rootURL: result.deletingLastPathComponent(), namePrefix: "TTStrainHome", script: standInSamtools
        )
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.homeURL.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        }
        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "--no-cleanup", "-q"]).run()
        return try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
    }

    private static func row(_ organism: String, in database: TaxTriageDatabase) throws -> TaxTriageTaxonomyRow {
        try XCTUnwrap(try database.fetchRows(samples: [sample]).first { $0.organism == organism }, organism)
    }

    /// The references stored for `row`, which Extract Reads, BLAST Verify and the alignment pane read.
    private static func references(of row: TaxTriageTaxonomyRow, in database: TaxTriageDatabase) throws -> [String] {
        try database.fetchOrganismReferences(of: [row]).values.flatMap { $0 }.map(\.accession).sorted()
    }

    /// Counts the records of `<bam>.sam` whose flag has none of the `-F` bits, on the named references or on all.
    private static let standInSamtools = #"""
    #!/bin/sh
    cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
      idxstats) exit 0 ;;
      index) : > "$1.bai"; exit 0 ;;
      view)
        header=0; flag=0; bam=""; regions=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -H) header=1; shift ;;
            -c) shift ;;
            -F) flag="$2"; shift 2 ;;
            -q) shift 2 ;;
            *) if [ -z "$bam" ]; then bam="$1"; else regions="$regions $1"; fi; shift ;;
          esac
        done
        if [ "$header" -eq 1 ]; then /usr/bin/grep '^@' "$bam.sam"; exit 0; fi
        /usr/bin/awk -v mask="$flag" -v regions="$regions" '
          BEGIN { n = split(regions, wanted, " "); for (i = 1; i <= n; i++) named[wanted[i]] = 1 }
          /^@/ { next }
          {
            skip = 0
            for (bit = 1; bit <= 2048; bit *= 2) if (int($2 / bit) % 2 == 1 && int(mask / bit) % 2 == 1) skip = 1
            if (!skip && (n == 0 || ($3 in named))) count++
          }
          END { print count + 0 }' "$bam.sam"
        ;;
      *) exit 1 ;;
    esac
    """#
}
