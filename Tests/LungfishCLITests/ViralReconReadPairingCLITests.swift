// ViralReconReadPairingCLITests.swift - workflow run nf-core/viralrecon builds the app's samplesheet and splits interleaved pairs in the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class ViralReconReadPairingCLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-pairing-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The CLI standardizes every path it records (/var -> /private/var).
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Records what Nextflow would have been launched with and inspects the
    /// samplesheet at that moment, before the run's scratch is removed.
    private final class CapturingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        struct Launch {
            let arguments: [String]
            let samplesheetText: String?
            let fastqRecordCounts: [Int]
        }
        private(set) var launches: [Launch] = []

        func runNextflow(arguments: [String], workingDirectory: URL, environment: [String: String]) async throws -> NFCoreWorkflowProcessResult {
            var samplesheetText: String?
            var counts: [Int] = []
            if let index = arguments.firstIndex(of: "--input"), index + 1 < arguments.count {
                let url = URL(fileURLWithPath: arguments[index + 1])
                samplesheetText = try? String(contentsOf: url, encoding: .utf8)
                for row in (samplesheetText ?? "").split(separator: "\n").dropFirst() {
                    for field in row.split(separator: ",", omittingEmptySubsequences: false).dropFirst() where !field.isEmpty {
                        counts.append((try? FASTQPairInterleaver.countRecords(in: URL(fileURLWithPath: String(field)))) ?? -1)
                    }
                }
            }
            launches.append(Launch(arguments: arguments, samplesheetText: samplesheetText, fastqRecordCounts: counts))
            // The pipeline would have created its results directory, which
            // is also the run's expected output.
            if let index = arguments.firstIndex(of: "--outdir"), index + 1 < arguments.count {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: arguments[index + 1]),
                    withIntermediateDirectories: true
                )
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
        }
    }

    private func gzipInPlace(_ url: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return URL(fileURLWithPath: url.path + ".gz")
    }

    /// An Illumina `.lungfishfastq` bundle holding one gzip interleaved file
    /// whose metadata names the platform, the way an import leaves it.
    private func writeInterleavedIlluminaBundle(named name: String, pairCount: Int) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundle = try InterleavedFASTQFixture.writeBundle(named: name, in: root, pairCount: pairCount, naming: .casava)
        var metadata = try XCTUnwrap(FASTQMetadataStore.load(for: bundle.fastqURL))
        metadata.sequencingPlatform = .illumina
        let compressed = try gzipInPlace(bundle.fastqURL)
        try? FileManager.default.removeItem(at: FASTQMetadataStore.metadataURL(for: bundle.fastqURL))
        FASTQMetadataStore.save(metadata, for: compressed)
        return (bundle.bundleURL, compressed)
    }

    /// Samplesheet rows with every path canonicalized (`/private/var` and
    /// `/var` compare equal), since the CLI standardizes what it records.
    private func rows(_ text: String?) -> [[String]] {
        (text ?? "").split(separator: "\n").dropFirst().map { line in
            line.split(separator: ",", omittingEmptySubsequences: false).enumerated().map { index, field in
                index == 0 || field.isEmpty ? String(field) : canonical(String(field))
            }
        }
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Bundle input: the CLI builds the app's samplesheet and splits inside the run

    func testBundleInputIsSplitIntoFastq1AndFastq2InsideTheRunAndRecorded() async throws {
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        let runner = CapturingNextflowRunner()
        RunSubcommand.nfCoreWorkflowProcessRunner = runner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        let bundle = try writeInterleavedIlluminaBundle(named: "patient", pairCount: 7)
        let runBundleURL = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)

        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", bundle.bundleURL.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", runBundleURL.path,
            "--version", "3.0.0",
            "--param", "protocol=amplicon",
            "--quiet",
        ]).run()

        // The caller-facing samplesheet is the one the app builds: one row, one file.
        let callerSamplesheet = runBundleURL.appendingPathComponent("inputs/samplesheet.csv")
        XCTAssertEqual(rows(try String(contentsOf: callerSamplesheet, encoding: .utf8)), [["patient", canonical(bundle.fastqURL.path), ""]])
        let manifest = try NFCoreRunBundleStore.read(from: runBundleURL)
        XCTAssertEqual(manifest.params["input"], callerSamplesheet.path)
        XCTAssertEqual(manifest.params["platform"], "illumina", "the platform comes from the bundle when the caller did not name it")
        XCTAssertEqual(manifest.executionStatus, .completed)

        // Nextflow was launched with the paired samplesheet: both columns filled, 7 reads each.
        let launch = try XCTUnwrap(runner.launches.first)
        let launched = rows(launch.samplesheetText)
        XCTAssertEqual(launched.count, 1)
        XCTAssertEqual(launched[0][0], "patient")
        XCTAssertTrue(launched[0][1].hasSuffix("_R1.fastq.gz"), launched[0][1])
        XCTAssertTrue(launched[0][2].hasSuffix("_R2.fastq.gz"), "fastq_2 must be filled: \(launched[0])")
        XCTAssertFalse(launched[0][1].contains(" "), "the split mates live on a whitespace-free path")
        XCTAssertEqual(launch.fastqRecordCounts, [7, 7])
        let pairedSamplesheet = runBundleURL.appendingPathComponent("inputs/\(ViralReconReadPairing.pairedSamplesheetFilename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pairedSamplesheet.path))
        XCTAssertTrue(launch.arguments.contains(pairedSamplesheet.path), launch.arguments.joined(separator: " "))

        // The split mates were scratch: gone with the run.
        XCTAssertFalse(FileManager.default.fileExists(atPath: launched[0][1]))

        // The decision is recorded next to the inputs and in the provenance.
        let decisions = try XCTUnwrap(ViralReconReadPairing.loadDecisions(
            from: runBundleURL.appendingPathComponent("inputs/\(ViralReconReadPairing.decisionsFilename)")
        ))
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].layout, .strictlyInterleaved)
        XCTAssertEqual(decisions[0].handling, .splitToR1R2)
        XCTAssertEqual(decisions[0].pairCount, 7)
        XCTAssertEqual(decisions[0].sourceFASTQURLs.map { canonical($0.path) }, [canonical(bundle.fastqURL.path)])
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: runBundleURL))
        guard case .array(let recorded)? = provenance.options.explicit["readPairing"],
              case .dictionary(let fields)? = recorded.first else {
            return XCTFail("readPairing missing from provenance: \(provenance.options.explicit.keys.sorted())")
        }
        XCTAssertEqual(fields["handling"], .string("split_to_r1_r2"))
        XCTAssertEqual(fields["pairs"], .integer(7))
        XCTAssertEqual(provenance.options.explicit["effectiveSamplesheet"], .file(pairedSamplesheet))
    }

    // MARK: - Samplesheet input (what the app hands over) makes the same decision

    func testSamplesheetWithAnInterleavedFileIsSplitTheSameWay() async throws {
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        let runner = CapturingNextflowRunner()
        RunSubcommand.nfCoreWorkflowProcessRunner = runner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        let bundle = try writeInterleavedIlluminaBundle(named: "sheet", pairCount: 4)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let samplesheet = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(
            samples: try ViralReconInputResolver.makeSamples(from: try ViralReconInputResolver.resolveInputs(from: [bundle.bundleURL])),
            in: staging
        )
        XCTAssertEqual(rows(try String(contentsOf: samplesheet, encoding: .utf8)), [["sheet", canonical(bundle.fastqURL.path), ""]])
        let runBundleURL = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)

        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", runBundleURL.path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--quiet",
        ]).run()

        let launch = try XCTUnwrap(runner.launches.first)
        let launched = rows(launch.samplesheetText)
        XCTAssertEqual(launched.count, 1)
        XCTAssertTrue(launched[0][1].hasSuffix("sheet_R1.fastq.gz"))
        XCTAssertTrue(launched[0][2].hasSuffix("sheet_R2.fastq.gz"))
        XCTAssertEqual(launch.fastqRecordCounts, [4, 4])
        // The caller's samplesheet is what the manifest records, untouched.
        XCTAssertEqual(try NFCoreRunBundleStore.read(from: runBundleURL).params["input"], samplesheet.path)
        XCTAssertEqual(rows(try String(contentsOf: samplesheet, encoding: .utf8)), [["sheet", canonical(bundle.fastqURL.path), ""]])
    }

    func testPairedRowsAndSingleEndRowsAreLaunchedUnchanged() async throws {
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        let runner = CapturingNextflowRunner()
        RunSubcommand.nfCoreWorkflowProcessRunner = runner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        let solo = root.appendingPathComponent("solo.fastq")
        try (1...3).map { "@solo\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined().write(to: solo, atomically: true, encoding: .utf8)
        let soloGz = try gzipInPlace(solo)
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nP,/tmp/P_R1.fastq.gz,/tmp/P_R2.fastq.gz\nS,\(soloGz.path),\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        let runBundleURL = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)

        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", runBundleURL.path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--quiet",
        ]).run()

        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertTrue(launch.arguments.contains(samplesheet.path), "no split, so the caller's samplesheet is launched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runBundleURL.appendingPathComponent("inputs/\(ViralReconReadPairing.pairedSamplesheetFilename)").path))
        let decisions = try XCTUnwrap(ViralReconReadPairing.loadDecisions(
            from: runBundleURL.appendingPathComponent("inputs/\(ViralReconReadPairing.decisionsFilename)")
        ))
        XCTAssertEqual(decisions.map(\.handling), [.asPairs, .asSingle])
        XCTAssertEqual(decisions.map(\.layout), [.pairedFiles, .singleEnd])
    }

    // MARK: - prepare-only records the decision without splitting

    func testPrepareOnlyRecordsThePlannedSplitWithoutRunningIt() async throws {
        let bundle = try writeInterleavedIlluminaBundle(named: "planned", pairCount: 3)
        let runBundleURL = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", bundle.bundleURL.path,
            "--results-dir", root.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", runBundleURL.path,
            "--version", "3.0.0",
            "--prepare-only",
            "--quiet",
        ]).run()

        let decisions = try XCTUnwrap(ViralReconReadPairing.loadDecisions(
            from: runBundleURL.appendingPathComponent("inputs/\(ViralReconReadPairing.decisionsFilename)")
        ))
        XCTAssertEqual(decisions.map(\.handling), [.splitToR1R2])
        XCTAssertNil(decisions[0].pairCount, "prepare-only plans the split; only a run performs it")
        XCTAssertNil(decisions[0].splitR1URL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runBundleURL.appendingPathComponent("inputs/\(ViralReconReadPairing.pairedSamplesheetFilename)").path))
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: runBundleURL))
        XCTAssertNotNil(provenance.options.explicit["readPairing"])
    }

    // MARK: - Input validation

    func testSamplesheetAndBundleInputsCannotBeMixed() async throws {
        let bundle = try writeInterleavedIlluminaBundle(named: "mixed-inputs", pairCount: 1)
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\n".write(to: samplesheet, atomically: true, encoding: .utf8)

        let command = try RunSubcommand.parse([
            "nf-core/viralrecon",
            "--input", samplesheet.path,
            "--input", bundle.bundleURL.path,
            "--results-dir", root.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true).path,
            "--prepare-only",
            "--quiet",
        ])
        do {
            try await command.run()
            XCTFail("expected the mixed inputs to be refused")
        } catch let error as CLIError {
            XCTAssertTrue(error.localizedDescription.contains("not both"), error.localizedDescription)
        }
    }

    func testPlatformParameterMustAgreeWithTheBundle() async throws {
        let bundle = try writeInterleavedIlluminaBundle(named: "platform", pairCount: 1)
        let command = try RunSubcommand.parse([
            "nf-core/viralrecon",
            "--input", bundle.bundleURL.path,
            "--results-dir", root.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true).path,
            "--param", "platform=nanopore",
            "--prepare-only",
            "--quiet",
        ])
        do {
            try await command.run()
            XCTFail("expected the platform mismatch to be refused")
        } catch let error as CLIError {
            XCTAssertTrue(error.localizedDescription.contains("platform=nanopore"), error.localizedDescription)
        }
    }
}
