import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class AssemblyContigCatalogTests: XCTestCase {
    func testRecordsRankByLengthAndReportGCAndShare() async throws {
        let catalog = try await makeFixtureCatalog()

        let records = try await catalog.records()

        XCTAssertEqual(records.map(\.rank), [1, 2, 3])
        XCTAssertEqual(records.map(\.name), ["alpha", "beta", "gamma"])
        XCTAssertEqual(records[0].header, "alpha long header")
        XCTAssertEqual(records[0].lengthBP, 8)
        XCTAssertEqual(records[0].gcPercent, 50.0, accuracy: 0.001)
        XCTAssertEqual(records[0].shareOfAssemblyPercent, 44.444444, accuracy: 0.001)
        XCTAssertEqual(records[1].gcPercent, 50.0, accuracy: 0.001)
        XCTAssertEqual(records[1].shareOfAssemblyPercent, 33.333333, accuracy: 0.001)
        XCTAssertEqual(records[2].gcPercent, 0.0, accuracy: 0.001)
        XCTAssertEqual(records[2].shareOfAssemblyPercent, 22.222222, accuracy: 0.001)
    }

    func testSequenceFASTAUsesIndexedLookupAndPreservesFullHeader() async throws {
        let catalog = try await makeFixtureCatalog()

        let fasta = try await catalog.sequenceFASTA(for: "beta", lineWidth: 4)

        XCTAssertEqual(fasta, ">beta middle header\nACGT\nAC\n")
    }

    func testSequenceFASTAPreservesTrailingSpacesInHeader() async throws {
        let catalog = try await makeFixtureCatalog(contigs: [
            ("spacey header   ", "ATGC"),
        ])

        let fasta = try await catalog.sequenceFASTA(for: "spacey", lineWidth: 8)

        XCTAssertEqual(fasta, ">spacey header   \nATGC\n")
    }

    func testTabDelimitedHeaderSupportsTabTruncatedIndexNamesAndPreservesFullHeader() async throws {
        let catalog = try await makeFixtureCatalog(
            contigs: [
                ("tabbed\tfull header", "ACGTACGT"),
                ("plain header", "ATAT"),
            ],
            indexNameTransform: { header in
                String(header.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "")
            }
        )

        let records = try await catalog.records()
        let fasta = try await catalog.sequenceFASTA(for: "tabbed", lineWidth: 8)

        XCTAssertEqual(records.map(\.name), ["tabbed", "plain"])
        XCTAssertEqual(records[0].header, "tabbed\tfull header")
        XCTAssertEqual(fasta, ">tabbed\tfull header\nACGTACGT\n")
    }

    func testSelectionSummaryUsesLengthWeightedGC() async throws {
        let catalog = try await makeFixtureCatalog()

        let summary = try await catalog.selectionSummary(for: ["alpha", "gamma"])

        XCTAssertEqual(summary.selectedContigCount, 2)
        XCTAssertEqual(summary.totalSelectedBP, 12)
        XCTAssertEqual(summary.longestContigBP, 8)
        XCTAssertEqual(summary.shortestContigBP, 4)
        XCTAssertEqual(summary.lengthWeightedGCPercent, 33.333333, accuracy: 0.001)
    }

    func testSelectionSummaryUsesContigLengthsForAmbiguityCodes() async throws {
        let catalog = try await makeFixtureCatalog(contigs: [
            ("alpha long header", "GGGGAAAA"),
            ("beta middle header", "ACGTAC"),
            ("gamma short header", "ATAT"),
            ("delta ambiguity header", "RYSW"),
        ])

        let summary = try await catalog.selectionSummary(for: ["gamma", "delta"])

        XCTAssertEqual(summary.selectedContigCount, 2)
        XCTAssertEqual(summary.totalSelectedBP, 8)
        XCTAssertEqual(summary.longestContigBP, 4)
        XCTAssertEqual(summary.shortestContigBP, 4)
        XCTAssertEqual(summary.lengthWeightedGCPercent, 0.0, accuracy: 0.001)
    }

    func testParseHeadersPreservesPrimaryMappingWhenTabCompatibilityAliasCollides() throws {
        let fastaURL = try writeFixtureFASTA([
            ("foo real description", "AAAAA"),
            ("foo\talt description", "CCCC"),
        ])

        let headersByName = try AssemblyContigCatalog.parseHeaders(from: fastaURL)

        XCTAssertEqual(headersByName["foo"], "foo real description")
        XCTAssertEqual(headersByName["foo\talt"], "foo\talt description")
    }

    func testParseHeadersAllowsUTF8HeaderSplitAcrossReadBufferBoundary() throws {
        let padding = String(repeating: "a", count: (256 * 1024) - 2)
        let splitHeader = padding + "é-split-header"
        let fastaURL = try writeFixtureFASTA([
            (splitHeader, "ATGC"),
        ])

        let headersByName = try AssemblyContigCatalog.parseHeaders(from: fastaURL)

        XCTAssertEqual(headersByName[splitHeader], splitHeader)
    }

    func testInitThrowsRecoverableErrorForDuplicateIndexNames() async throws {
        let result = try makeFixtureAssemblyResult(
            contigs: [
                ("alpha primary", "AAAA"),
                ("beta secondary", "CCCC"),
            ],
            indexNameTransform: { _ in "duplicate" }
        )

        do {
            _ = try await AssemblyContigCatalog(result: result)
            XCTFail("Expected duplicate index names to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Duplicate contig name in FASTA index: duplicate"))
        }
    }

    func testZeroLengthContigBuildsRecordAndFormatsEmptyFASTA() async throws {
        let catalog = try await makeFixtureCatalog(
            contigs: [
                ("empty header", ""),
                ("beta middle header", "ACGT"),
            ],
            indexNameTransform: { header in
                String(header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
            }
        )

        let records = try await catalog.records()
        let fasta = try await catalog.sequenceFASTA(for: "empty", lineWidth: 8)
        let emptyRecord = try XCTUnwrap(records.last)

        XCTAssertEqual(records.map(\.name), ["beta", "empty"])
        XCTAssertEqual(emptyRecord.lengthBP, 0)
        XCTAssertEqual(emptyRecord.gcPercent, 0.0, accuracy: 0.001)
        XCTAssertEqual(fasta, ">empty header\n")
    }

    private func makeFixtureCatalog() async throws -> AssemblyContigCatalog {
        let result = try makeFixtureAssemblyResult()
        return try await AssemblyContigCatalog(result: result)
    }

    private func makeFixtureCatalog(contigs: [(String, String)]) async throws -> AssemblyContigCatalog {
        let result = try makeFixtureAssemblyResult(contigs: contigs)
        return try await AssemblyContigCatalog(result: result)
    }

    private func makeFixtureCatalog(
        contigs: [(String, String)],
        indexNameTransform: @escaping (String) -> String
    ) async throws -> AssemblyContigCatalog {
        let result = try makeFixtureAssemblyResult(contigs: contigs, indexNameTransform: indexNameTransform)
        return try await AssemblyContigCatalog(result: result)
    }

    private func makeFixtureAssemblyResult() throws -> AssemblyResult {
        try makeFixtureAssemblyResult(contigs: [
            ("alpha long header", "GGGGAAAA"),
            ("beta middle header", "ACGTAC"),
            ("gamma short header", "ATAT"),
        ])
    }

    private func makeFixtureAssemblyResult(contigs: [(String, String)]) throws -> AssemblyResult {
        try makeFixtureAssemblyResult(contigs: contigs, indexNameTransform: nil)
    }

    private func makeFixtureAssemblyResult(
        contigs: [(String, String)],
        indexNameTransform: ((String) -> String)?
    ) throws -> AssemblyResult {
        let contigsURL = try writeFixtureFASTA(contigs)
        let tempDir = contigsURL.deletingLastPathComponent()
        if let indexNameTransform {
            try writeFASTAIndex(contigs, to: contigsURL.appendingPathExtension("fai"), lineWidth: 4, nameTransform: indexNameTransform)
        } else {
            try FASTAIndexBuilder.buildAndWrite(for: contigsURL)
        }

        let statistics = try AssemblyStatisticsCalculator.compute(from: contigsURL)

        return AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "test",
            commandLine: "spades.py --isolate",
            outputDirectory: tempDir,
            statistics: statistics,
            wallTimeSeconds: 1.0
        )
    }

    private func writeFixtureFASTA(_ records: [(String, String)]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssemblyContigCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let contigsURL = tempDir.appendingPathComponent("contigs.fasta")
        try writeFASTA(records, to: contigsURL, lineWidth: 4)
        return contigsURL
    }

    private func writeFASTA(_ records: [(String, String)], to url: URL, lineWidth: Int) throws {
        var output = ""
        for (header, sequence) in records {
            output += ">\(header)\n"
            if lineWidth <= 0 {
                output += sequence + "\n"
                continue
            }

            var index = sequence.startIndex
            while index < sequence.endIndex {
                let endIndex = sequence.index(index, offsetBy: lineWidth, limitedBy: sequence.endIndex) ?? sequence.endIndex
                output += String(sequence[index..<endIndex]) + "\n"
                index = endIndex
            }
        }

        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeFASTAIndex(
        _ records: [(String, String)],
        to url: URL,
        lineWidth: Int,
        nameTransform: (String) -> String
    ) throws {
        var offset = 0
        var lines: [String] = []

        for (header, sequence) in records {
            let headerLine = ">\(header)\n"
            offset += headerLine.utf8.count

            let entryOffset = offset
            let sequenceLines = wrappedSequenceLines(sequence, lineWidth: lineWidth)
            let lineBases = sequenceLines.first?.count ?? 0
            let lineWidthWithNewline = lineBases + 1

            lines.append("\(nameTransform(header))\t\(sequence.count)\t\(entryOffset)\t\(lineBases)\t\(lineWidthWithNewline)")

            for line in sequenceLines {
                offset += line.utf8.count + 1
            }
        }

        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func wrappedSequenceLines(_ sequence: String, lineWidth: Int) -> [String] {
        guard lineWidth > 0 else { return [sequence] }

        var lines: [String] = []
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let endIndex = sequence.index(index, offsetBy: lineWidth, limitedBy: sequence.endIndex) ?? sequence.endIndex
            lines.append(String(sequence[index..<endIndex]))
            index = endIndex
        }
        return lines
    }

}
