// RouteParityHarnessSigningTests.swift - The signature assertion of the route parity harness on fabricated runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN. `RouteParityHarness.assertNoSignatureLost` (RouteParityHarness+Signing.swift) reads
// records and the two files a signed record adds, so these cases fabricate the three side roots of a run with
// records signed on some sides and not on others, and need no CLI, no key and no tool. The cases that run the
// real routes with a key are each family's `<Family>SigningReplayTests`.

import CryptoKit
import Foundation
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

final class RouteParityHarnessSigningTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "route-parity-signing")
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    private static let bundleRecord = "Fixture.lungfishref/.lungfish-provenance.json"
    private static let innerRecord = "results/inner.lungfish-provenance.json"

    /// The three side roots of a run, each holding the records its dictionary names, signed when its value is true.
    private func fabricate(
        a: [String: Bool], c: [String: Bool], cPrime: [String: Bool], fixture: [String: String] = [:]
    ) throws -> RouteParityRuns {
        let caseRoot = scratch.appendingPathComponent("case-\(UUID().uuidString)", isDirectory: true)
        func side(_ side: RouteParitySide, _ records: [String: Bool]) throws -> RouteParitySideRun {
            let root = RouteParityHarness.root(of: side, in: caseRoot)
            for (name, isSigned) in records {
                let record = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "{\"run\": \(records.count)}".write(to: record, atomically: true, encoding: .utf8)
                guard isSigned else { continue }
                try "{}".write(to: ProvenanceSigningConfiguration.signatureURL(for: record), atomically: true, encoding: .utf8)
                try "key".write(to: ProvenanceSigningConfiguration.publicKeyURL(for: record), atomically: true, encoding: .utf8)
            }
            let outcome = RouteParitySideOutcome(end: .completed)
            return RouteParitySideRun(side: side, root: root, outcome: outcome)
        }
        return RouteParityRuns(
            caseRoot: caseRoot, a: try side(.a, a), c: try side(.c, c), cPrime: try side(.cPrime, cPrime), fixture: fixture
        )
    }

    private static func opening(_ root: URL) -> URL {
        root.appendingPathComponent(bundleRecord)
    }

    func testARunWithEveryRecordSignedOnEverySideLosesNothing() throws {
        let signed = [Self.bundleRecord: true, Self.innerRecord: true]
        let runs = try fabricate(a: signed, c: signed, cPrime: signed)
        XCTAssertEqual(RouteParityHarness.signatureLosses(in: runs, opening: Self.opening), [])
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.opening)
    }

    func testARecordSideASignedAndSideCLeftUnsignedIsALossOnThatSide() throws {
        let signed = [Self.bundleRecord: true, Self.innerRecord: true]
        let unsignedInner = [Self.bundleRecord: true, Self.innerRecord: false]
        let runs = try fabricate(a: signed, c: unsignedInner, cPrime: signed)
        let losses = RouteParityHarness.signatureLosses(in: runs, opening: Self.opening)
        XCTAssertEqual(losses.count, 1, "\(losses)")
        XCTAssertTrue(losses.first?.hasPrefix("side C: ") == true, "\(losses)")
        XCTAssertTrue(losses.first?.contains(Self.innerRecord) == true, "\(losses)")
    }

    func testAnUnsignedRecordOnBothRoutesIsALossOnlyWhenTheResultOpensOnIt() throws {
        let unsigned = [Self.bundleRecord: false, Self.innerRecord: false]
        let runs = try fabricate(a: unsigned, c: unsigned, cPrime: unsigned)
        let losses = RouteParityHarness.signatureLosses(in: runs, opening: Self.opening)
        XCTAssertEqual(losses.count, 2, "one for side C and one for side C': \(losses)")
        XCTAssertTrue(losses.allSatisfy { $0.contains("the record the result opens first") }, "\(losses)")
        XCTAssertTrue(losses.allSatisfy { $0.contains("is unsigned though a key is set") }, "\(losses)")
    }

    func testAnInnerRecordNamedByTheCaseMayStayUnsigned() throws {
        let signed = [Self.bundleRecord: true, Self.innerRecord: true]
        let unsignedInner = [Self.bundleRecord: true, Self.innerRecord: false]
        let runs = try fabricate(a: signed, c: unsignedInner, cPrime: unsignedInner)
        XCTAssertEqual(RouteParityHarness.signatureLosses(in: runs, opening: Self.opening, inner: [Self.innerRecord]), [])
    }

    func testARecordTheOtherSideLacksIsNotASignatureLoss() throws {
        let runs = try fabricate(
            a: [Self.bundleRecord: true, Self.innerRecord: true],
            c: [Self.bundleRecord: true],
            cPrime: [Self.bundleRecord: true]
        )
        XCTAssertEqual(RouteParityHarness.signatureLosses(in: runs, opening: Self.opening), [], "the files differ, which the comparison reports")
    }

    func testTheRecordTheResultOpensFirstMustExistOnSideC() throws {
        let runs = try fabricate(
            a: [Self.bundleRecord: true], c: [Self.innerRecord: true], cPrime: [Self.bundleRecord: true]
        )
        let losses = RouteParityHarness.signatureLosses(in: runs, opening: Self.opening)
        XCTAssertEqual(losses.count, 1, "\(losses)")
        XCTAssertTrue(losses.first?.contains("does not exist") == true, "\(losses)")
    }

    func testARecordTheFixtureHeldAsItIsIsNotNewInTheRun() throws {
        let unsignedInner = [Self.bundleRecord: true, Self.innerRecord: false]
        var runs = try fabricate(a: [Self.bundleRecord: true, Self.innerRecord: true], c: unsignedInner, cPrime: unsignedInner)
        let held = try Data(contentsOf: runs.c.root.appendingPathComponent(Self.innerRecord))
        let digest = SHA256.hash(data: held).map { String(format: "%02x", $0) }.joined()
        runs = RouteParityRuns(caseRoot: runs.caseRoot, a: runs.a, c: runs.c, cPrime: runs.cPrime, fixture: [Self.innerRecord: digest])
        XCTAssertEqual(RouteParityHarness.signatureLosses(in: runs, opening: Self.opening), [], "side A's copy has the same bytes, so it is not new either")
    }

    func testTwoRecordsNamedByAUUIDMatchAcrossSidesThroughTheMask() throws {
        let nameA = "results/\(UUID().uuidString).lungfish-provenance.json"
        let nameC = "results/\(UUID().uuidString).lungfish-provenance.json"
        let runs = try fabricate(
            a: [Self.bundleRecord: true, nameA: true],
            c: [Self.bundleRecord: true, nameC: false],
            cPrime: [Self.bundleRecord: true, nameC: false]
        )
        let losses = RouteParityHarness.signatureLosses(in: runs, opening: Self.opening)
        XCTAssertEqual(losses.count, 2, "side C and side C' each hold the record unsigned: \(losses)")
        XCTAssertTrue(losses.allSatisfy { $0.contains("<UUID>.lungfish-provenance.json") }, "\(losses)")
    }

    func testTheAssertionFailsTheTestWhenASignatureIsLost() throws {
        let runs = try fabricate(
            a: [Self.bundleRecord: true], c: [Self.bundleRecord: false], cPrime: [Self.bundleRecord: true]
        )
        XCTExpectFailure("a record side A signed and side C left unsigned fails the case") {
            RouteParityHarness.assertNoSignatureLost(runs, opening: Self.opening)
        }
    }

    func testEditingOneDigitChangesExactlyOneCharacter() {
        let edited = RouteParityHarness.editingOneDigit(of: "{\"digest\": \"ab19\"}")
        XCTAssertEqual(edited, "{\"digest\": \"ab29\"}")
        XCTAssertEqual(RouteParityHarness.editingOneDigit(of: "{\"n\": 9}"), "{\"n\": 0}")
        XCTAssertNil(RouteParityHarness.editingOneDigit(of: "{}"))
    }
}
