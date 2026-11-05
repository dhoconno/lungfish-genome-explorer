// BuildDbTaxTriageOrganismReadsLiveConformanceTests.swift - The live form of BuildDbTaxTriageOrganismReadsTests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTREADS (WALK-BIO ruling, section Influenza, S1). The same check as the stand-in class, with the
// managed samtools on the fixture's real BAMs, whose markdup the build runs on the staged copy (2.9 O5).
// `LUNGFISH_REQUIRE_TOOLS=1` turns a missing samtools into a failure.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbTaxTriageOrganismReadsLiveConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageOrganismReadsLive")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, where Influenza A reads 0 in patient and NTC_1 because segment 4, its primary accession,
    /// holds none of its reads.
    func testTaxTriageRowReadsEqualODRReadsAligned() async throws {
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let result = try TaxTriageNTCPFixture.stage(in: root)

        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()

        try TaxTriageNTCPFixture.assertRowsReadTheirReports(in: result)
    }
}
