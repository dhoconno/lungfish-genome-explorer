// TaxTriagePlatformPinTests.swift - What a TaxTriage record files for a platform the user typed, and the fixtures of the platform tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.15 M1 (SW13, BIO 4 and 7). A platform the user typed stays an explicit option and the record names
// no source for it. At the base the same held for the platform of a bundle and for the default platform, and the SW13
// commit moved those two pins into `TaxTriagePlatformSourceTests`.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The fixtures of the platform tests, a bundle that records a platform, a loose FASTQ file that records none and the
/// configuration of the one launch that the plan of `taxtriage run` makes over either.
class TaxTriagePlatformTestCase: XCTestCase {
    var root: URL!
    var database: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-platform").resolvingSymlinksInPath()
        database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A `.lungfishfastq` bundle of single reads whose sidecar records `platform`.
    func makeBundle(_ name: String, platform: SequencingPlatform) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("\(name).fastq")
        try ReadSetFixtures.fastq(["\(name)-1", "\(name)-2"]).write(to: reads, atomically: true, encoding: .utf8)
        try FASTQMetadataStore.write(PersistedFASTQMetadata(sequencingPlatform: platform), for: reads)
        return bundle
    }

    /// A FASTQ file that lies in no bundle, so it records no platform.
    func makeLooseReads(_ name: String) throws -> URL {
        let reads = root.appendingPathComponent("\(name).fastq")
        try ReadSetFixtures.fastq(["\(name)-1", "\(name)-2"]).write(to: reads, atomically: true, encoding: .utf8)
        return reads
    }

    /// The configuration of the one launch that planning `input` makes. `platform` is the `--platform` setting, and
    /// the command line names it only when `typed` is true, as the process's own arguments do.
    func plannedConfig(
        of input: URL,
        platform: TaxTriageConfig.Platform = .illumina,
        typed: Bool
    ) async throws -> TaxTriageConfig {
        let request = TaxTriageRunRequest(
            inputs: [input.path],
            settings: TaxTriageConfig(
                samples: [],
                platform: platform,
                outputDirectory: root,
                kraken2DatabasePath: database,
                maxCpus: 2
            )
        )
        let tool = TaxTriageAnalysisRunTool(
            request: request,
            services: TaxTriageRunServices(
                expandInputs: { arguments, _ in arguments.map { URL(fileURLWithPath: $0) } },
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
            )
        )
        let destination = AnalysisRunDestination.directory(root.appendingPathComponent("out", isDirectory: true))
        let commandLine = ["lungfish-cli", "taxtriage", "run", "--input", input.path]
            + (typed ? ["--platform", platform.rawValue.lowercased()] : [])
        let plan = try await tool.plan(
            AnalysisRunRequest(inputs: [], destination: destination, groupsSamples: false, commandLine: commandLine),
            context: AnalysisRunPlanningContext(projectURL: destination.projectURL)
        )
        return try XCTUnwrap(plan.units.first).value.config
    }
}

final class TaxTriagePlatformPinTests: TaxTriagePlatformTestCase {

    /// Loose reads record no platform, so they run on the `--platform` the user typed, and the record files it as
    /// an option the user chose, with no key that names a source.
    func testATypedPlatformIsAnExplicitOptionWithNoSource() async throws {
        let config = try await plannedConfig(of: try makeLooseReads("loose"), platform: .pacbio, typed: true)

        XCTAssertEqual(config.platform, .pacbio)
        let facts = TaxTriageRecordFacts(config: config)
        XCTAssertEqual(facts.explicitOptions["platform"], .string("PACBIO"))
        XCTAssertNil(facts.resolvedDefaults["platform"])
        XCTAssertNil(facts.explicitOptions["platformSource"])
        XCTAssertNil(facts.resolvedDefaults["platformSource"])
        let rootOptions = TaxTriageRecordFacts.rootRecordOptions(fromRunParameters: facts.runParameters)
        XCTAssertEqual(rootOptions.explicit["platform"], .string("PACBIO"))
        XCTAssertNil(rootOptions.resolved["platform"])
        XCTAssertNil(rootOptions.resolved["platformSource"])
        let saved = TaxTriageRecordFacts.recordOptions(fromRunParameters: facts.runParameters)
        XCTAssertNil(saved.resolvedDefaults["platform"])
        XCTAssertNil(saved.resolvedDefaults["platformSource"])
    }
}
