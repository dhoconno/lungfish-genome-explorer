// OverlappingReadsExtractionParityTests.swift - Extract Overlapping Reads and its recorded command extract the reads samtools reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The mapping viewport's Extract Overlapping Reads action builds a
// BAMRegionExtractionConfig with one samtools region per annotation block and
// runs ReadExtractionService.extractByBAMRegion. Its Operations row records
// `lungfish-cli extract reads --by-region` for the same configuration (R3).
// Both used to fail. The action passed no index, which the service requires,
// and the service matched whole reference names only, so a coordinate region
// such as `MT192765.1:1-3000` matched nothing. The action and its recorded
// command must now write the reads that `samtools view` reports for the
// regions, each read once, on the SARS-CoV-2 fixture BAM.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class OverlappingReadsExtractionParityTests: XCTestCase {
    private var root: URL!
    private var runDirectory: URL!

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("overlapping-reads-parity-\(UUID().uuidString)", isDirectory: true)
        runDirectory = root.appendingPathComponent("Mapping Run", isDirectory: true)
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: TestFixtures.sarscov2.sortedBam, to: runDirectory.appendingPathComponent("sample.sorted.bam"))
        try fileManager.copyItem(at: TestFixtures.sarscov2.bamIndex, to: runDirectory.appendingPathComponent("sample.sorted.bam.bai"))
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var mappingResult: MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: "short-read-default",
            bamURL: runDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: runDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 197,
            unmappedReads: 3,
            wallClockSeconds: 1,
            contigs: []
        )
    }

    private func samtoolsPath() throws -> String {
        guard let path = SamtoolsLocator.locate() else {
            throw XCTSkip("The managed samtools is not installed.")
        }
        return path
    }

    /// The read names `samtools view` prints for `regions`, sorted. `-M` takes
    /// the union of the regions so a read overlapping two of them is counted
    /// once. `-F 0xD00` drops the duplicate (0x400) records the extraction
    /// leaves out at its view step and the secondary and supplementary
    /// (0x900) records it leaves out when it writes FASTQ.
    private func samtoolsReadNames(regions: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try samtoolsPath())
        process.arguments = ["view", "-M", "-F", "0xD00", mappingResult.bamURL.path] + regions
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "samtools view \(regions)")
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0.split(separator: "\t", maxSplits: 1)[0]) }
            .sorted()
    }

    /// The read names in a FASTQ file without the /1 and /2 mate suffixes
    /// samtools fastq appends, sorted.
    private func fastqReadNames(_ url: URL) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: lines.count - 3, by: 4).map { index in
            var name = String(lines[index].dropFirst().split(separator: " ")[0])
            if name.hasSuffix("/1") || name.hasSuffix("/2") { name.removeLast(2) }
            return name
        }.sorted()
    }

    func testAnnotationActionAndItsRecordedCommandExtractTheReadsSamtoolsReports() async throws {
        _ = try samtoolsPath()
        let annotations: [(name: String, intervals: [AnnotationInterval], regions: [String])] = [
            ("orf1a start", [AnnotationInterval(start: 0, end: 3000)], ["MT192765.1:1-3000"]),
            // One read spans both blocks, so samtools without -M would print it twice.
            ("two blocks", [AnnotationInterval(start: 100, end: 130), AnnotationInterval(start: 200, end: 220)],
             ["MT192765.1:101-130", "MT192765.1:201-220"]),
            ("one base", [AnnotationInterval(start: 14_999, end: 15_000)], ["MT192765.1:15000-15000"]),
        ]

        for annotation in annotations {
            let config = try XCTUnwrap(MappingAnnotationActionCoordinator.extractionConfiguration(
                for: SequenceAnnotation(
                    type: .gene,
                    name: annotation.name,
                    chromosome: "MT192765.1",
                    intervals: annotation.intervals
                ),
                mappingResult: mappingResult,
                outputDirectory: runDirectory.appendingPathComponent("annotation-extractions", isDirectory: true)
            ))
            XCTAssertEqual(config.regions, annotation.regions)
            let expected = try samtoolsReadNames(regions: annotation.regions)
            XCTAssertFalse(expected.isEmpty, "the fixture has reads in \(annotation.regions)")

            // The action's run, as ViewerViewController.overlappingReadsExtractionRunner makes it.
            let appResult = try await ReadExtractionService().extractByBAMRegion(config: config)
            let appOutput = try XCTUnwrap(appResult.fastqURLs.first)
            let appReads = try fastqReadNames(appOutput)
            XCTAssertEqual(appReads, expected, "\(annotation.name): the action's reads")
            XCTAssertEqual(appResult.readCount, expected.count)
            try FileManager.default.removeItem(at: appOutput)

            // The command the Operations row records, run as the shipped binary parses it.
            let recorded = ViewerViewController.overlappingReadsExtractionCLICommand(config: config)
            let words = try AdvancedCommandLineOptions.parse(recorded)
            XCTAssertEqual(words.first, CLICommandIdentity.executableName)
            let parsed = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(Array(words.dropFirst())))
            let command = try XCTUnwrap(parsed as? ExtractReadsSubcommand)
            try await command.run()
            XCTAssertEqual(try fastqReadNames(URL(fileURLWithPath: command.output)), expected, "\(annotation.name): the command's reads")
            XCTAssertEqual(URL(fileURLWithPath: command.output).standardizedFileURL, appOutput.standardizedFileURL)
        }
    }
}
