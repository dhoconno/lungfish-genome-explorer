// SRAFASTQDownloadRouteTests.swift - An SRA run takes the SRA Toolkit route whenever ENA cannot serve it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// The window's SRA download asks `fastqDownloadRoute(forRun:)` where to
/// fetch each run from before it downloads anything. During the ENA outage
/// of 2026-10-04 that lookup threw, and the download failed although NCBI
/// could serve the run. An ENA error, a run ENA does not know and a record
/// without FASTQ links now all choose the SRA Toolkit, which fetches the run
/// from NCBI. The archive is a mock HTTP client.
final class SRAFASTQDownloadRouteTests: XCTestCase {

    func testRouteIsSRAToolkitWhenENAErrors() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(ENAOutageFixture.page, statusCode: 500))

        let route = try await ENAService(httpClient: client).fastqDownloadRoute(forRun: "SRR27069570")

        guard case .sraToolkit(let record, let reason) = route else {
            return XCTFail("Expected the SRA Toolkit route, got \(route)")
        }
        XCTAssertNil(record)
        XCTAssertEqual(reason, "ENA returned HTTP 500 (server error) for SRR27069570")
        XCTAssertEqual(route.toolkitReason, reason)
    }

    func testRouteIsSRAToolkitWhenENAIsUnreachable() async throws {
        let client = MockHTTPClient()

        let route = try await ENAService(httpClient: client).fastqDownloadRoute(forRun: "SRR27069570")

        guard case .sraToolkit(let record, let reason) = route else {
            return XCTFail("Expected the SRA Toolkit route, got \(route)")
        }
        XCTAssertNil(record)
        XCTAssertTrue(reason.hasPrefix("ENA could not be reached"), reason)
        XCTAssertTrue(reason.hasSuffix(" for SRR27069570"), reason)
    }

    func testRouteIsSRAToolkitWhenENAListsNoFASTQFiles() async throws {
        let client = MockHTTPClient()
        await client.register(
            pattern: "portal/api/filereport",
            response: .json([["run_accession": "SRR27069570", "library_layout": "PAIRED", "fastq_ftp": ""]])
        )

        let route = try await ENAService(httpClient: client).fastqDownloadRoute(forRun: "SRR27069570")

        guard case .sraToolkit(let record, let reason) = route else {
            return XCTFail("Expected the SRA Toolkit route, got \(route)")
        }
        XCTAssertEqual(record?.libraryLayout, "PAIRED", "ENA's record stays for the bundle's metadata")
        XCTAssertEqual(reason, "ENA lists no FASTQ files for SRR27069570")
    }

    func testRouteIsSRAToolkitWhenENAHasNoRecord() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text("[]"))

        let route = try await ENAService(httpClient: client).fastqDownloadRoute(forRun: "SRR27069570")

        guard case .sraToolkit(let record, let reason) = route else {
            return XCTFail("Expected the SRA Toolkit route, got \(route)")
        }
        XCTAssertNil(record)
        XCTAssertEqual(reason, "ENA has no record of SRR27069570")
    }

    func testRouteIsENAMirrorWhenENAListsFiles() async throws {
        let client = MockHTTPClient()
        await client.register(
            pattern: "portal/api/filereport",
            response: .json([[
                "run_accession": "SRR27069570",
                "library_layout": "PAIRED",
                "fastq_ftp": "ftp.sra.ebi.ac.uk/vol1/fastq/SRR270/070/SRR27069570/SRR27069570_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/SRR270/070/SRR27069570/SRR27069570_2.fastq.gz",
                "fastq_bytes": "100;100",
            ]])
        )

        let route = try await ENAService(httpClient: client).fastqDownloadRoute(forRun: "SRR27069570")

        guard case .enaMirror(let record) = route else {
            return XCTFail("Expected the ENA route, got \(route)")
        }
        XCTAssertEqual(
            record.fastqHTTPURLs.map(\.lastPathComponent),
            ["SRR27069570_1.fastq.gz", "SRR27069570_2.fastq.gz"]
        )
        XCTAssertNil(route.toolkitReason)
    }

    func testRoutePropagatesCancellation() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .cancelled)

        do {
            _ = try await ENAService(httpClient: client).fastqDownloadRoute(forRun: "SRR27069570")
            XCTFail("Expected the cancellation to propagate")
        } catch let error as URLError where error.code == .cancelled {
            // Expected: a cancelled download stops instead of starting the toolkit.
        }
    }
}
