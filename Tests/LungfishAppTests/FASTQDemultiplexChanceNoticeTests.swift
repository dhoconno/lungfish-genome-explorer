// FASTQDemultiplexChanceNoticeTests.swift - The words of a demultiplex run's Operations row about chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane EXACTBARE-WORDS. A finished demultiplex in the app shows no line of the command line's summary,
// since `fastq demultiplex` has no event channel (ruling UX-EXACT-BARE-WORDS), so the row needs its own words.
// DEMUX-EXACT-BARE-NO-FLOOR: Exact Bare Barcode checks no chance matches and says so when it made a sample file.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

final class FASTQDemultiplexChanceNoticeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chance-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A manifest in the run's folder, one barcode for each read count.
    private func writeManifest(readCounts: [Int]) throws {
        let barcodes = readCounts.enumerated().map { index, count in
            BarcodeResult(
                barcodeID: "S\(index + 1)", sampleName: "Sample\(index + 1)", readCount: count, baseCount: Int64(count * 150),
                bundleRelativePath: "S\(index + 1).lungfishfastq"
            )
        }
        try DemultiplexManifest(
            barcodeKit: BarcodeKit(name: "custom", vendor: "custom", barcodeCount: readCounts.count),
            parameters: DemultiplexParameters(tool: "exact-bare", maxMismatches: 0),
            barcodes: barcodes,
            unassigned: UnassignedReadsSummary(readCount: 200, baseCount: 30_000),
            outputDirectoryRelativePath: "demux/",
            inputReadCount: 200 + readCounts.reduce(0, +)
        ).save(to: folder)
    }

    private func result(engine: DemultiplexEngine) -> FASTQOperationExecutionResult {
        FASTQOperationExecutionResult(
            resolvedRequest: .derivative(
                request: .demultiplex(
                    kitID: "custom", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: engine,
                    trimBarcodes: false, sampleAssignments: nil, kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .groupedResult
            ),
            executedInvocations: [],
            importedURLs: [folder],
            groupedContainerURL: folder
        )
    }

    func testExactBareRunThatMadeASampleFileGetsTheWords() throws {
        try writeManifest(readCounts: [5])

        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .exactBareBarcode)),
            DemultiplexEngine.exactBareChanceWords
        )
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.rowDetail("Done in 12.3s"),
            "Not checked for chance matches. Done in 12.3s"
        )
    }

    func testNoWordsWithNoSampleFileOrAnotherEngine() throws {
        try writeManifest(readCounts: [0, 0])
        XCTAssertNil(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .exactBareBarcode)),
            "a run that made no sample file has no sample file to warn about"
        )

        try writeManifest(readCounts: [5])
        XCTAssertNil(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .cutadapt)),
            "a Cutadapt run has its chance floor and its own line"
        )
        XCTAssertNil(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .headerIndex)),
            "the split by read names is not this row"
        )
    }

    func testExactBareRunWhoseManifestCannotBeReadStillGetsTheWords() {
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .exactBareBarcode)),
            DemultiplexEngine.exactBareChanceWords,
            "with no manifest to read the run may have made sample files, so the words stay on the safe side"
        )
    }

    // MARK: - DEMUX-DUAL-FORM, the run's choice of form (UX-WORDS-2 section 3 (c))

    /// The record of a Cutadapt run in its own folder under the test's folder, with the two fields the command writes for a
    /// Custom Definition of dual indexes at Both Ends with no sample sheet (BIO-DUAL-FORM item 2), and the result of the run.
    private func dualFormResult(
        form: String?, votes: [String: Int], ambiguousReads: Int? = nil, ambiguousReadsEnds: String? = nil
    ) throws -> FASTQOperationExecutionResult {
        let run = folder.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let output = run.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: output, atomically: true, encoding: .utf8)
        var parameters: [String: ParameterValue] = ["engine": .string("cutadapt")]
        if let form {
            parameters["secondaryForm"] = .string(form)
            parameters["secondaryFormVotes"] = .dictionary(votes.mapValues { ParameterValue.integer($0) })
        }
        if let ambiguousReads { parameters["ambiguousReads"] = .integer(ambiguousReads) }
        if let ambiguousReadsEnds { parameters["ambiguousReadsEnds"] = .string(ambiguousReadsEnds) }
        let argv = ["lungfish-cli", "fastq", "demultiplex", "reads.fastq", "--output", run.path]
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq demultiplex", workflowVersion: "2026.11",
            toolName: "lungfish fastq demultiplex", toolVersion: "2026.11"
        )
        .argv(argv)
        .options(explicit: parameters, defaults: [:], resolved: parameters)
        .output(output, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish fastq demultiplex", toolVersion: "2026.11", argv: argv,
                outputs: [try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output)],
                exitStatus: 0, wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity())
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 80), endedAt: Date(timeIntervalSince1970: 81))
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: run)
        return FASTQOperationExecutionResult(
            resolvedRequest: result(engine: .cutadapt).resolvedRequest,
            executedInvocations: [],
            importedURLs: [run],
            groupedContainerURL: run
        )
    }

    /// The run says which way it read the secondary sequence in one line, the same in the row's detail and the Log. The
    /// line is information, so it goes to the Log at `.info` and adds no warning. A run with no such record says nothing.
    @MainActor
    func testTheRunsChoiceOfFormIsAnInformationLineOfTheRowAndItsLog() throws {
        let cases: [(form: String, votes: [String: Int], line: String)] = [
            ("as-written", ["readsRead": 10_000, "asWritten": 412, "reverseComplemented": 0, "disputed": 0, "rowsCarrying": 3],
             "The run read each secondary sequence as written, since 412 of the first 10,000 reads carry it that way."),
            ("reverse-complemented",
             ["readsRead": 10_000, "asWritten": 0, "reverseComplemented": 412, "disputed": 0, "rowsCarrying": 3],
             "The run read each secondary sequence reverse complemented, as the i5 primer's barcode, since 412 of the first "
                + "10,000 reads carry it that way."),
            ("as-written", ["readsRead": 10_000, "asWritten": 2, "reverseComplemented": 1, "disputed": 3, "rowsCarrying": 0],
             "The run read each secondary sequence as written, since too few of the first 10,000 reads carry a barcode pair "
                + "to tell which way it is written."),
        ]
        let center = OperationCenter()
        for (form, votes, line) in cases {
            let words = FASTQDemultiplexChanceNotice.rowWords(for: try dualFormResult(form: form, votes: votes))
            XCTAssertNil(words.notice, line)
            XCTAssertEqual(FASTQDemultiplexChanceNotice.rowDetail(words.notice, words.floorLimitLine, "Done in 12.3s"),
                           line + " Done in 12.3s")
            let id = try XCTUnwrap(center.begin(
                title: "Demultiplex Barcodes", detail: "", operationType: .fastqOperation,
                cliCommand: "lungfish fastq demultiplex"
            ).startedID)
            FASTQDemultiplexChanceNotice.log(words.notice, words.floorLimitLine, id: id, in: center)
            let item = try XCTUnwrap(center.items.first { $0.id == id })
            XCTAssertEqual(item.logEntries.map(\.level), [.info], line)
            XCTAssertEqual(item.logEntries.map(\.message), [line])
            XCTAssertFalse(item.hasWarnings, "the line adds no warning")
            XCTAssertFalse(line.contains("\u{2014}") || line.contains(";") || line.contains(":"), line)
        }
        let none = FASTQDemultiplexChanceNotice.rowWords(for: try dualFormResult(form: nil, votes: [:]))
        XCTAssertNil(none.notice)
        XCTAssertNil(none.floorLimitLine, "a record of any other route has no line")
    }

    // MARK: - DEMUX-DUAL-OFFSET-SHIFT, reads that two rows fit (BIO-OFFSET-SHIFT item 4)

    /// A run with a distance above 0 that sent reads two rows fit to Unassigned says so in the ruling's two sentences, after
    /// the line of the form, in the row's detail and the Log, read from the record's `ambiguousReads`. A count of 0 says
    /// nothing, and the line adds no warning.
    @MainActor
    func testReadsThatTwoRowsFitAreCountedInTheRowAndItsLog() throws {
        let votes = ["readsRead": 480, "asWritten": 0, "reverseComplemented": 412, "disputed": 0, "rowsCarrying": 12]
        let form = "The run read each secondary sequence reverse complemented, as the i5 primer's barcode, since 412 of the "
            + "first 480 reads carry it that way."
        let words = "1,204 reads went to Unassigned because they fit the barcodes of two or more samples equally well within the 5' "
            + "and 3' Distance. Set each distance only as far as your barcodes sit in from the read ends."
        let center = OperationCenter()
        let result = FASTQDemultiplexChanceNotice.rowWords(
            for: try dualFormResult(form: "reverse-complemented", votes: votes, ambiguousReads: 1_204)
        )
        XCTAssertNil(result.notice)
        XCTAssertEqual(FASTQDemultiplexChanceNotice.rowDetail(result.notice, result.floorLimitLine, "Done in 12.3s"),
                       form + " " + words + " Done in 12.3s")
        let id = try XCTUnwrap(center.begin(
            title: "Demultiplex Barcodes", detail: "", operationType: .fastqOperation, cliCommand: "lungfish fastq demultiplex"
        ).startedID)
        FASTQDemultiplexChanceNotice.log(result.notice, result.floorLimitLine, id: id, in: center)
        let item = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(item.logEntries.map(\.message), [form, words])
        XCTAssertEqual(item.logEntries.map(\.level), [.info, .info])
        XCTAssertFalse(item.hasWarnings, "the line adds no warning")
        XCTAssertFalse(words.contains("\u{2014}") || words.contains(";") || words.contains(":"), words)

        let zero = FASTQDemultiplexChanceNotice.rowWords(
            for: try dualFormResult(form: "reverse-complemented", votes: votes, ambiguousReads: 0)
        )
        XCTAssertEqual(zero.floorLimitLine, form, "a count of 0 says nothing")
    }

    /// A count of one reads in the singular and the window finds the line by its marker, whatever the count.
    func testTheLineOfReadsThatTwoRowsFitAgreesWithItsCount() throws {
        let tail = " the barcodes of two or more samples equally well within the 5' and 3' Distance. Set each distance only as far "
            + "as your barcodes sit in from the read ends."
        XCTAssertEqual(DemultiplexingPipeline.ambiguousReadsLine(1), "1 read went to Unassigned because it fits" + tail)
        XCTAssertEqual(DemultiplexingPipeline.ambiguousReadsLine(2), "2 reads went to Unassigned because they fit" + tail)
        XCTAssertNil(DemultiplexingPipeline.ambiguousReadsLine(0))
        let line = "The run read each secondary sequence as written, since 10,000 reads carry it that way. "
            + (DemultiplexingPipeline.ambiguousReadsLine(1) ?? "")
        let start = try XCTUnwrap(FASTQDemultiplexChanceNotice.ambiguousReadsLineStart(in: line))
        XCTAssertTrue(line[start...].hasPrefix("1 read went to Unassigned because it fits"))
    }

    /// The counts of the commands of a run of several inputs make one line, not one for equal counts or two for different ones.
    func testTheCountsOfSeveralInputsMakeOneLine() throws {
        let votes = ["readsRead": 480, "asWritten": 412, "reverseComplemented": 0, "disputed": 0, "rowsCarrying": 12]
        let first = try dualFormResult(form: "as-written", votes: votes, ambiguousReads: 2)
        let second = try dualFormResult(form: "as-written", votes: votes, ambiguousReads: 2)
        let both = FASTQOperationExecutionResult(
            resolvedRequest: first.resolvedRequest, executedInvocations: [],
            importedURLs: first.importedURLs + second.importedURLs, groupedContainerURL: nil
        )
        XCTAssertEqual(FASTQDemultiplexChanceNotice.ambiguousReadsLine(for: both), DemultiplexingPipeline.ambiguousReadsLine(4))
    }

    /// A run whose lines search one end names that end's distance, from the record's `ambiguousReadsEnds`, so the routes of
    /// single-barcode kits reuse the line (UX review of DEMUX-DUAL-OFFSET-SHIFT, ruling 4). A record that names no ends
    /// searched both. Each line keeps the marker the window finds it by, in the singular too.
    @MainActor
    func testTheLineNamesTheDistanceOfTheEndsTheLinesSearched() throws {
        let cases: [(ends: String?, count: Int, line: String)] = [
            (nil, 3, "3 reads went to Unassigned because they fit the barcodes of two or more samples equally well within the "
                + "5' and 3' Distance. Set each distance only as far as your barcodes sit in from the read ends."),
            ("fivePrime", 1_204, "1,204 reads went to Unassigned because they fit the barcodes of two or more samples equally "
                + "well within the 5' Distance. Set the distance only as far as your barcodes sit in from the start of the read."),
            ("threePrime", 1, "1 read went to Unassigned because it fits the barcodes of two or more samples equally well "
                + "within the 3' Distance. Set the distance only as far as your barcodes sit in from the end of the read."),
        ]
        let center = OperationCenter()
        for (ends, count, line) in cases {
            let result = try dualFormResult(form: nil, votes: [:], ambiguousReads: count, ambiguousReadsEnds: ends)
            let words = FASTQDemultiplexChanceNotice.rowWords(for: result)
            XCTAssertEqual(words.floorLimitLine, line)
            XCTAssertEqual(FASTQDemultiplexChanceNotice.rowDetail(words.notice, words.floorLimitLine, "Done in 12.3s"),
                           line + " Done in 12.3s", "no floor prefix in front of the line")
            let id = try XCTUnwrap(center.begin(
                title: "Demultiplex Barcodes", detail: "", operationType: .fastqOperation, cliCommand: "lungfish fastq demultiplex"
            ).startedID)
            FASTQDemultiplexChanceNotice.log(words.notice, words.floorLimitLine, id: id, in: center)
            let item = try XCTUnwrap(center.items.first { $0.id == id })
            XCTAssertEqual(item.logEntries.map(\.message), [line])
            XCTAssertEqual(item.logEntries.map(\.level), [.info])
            XCTAssertFalse(line.contains("\u{2014}") || line.contains(";") || line.contains(":"), line)
        }
    }
}
