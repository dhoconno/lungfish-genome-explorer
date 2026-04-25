// OperationFailureIssueReporterTests.swift - GitHub issue prefill tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class OperationFailureIssueReporterTests: XCTestCase {

    func testNewIssueURLPrefillsTitleBodyAndMetadataFromFailureReport() throws {
        let item = OperationCenter.Item(
            title: "Classify Reads",
            detail: "Process exited with code 137",
            progress: 0.3,
            state: .failed,
            operationType: .classification,
            cliCommand: "lungfish classify --input /Users/alice/private reads/R1.fastq.gz"
        )
        let failureReport = """
        === Lungfish Operation Failure Report ===
        Operation: Classify Reads

        CLI Command:
          lungfish classify --input /Users/alice/private reads/R1.fastq.gz

        Error: Out of memory
        """
        let environment = OperationFailureIssueEnvironment(
            appVersion: "9.8.7 (654)",
            operatingSystem: "macOS 99.0",
            hardware: "Mac99,1, 64 GB RAM"
        )

        let url = try XCTUnwrap(OperationFailureIssueReporter.newIssueURL(
            for: item,
            failureReport: failureReport,
            environment: environment,
            homeDirectory: "/Users/alice"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/dhoconno/lungfish-genome-explorer/issues/new")
        XCTAssertEqual(query["template"], "rough_report.md")
        XCTAssertEqual(query["labels"], "triage")
        XCTAssertEqual(query["title"], "[Operation failure]: Classify Reads")

        let body = try XCTUnwrap(query["body"])
        XCTAssertTrue(body.contains("## What happened?"))
        XCTAssertTrue(body.contains("Operation: Classify Reads"))
        XCTAssertTrue(body.contains("Lungfish Genome Explorer version: 9.8.7 (654)"))
        XCTAssertTrue(body.contains("macOS version: macOS 99.0"))
        XCTAssertTrue(body.contains("Mac model and memory: Mac99,1, 64 GB RAM"))
        XCTAssertTrue(body.contains("~/private reads/R1.fastq.gz"))
        XCTAssertFalse(body.contains("/Users/alice/private reads"))
    }

    func testNewIssueTitleTruncatesLongOperationNames() {
        let longTitle = String(repeating: "Very Long Operation ", count: 12)
        let item = OperationCenter.Item(
            title: longTitle,
            detail: "Failed",
            progress: 1,
            state: .failed
        )

        let title = OperationFailureIssueReporter.issueTitle(for: item)

        XCTAssertLessThanOrEqual(title.count, 120)
        XCTAssertTrue(title.hasPrefix("[Operation failure]: Very Long Operation"))
    }
}
