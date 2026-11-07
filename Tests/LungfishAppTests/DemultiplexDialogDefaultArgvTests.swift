// DemultiplexDialogDefaultArgvTests.swift - The dialog leaves the search route to the route owner unless a person picks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN (L4). The dialog wrote `--engine cutadapt` on every run, so a run of the default kit
// searched the read bases even when the read names carry the kit's index.

import XCTest
import LungfishWorkflow
@testable import LungfishApp

final class DemultiplexDialogDefaultArgvTests: XCTestCase {
    private func request(engine: DemultiplexEngine) -> FASTQOperationLaunchRequest {
        // The dialog's defaults (`FASTQOperationDialogState` init) for a built-in kit.
        .derivative(
            request: .demultiplex(
                kitID: "truseq-single-a",
                customCSVPath: nil,
                location: "bothends",
                symmetryMode: nil,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                errorRate: 0.15,
                engine: engine,
                trimBarcodes: true,
                sampleAssignments: nil,
                kitOverride: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.lungfishfastq")],
            outputMode: .groupedResult
        )
    }

    func testDialogDefaultArgvOfTheDefaultKitAsksTheRouteOwner() throws {
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request(engine: .cutadapt))
        XCTAssertEqual(Array(invocation.arguments.prefix(1)), ["demultiplex"])
        XCTAssertFalse(invocation.arguments.contains("--engine"), "\(invocation.arguments)")
        let kitIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--kit"))
        XCTAssertEqual(invocation.arguments[kitIndex + 1], "truseq-single-a")
        XCTAssertTrue(invocation.arguments.contains("--error-rate"))
    }

    /// A Read Names pick is written as `--engine header-index`, with none of the options of a search of the bases,
    /// so the run takes the header route the person chose and its record says so (DEMUXSPLIT Handoff 1).
    func testReadNamesPickWritesTheHeaderEngineAndNoBaseSearchOption() throws {
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request(engine: .headerIndex))
        let engineIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--engine"), "\(invocation.arguments)")
        XCTAssertEqual(invocation.arguments[engineIndex + 1], "header-index")
        for option in ["--location", "--max-distance-5prime", "--max-distance-3prime", "--error-rate", "--no-trim"] {
            XCTAssertFalse(invocation.arguments.contains(option), "\(option) in \(invocation.arguments)")
        }
    }
}
