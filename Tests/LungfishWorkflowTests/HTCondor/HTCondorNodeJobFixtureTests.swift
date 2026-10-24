// HTCondorNodeJobFixtureTests.swift - C4-09's node job against the template that wrote it (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Node job (a), cluster 593367 on e4004, ran the template's arguments line. Its submit file, its
// `condor_history -af MATCH_EXP_Arguments` line and its event log are fixtures in Tests/Fixtures/htcondor.

import XCTest
@testable import LungfishWorkflow

final class HTCondorNodeJobFixtureTests: XCTestCase {
    func testNodeJobRanTheTemplatesArgumentsWithEverySiteFactExpanded() throws {
        // The node job's arguments line is the template's, word for word.
        let rendered = try HTCondorSubmitTemplate.render(HTCondorSubmitTemplateTests.input())
        func argumentsLines(_ text: String) -> [String] {
            text.split(separator: "\n").filter { $0.hasPrefix("arguments = ") }.map(String.init)
        }
        XCTAssertEqual(argumentsLines(rendered).count, 1)
        XCTAssertEqual(argumentsLines(try HTCondorFixtures.text("h2a-echo.sub")), argumentsLines(rendered))

        // The schedd's expansion on the matched slot: every site fact expanded, in the template's order.
        let expanded = try HTCondorFixtures.text("h2a-match-exp-arguments.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(expanded.contains("$$("), "no machine-ad macro is left")
        XCTAssertFalse(expanded.contains(HTCondorSubmitTemplate.unsetValue), "the slot has every attribute the template names")
        let words = expanded.split(separator: " ").map(String.init)
        let separator = try XCTUnwrap(words.firstIndex(of: "--"))
        let pairs = Array(words[(separator + 1)...])
        XCTAssertEqual(pairs.count, 2 * HTCondorSubmitTemplate.siteFacts.count)
        let facts = stride(from: 0, to: pairs.count - 1, by: 2).map { (flag: pairs[$0], fact: pairs[$0 + 1]) }
        XCTAssertTrue(facts.allSatisfy { $0.flag == "--site-fact" })
        XCTAssertEqual(facts.map { String($0.fact.prefix { $0 != "=" }) }, HTCondorSubmitTemplate.siteFacts.map(\.key))
        XCTAssertTrue(facts.allSatisfy { !$0.fact.hasSuffix("=") }, "no fact is empty")
        XCTAssertEqual(facts.first?.fact, "Machine=e4004.chtc.wisc.edu")
        XCTAssertEqual(facts.last?.fact, "ProcId=0")

        // The job's event log: one run on e4004 that ended with return value 0, under the cluster the facts name.
        let log = try HTCondorJobEventLog.read(HTCondorFixtures.url("h2a-echo.log"))
        XCTAssertEqual(log.state, .ended(.exited(returnValue: 0)))
        XCTAssertEqual(log.host, "e4004.chtc.wisc.edu")
        XCTAssertTrue(facts.contains { $0.fact == "ClusterId=\(log.job.cluster)" })
    }
}
