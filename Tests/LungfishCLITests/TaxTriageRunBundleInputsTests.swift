// TaxTriageRunBundleInputsTests.swift - What `taxtriage run` makes of several bundles, their platforms and roles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30 M2 (decisions T4 and T6, BIO R5). The GUI's TaxTriage run moves onto `lungfish-cli taxtriage
// run` (T1), so the command must take what the wizard hands it, several bundles, each with the platform and the
// sample role its bundle records, and the user's own negative control marks. These cases pin what the command makes
// of them, from the parsed options to the units of its plan, and launch nothing.
//
// - A second `--input` replaces the first, so one run takes one input.
// - `--negative-control` is no option.
// - Every sample of an `--input` runs on `--platform`, whatever platform its bundle records, so a run of an Oxford
//   Nanopore bundle and an Illumina bundle runs both as Illumina, pooled or as a batch, and no sample carries the
//   negative control mark its bundle's role gives it.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageRunBundleInputsTests: XCTestCase {
    private var root: URL!
    private var database: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-bundle-inputs").resolvingSymlinksInPath()
        database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Several inputs

    func testASecondInputReplacesTheFirst() async throws {
        let bundles = try makeBundles()

        let command = try parse(["--input", bundles.control.path, "--input", bundles.patient.path, "--sample", "S", "--output", output.path])

        XCTAssertEqual(command.input, bundles.patient.path, "the last --input wins")
        let samples = try await plan(command).units.flatMap(\.value.config.samples)
        XCTAssertEqual(samples.map(\.sampleId), ["S"])
        XCTAssertEqual(samples.map(\.fastq1.lastPathComponent), ["patient.lungfishfastq"])
    }

    // MARK: - Negative controls

    func testNegativeControlIsNoOption() throws {
        try makeBundles()
        XCTAssertThrowsError(try parse(["--input", imports.path, "--output", output.path, "--negative-control", "patient"]))
    }

    // MARK: - Platforms and roles

    func testEverySampleOfAFolderOfBundlesRunsOnThePlatformFlagWithNoControlMark() async throws {
        try makeBundles()

        for batch in [false, true] {
            let planned = try await plan(try parse(["--input", imports.path, "--output", output.path] + (batch ? ["--batch"] : [])))

            let samples = planned.units.flatMap(\.value.config.samples)
            XCTAssertEqual(samples.map(\.sampleId), ["control", "patient"], "batch \(batch): each bundle names its sample")
            XCTAssertEqual(samples.map(\.platform), [.illumina, .illumina], "batch \(batch): --platform, not the Oxford Nanopore reads control's bundle records")
            XCTAssertEqual(samples.map(\.isNegativeControl), [false, false], "batch \(batch): control's role marks nothing")
            XCTAssertEqual(samples.map { $0.metadata == nil }, [true, true], "batch \(batch): no bundle's metadata is read")
            XCTAssertEqual(planned.units.map(\.value.config.platform), batch ? [.illumina, .illumina] : [.illumina], "batch \(batch)")
        }
    }

    // MARK: - Running the plan

    private var imports: URL { root.appendingPathComponent("Imports", isDirectory: true) }
    private var output: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func parse(_ arguments: [String]) throws -> TaxTriageCommand.RunSubcommand {
        try TaxTriageCommand.RunSubcommand.parse(["run"] + arguments + ["--db", database.path, "--max-cpus", "2"])
    }

    /// The plan of `command`'s request, with its folders expanded as the command expands them. Nothing launches.
    private func plan(_ command: TaxTriageCommand.RunSubcommand) async throws -> AnalysisRunPlan<TaxTriageRunUnit> {
        let (destination, conflict) = command.resultDestination()
        let tool = TaxTriageAnalysisRunTool(
            request: command.runRequest(usageConflict: conflict),
            services: TaxTriageRunServices(
                expandInputs: { arguments, recursive in
                    try CLIClassificationFolderResolver.expandInputArguments(arguments, recursive: recursive)
                },
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
            )
        )
        return try await tool.plan(
            AnalysisRunRequest(
                inputs: [],
                destination: destination,
                groupsSamples: command.batch,
                commandLine: ["lungfish-cli", "taxtriage", "run"]
            ),
            context: AnalysisRunPlanningContext(projectURL: destination.projectURL)
        )
    }

    // MARK: - Fixtures

    /// `Imports/control.lungfishfastq`, Oxford Nanopore reads whose `metadata.csv` names a negative control, and
    /// `Imports/patient.lungfishfastq`, Illumina reads with no `metadata.csv`, each one file of single reads whose
    /// sidecar records its platform.
    @discardableResult
    private func makeBundles() throws -> (control: URL, patient: URL) {
        (
            try makeBundle("control", platform: .oxfordNanopore, role: .negativeControl),
            try makeBundle("patient", platform: .illumina, role: nil)
        )
    }

    private func makeBundle(_ name: String, in folder: URL? = nil, platform: SequencingPlatform?, role: SampleRole?) throws -> URL {
        let bundle = (folder ?? imports).appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("\(name).fastq")
        try ReadSetFixtures.fastq(["\(name)-1", "\(name)-2"]).write(to: reads, atomically: true, encoding: .utf8)
        if let platform {
            try FASTQMetadataStore.write(PersistedFASTQMetadata(sequencingPlatform: platform), for: reads)
        }
        if let role {
            try FASTQBundleCSVMetadata.save(
                FASTQBundleCSVMetadata(keyValuePairs: ["sample_name": name, "sample_role": role.rawValue]),
                to: bundle
            )
        }
        return bundle
    }
}
