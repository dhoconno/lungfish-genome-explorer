// ToolIdentityTests.swift - Wire format and description of the typed tool ids
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class ToolIdentityTests: XCTestCase {
    private struct Wrapper<ID: Codable & Equatable>: Codable, Equatable {
        let id: ID
    }

    func testAnalysisToolIDEncodesAsBareJSONString() throws {
        let data = try JSONEncoder().encode(AnalysisToolID(rawValue: "kraken2"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"kraken2\"")
    }

    func testManagedToolIDEncodesAsBareJSONString() throws {
        let data = try JSONEncoder().encode(ManagedToolID(rawValue: "bbtools"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"bbtools\"")
    }

    func testUnknownIDsDecode() throws {
        let analysis = try JSONDecoder().decode(AnalysisToolID.self, from: Data("\"from-a-newer-build\"".utf8))
        XCTAssertEqual(analysis.rawValue, "from-a-newer-build")
        let managed = try JSONDecoder().decode(ManagedToolID.self, from: Data("\"from-a-newer-lock\"".utf8))
        XCTAssertEqual(managed.rawValue, "from-a-newer-lock")
    }

    func testRoundTripInsideAContainer() throws {
        let analysis = Wrapper(id: AnalysisToolID(rawValue: "ont-genotyping"))
        let analysisData = try JSONEncoder().encode(analysis)
        XCTAssertEqual(String(data: analysisData, encoding: .utf8), "{\"id\":\"ont-genotyping\"}")
        XCTAssertEqual(try JSONDecoder().decode(Wrapper<AnalysisToolID>.self, from: analysisData), analysis)

        let managed = Wrapper(id: ManagedToolID(rawValue: "gatk4"))
        let managedData = try JSONEncoder().encode(managed)
        XCTAssertEqual(try JSONDecoder().decode(Wrapper<ManagedToolID>.self, from: managedData), managed)
    }

    func testDecodingANonStringFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(AnalysisToolID.self, from: Data("{\"rawValue\":\"kraken2\"}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ManagedToolID.self, from: Data("7".utf8)))
    }

    func testDescriptionEqualsRawValueAndInterpolatesAsIt() {
        let analysis = AnalysisToolID(rawValue: "kraken2")
        XCTAssertEqual(analysis.description, "kraken2")
        XCTAssertEqual("\(analysis)-", "kraken2-")
        let managed = ManagedToolID(rawValue: "bbtools")
        XCTAssertEqual(managed.description, "bbtools")
        XCTAssertEqual("\(managed)-batch-", "bbtools-batch-")
    }

    func testEqualityAndHashingFollowTheRawValue() {
        XCTAssertEqual(AnalysisToolID(rawValue: "a"), AnalysisToolID(rawValue: "a"))
        XCTAssertNotEqual(AnalysisToolID(rawValue: "a"), AnalysisToolID(rawValue: "b"))
        XCTAssertEqual(Set([ManagedToolID(rawValue: "x"), ManagedToolID(rawValue: "x")]).count, 1)
    }
}
