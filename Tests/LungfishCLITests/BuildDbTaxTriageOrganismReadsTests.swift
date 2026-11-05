// BuildDbTaxTriageOrganismReadsTests.swift - A TaxTriage row's Reads count every reference of its organism
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTREADS (WALK-BIO ruling, section Influenza, items 1 and 2, S1). `build-db taxtriage` replaces each
// row's Reads and Unique Reads with counts of the row's BAM, and it counted only the row's primary accession, the
// first reference of the organism in `combine/<sample>.combined.gcfmap.tsv`. Influenza A has eight segments, each a
// reference of its own. In the walk's NTC-P batch (fixture `taxtriage-ntc-p`) its reads sit on segments 2 and 5
// (NC_007372.1 and NC_007369.1) and none on segment 4 (NC_007366.1, the primary accession), so the row read 0 where
// TaxTriage's own report says 3 for patient and 2 for the negative control NTC_1.
//
// The stand-in samtools answers `view -c -F <flag> <bam> <accession>...` with the sum of the per-reference counts of
// the fixture's BAMs (`samtools view -F 0x904` and `-F 0xD04`, then `cut -f3 | uniq -c`), so a count that names the
// primary accession alone reads 0 for Influenza. The live form is `BuildDbTaxTriageOrganismReadsLiveConformanceTests`.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbTaxTriageOrganismReadsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageOrganismReads")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, where Influenza reads 0 in both samples. Every row of the two reports reads the
    /// `# Reads Aligned` of its report, which on this batch is also the count of the row's primary records over all
    /// the references of its organism.
    func testTaxTriageRowReadsEqualODRReadsAligned() async throws {
        let home = try ManagedSamtoolsHome.makeStub(rootURL: root, namePrefix: "TTReadsHome", script: Self.standInSamtools)
        let result = try TaxTriageNTCPFixture.stage(in: root)

        try await Self.withHomeDirectory(home.homeURL) {
            try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()
        }

        try TaxTriageNTCPFixture.assertRowsReadTheirReports(in: result)
    }

    /// BIO ruling 1, option (a). Reads are TaxTriage's own `# Reads Aligned`, counted after its mapping-quality and
    /// conflict filters, and Unique Reads count the BAM over every reference of the organism. Here the patient's BAM
    /// holds 40 primary records on the SARS-CoV-2 reference, 38 of them not duplicates, where the report kept 33. Reads
    /// stay 33 and Unique Reads reads a dash (nil), since the BAM holds more unique reads than the row has Reads. Red at
    /// 0ea86b0a9, which wrote the BAM's 40 and 38.
    func testTaxTriageReadsKeepTheReportCountWhenTheBAMHoldsMore() async throws {
        let script = Self.standIn(patientSARSTotal: 40, patientSARSUnique: 38)
        let home = try ManagedSamtoolsHome.makeStub(rootURL: root, namePrefix: "TTReadsHome", script: script)
        let result = try TaxTriageNTCPFixture.stage(in: root)

        try await Self.withHomeDirectory(home.homeURL) {
            try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()
        }

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let rows = try database.fetchRows(samples: try database.fetchSamples().map(\.sample))
        func row(_ sample: String, _ matches: (TaxTriageTaxonomyRow) -> Bool) throws -> TaxTriageTaxonomyRow {
            try XCTUnwrap(rows.first { $0.sample == sample && matches($0) }, "a row of \(sample)")
        }
        let patientCoV = try row("patient") { $0.primaryAccession == "NC_045512.2" }
        XCTAssertEqual(patientCoV.readsAligned, 33, "patient SARS-CoV-2 keeps its report's # Reads Aligned, though its BAM holds 40")
        XCTAssertNil(patientCoV.uniqueReads, "the BAM holds 38 unique reads where the row has 33 Reads, so the count does not apply")
        let patientFlu = try row("patient") { $0.taxId == 335341 }
        XCTAssertEqual(patientFlu.readsAligned, 3, "patient Influenza A keeps its report's 3")
        XCTAssertEqual(patientFlu.uniqueReads, 2, "its unique count is the BAM's over the references of the organism")
        let controlCoV = try row("NTC_1") { $0.primaryAccession == "NC_045512.2" }
        XCTAssertEqual(controlCoV.readsAligned, 20)
        XCTAssertEqual(controlCoV.uniqueReads, 6)
    }

    /// ARCH should-fix 1. The `read_count` mark vouches for the counts that the BAM pass writes, so the database does not
    /// hold it while the pass runs. A kill in that window would otherwise leave a database that reads as current with the
    /// report's parsed counts. Red at 0ea86b0a9, whose `create` wrote the mark.
    func testReadCountKeyIsAbsentUntilTheCountPassEnds() async throws {
        let home = try ManagedSamtoolsHome.makeStub(rootURL: root, namePrefix: "TTReadsHome", script: Self.standInSamtools)
        let result = try TaxTriageNTCPFixture.stage(in: root)
        let databaseURL = result.appendingPathComponent("taxtriage.sqlite")
        let tap = BuiltDatabaseTap(databaseURL: databaseURL)

        try await Self.withHomeDirectory(home.homeURL) {
            _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(
                in: result, options: BuildDbRunOptions(globalOptions: try GlobalOptions.parse([])), events: tap.sink
            )
        }

        XCTAssertTrue(tap.sawSummary, "the build reported that it built the database")
        XCTAssertNil(tap.readCountAtSummary, "no read_count while the count pass has not run")
        let finished = try TaxTriageDatabase(at: databaseURL).fetchMetadata()
        XCTAssertEqual(finished[TaxTriageDatabase.readCountMetadataKey], TaxTriageDatabase.currentReadCount, "marked once the pass ends")
    }

    private static func withHomeDirectory(_ home: URL, perform block: () async throws -> Void) async throws {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        }
        try await block()
    }

    /// Answers the calls of the build's count pass on the fixture's BAMs. The header names `samtools markdup`, so the
    /// pass keeps the BAMs, and each count sums the named references for the sample of the BAM's file name.
    private static let standInSamtools = standIn(patientSARSTotal: 33, patientSARSUnique: 6)

    /// The stand-in, with the patient's BAM holding `patientSARSTotal` primary records on the SARS-CoV-2 reference and
    /// `patientSARSUnique` of them not marked as duplicates.
    private static func standIn(patientSARSTotal: Int, patientSARSUnique: Int) -> String {
        #"""
    #!/bin/sh
    cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
      idxstats) exit 0 ;;
      index) : > "$1.bai"; exit 0 ;;
      view)
        header=0; flag=""; bam=""; accessions=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -H) header=1; shift ;;
            -c) shift ;;
            -F) flag="$2"; shift 2 ;;
            *) if [ -z "$bam" ]; then bam="$1"; else accessions="$accessions $1"; fi; shift ;;
          esac
        done
        if [ "$header" -eq 1 ]; then
          printf '@HD\tVN:1.6\tSO:coordinate\n@PG\tID:samtools.markdup\tPN:samtools\tCL:samtools markdup\n'
          exit 0
        fi
        case "$flag" in
          2308) kind=total ;;
          3332) kind=unique ;;
          4|1028) echo 0; exit 0 ;;
          *) exit 1 ;;
        esac
        sample=$(/usr/bin/basename "$bam")
        sample=${sample%%.*}
        sum=0
        for accession in $accessions; do
          case "$sample:$accession:$kind" in
            patient:NC_045512.2:total) n=\#(patientSARSTotal) ;;
            patient:NC_045512.2:unique) n=\#(patientSARSUnique) ;;
            patient:NC_007369.1:total) n=2 ;;
            patient:NC_007369.1:unique) n=1 ;;
            patient:NC_007372.1:*) n=1 ;;
            patient:NC_026144.1:*) n=1 ;;
            patient:NC_003045.1:*) n=1 ;;
            NTC_1:NC_045512.2:total) n=20 ;;
            NTC_1:NC_045512.2:unique) n=6 ;;
            NTC_1:NC_007369.1:total) n=2 ;;
            NTC_1:NC_007369.1:unique) n=1 ;;
            NTC_1:NC_026144.1:*) n=1 ;;
            *) n=0 ;;
          esac
          sum=$((sum + n))
        done
        echo "$sum"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    """#
    }
}

/// The `taxtriage-ntc-p` fixture, the patient and NTC_1 folders of the walk's NTC-P batch, and what its reports say.
enum TaxTriageNTCPFixture {
    /// Copies the fixture to `root` and returns the batch folder.
    static func stage(in root: URL) throws -> URL {
        let fixture = BuildDbStreamCapture.fixturesFolder.appendingPathComponent("taxtriage-ntc-p", isDirectory: true)
        let result = root.appendingPathComponent("taxtriage-ntc-p", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        return result
    }

    /// `# Reads Aligned` of each row of `<sample>/report/<sample>.odr.txt`, keyed by sample and taxonomic ID.
    static func reportedReads(in result: URL) throws -> [String: Int] {
        var reads: [String: Int] = [:]
        for sample in ["patient", "NTC_1"] {
            let report = result.appendingPathComponent("\(sample)/report/\(sample).odr.txt")
            let lines = try String(contentsOf: report, encoding: .utf8).split(separator: "\n").map(String.init)
            let header = try XCTUnwrap(lines.first).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let specimen = try XCTUnwrap(header.firstIndex(of: "Specimen ID"))
            let taxID = try XCTUnwrap(header.firstIndex(of: "Taxonomic ID #"))
            let aligned = try XCTUnwrap(header.firstIndex(of: "# Reads Aligned"))
            for line in lines.dropFirst() {
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                reads["\(cells[specimen])\t\(cells[taxID])"] = try XCTUnwrap(Int(cells[aligned]), line)
            }
        }
        return reads
    }

    /// Every row of the database that `build-db taxtriage` wrote into `result` reads its report's `# Reads Aligned`,
    /// Influenza A (taxid 335341) 3 in patient and 2 in NTC_1, and holds a unique count no larger than its reads.
    static func assertRowsReadTheirReports(in result: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let reported = try reportedReads(in: result)
        XCTAssertEqual(reported["patient\t335341"], 3, "the patient report holds 3 Influenza A reads", file: file, line: line)
        XCTAssertEqual(reported["NTC_1\t335341"], 2, "the NTC_1 report holds 2 Influenza A reads", file: file, line: line)

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let rows = try database.fetchRows(samples: try database.fetchSamples().map(\.sample))
        XCTAssertEqual(rows.count, reported.count, "one row for each row of the two reports", file: file, line: line)
        for row in rows {
            let key = "\(row.sample)\t\(row.taxId.map(String.init) ?? "")"
            XCTAssertEqual(
                row.readsAligned, reported[key],
                "\(row.sample) \(row.organism) reads its report's # Reads Aligned", file: file, line: line
            )
            let unique = try XCTUnwrap(row.uniqueReads, "\(row.sample) \(row.organism) has a unique count", file: file, line: line)
            XCTAssertTrue(
                unique >= 1 && unique <= row.readsAligned,
                "\(row.sample) \(row.organism) holds \(unique) unique of \(row.readsAligned) reads", file: file, line: line
            )
        }
    }
}

/// Reads the `read_count` mark of the database at the moment the build reports that it built it.
private final class BuiltDatabaseTap: @unchecked Sendable {
    private let databaseURL: URL
    private let lock = NSLock()
    private var summarySeen = false
    private var readCount: String?

    init(databaseURL: URL) { self.databaseURL = databaseURL }

    var sawSummary: Bool {
        lock.lock()
        defer { lock.unlock() }
        return summarySeen
    }

    var readCountAtSummary: String? {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    var sink: BuildDbEventSink {
        BuildDbEventSink(progress: { _, _ in }, text: { self.take($0) }, textWarning: { _ in }, warning: { _ in })
    }

    private func take(_ line: String) {
        guard line.hasPrefix("Built taxtriage.sqlite") else { return }
        let mark = (try? TaxTriageDatabase(at: databaseURL).fetchMetadata())?[TaxTriageDatabase.readCountMetadataKey]
        lock.lock()
        defer { lock.unlock() }
        summarySeen = true
        readCount = mark
    }
}
