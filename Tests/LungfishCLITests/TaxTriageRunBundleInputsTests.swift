// TaxTriageRunBundleInputsTests.swift - What `taxtriage run` makes of several bundles, their platforms and roles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30 M2 (decisions T4 and T6, BIO R5). The GUI's TaxTriage run moves onto `lungfish-cli taxtriage
// run` (T1), so the command must take what the wizard hands it, several bundles, each with the platform and the
// sample role its bundle records, and the user's own negative control marks. These cases pin what the command makes
// of them, from the parsed options to the units of its plan, and launch nothing.
//
// - `--input` repeats, each input one sample or a folder of them, in the order given. Before M2 a second `--input`
//   replaced the first.
// - `--negative-control <sample>` repeats and marks the samples it names, beside the marks of the bundles' roles,
//   and the record names it as an explicit option. Before M2 it was no option.
// - Each sample whose reads lie in a bundle runs on the platform the bundle records and carries the mark its role
//   gives it, and a pooled run of two platforms is refused. Before M2 every sample ran on `--platform` with no mark.

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

    func testEachInputIsOneSampleNamedAfterItsBundleInTheOrderGiven() async throws {
        let patient = try makeBundle("patient", platform: .illumina, role: nil)
        let control = try makeBundle("control", in: root.appendingPathComponent("Controls", isDirectory: true), platform: .illumina, role: .negativeControl)

        let command = try parse(["--input", patient.path, "--input", control.path, "--input", patient.path, "--output", output.path])

        XCTAssertEqual(command.inputs, [patient.path, control.path, patient.path], "flipped by M2, a second --input no longer replaces the first")
        XCTAssertNil(command.input, "no one --input")
        let planned = try await plan(command)
        XCTAssertEqual(planned.units.count, 1, "a plain --output pools its samples")
        let samples = try XCTUnwrap(planned.units.first).value.config.samples
        XCTAssertEqual(samples.map(\.sampleId), ["patient", "control"], "in the order given, and an input named twice runs once")
        XCTAssertEqual(samples.map(\.fastq1.path), [patient.path, control.path])
        XCTAssertEqual(samples.map(\.isNegativeControl), [false, true], "control's role marks it")

        let prefixed = try await plan(try parse(["--input", patient.path, "--input", control.path, "--sample", "S", "--output", output.path, "--batch"]))
        XCTAssertEqual(prefixed.units.map(\.label), ["S-patient", "S-control"], "--sample prefixes each input's name, as for a folder")
    }

    func testInput2PairsWithOneInputOnly() async throws {
        let bundles = try makeBundles()
        let read2 = bundles.patient.appendingPathComponent("patient.fastq").path
        let words = "--input2 pairs with one --input. Give the pairs of several samples in a --samplesheet."

        XCTAssertThrowsError(try parse([
            "--input", bundles.control.path, "--input", bundles.patient.path, "--input2", read2, "--sample", "S", "--output", output.path,
        ]))
        let tool = makeTool(TaxTriageRunRequest(
            inputs: [bundles.control.path, bundles.patient.path],
            input2: read2,
            sampleID: "S",
            settings: TaxTriageConfig(samples: [], outputDirectory: output, kraken2DatabasePath: database, maxCpus: 2)
        ))
        let error = await planError(tool, .directory(output), batch: false)
        XCTAssertEqual(error?.localizedDescription, words)
        XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 3)
    }

    // MARK: - Negative controls

    func testNegativeControlMarksTheSampleItNamesAndTheRecordNamesIt() async throws {
        try makeBundles()

        let command = try parse(["--input", imports.path, "--output", output.path, "--batch", "--negative-control", "patient"])

        XCTAssertEqual(command.negativeControls, ["patient"], "flipped by M2, --negative-control is an option")
        let canonical = command.canonicalArguments()
        XCTAssertEqual(try TaxTriageCommand.RunSubcommand.parse(Array(canonical.dropFirst(2))).negativeControls, ["patient"], "the canonical command spells it")
        let units = try await plan(command).units
        let samples = units.flatMap(\.value.config.samples)
        XCTAssertEqual(samples.map(\.sampleId), ["control", "patient"])
        XCTAssertEqual(samples.map(\.isNegativeControl), [true, true], "control by its bundle's role, patient by --negative-control")
        XCTAssertEqual(
            units.map { TaxTriageRecordFacts(config: $0.value.config).explicitOptions["negative_controls"] },
            [nil, .array([.string("patient")])],
            "T4, the mark the user gave is explicit, the role's is no option"
        )
    }

    func testANegativeControlThatNamesNoSampleIsRefusedBeforeAnyFolderExists() async throws {
        try makeBundles()
        let command = try parse([
            "--input", imports.path, "--output", output.path, "--batch",
            "--negative-control", "blank", "--negative-control", "patient", "--negative-control", "NTC", "--negative-control", "blank",
        ])

        let error = await planError(command)

        XCTAssertEqual(
            error?.localizedDescription,
            "This run has no sample named blank or NTC, which --negative-control names. Its samples are control and patient."
        )
        XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused plan makes no folder")
    }

    // MARK: - Platforms and roles

    func testEachSampleRunsOnThePlatformItsBundleRecordsAndAPooledRunOfTwoPlatformsIsRefused() async throws {
        try makeBundles()

        let batch = try await plan(try parse(["--input", imports.path, "--output", output.path, "--batch"]))

        let samples = batch.units.flatMap(\.value.config.samples)
        XCTAssertEqual(samples.map(\.sampleId), ["control", "patient"], "each bundle names its sample")
        XCTAssertEqual(samples.map(\.platform), [.oxford, .illumina], "flipped by M2, the platform each bundle records")
        XCTAssertEqual(batch.units.map(\.value.config.platform), [.oxford, .illumina], "each launch's record and analysis entry name its sample's platform")
        XCTAssertEqual(samples.map(\.isNegativeControl), [true, false], "flipped by M2, control's role marks it")
        XCTAssertEqual(samples.map { $0.metadata?.sampleRole }, [.negativeControl, nil], "the bundle's metadata, as the wizard reads it")

        let error = await planError(try parse(["--input", imports.path, "--output", output.path]))
        XCTAssertEqual(
            error?.localizedDescription,
            "These samples record different platforms, control as Oxford Nanopore and patient as Illumina, and one Nextflow run takes one platform. Add --batch to run each sample alone on its own platform.",
            "T6, a pooled run of two platforms is refused, never relabelled"
        )
        XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 3)
    }

    func testAPooledRunOfOnePlatformRunsOnItAndReadsThatRecordNoneTakeThePlatformFlag() async throws {
        let first = try makeBundle("ont-1", platform: .oxfordNanopore, role: nil)
        let second = try makeBundle("ont-2", platform: .oxfordNanopore, role: nil)
        let pooled = try await plan(try parse(["--input", first.path, "--input", second.path, "--output", output.path]))
        XCTAssertEqual(pooled.units.map(\.value.config.platform), [.oxford], "not the illumina of --platform's default")
        XCTAssertEqual(pooled.units.flatMap(\.value.config.samples).map(\.platform), [.oxford, .oxford])

        let mgi = try makeBundle("mgi", platform: .mgi, role: nil)
        let unrecorded = try makeBundle("unrecorded", platform: nil, role: nil)
        let loose = root.appendingPathComponent("loose.fastq")
        try ReadSetFixtures.fastq(["loose-1"]).write(to: loose, atomically: true, encoding: .utf8)
        let flagged = try await plan(try parse([
            "--input", mgi.path, "--input", unrecorded.path, "--input", loose.path, "--platform", "pacbio", "--output", output.path,
        ]))
        XCTAssertEqual(
            flagged.units.flatMap(\.value.config.samples).map(\.platform),
            [.pacbio, .pacbio, .pacbio],
            "MGI reads, which TaxTriage has no mode for, a bundle that records none and loose reads take --platform"
        )
        XCTAssertEqual(flagged.units.map(\.value.config.platform), [.pacbio])
    }

    func testAPooledSamplesheetOfTwoPlatformsIsRefusedAndABatchRunsEachOnItsOwn() async throws {
        let ont = root.appendingPathComponent("ont.fastq")
        let ilmn = root.appendingPathComponent("ilmn.fastq")
        try ReadSetFixtures.fastq(["ont-1"]).write(to: ont, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["ilmn-1"]).write(to: ilmn, atomically: true, encoding: .utf8)
        let sheet = root.appendingPathComponent("samplesheet.csv")
        try TaxTriageSamplesheetBuilder().write([
            TaxTriageSample(sampleId: "ont", fastq1: ont, platform: .oxford),
            TaxTriageSample(sampleId: "ilmn", fastq1: ilmn, platform: .illumina),
        ], to: sheet)

        let error = await planError(try parse(["--samplesheet", sheet.path, "--output", output.path]))
        XCTAssertEqual(
            error?.localizedDescription,
            "These samples record different platforms, ont as Oxford Nanopore and ilmn as Illumina, and one Nextflow run takes one platform. Add --batch to run each sample alone on its own platform.",
            "T6, a pooled samplesheet of two platforms is refused, never relabelled"
        )
        XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused plan makes no folder")

        let batch = try await plan(try parse(["--samplesheet", sheet.path, "--output", output.path, "--batch"]))
        XCTAssertEqual(batch.units.map(\.value.config.platform), [.oxford, .illumina], "each row runs on its own platform")
    }

    func testAFileInsideABundleReadsItsBundleAndAnExtractionBlankIsAControl() async throws {
        let blank = try makeBundle("blank", platform: .pacbio, role: .extractionBlank)

        let planned = try await plan(try parse(["--input", blank.appendingPathComponent("blank.fastq").path, "--sample", "EB1", "--output", output.path]))

        let config = try XCTUnwrap(planned.units.first).value.config
        XCTAssertEqual(config.samples.map(\.sampleId), ["EB1"])
        XCTAssertEqual(config.samples.map(\.platform), [.pacbio])
        XCTAssertEqual(config.samples.map(\.isNegativeControl), [true], "an extraction blank is a negative control, as the wizard reads it")
        XCTAssertEqual(config.samples.map { $0.metadata?.sampleRole }, [.extractionBlank])
        XCTAssertNil(TaxTriageRecordFacts(config: config).explicitOptions["negative_controls"], "a mark the role makes is no option")
    }

    // MARK: - The record and the launch's settings

    func testTheRecordNamesOnlyTheControlsAUserMarkedInSampleOrder() {
        func sample(_ name: String, role: SampleRole?, marked: Bool) -> TaxTriageSample {
            var metadata = role.map { _ in FASTQSampleMetadata(sampleName: name) }
            if let role { metadata?.sampleRole = role }
            return TaxTriageSample(sampleId: name, fastq1: root.appendingPathComponent("\(name).fastq"), isNegativeControl: marked, metadata: metadata)
        }
        let samples = [
            sample("role", role: .negativeControl, marked: true),
            sample("named", role: .testSample, marked: true),
            sample("loose", role: nil, marked: true),
            sample("both", role: .extractionBlank, marked: true),
            sample("plain", role: .testSample, marked: false),
        ]

        let facts = TaxTriageRecordFacts(config: TaxTriageConfig(samples: samples, outputDirectory: output))
        XCTAssertEqual(facts.explicitOptions["negative_controls"], .array([.string("named"), .string("loose")]))
        XCTAssertNil(facts.resolvedDefaults["negative_controls"])
        let unmarked = TaxTriageRecordFacts(config: TaxTriageConfig(samples: [samples[0], samples[4]], outputDirectory: output))
        XCTAssertNil(unmarked.explicitOptions["negative_controls"], "recorded only when a user named one")
    }

    func testALaunchOnAnotherPlatformKeepsEveryOtherSetting() {
        let settings = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S", fastq1: root.appendingPathComponent("S.fastq"))],
            platform: .illumina,
            outputDirectory: output,
            kraken2DatabasePath: database,
            classifiers: ["kraken2", "other"],
            topHitsCount: 7,
            k2Confidence: 0.35,
            rank: "G",
            skipAssembly: false,
            skipKrona: true,
            maxMemory: "8.GB",
            maxCpus: 3,
            profile: "conda",
            containerRuntime: "apple",
            revision: "v3.3.9",
            sourceBundleURLs: [root.appendingPathComponent("A.lungfishfastq")],
            extraArguments: ["--flag", "x"],
            removeTaxids: "9606"
        )

        let moved = TaxTriageAnalysisRunTool.settings(settings, platform: .oxford)

        XCTAssertEqual(moved.platform, .oxford)
        let before = Array(Mirror(reflecting: settings).children)
        let after = Array(Mirror(reflecting: moved).children)
        XCTAssertEqual(before.count, 19, "a new stored value of TaxTriageConfig needs its line in TaxTriageAnalysisRunTool.settings(_:platform:), except platformSource, which only the plan sets (SW13)")
        XCTAssertEqual(after.map(\.label), before.map(\.label))
        for (old, new) in zip(before, after) where old.label != "platform" {
            XCTAssertEqual(String(describing: new.value), String(describing: old.value), old.label ?? "?")
        }
        XCTAssertEqual(TaxTriageAnalysisRunTool.settings(settings, platform: .illumina), settings)
    }

    // MARK: - Running the plan

    private var imports: URL { root.appendingPathComponent("Imports", isDirectory: true) }
    private var output: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func parse(_ arguments: [String]) throws -> TaxTriageCommand.RunSubcommand {
        try TaxTriageCommand.RunSubcommand.parse(["run"] + arguments + ["--db", database.path, "--max-cpus", "2"])
    }

    private func makeTool(_ request: TaxTriageRunRequest) -> TaxTriageAnalysisRunTool {
        TaxTriageAnalysisRunTool(
            request: request,
            services: TaxTriageRunServices(
                expandInputs: { arguments, recursive in
                    try CLIClassificationFolderResolver.expandInputArguments(arguments, recursive: recursive)
                },
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
            )
        )
    }

    /// The plan of `command`'s request, with its folders expanded as the command expands them. Nothing launches.
    private func plan(_ command: TaxTriageCommand.RunSubcommand) async throws -> AnalysisRunPlan<TaxTriageRunUnit> {
        let (destination, conflict) = command.resultDestination()
        return try await plan(makeTool(command.runRequest(usageConflict: conflict)), destination, batch: command.batch)
    }

    private func plan(_ tool: TaxTriageAnalysisRunTool, _ destination: AnalysisRunDestination, batch: Bool) async throws -> AnalysisRunPlan<TaxTriageRunUnit> {
        try await tool.plan(
            AnalysisRunRequest(inputs: [], destination: destination, groupsSamples: batch, commandLine: ["lungfish-cli", "taxtriage", "run"]),
            context: AnalysisRunPlanningContext(projectURL: destination.projectURL)
        )
    }

    private func planError(_ command: TaxTriageCommand.RunSubcommand) async -> Error? {
        let (destination, conflict) = command.resultDestination()
        return await planError(makeTool(command.runRequest(usageConflict: conflict)), destination, batch: command.batch)
    }

    private func planError(_ tool: TaxTriageAnalysisRunTool, _ destination: AnalysisRunDestination, batch: Bool) async -> Error? {
        do {
            _ = try await plan(tool, destination, batch: batch)
            return nil
        } catch {
            return error
        }
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
