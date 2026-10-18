// TaxTriageBlastReadsTests.swift - The BAM extraction of a TaxTriage BLAST Verify hands the BAM index on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.09 (PF12), the shape of `EsVirituBlastReadsTests`. `ClassifierBlastExtractionConfigTests` pins the
// config builder, but `TaxTriageBlastReads.extract`, the extraction the TaxTriage site runs, could drop the index it is
// given and every test would stay green. That is the bug `d4bed54e0` fixed, a BAM index that never reached the read
// extraction service. The service checks the index before any tool starts, so these cases run no samtools. A named
// index that is missing is refused as that file, which shows the index reached the service. No index is refused as
// required. Either way the folder the extraction made under the project's `.tmp` is gone.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

final class TaxTriageBlastReadsTests: XCTestCase {
    func testTheExtractionHandsTheBAMIndexToTheService() async throws {
        let scratch = try TestTempDirectory.make(prefix: "taxtriage-blast-reads")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bam = project.appendingPathComponent("x.bam")
        try Data().write(to: bam)

        // The index the site passes is the one the service checks.
        let missing = project.appendingPathComponent("x.bam.bai")
        let named = await extractionError(bam: bam, index: missing, project: project)
        if case .bamNotIndexed(let url)? = named {
            XCTAssertEqual(url, missing, "the service reports the index it was given")
        } else {
            XCTFail("a named index that is missing must be refused as bamNotIndexed, got \(String(describing: named))")
        }
        XCTAssertEqual(stages(in: project), [], "the folder the extraction made is gone")

        // With no index the service asks for one and starts nothing.
        let unnamed = await extractionError(bam: bam, index: nil, project: project)
        if case .explicitIndexRequired(let url)? = unnamed {
            XCTAssertEqual(url, bam)
        } else {
            XCTFail("no index must be refused as explicitIndexRequired, got \(String(describing: unnamed))")
        }
        XCTAssertEqual(stages(in: project), [], "the folder the extraction made is gone")
    }

    /// The error `TaxTriageBlastReads.extract` throws for `bam` and `index`, nil when it throws none or another kind.
    private func extractionError(bam: URL, index: URL?, project: URL) async -> ExtractionError? {
        do {
            _ = try await TaxTriageBlastReads.extract(
                bamURL: bam, indexURL: index, accessions: ["NC_026438.1"], projectURL: project
            )
            return nil
        } catch {
            return error as? ExtractionError
        }
    }

    /// The `taxtriage-blast-*` folders under the project's `.tmp`.
    private func stages(in project: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".tmp").path)) ?? [])
            .filter { $0.hasPrefix("taxtriage-blast-") }
    }
}
