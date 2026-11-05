// TaxTriageOrganismReferencesTests.swift - A TaxTriage row's actions reach every reference of its organism
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTACCESSIONS (BIO F7, S1, with TTREADS F5 and F6). The viewer built each row's accessions from the
// database's `primary_accession`, the first reference of the organism in the sample's gcfmap. Influenza A has eight
// segments, each a reference of its own. In the walk's NTC-P batch (fixture `taxtriage-ntc-p`) its reads sit on
// segment 5 (NC_007369.1) in both samples and on segment 2 (NC_007372.1) in patient, and none on segment 4
// (NC_007366.1, the primary accession). So Extract Reads and BLAST Verify sent segment 4 alone and found no read for a
// row whose Reads say 2 or 3, and the alignment pane opened on segment 4 with segment 4's length.
//
// The stand-in samtools answers the build's calls on the fixture's BAMs. Its `idxstats` prints what the real samtools
// prints for them. The live form, which extracts the reads, is `TaxTriageOrganismReferencesLiveConformanceTests`.

import AppKit
import XCTest
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageOrganismReferencesTests: XCTestCase {

    /// Red at the base, where each Influenza row sends segment 4 alone and opens it. Every action of the row now
    /// reaches all eight segments, and the pane opens segment 5, which holds the most reads, at its own length.
    func testInfluenzaRowActionsReachTheSegmentsThatHoldItsReads() throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageOrganismReferences")
        defer { TestTempDirectory.cleanup(root) }
        let result = try Self.offMain { try await Self.buildFixture(in: root, standIn: true) }
        let pane = RecordingAlignmentPane()
        let vc = try Self.openViewer(
            on: result, pane: pane, defaults: makeTestDefaultsSuite(prefix: "TaxTriageOrganismReferences").defaults
        )
        var extracted: [ClassifierRowSelector]?
        vc.resultActions.onExtractionRequested = { extracted = $0.selectors }
        var blasted: [String]?
        vc.onBlastVerification = { _, _, accessions, _, _ in blasted = accessions }

        for sample in ["NTC_1", "patient"] {
            extracted = nil
            blasted = nil
            let metric = try Self.selectInfluenzaRow(of: sample, in: vc, pane: pane)

            let request = try XCTUnwrap(pane.requests.last, sample)
            XCTAssertEqual(request.contig.name, Self.segment5, "\(sample): the pane opens the segment that holds the most reads")
            XCTAssertEqual(request.contig.expectedLength, 1566, "\(sample): at segment 5's own length, not segment 4's 1,762")

            vc.testActionBar.extractButton.performClick(nil)
            let selectors = try XCTUnwrap(extracted, "\(sample): Extract Reads made a request")
            XCTAssertEqual(selectors.map(\.sampleId), [sample], "\(sample): the request names the row's own sample")
            let regions = selectors.flatMap(\.accessions)
            XCTAssertEqual(Set(regions), Self.h3n2Segments, "\(sample): Extract Reads names every segment, sent \(regions)")
            XCTAssertTrue(regions.contains(Self.segment5) && regions.contains(Self.segment2), "\(sample): sent \(regions)")

            vc.testBatchFlatTableView.onBlastVerifyRequested?(metric, metric.reads)
            let searched = try XCTUnwrap(blasted, "\(sample): BLAST Verify reached the host")
            XCTAssertEqual(Set(searched), Self.h3n2Segments, "\(sample): BLAST Verify reads every segment, sent \(searched)")
        }
    }

    /// Review SF1. Two rows of one sample whose primary accessions sit in one gcfmap organism group each store the same
    /// references, and Extract Reads appended both lists to the sample's request, so it sent every reference twice,
    /// which samtools can answer by writing a read twice. NTC_1's second row takes the Influenza row's eight segments
    /// here. Red at the base, which sends sixteen entries for the eight segments.
    func testTwoRowsOfOneSampleThatShareReferencesSendEachReferenceOnce() throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageOrganismReferences")
        defer { TestTempDirectory.cleanup(root) }
        let result = try Self.offMain { try await Self.buildFixture(in: root, standIn: true) }
        let databaseURL = result.appendingPathComponent("taxtriage.sqlite")
        let (rows, existing) = try {
            let database = try TaxTriageDatabase(at: databaseURL)
            let rows = try database.fetchRows(samples: ["NTC_1", "patient"])
            return (rows, try database.fetchOrganismReferences(of: rows))
        }()
        let influenza = try XCTUnwrap(rows.first { $0.sample == "NTC_1" && $0.taxId == Self.influenzaTaxID })
        let second = try XCTUnwrap(rows.first {
            $0.sample == "NTC_1" && $0.taxId != Self.influenzaTaxID && $0.primaryAccession != nil
        })
        var references = existing.values.flatMap { $0 }
        let shared = references.filter { $0.sample == "NTC_1" && $0.primaryAccession == influenza.primaryAccession }
        XCTAssertEqual(Set(shared.map(\.accession)), Self.h3n2Segments, "the Influenza row stores its eight segments")
        references.removeAll { $0.sample == "NTC_1" && $0.primaryAccession == second.primaryAccession }
        references += shared.map {
            TaxTriageOrganismReference(
                sample: "NTC_1", primaryAccession: second.primaryAccession ?? "", accession: $0.accession,
                length: $0.length, mappedReads: $0.mappedReads
            )
        }
        try TaxTriageDatabase.storeOrganismReferences(references, at: databaseURL)

        let pane = RecordingAlignmentPane()
        let vc = try Self.openViewer(
            on: result, pane: pane, defaults: makeTestDefaultsSuite(prefix: "TaxTriageOrganismReferences").defaults
        )
        var extracted: [ClassifierRowSelector]?
        vc.resultActions.onExtractionRequested = { extracted = $0.selectors }
        let displayed = vc.testBatchFlatTableView.displayedRows
        let both = IndexSet(displayed.indices.filter {
            displayed[$0].sample == "NTC_1" && [influenza.taxId, second.taxId].contains(displayed[$0].taxId)
        })
        XCTAssertEqual(both.count, 2, "NTC_1's Influenza row and its second row are shown")
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(both, byExtendingSelection: false)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testActionBar.extractButton.isEnabled }, "Extract Reads is enabled"
        )
        vc.testActionBar.extractButton.performClick(nil)

        let selectors = try XCTUnwrap(extracted, "Extract Reads made a request")
        XCTAssertEqual(selectors.map(\.sampleId), ["NTC_1"], "both rows are one request of their sample")
        let regions = selectors.flatMap(\.accessions)
        XCTAssertEqual(regions.count, Set(regions).count, "each reference is sent once, sent \(regions)")
        XCTAssertEqual(Set(regions), Self.h3n2Segments, "the request still names the eight segments, sent \(regions)")
        XCTAssertEqual(regions.count, 8, "eight entries for the eight segments, sent \(regions)")
    }

    // MARK: - Shared with the live form

    /// Runs `work` off the main thread and spins the main run loop until it ends, so the viewer's row pages, which
    /// load on the main actor, keep loading. An `async` test would hold the main queue while it waits.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = OffMainResult<T>()
        Task.detached {
            do { box.set(.success(try await work())) } catch { box.set(.failure(error)) }
        }
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { box.value != nil }, "the work off the main thread ended")
        return try XCTUnwrap(box.value).get()
    }

    static let segment5 = "NC_007369.1"
    static let segment2 = "NC_007372.1"
    static let influenzaTaxID = 335341

    /// The eight segments of Influenza A virus (A/New York/392/2004(H3N2)) in the fixture's gcfmaps.
    static let h3n2Segments: Set<String> = [
        "NC_007366.1", "NC_007367.1", "NC_007368.1", "NC_007369.1",
        "NC_007370.1", "NC_007371.1", "NC_007372.1", "NC_007373.1",
    ]

    /// Copies `taxtriage-ntc-p` into `root` and runs `build-db taxtriage` on it, with the stand-in samtools when
    /// `standIn` is true and the managed samtools otherwise. Returns the batch folder.
    nonisolated static func buildFixture(in root: URL, standIn: Bool) async throws -> URL {
        let result = root.appendingPathComponent("taxtriage-ntc-p", isDirectory: true)
        try FileManager.default.copyItem(
            at: ClassifierImportAppFixtures.fixturesFolder.appendingPathComponent("taxtriage-ntc-p", isDirectory: true),
            to: result
        )
        guard standIn else {
            try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()
            return result
        }
        let stats = root.appendingPathComponent("idxstats", isDirectory: true)
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        for (sample, text) in idxstats {
            try text.write(to: stats.appendingPathComponent("\(sample).idxstats"), atomically: true, encoding: .utf8)
        }
        let home = try ManagedSamtoolsHome.makeStub(
            rootURL: root, namePrefix: "TTAccessionsHome", script: standInSamtools(idxstatsFolder: stats)
        )
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.homeURL.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        }
        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()
        return result
    }

    /// A viewer over the database `build-db` wrote in `result`, with its seven rows loaded and its first selection
    /// shown in `pane`.
    static func openViewer(
        on result: URL, pane: RecordingAlignmentPane, defaults: UserDefaults
    ) throws -> TaxTriageResultViewController {
        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = defaults
        vc.classifierAlignmentViewerFactory = { pane }
        _ = vc.view
        vc.configureFromDatabase(database, resultURL: result)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testBatchFlatTableView.displayedRows.count == 7 },
            "the seven rows of the two reports load"
        )
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { !pane.requests.isEmpty }, "the first row opens in the pane")
        return vc
    }

    /// Selects the Influenza A row of `sample` and waits until the pane shows it and Extract Reads is enabled.
    static func selectInfluenzaRow(
        of sample: String, in vc: TaxTriageResultViewController, pane: RecordingAlignmentPane
    ) throws -> TaxTriageMetric {
        let rows = vc.testBatchFlatTableView.displayedRows
        let index = try XCTUnwrap(
            rows.firstIndex { $0.sample == sample && $0.taxId == influenzaTaxID }, "\(sample) has an Influenza A row"
        )
        let before = pane.requests.count
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { pane.requests.count > before && vc.testActionBar.extractButton.isEnabled },
            "\(sample): the row opens in the pane and Extract Reads is enabled"
        )
        return rows[index]
    }

    /// `samtools idxstats` of the fixture's two BAMs, as the managed samtools 1.2x prints them.
    nonisolated static let idxstats: [String: String] = {
        let lengths: [(String, Int)] = [
            ("NC_026144.1", 2115), ("NC_045512.2", 29903), ("NC_004910.1", 2341), ("NC_004911.1", 2328),
            ("NC_004912.1", 2225), ("NC_004908.1", 1714), ("NC_004905.2", 1557), ("NC_004909.1", 1418),
            ("NC_004907.1", 1025), ("NC_004906.1", 890), ("NC_007373.1", 2341), ("NC_007372.1", 2341),
            ("NC_007371.1", 2233), ("NC_007366.1", 1762), ("NC_007369.1", 1566), ("NC_007368.1", 1467),
            ("NC_007367.1", 1027), ("NC_007370.1", 890), ("NC_004718.3", 29751),
        ]
        let mapped: [String: [String: Int]] = [
            "NTC_1": ["NC_026144.1": 1, "NC_045512.2": 20, "NC_007369.1": 2],
            "patient": ["NC_026144.1": 1, "NC_045512.2": 33, "NC_007372.1": 1, "NC_007369.1": 2, "NC_003045.1": 1],
        ]
        var out: [String: String] = [:]
        for (sample, reads) in mapped {
            var references = lengths
            if sample == "patient" { references.append(("NC_003045.1", 31028)) }
            let unmapped = sample == "patient" ? 187 : 97
            out[sample] = references.map { "\($0.0)\t\($0.1)\t\(reads[$0.0] ?? 0)\t0\n" }.joined() + "*\t0\t0\t\(unmapped)\n"
        }
        return out
    }()

    /// Answers the build's calls on the fixture's BAMs: a header that names `samtools markdup`, so the pass keeps the
    /// BAMs, Unique Reads summed over the named references, and `idxstats` from `idxstatsFolder`.
    nonisolated static func standInSamtools(idxstatsFolder: URL) -> String {
        #"""
    #!/bin/sh
    cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
      idxstats)
        sample=$(/usr/bin/basename "$1")
        sample=${sample%%.*}
        /bin/cat "\#(idxstatsFolder.path)/$sample.idxstats"
        exit 0
        ;;
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
          3332) ;;
          4|1028) echo 0; exit 0 ;;
          *) exit 1 ;;
        esac
        sample=$(/usr/bin/basename "$bam")
        sample=${sample%%.*}
        sum=0
        for accession in $accessions; do
          case "$sample:$accession" in
            patient:NC_045512.2) n=6 ;;
            patient:NC_007369.1|patient:NC_007372.1|patient:NC_026144.1|patient:NC_003045.1) n=1 ;;
            NTC_1:NC_045512.2) n=6 ;;
            NTC_1:NC_007369.1|NTC_1:NC_026144.1) n=1 ;;
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

/// The result of work that `TaxTriageOrganismReferencesTests.offMain` runs, under a lock.
final class OffMainResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, any Error>?

    var value: Result<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ result: Result<T, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }
}

/// An alignment pane that records each request it is asked to show.
final class RecordingAlignmentPane: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []

    override init() {
        super.init()
        viewController.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func display(_ request: ClassifierAlignmentEvidenceRequest) { requests.append(request) }
    func clear() {}
}
