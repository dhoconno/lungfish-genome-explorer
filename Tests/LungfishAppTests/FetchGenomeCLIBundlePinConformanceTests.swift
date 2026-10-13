// FetchGenomeCLIBundlePinConformanceTests.swift - Pins the bundles lungfish-cli fetch genome builds today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// Pins the bundle `fetch genome` builds for an assembly and for a nucleotide record, its name
/// included, before Phase 2.10 lane A44 moves the leaf onto the download builders (review ruling
/// Q2c item 1). The leaf builds through `NativeBundleBuilder` with names and a layout of its own
/// (`bundleDirectoryName`), so the commit that moves it changes these snapshots and names each
/// changed default against them.
///
/// The leaf runs in this process against a loopback stand-in. Its `NCBIService` reads the
/// process environment, so each case sets the stand-in origin there (ruling Q2a) and clears
/// `NCBI_API_KEY` for the run, then puts both back. Each case runs the managed bgzip and samtools
/// faidx, so the class sits in the conformance tier and skips without them unless
/// `LUNGFISH_REQUIRE_TOOLS=1`.
final class FetchGenomeCLIBundlePinConformanceTests: XCTestCase {

    func testAssemblyAccessionBuildsTodaysCLIBundle() async throws {
        try await assertCLIBundle(pin: "cli-fetch-genome-assembly", accession: "GCF_000000001.1")
    }

    func testNucleotideAccessionBuildsTodaysCLIBundle() async throws {
        try await assertCLIBundle(pin: "cli-fetch-genome-nucleotide", accession: NCBIDownloadPinFixtures.genBankAccession)
    }

    // MARK: - Helpers

    private func assertCLIBundle(
        pin: String, accession: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
        let root = try TestTempDirectory.make(prefix: "fetch-genome-cli-pin")
        defer { TestTempDirectory.cleanup(root) }
        let served = root.appendingPathComponent("served", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let server = try await NCBIGenomeStandIn.start(servingIn: served)
        defer { server.stop() }

        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        var command = try GenomeSubcommand.parse([accession, "--output-dir", output.path, "--quiet"])
        try await command.run()

        let bundles = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(bundles.count, 1, "\(bundles)", file: file, line: line)
        let bundle = output.appendingPathComponent(try XCTUnwrap(bundles.first))
        // Since lane A44 M2 the leaf builds through the download builders, so the assembly bundle
        // is named `<organism> - <assembly name>` and carries the record of what was fetched, and
        // the nucleotide bundle is the GenBank download's, with its record. No record names a
        // scratch folder now. The temporary folder and UUIDs stay masked for the builders' own
        // scratch names.
        var snapshot = try await DownloadedBundleSnapshot.text(
            of: bundle,
            replacing: [(server.baseURL.absoluteString, "<STAND-IN>")]
                + DownloadedBundleSnapshot.directoryReplacements(output, as: "<OUT>")
                + DownloadedBundleSnapshot.directoryReplacements(FileManager.default.temporaryDirectory, as: "<TMP>"))
        snapshot = snapshot.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            with: "<UUID>", options: .regularExpression)
        snapshot += server.requests.map { "\nrequest \($0.method) \($0.target)" }.joined()
        DownloadedBundleSnapshot.recordIfAsked(snapshot, name: pin)
        XCTAssertEqual(snapshot, try DownloadBundlePins.expected(pin), file: file, line: line)
    }

}

/// Sets and clears process environment variables for one in-process CLI run and puts back what
/// was there. Only a conformance or replay class uses it, never the parallel unit tier.
struct ProcessEnvironmentOverride {
    private let previous: [String: String?]

    init(set: [String: String], unset: [String]) {
        var previous: [String: String?] = [:]
        for name in Array(set.keys) + unset {
            previous[name] = ProcessInfo.processInfo.environment[name]
        }
        self.previous = previous
        for (name, value) in set { setenv(name, value, 1) }
        for name in unset { unsetenv(name) }
    }

    func restore() {
        for (name, value) in previous {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
}
