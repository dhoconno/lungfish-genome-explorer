// ViewerFigureReadTrackReplayTests.swift - The read track builder over a real BAM through samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// The read track read through `AlignmentDataProvider`, which runs samtools, so the class sits
/// in the integration tier and skips without samtools (fails under `LUNGFISH_REQUIRE_TOOLS=1`).
final class ViewerFigureReadTrackReplayTests: XCTestCase {
    private var bam: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
    }

    private func source() async throws -> (ViewerFigureReadTrack.Source, String) {
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let source = ViewerFigureReadTrack.Source(alignmentPath: bam.path, indexPath: bam.path + ".bai")
        let header = try await AlignmentDataProvider(alignmentPath: source.alignmentPath, indexPath: source.indexPath).fetchHeader()
        let sequenceLine = try XCTUnwrap(header.split(separator: "\n").first { $0.hasPrefix("@SQ") })
        let name = try XCTUnwrap(sequenceLine.split(separator: "\t").first { $0.hasPrefix("SN:") }?.dropFirst(3))
        return (source, String(name))
    }

    private func scene(_ source: ViewerFigureReadTrack.Source, chromosome: String, options: ViewerFigureReadTrack.Options) async throws -> ViewerFigureScene {
        let frame = ViewerFigureFrame(chromosome: chromosome, start: 0, end: 1_000, pixelWidth: 1_000)
        return try await ViewerFigureSceneBuilder.build(
            frame: frame, appearance: .light,
            tracks: [ViewerFigureReadTrack(source: source, height: 300, options: options)]
        )
    }

    func testReadTrackBuildsFromTheBAMWithItsOmissions() async throws {
        let (source, chromosome) = try await source()
        let scene = try await scene(source, chromosome: chromosome, options: .init())
        let bodies = scene.items.filter {
            if case .fill(_, let paint) = $0 { [.forwardRead, .reverseRead].contains(paint.role) } else { false }
        }
        XCTAssertFalse(bodies.isEmpty, "reads from the BAM are drawn")
        XCTAssertTrue(scene.omissions.allSatisfy { $0.trackID == "reads" })
        XCTAssertFalse(scene.omissions.contains { $0.kind == .readSample }, "the fixture holds under 5000 reads in the window")
        print("ViewerFigureReadTrackReplayTests reads drawn \(bodies.count) omissions \(scene.omissions)")
    }

    func testReadTrackFetchesTheContigNamedByTheSourceAliases() async throws {
        let (plain, chromosome) = try await source()
        let aliased = ViewerFigureReadTrack.Source(
            alignmentPath: plain.alignmentPath, indexPath: plain.indexPath, chromosomeAliases: ["reference-name": chromosome]
        )
        let scene = try await scene(aliased, chromosome: "reference-name", options: .init())
        let bodies = scene.items.filter {
            if case .fill(_, let paint) = $0 { [.forwardRead, .reverseRead].contains(paint.role) } else { false }
        }
        XCTAssertFalse(bodies.isEmpty, "the frame names the reference contig and the source maps it to the BAM's")
    }

    func testFigureReadSampleOfTheBAMIsTheSameInTwoRenders() async throws {
        let (source, chromosome) = try await source()
        var options = ViewerFigureReadTrack.Options()
        options.maxReads = 3
        let first = try await scene(source, chromosome: chromosome, options: options)
        let second = try await scene(source, chromosome: chromosome, options: options)
        XCTAssertEqual(try first.goldenJSON(), try second.goldenJSON())
        let sample = try XCTUnwrap(first.omissions.first { $0.kind == .readSample }, "the window holds 7 reads")
        XCTAssertEqual(sample.reason, ViewerFigureReadSample.rule(maxReads: 3))
        XCTAssertGreaterThan(sample.count ?? 0, 0)
        print("ViewerFigureReadTrackReplayTests sample omission \(sample)")
    }
}
