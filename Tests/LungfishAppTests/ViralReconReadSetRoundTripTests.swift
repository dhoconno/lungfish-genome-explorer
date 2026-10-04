// ViralReconReadSetRoundTripTests.swift - The recorded Viral Recon command stages the rows the app's run stages
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The app builds the samplesheet with the wizard's input policy, copies it
// into the run bundle and runs `lungfish-cli workflow run nf-core/viralrecon`
// on it. A derived or virtual bundle is named in that samplesheet as the
// bundle, and the CLI plans and stages its reads inside the run. Pasting
// the recorded command must stage the same rows (docs/contracts/CLI-EQUIVALENCE.md,
// docs/contracts/READ-PAIRING.md, Phase 1.5 lane A6b).

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ViralReconReadSetRoundTripTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "viralrecon-read-set-round-trip")
        root = root.resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// One launched samplesheet row by sample and read names, which stay the
    /// same between runs while the scratch paths do not.
    struct Row: Equatable {
        let sample: String
        let reads1: [String]
        let reads2: [String]
    }

    final class CapturingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        private(set) var launches: [[Row]] = []

        func runNextflow(arguments: [String], workingDirectory: URL, environment: [String: String]) async throws -> NFCoreWorkflowProcessResult {
            var rows: [Row] = []
            if let index = arguments.firstIndex(of: "--input"), index + 1 < arguments.count {
                let text = (try? String(contentsOf: URL(fileURLWithPath: arguments[index + 1]), encoding: .utf8)) ?? ""
                for line in text.split(separator: "\n").dropFirst() {
                    let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    let fastq2 = fields.count > 2 ? fields[2] : ""
                    rows.append(Row(
                        sample: fields[0],
                        reads1: await Self.names(fields[1]),
                        reads2: fastq2.isEmpty ? [] : await Self.names(fastq2)
                    ))
                }
            }
            launches.append(rows)
            if let index = arguments.firstIndex(of: "--outdir"), index + 1 < arguments.count {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: arguments[index + 1]), withIntermediateDirectories: true)
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }

        static func names(_ path: String) async -> [String] {
            guard let records = try? await FASTQReader(validateSequence: false).readAll(from: URL(fileURLWithPath: path)) else {
                return ["<unreadable \(path)>"]
            }
            return records.map(\.identifier)
        }
    }

    /// The request the app's wizard and execution service build for
    /// `bundle`, with its samplesheet copied into the run bundle as the
    /// service persists it.
    private func appRequest(for bundle: URL, runBundle: URL) throws -> ViralReconRunRequest {
        let resolved = try ViralReconWizardInputPolicy.resolveInputs([bundle], platformOverride: nil)
        let samples = try ViralReconInputResolver.makeSamples(from: resolved)
        let staging = root.appendingPathComponent(".viralrecon-inputs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let wizardSheet = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: staging)
        let inputs = runBundle.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let persistedSheet = inputs.appendingPathComponent("samplesheet.csv")
        try FileManager.default.copyItem(at: wizardSheet, to: persistedSheet)
        let primers = inputs.appendingPathComponent("primers", isDirectory: true)
        try FileManager.default.createDirectory(at: primers, withIntermediateDirectories: true)
        let bed = primers.appendingPathComponent("primers.bed")
        let fasta = primers.appendingPathComponent("primers.fasta")
        try "MN908947.3\t30\t54\tnCoV-2019_1_LEFT\t1\t+\n".write(to: bed, atomically: true, encoding: .utf8)
        try ">nCoV-2019_1_LEFT\nACCAACCAACTTTCGATCTCTTGT\n".write(to: fasta, atomically: true, encoding: .utf8)
        return try ViralReconRunRequest(
            samples: samples,
            platform: .illumina,
            protocol: .amplicon,
            samplesheetURL: persistedSheet,
            outputDirectory: root.appendingPathComponent("viralrecon-results", isDirectory: true),
            executor: .docker,
            version: "3.0.0",
            reference: .genome(ViralReconReferenceCatalog.canonicalAccession),
            primer: ViralReconPrimerSelection(
                bundleURL: primers,
                displayName: "Test scheme",
                bedURL: bed,
                fastaURL: fasta,
                leftSuffix: "_LEFT",
                rightSuffix: "_RIGHT",
                derivedFasta: false
            ),
            minimumMappedReads: 1,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: [],
            advancedParams: ["max_cpus": "2", "max_memory": "4.GB"]
        )
    }

    /// For each derived bundle shape: the app's run (the argv the service
    /// hands `lungfish-cli`) and a replay of the recorded command string
    /// launch the same rows, and those rows hold every read in its role.
    func testTheRecordedCommandStagesTheRowsTheAppsRunStages() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let expected: [(URL, [Row])] = [
            (fixtures.pairedDerivative, [Row(sample: "paired", reads1: ["p1/1", "p2/1"], reads2: ["p1/2", "p2/2"])]),
            (fixtures.mergeDerivative, [Row(sample: "merge", reads1: ["u1/1", "u1/2", "x1", "x2", "x3"], reads2: [])]),
            (fixtures.repairDerivative, [Row(sample: "repair", reads1: ["r1/1", "r2/1", "r1/2", "r2/2", "o1"], reads2: [])]),
        ]
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        for (bundle, rows) in expected {
            let runner = CapturingNextflowRunner()
            RunSubcommand.nfCoreWorkflowProcessRunner = runner
            let runBundle = root.appendingPathComponent("\(bundle.deletingPathExtension().lastPathComponent).lungfishrun", isDirectory: true)
            let request = try appRequest(for: bundle, runBundle: runBundle)

            // The app's run: the argv the execution service hands lungfish-cli.
            var appCommand = try LungfishCLI.parseAsRoot(
                LungfishCLI.normalizedArgumentsForParsing(request.cliArguments(bundlePath: runBundle))
            )
            if var asyncCommand = appCommand as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try appCommand.run()
            }
            let appRows = try XCTUnwrap(runner.launches.last, bundle.lastPathComponent)

            // The recorded command, parsed back from the Operations panel string.
            let recorded = ViralReconWorkflowExecutionService.cliCommandPreview(for: request, bundleURL: runBundle)
            try await RecordedCLICommand.runInProcess(recorded)
            let replayRows = try XCTUnwrap(runner.launches.last, bundle.lastPathComponent)

            XCTAssertEqual(runner.launches.count, 2, bundle.lastPathComponent)
            XCTAssertEqual(appRows, rows, bundle.lastPathComponent)
            XCTAssertEqual(replayRows, appRows, "\(bundle.lastPathComponent): the replay stages the app's rows")
        }
    }
}
