// DemultiplexLongReadTimesTwoPinTests.swift - The kept side of cutadapt's --times 2 is pinned in the argument list
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane PROBES-A, row DEMUX-LONGREAD-TIMES2. A single-end kit on a platform whose reads can be reversed
// (ONT Rapid Barcoding, ONT 16S Rapid Amplicon, M13 Universal Primers) is searched with `--times 2`, and a short-read
// single-index kit is not (`DemultiplexingPipeline.buildCutadaptArguments`, BIO-DEMUX-PARITY). Nothing pinned the
// kept side. A stand-in cutadapt prints the argument list and the adapter file it was given, then fails, so the run
// needs no real tool. BIO ruled that --times 2 stays (BIO-PROBES-A Q2, backlog row DEMUX-LONGREAD-TIMES2, S3). On a
// fixture of ONT Rapid Barcoding 24, one search sends half of the A+B chimeras to A carrying B's bases, and
// --times 2 sends them to B with B's bases only. The measure was made on the 24-barcode kit. Rapid 12 follows from
// the same construct. For 16S Rapid Amplicon and M13 the pin rests on how their reads are built and was not
// measured. A change that drops --times 2 flips the first test and needs a new BIO ruling.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexLongReadTimesTwoPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-times-two-pin")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func makeManagedTool(root: URL, environment: String, executable: String, script: String) throws {
        let directory = root.appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(executable)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// What cutadapt received for one run of `kit`: its arguments, and the adapter file's lines.
    private func cutadaptCall(for kit: BarcodeKitDefinition, location: BarcodeLocation = .bothEnds) async throws
        -> (arguments: [String], adapterLines: [String]) {
        let runnerRoot = root.appendingPathComponent("tools-\(kit.id)", isDirectory: true)
        try makeManagedTool(root: runnerRoot, environment: "cutadapt", executable: "cutadapt", script: """
            #!/bin/sh
            case "$1" in
              --version|version) echo "cutadapt 5.2"; exit 0 ;;
            esac
            echo "ARGV $*" >&2
            for argument in "$@"; do
              case "$argument" in
                file:*) sed 's/^/FASTA /' "${argument#file:}" >&2 ;;
              esac
            done
            exit 3
            """)
        let project = root.appendingPathComponent("Project-\(kit.id).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        let bases = String(repeating: "ACGTTGCAGGATCCATTGACC", count: 5)
        try "@r1\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n".write(to: input, atomically: true, encoding: .utf8)
        let config = DemultiplexConfig(
            inputURL: input,
            barcodeKit: kit,
            outputDirectory: project.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: location,
            errorRate: 0.15,
            threads: 1,
            engine: .cutadapt
        )
        let pipeline = DemultiplexingPipeline(
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot, appIdentity: .preview),
            cutadaptVersionOverride: "5.2"
        )
        do {
            _ = try await pipeline.run(config: config, progress: { _, _ in })
        } catch DemultiplexError.cutadaptFailed(_, let stderr) {
            let lines = stderr.split(separator: "\n").map(String.init)
            let argv = try XCTUnwrap(lines.first { $0.hasPrefix("ARGV ") }, "the stand-in printed no argument line, got: \(stderr)")
            return (
                argv.dropFirst(5).split(separator: " ").map(String.init),
                lines.filter { $0.hasPrefix("FASTA ") }.map { String($0.dropFirst(6)) }
            )
        }
        XCTFail("the stand-in cutadapt fails, so the run must stop with cutadaptFailed")
        return ([], [])
    }

    private func timesValue(in arguments: [String]) -> String? {
        arguments.firstIndex(of: "--times").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
    }

    func testOntRapidBarcodingOntSixteenSRapidAmpliconAndM13KeepTimesTwo() async throws {
        let m13 = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "m13-universal-primers"))
        let kits: [BarcodeKitDefinition] = [
            BarcodeKitRegistry.ontRapidBarcoding12, BarcodeKitRegistry.ontRapidBarcoding24,
            BarcodeKitRegistry.ont16SRapidAmplicon24, m13,
        ]
        for kit in kits {
            let call = try await cutadaptCall(for: kit)
            XCTAssertEqual(timesValue(in: call.arguments), "2", "\(kit.id) keeps --times 2, got: \(call.arguments)")
            XCTAssertFalse(call.adapterLines.isEmpty, "\(kit.id) gave cutadapt an adapter file")
        }
    }

    func testShortReadSingleIndexKitGetsNoSecondSearch() async throws {
        for kit in [BarcodeKitRegistry.truseqSingleA, BarcodeKitRegistry.truseqSingleB] {
            let call = try await cutadaptCall(for: kit, location: .fivePrime)
            XCTAssertNil(timesValue(in: call.arguments), "\(kit.id) is searched once, got: \(call.arguments)")
        }
    }

    /// The adapter file the run gives cutadapt for ONT Rapid Barcoding 24 holds its 24 barcodes.
    func testOntRapidBarcoding24AdapterFileHoldsItsTwentyFourBarcodes() async throws {
        let call = try await cutadaptCall(for: BarcodeKitRegistry.ontRapidBarcoding24)
        XCTAssertEqual(call.adapterLines.filter { $0.hasPrefix(">") }.count, 24)
    }
}
