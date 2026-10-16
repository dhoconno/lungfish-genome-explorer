// TaxTriageCLICancelSignalTests.swift - The TaxTriage CLI route's cancel signals the command first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 U30 walk, finding W2. A cancel of `lungfish-cli taxtriage run` left three exited containers,
// because the transport's SIGTERM reached the `docker ps` of the command's container cleanup. The TaxTriage
// route now sends SIGTERM to the command alone (`ToolProcessSpec.signalsProcessFirst`), so the command stops
// Nextflow and removes the containers itself, as the legacy route's in-app cleanup does. Kraken2 and EsViritu
// keep the termination of the whole tree. The live form is `TaxTriageParityLiveConformanceTests`'s X6 cancel.

import XCTest
@testable import LungfishApp

final class TaxTriageCLICancelSignalTests: XCTestCase {
    func testOnlyTheTaxTriageRouteSignalsTheCommandFirst() {
        XCTAssertTrue(CLIClassifierRunner.signalsCommandFirst(.taxTriage))
        XCTAssertFalse(CLIClassifierRunner.signalsCommandFirst(.kraken2))
        XCTAssertFalse(CLIClassifierRunner.signalsCommandFirst(.esViritu))
    }

    /// The grace the command gets covers Nextflow's own grace and the container cleanup's bound.
    func testTheGraceCoversTheEngineStopAndTheContainerCleanup() {
        XCTAssertGreaterThan(CLIClassifierRunner.terminationGracePeriod, .seconds(4) + .milliseconds(1500))
    }
}
