// SequenceAnnotationProvenanceClockStepTests.swift - Annotation edits survive a wall-clock step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// A stress run on 2026-10-07 stepped the wall clock back 63 ms while a
/// Delete Annotation ran. The workflow stamped its start and end with two
/// `Date()` calls, so the end came before the start and
/// `ProvenanceRunBuilder.complete` failed an edit that had succeeded.
final class SequenceAnnotationProvenanceClockStepTests: XCTestCase {
    private let wallClockStart = Date(timeIntervalSince1970: 1_791_331_200)
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try TestTempDirectory.make(prefix: "annotation-clock-step")
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            TestTempDirectory.cleanup(tempDirectory)
        }
        tempDirectory = nil
    }

    func testDeleteAnnotationsSucceedsWhenTheWallClockStepsBackDuringTheRun() async throws {
        let bundleURL = try await makeBundleWithTwoORFs()
        let rowID = try XCTUnwrap(try firstRowID(bundleURL: bundleURL))
        let time = SteppedTimeSource(startingAt: wallClockStart)
        time.stepWallClockAfterNextRead(by: -0.063)

        let result = try await time.override {
            try await SequenceAnnotationTrackWorkflow.deleteAnnotations(.init(
                bundleURL: bundleURL,
                trackID: "orfs_chr1",
                rowIDs: [rowID],
                command: ["lungfish", "sequence", "delete-annotations", bundleURL.path],
                explicitOptions: [:],
                defaultOptions: [:],
                resolvedOptions: [:],
                toolVersion: "test"
            ))
        }

        XCTAssertEqual(result.deletedCount, 1)
        try assertRunTimesStartAtTheWallClockAndTakeNoTime(result.provenanceURL)
    }

    func testUpdateAnnotationSucceedsWhenTheWallClockStepsBackDuringTheRun() async throws {
        let bundleURL = try await makeBundleWithTwoORFs()
        let rowID = try XCTUnwrap(try firstRowID(bundleURL: bundleURL))
        let time = SteppedTimeSource(startingAt: wallClockStart)
        time.stepWallClockAfterNextRead(by: -0.063)

        let result = try await time.override {
            try await SequenceAnnotationTrackWorkflow.updateAnnotation(.init(
                bundleURL: bundleURL,
                trackID: "orfs_chr1",
                rowID: rowID,
                name: "renamed",
                type: "ORF",
                strand: "+",
                note: nil,
                command: ["lungfish", "sequence", "update-annotation", bundleURL.path],
                explicitOptions: [:],
                defaultOptions: [:],
                resolvedOptions: [:],
                toolVersion: "test"
            ))
        }

        XCTAssertEqual(result.rowID, rowID)
        try assertRunTimesStartAtTheWallClockAndTakeNoTime(result.provenanceURL)
    }

    /// No time passed on the monotonic clock, so the run takes no time and
    /// starts and ends at the wall-clock reading taken when it began.
    private func assertRunTimesStartAtTheWallClockAndTakeNoTime(
        _ provenanceURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL), file: file, line: line)
        XCTAssertEqual(envelope.createdAt, wallClockStart, file: file, line: line)
        XCTAssertEqual(envelope.wallTimeSeconds, 0, file: file, line: line)
        let step = try XCTUnwrap(envelope.steps.first, file: file, line: line)
        XCTAssertEqual(step.startedAt, wallClockStart, file: file, line: line)
        XCTAssertEqual(step.completedAt, wallClockStart, file: file, line: line)
        XCTAssertEqual(step.wallTimeSeconds, 0, file: file, line: line)
    }

    private func firstRowID(bundleURL: URL) throws -> Int64? {
        let databaseURL = bundleURL.appendingPathComponent("annotations/orfs_chr1.db")
        return try AnnotationDatabase(url: databaseURL).query(types: ["ORF"], limit: 10).first?.rowID
    }

    /// A one-chromosome bundle whose ORF track holds two rows.
    private func makeBundleWithTwoORFs() async throws -> URL {
        let sequence = "ATGTAAATGTAA"
        let bundleURL = tempDirectory.appendingPathComponent("tiny.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try ">chr1\n\(sequence)\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        let offset = ">chr1\n".utf8.count
        try "chr1\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )
        try BundleManifest(
            formatVersion: "1.0",
            name: "Tiny Reference",
            identifier: "org.lungfish.tests.tiny",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: Int64(sequence.count),
                        offset: Int64(offset),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    )
                ]
            )
        ).save(to: bundleURL)

        let created = try await SequenceAnnotationTrackWorkflow.run(.init(
            bundleURL: bundleURL,
            sequenceName: "chr1",
            start: 0,
            end: sequence.count,
            frames: [.plus1],
            tableID: 1,
            trackID: "orfs_chr1",
            trackName: "ORFs chr1",
            kind: .orf(minLength: 6, includePartial: false, allowAlternativeStarts: false),
            command: ["lungfish", "sequence", "annotate-orfs", bundleURL.path],
            explicitOptions: [:],
            defaultOptions: [:],
            resolvedOptions: [:],
            toolVersion: "test"
        ))
        XCTAssertEqual(created.featureCount, 2)
        return bundleURL
    }
}
