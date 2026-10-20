// ViewerFigureOmissionTests.swift - The scene lists what its tracks left out
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ViewerFigureOmissionTests: XCTestCase {

    private struct OmittingTrack: ViewerFigureTrackBuilding {
        let height = 10.0
        let omissions: [ViewerFigureOmission]

        func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
            canvas.fill(area, ViewerFigurePaint(.separator))
            for omission in omissions {
                canvas.omit(omission)
            }
        }
    }

    private let rowCap = ViewerFigureOmission(trackID: "reads", kind: .readRowCap, reason: "max 75 rows", count: 12)
    private let sample = ViewerFigureOmission(trackID: "reads", kind: .readSample, reason: "splitmix64 seed 0", count: 900)
    private let limit = ViewerFigureOmission(
        trackID: "genes", kind: .annotationLimit, reason: "query limit 50000", count: nil
    )
    private let labels = ViewerFigureOmission(trackID: "genes", kind: .labelsOmitted, reason: "no room", count: 3)

    private func scene(omissions: [ViewerFigureOmission]) -> ViewerFigureScene {
        ViewerFigureScene(
            width: 10, height: 10, appearance: .light, background: ViewerFigurePaint(.textBackground),
            frame: nil, fonts: [], items: [], omissions: omissions
        )
    }

    func testSceneEncodesItsOmissionsSorted() throws {
        let built = scene(omissions: [sample, labels, rowCap, limit])
        XCTAssertEqual(built.omissions, [limit, labels, rowCap, sample])
        XCTAssertEqual(built.formatVersion, 1)

        let json = try XCTUnwrap(String(data: try built.goldenJSON(), encoding: .utf8))
        let order = ["\"annotationLimit\"", "\"labelsOmitted\"", "\"readRowCap\"", "\"readSample\""]
        let offsets = try order.map { try XCTUnwrap(json.range(of: $0)?.lowerBound, $0) }
        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertTrue(json.contains("\"trackID\" : \"genes\""))

        let decoded = try JSONDecoder().decode(ViewerFigureScene.self, from: try built.goldenJSON())
        XCTAssertEqual(decoded, built)
    }

    func testASceneThatLeftNothingOutEncodesAnEmptyList() throws {
        let json = try XCTUnwrap(String(data: try scene(omissions: []).goldenJSON(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"omissions\" : [\n\n  ]") || json.contains("\"omissions\" : []"), json)
    }

    func testTheBuilderCarriesEachTracksOmissionsIntoTheScene() async throws {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: 100, pixelWidth: 100)
        let built = try await ViewerFigureSceneBuilder.build(
            frame: frame, appearance: .dark,
            tracks: [OmittingTrack(omissions: [sample, rowCap]), OmittingTrack(omissions: [labels])]
        )
        XCTAssertEqual(built.omissions, [labels, rowCap, sample])
        XCTAssertEqual(built.items.count, 2)
    }

    func testOmissionsOrderByTrackThenKindThenReasonThenCount() {
        let unknown = ViewerFigureOmission(trackID: "reads", kind: .readRowCap, reason: "max 75 rows", count: nil)
        let more = ViewerFigureOmission(trackID: "reads", kind: .readRowCap, reason: "max 75 rows", count: 40)
        XCTAssertEqual([more, rowCap, unknown, sample].sorted(), [unknown, rowCap, more, sample])
    }
}
