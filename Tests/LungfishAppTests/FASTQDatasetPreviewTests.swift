// FASTQDatasetPreviewTests.swift - Pins what the FASTQ dataset dashboard previews show
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 S37. The dashboard shows the first 1,000 reads of a dataset as a table and as FASTA text.
// It used to ask seqkit for them. The answers below are literals taken from seqkit v2.13.0 on the
// fixture (`seqkit head -n 1000`, `seqkit fq2fa -w 0` and `seqkit fx2tab -n -l -q`), and the mean
// qualities were recomputed from the quality strings in Python as -10 log10 of the mean error
// probability. The Conformance class checks the literals against the tool and against the app, so
// it holds the pin before and after the preview moves to the Swift FASTQ reader.

import XCTest
import AppKit
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// A small interleaved paired-end FASTQ and what the previews show for it.
///
/// Mates stay in file order. The first pair shares one identifier and differs in its description
/// (`1:N:0` then `2:N:0`), the second uses `/1` and `/2` suffixes with an `N` base, and the third
/// uses SRA style identifiers with a description of several words.
enum FASTQDatasetPreviewFixture {
    struct Row {
        let index: Int
        let readID: String
        let sequence: String
        let length: Int
        let meanQuality: Double
    }

    struct Dataset {
        let project: URL
        let bundle: URL
        let plain: URL
        let gzip: URL
    }

    static let emptyFASTAText = "No FASTQ reads available for preview."
    static let extractFailureText = "Failed to extract reads from FASTQ file."

    static let pairedFASTQ = """
        @A00123:7:H5XYZDSXX:1:1101:1000:1000 1:N:0:ACGTACGT
        GATTACAGATTACAGATTACAGATTACAGATTACAG
        +
        IIIIIIIIIIIIIIIIFFFFFFFFFF::::::::,,
        @A00123:7:H5XYZDSXX:1:1101:1000:1000 2:N:0:ACGTACGT
        CTGTAATCTGTAATCTGTAATCTGTAATCT
        +
        FFFFFFFFFFFFFFFFFFFF::::::::::
        @pair_b/1
        ACGTNACGTACGTTGCATGCAAGCTTAGCCTA
        +
        IIII#IIIIIIIIIIIIIIIIIIIIIIIIIII
        @pair_b/2
        TAGGCTAAGCTTGCATGCAACGTACGTNACGT
        +
        5555555555IIIIIIIIIIIIIIIIIIIIII
        @SRR000001.3.1 3 length=24
        TTGACCGGTTAACCGGTTGACCAA
        +
        @@@@@@@@@@@@@@@@@@@@@@@@
        @SRR000001.3.2 3 length=24
        AACCGGTTAACCGGTTGGTCAACC
        +
        IIIIIIIIIIIIIIIIIIIIIIII

        """

    static let pairedFASTA = """
        >A00123:7:H5XYZDSXX:1:1101:1000:1000 1:N:0:ACGTACGT
        GATTACAGATTACAGATTACAGATTACAGATTACAG
        >A00123:7:H5XYZDSXX:1:1101:1000:1000 2:N:0:ACGTACGT
        CTGTAATCTGTAATCTGTAATCTGTAATCT
        >pair_b/1
        ACGTNACGTACGTTGCATGCAAGCTTAGCCTA
        >pair_b/2
        TAGGCTAAGCTTGCATGCAACGTACGTNACGT
        >SRR000001.3.1 3 length=24
        TTGACCGGTTAACCGGTTGACCAA
        >SRR000001.3.2 3 length=24
        AACCGGTTAACCGGTTGGTCAACC

        """

    /// The first three FASTA entries, for a limit that cuts the second pair in half.
    static let pairedFASTAFirstThree = """
        >A00123:7:H5XYZDSXX:1:1101:1000:1000 1:N:0:ACGTACGT
        GATTACAGATTACAGATTACAGATTACAGATTACAG
        >A00123:7:H5XYZDSXX:1:1101:1000:1000 2:N:0:ACGTACGT
        CTGTAATCTGTAATCTGTAATCTGTAATCT
        >pair_b/1
        ACGTNACGTACGTTGCATGCAAGCTTAGCCTA

        """

    static let rows: [Row] = [
        Row(index: 1, readID: "A00123:7:H5XYZDSXX:1:1101:1000:1000",
            sequence: "GATTACAGATTACAGATTACAGATTACAGATTACAG", length: 36, meanQuality: 22.827014352656),
        Row(index: 2, readID: "A00123:7:H5XYZDSXX:1:1101:1000:1000",
            sequence: "CTGTAATCTGTAATCTGTAATCTGTAATCT", length: 30, meanQuality: 29.255090215614),
        Row(index: 3, readID: "pair_b/1",
            sequence: "ACGTNACGTACGTTGCATGCAAGCTTAGCCTA", length: 32, meanQuality: 17.030214408402),
        Row(index: 4, readID: "pair_b/2",
            sequence: "TAGGCTAAGCTTGCATGCAACGTACGTNACGT", length: 32, meanQuality: 24.956990825212),
        Row(index: 5, readID: "SRR000001.3.1",
            sequence: "TTGACCGGTTAACCGGTTGACCAA", length: 24, meanQuality: 31.0),
        Row(index: 6, readID: "SRR000001.3.2",
            sequence: "AACCGGTTAACCGGTTGGTCAACC", length: 24, meanQuality: 40.0),
    ]

    /// `count` reads named `limit_0001`, `limit_0002` and so on, each 8 bases long at Q40.
    static func numberedFASTQ(count: Int) -> String {
        var text = ""
        for number in 1...count {
            text += "@limit_\(String(format: "%04d", number))\nACGTACGT\n+\nIIIIIIII\n"
        }
        return text
    }

    // MARK: - Files

    /// Writes `<root>/Project.lungfish/Sample.lungfishfastq/reads.fastq` and its `.gz` twin.
    static func makeDataset(in root: URL, fastq: String = pairedFASTQ) throws -> Dataset {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plain = bundle.appendingPathComponent("reads.fastq")
        try Data(fastq.utf8).write(to: plain)
        let gzip = bundle.appendingPathComponent("reads.fastq.gz")
        try gzipCopy(of: plain, to: gzip)
        return Dataset(project: project, bundle: bundle, plain: plain, gzip: gzip)
    }

    private static func gzipCopy(of source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        let compressed = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FASTQDatasetPreviewFixture.gzip", code: Int(process.terminationStatus))
        }
        try compressed.write(to: destination)
    }

    // MARK: - Assertions

    static func assertRows(
        _ records: [FASTQReadPreviewRecord],
        equal expected: [Row] = rows,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(records.count, expected.count, "row count", file: file, line: line)
        for (actual, want) in zip(records, expected) {
            XCTAssertEqual(actual.index, want.index, "index of row \(want.index)", file: file, line: line)
            XCTAssertEqual(actual.readID, want.readID, "read ID of row \(want.index)", file: file, line: line)
            XCTAssertEqual(actual.sequence, want.sequence, "sequence of row \(want.index)", file: file, line: line)
            XCTAssertEqual(actual.length, want.length, "length of row \(want.index)", file: file, line: line)
            XCTAssertEqual(
                actual.meanQuality, want.meanQuality, accuracy: 1e-9,
                "mean quality of row \(want.index)", file: file, line: line)
        }
    }

    // MARK: - Driving the dashboard

    /// Opens the dashboard on `url`, asks for the read preview and waits for its rows or its failure text.
    @MainActor
    static func readPreview(of url: URL, timeout: TimeInterval = 30) async throws -> FASTQDatasetViewController {
        let controller = FASTQDatasetViewController()
        _ = controller.view
        controller.configure(statistics: .empty, records: [], fastqURL: url)
        controller.loadReadPreview()
        let deadline = Date().addingTimeInterval(timeout)
        while !controller.readPreviewLoaded && controller.readPreviewPlaceholder.isHidden {
            guard Date() < deadline else {
                XCTFail("The read preview of \(url.lastPathComponent) neither loaded nor failed in \(timeout) s")
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return controller
    }
}

// MARK: - The pin: seqkit's answers and the app's previews

/// Needs seqkit, so it carries the Conformance name and never runs in the unit tier. It skips on a Mac
/// without the tool and fails there under `LUNGFISH_REQUIRE_TOOLS=1`.
@MainActor
final class FASTQDatasetPreviewSeqkitConformanceTests: XCTestCase {
    private typealias Fixture = FASTQDatasetPreviewFixture
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("seqkit is not installed in the managed tools folder")
        }
        root = try TestTempDirectory.make(prefix: "fastq-dataset-preview-pin")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
        try await super.tearDown()
    }

    private func seqkit(_ arguments: [String]) async throws -> String {
        let result = try await NativeToolRunner.shared.run(.seqkit, arguments: arguments, timeout: 120)
        XCTAssertTrue(result.isSuccess, "seqkit \(arguments.first ?? "") failed: \(result.stderr)")
        return result.stdout
    }

    // MARK: The literals are what seqkit prints

    func testSeqkitPrintsTheLiteralsForPlainAndGzip() async throws {
        let dataset = try Fixture.makeDataset(in: root)
        for url in [dataset.plain, dataset.gzip] {
            let head = try await seqkit(["head", "-n", "1000", url.path])
            XCTAssertEqual(
                head.trimmingCharacters(in: .newlines),
                Fixture.pairedFASTQ.trimmingCharacters(in: .newlines), "head of \(url.lastPathComponent)")
            let fasta = try await seqkit(["fq2fa", "-w", "0", url.path])
            XCTAssertEqual(
                fasta.trimmingCharacters(in: .newlines),
                Fixture.pairedFASTA.trimmingCharacters(in: .newlines), "fq2fa of \(url.lastPathComponent)")
            let table = try await seqkit(["fx2tab", "-n", "-l", "-q", url.path])
            let lines = table.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            XCTAssertEqual(lines.count, Fixture.rows.count, "fx2tab rows of \(url.lastPathComponent)")
            for (columns, row) in zip(lines, Fixture.rows) where columns.count == 3 {
                XCTAssertEqual(columns[0].split(separator: " ").first.map(String.init), row.readID)
                XCTAssertEqual(Int(columns[1]), row.length, "length of \(row.readID)")
                XCTAssertEqual(Double(columns[2]) ?? -1, row.meanQuality, accuracy: 0.0051, "mean Q of \(row.readID)")
            }
        }
    }

    // MARK: The app shows them

    func testFASTAPreviewIsTheLiteralForPlainAndGzip() async throws {
        let dataset = try Fixture.makeDataset(in: root)
        for url in [dataset.plain, dataset.gzip] {
            let fasta = try await FASTQDatasetViewController.buildFASTAPreview(from: url, readLimit: 1_000)
            XCTAssertEqual(fasta, Fixture.pairedFASTA, url.lastPathComponent)
        }
    }

    func testFASTAPreviewLimitCutsAPairInFileOrder() async throws {
        let dataset = try Fixture.makeDataset(in: root)
        for url in [dataset.plain, dataset.gzip] {
            let fasta = try await FASTQDatasetViewController.buildFASTAPreview(from: url, readLimit: 3)
            XCTAssertEqual(fasta, Fixture.pairedFASTAFirstThree, url.lastPathComponent)
        }
    }

    func testReadPreviewRowsAreTheLiteralsForPlainAndGzip() async throws {
        let dataset = try Fixture.makeDataset(in: root)
        for url in [dataset.plain, dataset.gzip] {
            let controller = try await Fixture.readPreview(of: url)
            XCTAssertTrue(controller.readPreviewLoaded, url.lastPathComponent)
            Fixture.assertRows(controller.readPreviewRecords)
        }
    }

    func testBothPreviewsStopAtTheFirstThousandReads() async throws {
        let dataset = try Fixture.makeDataset(in: root, fastq: Fixture.numberedFASTQ(count: 1_200))
        for url in [dataset.plain, dataset.gzip] {
            let controller = try await Fixture.readPreview(of: url)
            let rows = controller.readPreviewRecords
            XCTAssertEqual(rows.count, 1_000, url.lastPathComponent)
            XCTAssertEqual(rows.first?.readID, "limit_0001")
            XCTAssertEqual(rows.last?.readID, "limit_1000")
            XCTAssertEqual(rows.last?.index, 1_000)
            let fasta = try await FASTQDatasetViewController.buildFASTAPreview(from: url, readLimit: 1_000)
            XCTAssertEqual(fasta.split(separator: "\n").count, 2_000, url.lastPathComponent)
            XCTAssertTrue(fasta.hasPrefix(">limit_0001\nACGTACGT\n>limit_0002\n"))
            XCTAssertTrue(fasta.hasSuffix(">limit_1000\nACGTACGT\n"))
        }
    }

    // MARK: The empty and failure texts

    func testAnEmptyFileShowsTheNoReadsTexts() async throws {
        let dataset = try Fixture.makeDataset(in: root, fastq: "")
        for url in [dataset.plain, dataset.gzip] {
            let fasta = try await FASTQDatasetViewController.buildFASTAPreview(from: url, readLimit: 1_000)
            XCTAssertEqual(fasta, Fixture.emptyFASTAText, url.lastPathComponent)
            let controller = try await Fixture.readPreview(of: url)
            XCTAssertFalse(controller.readPreviewLoaded, url.lastPathComponent)
            XCTAssertFalse(controller.readPreviewPlaceholder.isHidden, url.lastPathComponent)
            XCTAssertEqual(controller.readPreviewPlaceholder.stringValue, Fixture.extractFailureText)
        }
    }

    func testAFileThatIsNotFASTQShowsTheFailureTexts() async throws {
        let dataset = try Fixture.makeDataset(in: root, fastq: "this is not a FASTQ file\nat all\n")
        for url in [dataset.plain, dataset.gzip] {
            do {
                let fasta = try await FASTQDatasetViewController.buildFASTAPreview(from: url, readLimit: 1_000)
                XCTFail("The FASTA preview of \(url.lastPathComponent) should throw, it returned \(fasta)")
            } catch {
                XCTAssertTrue(error is FASTQError, "\(url.lastPathComponent): \(error)")
            }
            let controller = try await Fixture.readPreview(of: url)
            XCTAssertFalse(controller.readPreviewLoaded, url.lastPathComponent)
            XCTAssertEqual(controller.readPreviewPlaceholder.stringValue, Fixture.extractFailureText)
        }
    }
}
