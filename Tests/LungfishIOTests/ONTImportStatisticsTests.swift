// ONTImportStatisticsTests.swift - An ONT import stores the statistics it measured and takes the run folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Phase 3.0 lane ONT, from the GUI walk of 2026-10-26. Every ONT bundle showed a base count of compressed bytes
/// times 1.5 and stored 0 for every other statistic (BIO WF-8, S1). The ONT Run Folder card refused the run folder
/// MinKNOW writes (UX WF-7, S2), and the manifest said no read was left out when 204 were (BIO WO-10). The fixture is
/// the walk's staged run folder, and `Tests/Fixtures/README.md` gives its `seqkit stats -a` numbers.
final class ONTImportStatisticsTests: XCTestCase {
    private static let runFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ont/nrg1-run", isDirectory: true)
    private static let fastqPass = runFolder.appendingPathComponent("fastq_pass", isDirectory: true)
    private static let barcodeBundles = ["barcode85", "barcode86", "barcode87", "barcode89", "barcode90", "barcode91"]
        .map { "\($0).\(FASTQBundle.directoryExtension)" }

    private func makeFolder() throws -> URL {
        let folder = try TestTempDirectory.make(prefix: "ont-import-statistics")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        return folder
    }

    private func importFixture(
        _ mode: ONTImportStorageMode,
        from source: URL = ONTImportStatisticsTests.fastqPass
    ) async throws -> (result: ONTImportResult, output: URL) {
        let output = try makeFolder().appendingPathComponent("Imports", isDirectory: true)
        let result = try await ONTDirectoryImporter().importDirectory(
            config: ONTImportConfig(sourceDirectory: source, outputDirectory: output, storageMode: mode),
            progress: { _, _ in }
        )
        return (result, output)
    }

    /// barcode85 by `seqkit stats -a`: 500 + 500 reads, 864,096 + 871,077 bases, min 148, max 3,994, median 1,861,
    /// N50 1,864, GC 48.86% and 48.88%. Every quality is `!`, so the mean quality is a measured 0.
    private func assertBarcode85(
        _ statistics: FASTQDatasetStatistics?,
        _ route: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let s = statistics else {
            return XCTFail("\(route) stores no statistics", file: file, line: line)
        }
        XCTAssertEqual(s.readCount, 1_000, route, file: file, line: line)
        XCTAssertEqual(s.baseCount, 1_735_173, "\(route) base count", file: file, line: line)
        XCTAssertEqual(s.meanReadLength, 1_735.173, accuracy: 0.001, "\(route) mean length", file: file, line: line)
        XCTAssertEqual(s.minReadLength, 148, "\(route) min", file: file, line: line)
        XCTAssertEqual(s.maxReadLength, 3_994, "\(route) max", file: file, line: line)
        XCTAssertEqual(s.medianReadLength, 1_861, "\(route) median", file: file, line: line)
        XCTAssertEqual(s.n50ReadLength, 1_864, "\(route) N50", file: file, line: line)
        XCTAssertEqual(s.gcContent, 0.4887, accuracy: 0.0005, "\(route) GC", file: file, line: line)
        XCTAssertEqual(s.meanQuality, 0, accuracy: 0.05, "\(route) mean Q of Q0 bases", file: file, line: line)
        XCTAssertEqual(s.q20Percentage, 0, "\(route) Q20", file: file, line: line)
        XCTAssertEqual(s.readLengthHistogram.values.reduce(0, +), 1_000, "\(route) length histogram", file: file, line: line)
        XCTAssertEqual(s.qualityScoreHistogram[0], 1_735_173, "\(route) quality histogram", file: file, line: line)
    }

    /// No stored statistics may count reads and give them no length (BIO WF-8).
    private func assertMeasured(
        _ statistics: FASTQDatasetStatistics?,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let s = statistics, s.readCount > 0 else { return }
        XCTAssertGreaterThan(
            s.maxReadLength, 0, "\(label) holds \(s.readCount) reads with a longest read of 0", file: file, line: line
        )
        XCTAssertGreaterThan(s.minReadLength, 0, "\(label) min", file: file, line: line)
        XCTAssertGreaterThan(s.n50ReadLength, 0, "\(label) N50", file: file, line: line)
    }

    // MARK: - WF-8, measured statistics

    func testTheConcatenatingRouteStoresBarcode85sMeasuredStatistics() async throws {
        let (result, output) = try await importFixture(.flattened)
        let bundle = output.appendingPathComponent("barcode85.\(FASTQBundle.directoryExtension)", isDirectory: true)
        assertBarcode85(FASTQMetadataStore.load(for: bundle)?.computedStatistics, "flattened bundle sidecar")
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        assertBarcode85(FASTQMetadataStore.load(for: payload)?.computedStatistics, "flattened payload sidecar")
        let row = try XCTUnwrap(result.manifest.barcodes.first { $0.barcodeID == "barcode85" })
        XCTAssertEqual(row.readCount, 1_000)
        XCTAssertEqual(row.baseCount, 1_735_173, "the manifest's base count is counted, not estimated")
    }

    func testTheVirtualRouteStoresBarcode85sMeasuredStatistics() async throws {
        let (result, output) = try await importFixture(.chunked)
        let bundle = output.appendingPathComponent("barcode85.\(FASTQBundle.directoryExtension)", isDirectory: true)
        assertBarcode85(FASTQMetadataStore.load(for: bundle)?.computedStatistics, "chunked bundle sidecar")
        let row = try XCTUnwrap(result.manifest.barcodes.first { $0.barcodeID == "barcode85" })
        XCTAssertEqual(row.readCount, 1_000)
        XCTAssertEqual(row.baseCount, 1_735_173, "the manifest's base count is counted, not estimated")
    }

    /// Every sidecar an import writes, the manifest's display fallback and the FASTA bridge store only what they
    /// measured. A route that knows only counts leaves the statistics unset.
    func testNoStoredStatisticsCountReadsWithoutMeasuringThem() async throws {
        let suffix = ".lungfish-meta.json"
        for mode in ONTImportStorageMode.allCases {
            let (result, output) = try await importFixture(mode)
            let sidecars = try FileManager.default.subpathsOfDirectory(atPath: output.path).filter { $0.hasSuffix(suffix) }
            XCTAssertGreaterThanOrEqual(sidecars.count, 6, "\(mode) writes a sidecar per bundle")
            for path in sidecars {
                let described = output.appendingPathComponent(String(path.dropLast(suffix.count)))
                assertMeasured(FASTQMetadataStore.load(for: described)?.computedStatistics, "\(mode) \(path)")
            }
            for bundle in result.bundleURLs {
                assertMeasured(
                    DemultiplexManifest.cachedFASTQMetadata(forBundle: bundle)?.computedStatistics,
                    "\(mode) manifest fallback for \(bundle.lastPathComponent)"
                )
            }
        }

        let fastq = try makeFolder().appendingPathComponent("reads.fastq")
        try "@r1\nACGTAC\n+\nIIIIII\n@r2\nACG\n+\nIII\n".write(to: fastq, atomically: true, encoding: .utf8)
        let bridged = try await SyntheticFASTQBridge.placeholderStatistics(fromFASTQ: fastq)
        assertMeasured(bridged, "the FASTA bridge")
        XCTAssertEqual(bridged.maxReadLength, 6)
        XCTAssertEqual(bridged.minReadLength, 3)
    }

    // MARK: - WF-8, the file shapes the parser reads

    /// A FASTQ of `reads` records, each `ACGTACGT` over `IIIIIIII`.
    private func fastq(reads: Int, newline: String = "\n", finalNewline: Bool = true) -> String {
        var text = (0..<reads).map { "@read\($0) runid=abc\(newline)ACGTACGT\(newline)+\(newline)IIIIIIII" }
            .joined(separator: newline)
        if finalNewline && reads > 0 { text += newline }
        return text
    }

    /// A file the parser cannot read ends the measure with an error. The line counter this parse replaced gave such a
    /// file a count of 0 and went on (`ONTReadCountPinTests`).
    private func assertMeasuringThrows(
        _ file: URL,
        _ label: String,
        testFile: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let counted = try await ONTDirectoryImporter.measureStatistics(of: [file])
            XCTFail("\(label) gave a count of \(counted.readCount) reads where it must throw", file: testFile, line: line)
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty, label, file: testFile, line: line)
        }
    }

    /// The shapes the retired line counter was pinned on, now for the parser. One shape differs from the base on
    /// purpose. A chunk with no final newline counted one read short at the base (3 reads gave 2).
    func testMeasuringCountsEveryReadWhateverTheFileShape() async throws {
        let folder = try makeFolder()
        func write(_ text: String, _ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }

        var plainFiles: [URL] = []
        var gzipFiles: [URL] = []
        for (index, reads) in [10, 20, 30].enumerated() {
            let text = fastq(reads: reads)
            plainFiles.append(try write(text, "plain_\(index).fastq"))
            gzipFiles.append(try GzipPinSupport.gzip(text, in: folder, named: "gzip_\(index).fastq"))
        }
        for (label, files) in [("plain", plainFiles), ("gzip", gzipFiles)] {
            let total = try await ONTDirectoryImporter.measureStatistics(of: files)
            XCTAssertEqual(total.readCount, 60, "\(label) folder")
            XCTAssertEqual(total.baseCount, 480, "\(label) folder")
            for (file, reads) in zip(files, [10, 20, 30]) {
                let one = try await ONTDirectoryImporter.measureStatistics(of: [file])
                XCTAssertEqual(one.readCount, reads, "\(label) \(file.lastPathComponent)")
            }
        }

        let crlf = try await ONTDirectoryImporter.measureStatistics(
            of: [try write(fastq(reads: 3, newline: "\r\n"), "crlf.fastq")]
        )
        XCTAssertEqual(crlf.readCount, 3, "CRLF line ends")
        XCTAssertEqual(crlf.baseCount, 24, "a CRLF file counts no carriage return as a base")

        let noFinalNewline = try await ONTDirectoryImporter.measureStatistics(
            of: [try write(fastq(reads: 3, finalNewline: false), "no-final-newline.fastq")]
        )
        XCTAssertEqual(noFinalNewline.readCount, 3, "no final newline, 2 at the base")

        let empty = try await ONTDirectoryImporter.measureStatistics(of: [try write("", "empty.fastq")])
        XCTAssertEqual(empty.readCount, 0, "empty file")

        let first = try GzipPinSupport.gzip(fastq(reads: 2), in: folder, named: "member-a.fastq")
        let second = try GzipPinSupport.gzip(fastq(reads: 3), in: folder, named: "member-b.fastq")
        let joined = folder.appendingPathComponent("joined.fastq.gz")
        try (Data(contentsOf: first) + Data(contentsOf: second)).write(to: joined)
        let members = try await ONTDirectoryImporter.measureStatistics(of: [joined])
        XCTAssertEqual(members.readCount, 5, "two gzip members joined")

        let whole = try GzipPinSupport.gzip(fastq(reads: 1_000), in: folder, named: "whole.fastq")
        let cut = try GzipPinSupport.truncated(whole, removing: 30, as: "cut.fastq.gz")
        await assertMeasuringThrows(cut, "a truncated gzip")
        let notGzip = try write(fastq(reads: 5), "not-gzip.fastq.gz")
        await assertMeasuringThrows(notGzip, "a plain-text file named .fastq.gz")
    }

    // MARK: - WO-10, the reads left out

    func testTheManifestRecordsTheUnclassifiedReadsItLeftOut() async throws {
        let (result, _) = try await importFixture(.chunked)
        XCTAssertEqual(result.bundleURLs.map(\.lastPathComponent), Self.barcodeBundles)
        XCTAssertEqual(result.totalReadCount, 6_000)
        XCTAssertEqual(result.manifest.unassigned.readCount, 204, "the unclassified folder's reads were not imported")
        XCTAssertEqual(result.manifest.unassigned.baseCount, 207_358)
        XCTAssertEqual(result.manifest.unassigned.disposition, .discard)
        XCTAssertEqual(result.manifest.inputReadCount, 6_204, "the run held 6,204 reads")
    }

    // MARK: - WF-7, the run folder

    func testTheRunFolderMinKNOWWritesIsAnONTLayout() throws {
        let layout = try ONTDirectoryImporter().detectLayout(at: Self.runFolder)
        XCTAssertEqual(layout.barcodeDirectories.count, 7, "Found 7 barcode directories.")
        XCTAssertEqual(
            layout.barcodeDirectories.map(\.barcodeName),
            ["barcode85", "barcode86", "barcode87", "barcode89", "barcode90", "barcode91", "unclassified"]
        )
        XCTAssertTrue(layout.hasUnclassified)
        XCTAssertEqual(layout.totalSizeBytes, 990_786, "the sheet reads Total size: 991 KB")
    }

    func testTheRunFolderImportsTheSameSixBundlesAsFastqPass() async throws {
        let (result, _) = try await importFixture(.chunked, from: Self.runFolder)
        XCTAssertEqual(result.bundleURLs.map(\.lastPathComponent), Self.barcodeBundles)
        XCTAssertEqual(result.totalReadCount, 6_000)
    }

    /// The sheet's platform check is handed the folder the person chose. It reads the folder's first chunk, so no
    /// sheet says the records could not be read.
    func testThePlatformCheckReadsAnONTFolderThroughItsFirstChunk() {
        let barcode85 = Self.fastqPass.appendingPathComponent("barcode85", isDirectory: true)
        for folder in [Self.runFolder, Self.fastqPass, barcode85] {
            let inference = PlatformInference.infer(fromFASTQ: folder)
            XCTAssertFalse(
                inference.evidence.contains("No complete FASTQ records could be read."),
                "\(folder.lastPathComponent): \(inference.evidence)"
            )
            XCTAssertGreaterThan(inference.sampledRecords, 0, folder.lastPathComponent)
        }
    }

    func testAFolderWithNoONTLayoutIsRefusedWithWordsThatSayWhatToChoose() throws {
        let root = try makeFolder()
        let empty = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try "not reads".write(to: empty.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let illumina = root.appendingPathComponent("illumina-reads", isDirectory: true)
        try FileManager.default.createDirectory(at: illumina, withIntermediateDirectories: true)
        let record = "@M00123:45:000000000-ABCDE:1:1101:15589:1331 1:N:0:1\nACGTACGTAC\n+\nIIIIIIIIII\n"
        try String(repeating: record, count: 8)
            .write(to: illumina.appendingPathComponent("sample_R1.fastq"), atomically: true, encoding: .utf8)

        for folder in [empty, illumina] {
            XCTAssertThrowsError(try ONTDirectoryImporter().detectLayout(at: folder), folder.lastPathComponent) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "'\(folder.lastPathComponent)' holds no fastq_pass folder and no barcode folders. "
                        + "Choose the run folder that MinKNOW wrote, its fastq_pass folder or one barcode folder."
                )
            }
        }
    }
}
