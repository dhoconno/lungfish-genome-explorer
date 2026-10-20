// MappingRecordPassStepsTests.swift - The mapping record keeps the summary's coverage and view passes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.16 M2, item 7 (Q-B3) and the ARCH ruling for M2. The `mapping` golden capture is a real
/// run of `lungfish-cli map` with minimap2 on the sarscov2 fixture, so its two provenance files are the typed
/// record and the envelope that run wrote, with only paths, times and digests masked. This test reads them and
/// holds their last two steps to the `samtools coverage` and `samtools view` passes of the summary.
final class MappingRecordPassStepsTests: XCTestCase {
    private let goldenFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/golden/mapping", isDirectory: true)

    private func recordedSteps(in name: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: goldenFolder.appendingPathComponent(name))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], name)
        return try XCTUnwrap(object["steps"] as? [[String: Any]], name)
    }

    func testTheMappingRecordHoldsTheCoverageAndViewPasses() throws {
        let bam = "<RUN_ROOT>/mapping/out/sarscov2-test.sorted.bam"
        let expected: [[String]] = [
            ["coverage", "--ff", "UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP", bam],
            ["view", bam],
        ]
        // The typed record names the argv `command` and the digest `sha256`, the envelope `argv` and `checksumSHA256`.
        let forms = [("mapping-provenance.json", "command", "sha256"), ("lungfish-provenance.json", "argv", "checksumSHA256")]
        for (name, argvKey, digestKey) in forms {
            let all = try recordedSteps(in: name)
            XCTAssertGreaterThanOrEqual(all.count, 3, name)
            let earlier = all.dropLast(2)
            XCTAssertTrue(earlier.allSatisfy { $0["stdoutReadInProcess"] == nil }, "\(name): no earlier step holds the mark")
            let knownDigests = earlier
                .flatMap { (($0["inputs"] as? [[String: Any]]) ?? []) + (($0["outputs"] as? [[String: Any]]) ?? []) }
                .filter { $0["path"] as? String == bam }
                .compactMap { $0[digestKey] as? String }

            for (pass, arguments) in zip(all.suffix(2), expected) {
                let argv = try XCTUnwrap(pass[argvKey] as? [String], name)
                XCTAssertTrue(argv.first?.hasSuffix("/samtools") == true, "\(name): \(argv)")
                XCTAssertEqual(Array(argv.dropFirst()), arguments, name)
                XCTAssertEqual(pass["stdoutReadInProcess"] as? Bool, true, "\(name): \(argv)")
                XCTAssertEqual((pass["outputs"] as? [Any])?.count, 0, "\(name): the app read the stdout, so no file")
                XCTAssertEqual((pass["exitCode"] ?? pass["exitStatus"]) as? Int, 0, name)
                let inputs = try XCTUnwrap(pass["inputs"] as? [[String: Any]], name)
                XCTAssertEqual(inputs.map { $0["role"] as? String }, ["input", "index"], name)
                XCTAssertEqual(inputs.map { $0["path"] as? String }, [bam, bam + ".bai"], name)
                let digest = try XCTUnwrap(inputs.first?[digestKey] as? String, name)
                XCTAssertFalse(knownDigests.isEmpty, "\(name): the record gives the BAM a digest before the passes")
                XCTAssertEqual(Set(knownDigests), [digest], "\(name): the pass reads the BAM the record already digested")
            }
        }
    }
}
