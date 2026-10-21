// GATKVariantCallingParityLiveConformanceTests.swift - The GATK row's replay on real GATK
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M3 (2.9 O5, live tests first). `GATKVariantCallingCLIGUIParityReplayTests` shows the
// GATK row's replay on a stand-in GATK and stays the default. This class runs its sides C and C' on the
// managed gatk-core environment, with the tiny reference and the forty-read BAM of
// `GATKVariantCallPinConformanceTests` (one heterozygous SNP), built here with samtools from SAM text. The
// in-process route and its side A left in Phase 2.12 (lane 12.02, K3).
//
// - Side C is the row's route, the built `lungfish-cli variants call --caller gatk` with this process's conda root.
// - Side C' is the replay of the command side C's row recorded.
//
// C against C' declares nothing. The VCF is the bundle's bgzip `.vcf.gz`, compared under `MaskPolicy.gatk`, so
// the G5 rule (the `##GATKCommandLine` line stays in the compare, its `Date=` is masked and the track's ID in
// its `--output` path is numbered as a file name numbers it) runs on real GATK output. Real GATK adds one
// difference that any two runs show, C against C' included, and no route causes. GATK's log in the execution
// record holds the clock, and the contract masks it nowhere, so the class pins it apart (`isRunToRun`). Only
// the log is run to run. The class also checks that, with the bundle's path, the track's ID and the date set
// aside, both sides' `##GATKCommandLine` line is the same, which shows that the replay ran the command the row
// ran.
//
// The class name holds Conformance, so the unit tier never runs it. Without gatk-core or samtools it skips, and
// under `LUNGFISH_REQUIRE_TOOLS=1` it fails. Run it with `LUNGFISH_REQUIRE_TOOLS=1 LUNGFISH_CONDA_ROOT=<root>
// swift test --skip-update --filter GATKVariantCallingParityLiveConformanceTests`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class GATKVariantCallingParityLiveConformanceTests: XCTestCase {
    typealias StandIn = GATKVariantCallingCLIGUIParityReplayTests

    private var scratch: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "gatk-call-parity-live")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testRealGATKReplaysToTheSameTrackAndRecords() async throws {
        let conda = CondaManager.shared
        do {
            _ = try await conda.toolPath(name: "gatk", environment: "gatk-core")
            _ = try await conda.toolPath(name: "samtools", environment: "samtools")
        } catch {
            try ToolAvailability.skipOrFail("gatk-core or samtools is not installed: \(error)")
        }
        let probed = await GATKInstalledToolVersion.probe(condaManager: conda)
        let version = try XCTUnwrap(probed, "the installed GATK answers --version")
        let inputs = try await makeInputs(conda)
        let environment = ["LUNGFISH_CONDA_ROOT": conda.rootPrefix.path]
        let wrapper = scratch.appendingPathComponent("lungfish-cli-live")
        try StandIn.writeExecutable(
            "#!/bin/sh\nexport LUNGFISH_CONDA_ROOT='\(conda.rootPrefix.path)'\nexec '\(cli.path)' \"$@\"\n", to: wrapper
        )
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .gatk, replayTimeout: .seconds(600), environment: { _ in environment }
        )
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("call", isDirectory: true),
            fixture: { try StandIn.writeFixture($0, from: inputs) },
            sideC: { await StandIn.sideC($0, cli: wrapper) }
        )
        // C against C' declares nothing. The pair still shows the run-to-run difference in GATK's log, which the
        // contract masks nowhere, so the class checks it apart and pins how many there are. The `##GATKCommandLine`
        // line of a VCF agrees across the sides under the policy, so it is not among them.
        let result = try harness.evaluate(StandIn.Case.haplotypeCaller, declared: [], runs: runs)
        XCTAssertEqual(result.failures.filter { !Self.isRunToRun($0) }, [], "only the run-to-run differences")
        XCTAssertEqual(
            result.failures.filter(Self.isRunToRun).count, 2,
            "the pair differs in the execution record's two stderr keys, where GATK's log holds the clock"
        )

        var commandLines: [String] = []
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            let bundle = StandIn.bundleURL(in: run.root)
            let track = try XCTUnwrap(BundleManifest.load(from: bundle).variants.first, "side \(run.side) attaches a track")
            XCTAssertEqual(track.version, version, "side \(run.side)")
            XCTAssertTrue(track.path.hasSuffix(".vcf.gz"), "side \(run.side) keeps the bgzip VCF: \(track.path)")
            // G5 on the bgzip VCF. GATK's command line header is in the file with the version both records name.
            var header = ""
            var calls = 0
            try bundle.appendingPathComponent(track.path).forEachLineAutoDecompressing { line in
                if line.hasPrefix("##GATKCommandLine=<") { header = line }
                if !line.hasPrefix("#"), !line.isEmpty { calls += 1 }
            }
            XCTAssertTrue(header.contains("ID=HaplotypeCaller"), "side \(run.side): \(header)")
            XCTAssertTrue(header.contains("Version=\"\(version)\""), "side \(run.side): \(header)")
            XCTAssertTrue(header.contains("Date=\""), "side \(run.side): \(header)")
            XCTAssertGreaterThanOrEqual(calls, 1, "side \(run.side): GATK calls the heterozygous SNP")
            commandLines.append(Self.commandLineAsideFromTheRun(header, bundle: bundle))
        }
        XCTAssertEqual(
            Set(commandLines).count, 1,
            "with the bundle's path, the track's ID and the date set aside, both sides ran one GATK command:\n"
                + commandLines.joined(separator: "\n")
        )
    }

    /// A difference that any two runs of real GATK show, whatever their routes. Only GATK's log is run to run. It
    /// sits in the execution record's `stderr` and `steps[0].stderr` and holds the clock, and the contract masks it
    /// nowhere. The record is the run's own file, `variants/gatk/<track>.gatk-run.lungfish-provenance.json` since
    /// lane 13.16, and the harness prints it with the track's ID numbered. The pieces of its path come from the
    /// builder the writer uses. The `##GATKCommandLine` line is not run to run, since the policy masks its date
    /// and numbers its track ID (G5 and A50 M3 ruling R2). A new mask needs a reviewed change to the "Same result"
    /// table of CLI-EQUIVALENCE.md.
    nonisolated static func isRunToRun(_ failure: String) -> Bool {
        let line = failure.split(separator: "\n").first.map(String.init) ?? failure
        let record = runRecordPathAroundTheTrackID()
        return [" at stderr", " at steps[0].stderr"].contains { key in
            line.contains(record.before) && line.hasSuffix(record.after + key)
        }
    }

    /// The execution record's path inside a bundle as `GATKPipelineExecutionRequest.bundleRunRecordURL` builds it,
    /// split around the track's ID. `before` is the folder and `after` is the ending of the file name.
    nonisolated static func runRecordPathAroundTheTrackID() -> (before: String, after: String) {
        let bundle = URL(fileURLWithPath: "/bundle", isDirectory: true)
        let record = GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: "TRACKID", inBundle: bundle)
        let pieces = String(record.path.dropFirst(bundle.path.count)).components(separatedBy: "TRACKID")
        return (pieces.first ?? "", pieces.last ?? "")
    }

    /// The `##GATKCommandLine` line with the bundle's path, the track's ID and the date set aside.
    nonisolated static func commandLineAsideFromTheRun(_ line: String, bundle: URL) -> String {
        var text = line
        for path in [bundle.resolvingSymlinksInPath().path, bundle.path] {
            text = text.replacingOccurrences(of: path, with: "<BUNDLE>")
        }
        for pattern in [#"vc-[0-9a-fA-F-]{36}"#, #"Date="[^"]*""#] {
            text = text.replacingOccurrences(of: pattern, with: "<RUN>", options: .regularExpression)
        }
        return text
    }

    // MARK: - The tiny inputs

    /// 300 bases from a fixed generator, as `GATKPinBundle.referenceSequence` writes them.
    nonisolated static let referenceSequence: String = {
        var state: UInt32 = 12345
        let bases = Array("ACGT")
        return String((0..<300).map { _ -> Character in
            state = state &* 1_664_525 &+ 1_013_904_223
            return bases[Int((state >> 24) & 3)]
        })
    }()

    /// Forty reads of 100 bases that all cover position 150, half with another base, on both strands.
    nonisolated static func samText() -> String {
        let reference = Array(referenceSequence)
        let alternate: Character = reference[149] == "A" ? "C" : "A"
        var lines = ["@HD\tVN:1.6\tSO:coordinate", "@SQ\tSN:chr1\tLN:300", "@RG\tID:rg1\tSM:sample\tPL:ILLUMINA\tLB:lib1"]
        for index in 0..<40 {
            let start = 51 + index * 2
            var bases = Array(reference[(start - 1)..<(start + 99)])
            if index % 2 == 1 { bases[150 - start] = alternate }
            let flag = index % 4 < 2 ? 0 : 16
            let quality = String(repeating: "I", count: 100)
            lines.append("read\(index)\t\(flag)\tchr1\t\(start)\t60\t100M\t*\t0\t0\t\(String(bases))\t\(quality)\tRG:Z:rg1")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The reference with its index and sequence dictionary and the BAM with its index, under the names
    /// `writeFixture` copies.
    private func makeInputs(_ conda: CondaManager) async throws -> URL {
        let inputs = scratch.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let reference = inputs.appendingPathComponent("genome.fasta")
        try Data(">chr1\n\(Self.referenceSequence)\n".utf8).write(to: reference)
        try Data("chr1\t300\t6\t300\t301\n".utf8).write(to: inputs.appendingPathComponent("genome.fasta.fai"))
        let sam = scratch.appendingPathComponent("sample.sam")
        try Data(Self.samText().utf8).write(to: sam)
        let bam = inputs.appendingPathComponent("test.paired_end.sorted.bam")
        let steps: [(tool: String, arguments: [String], environment: String)] = [
            ("gatk", ["CreateSequenceDictionary", "-R", reference.path, "-O", inputs.appendingPathComponent("genome.dict").path], "gatk-core"),
            ("samtools", ["view", "-b", "-o", bam.path, sam.path], "samtools"),
            ("samtools", ["index", bam.path], "samtools"),
        ]
        for step in steps {
            let run = try await conda.runTool(
                name: step.tool, arguments: step.arguments, environment: step.environment, timeout: 600
            )
            XCTAssertEqual(run.exitCode, 0, "\(step.tool) \(step.arguments[0]): \(run.stderr)")
        }
        return inputs
    }
}
