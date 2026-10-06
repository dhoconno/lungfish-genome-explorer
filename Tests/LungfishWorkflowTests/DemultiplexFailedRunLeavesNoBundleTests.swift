// DemultiplexFailedRunLeavesNoBundleTests.swift - A failed demultiplex run leaves nothing that looks like a finished barcode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The pipeline made every barcode folder before the heavy work, wrote a
// rebuild group's previews while later groups still ran, and wrote the
// derived manifests last, with no cleanup when a step threw. A failed run
// left folders holding `preview.fastq` and no manifest, and a later command
// read such a folder as a physical bundle whose reads were its 1,000-read
// preview (Phase 1 re-review round 2 N1, L5 item 4). A physical run left the
// FASTQ cutadapt wrote for a barcode in a folder of a run that never ended.

import Foundation
import os
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

private struct RootReadFailure: Error {}

/// The pipeline's root reader, failing from the `failingOpen`th open of a root file on.
private final class FailingRootSource: Sendable {
    private let opens = OSAllocatedUnfairLock(initialState: 0)
    private let failingOpen: Int

    init(failingOpen: Int) {
        self.failingOpen = failingOpen
    }

    var source: VirtualRootRecordSource {
        { url in
            let open = self.opens.withLock { count -> Int in
                count += 1
                return count
            }
            guard open < self.failingOpen else {
                return AsyncThrowingStream { $0.finish(throwing: RootReadFailure()) }
            }
            return DemultiplexingPipeline.fileRootRecordSource(url)
        }
    }
}

final class DemultiplexFailedRunLeavesNoBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-failed-run")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Eleven barcodes, 12-mers at least seven mismatches apart.
    private static let barcodes: [(id: String, sequence: String)] = [
        ("BC01", "TTCGTGACAGAC"), ("BC02", "GACTCAAGCCAA"), ("BC03", "TTGCTGGATTGT"), ("BC04", "TAGCATGTCGGC"),
        ("BC05", "TGCTATCATCTC"), ("BC06", "ACGTAAGGCGCA"), ("BC07", "CACAGTGCCAAG"), ("BC08", "GCTACGCTCCAT"),
        ("BC09", "AGTCTGCCTCCT"), ("BC10", "TGAGGTCCAGTG"), ("BC11", "GGACCGTATGCA"),
    ]

    private static func fastq(_ reads: [(name: String, sequence: String)]) -> String {
        reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
    }

    /// The items of `folder` a listing shows, every barcode bundle among them.
    private func visibleItems(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Every `preview.fastq` under `folder`, hidden folders included.
    private func previews(under folder: URL) -> [URL] {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "preview.fastq" }
    }

    /// Twelve virtual bundles fall in two rebuild groups of eight. The root
    /// read fails in the second group's pass, after the first group's
    /// previews were written.
    func testAVirtualRunThatFailsInItsSecondRebuildGroupLeavesNoBarcodeFolder() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Imports/multi.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let insert = "GATTACAGATTACAGATTACAGATTACA"
        func chunk(_ index: Int) -> [(name: String, sequence: String)] {
            Self.barcodes.map { (name: "c\(index)_\($0.id)", sequence: $0.sequence + insert) }
                + [(name: "c\(index)_none", sequence: "CCCCCCCCCCCC" + insert)]
        }
        try Self.fastq(chunk(0)).write(to: chunks.appendingPathComponent("run_0.fastq"), atomically: true, encoding: .utf8)
        try Self.fastq(chunk(1)).write(to: chunks.appendingPathComponent("run_1.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        let joined = project.appendingPathComponent("joined.fastq")
        try Self.fastq(chunk(0) + chunk(1)).write(to: joined, atomically: true, encoding: .utf8)
        let kitCSV = root.appendingPathComponent("barcodes.csv")
        try ("id,sequence\n" + Self.barcodes.map { "\($0.id),\($0.sequence)\n" }.joined())
            .write(to: kitCSV, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: kitCSV, name: "Custom")

        // Each pass opens run_0 and run_1, so the third open starts the second group's pass.
        let failing = FailingRootSource(failingOpen: 3)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)
        do {
            _ = try await DemultiplexingPipeline(runner: .shared, rootRecordSource: failing.source).run(
                config: DemultiplexConfig(
                    inputURL: joined,
                    sourceBundleURL: bundle,
                    barcodeKit: kit,
                    outputDirectory: output,
                    barcodeLocation: .fivePrime,
                    errorRate: 0.15,
                    trimBarcodes: false,
                    unassignedDisposition: .keep,
                    engine: .cutadapt,
                    rootBundleURL: bundle,
                    rootFASTQFilename: "chunks/run_0.fastq",
                    inputSequenceFormat: .fastq
                ),
                progress: { _, _ in }
            )
            XCTFail("the root read fails in the second rebuild group")
        } catch is RootReadFailure {
        }

        XCTAssertEqual(visibleItems(in: output), [], "a failed run leaves no barcode folder in the output")
        XCTAssertEqual(previews(under: output), [], "and no preview a later command could read as a barcode's reads")
    }

    /// A physical run moves cutadapt's FASTQ into its barcode folder and then
    /// counts it. Here the count fails.
    func testAPhysicalRunWhoseStatisticsFailLeavesNoBarcodeFolder() async throws {
        let runnerRoot = root.appendingPathComponent("managed-tools", isDirectory: true)
        try makeManagedTool(root: runnerRoot, environment: "cutadapt", executable: "cutadapt", script: """
            #!/bin/sh
            case "$1" in
              --version|version) echo "cutadapt 5.2"; exit 0 ;;
            esac
            output_pattern=""
            json_path=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) output_pattern="$2"; shift 2 ;;
                --json) json_path="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            sample_output=$(printf '%s' "$output_pattern" | sed 's/{name}/BC01/g')
            mkdir -p "$(dirname "$sample_output")"
            printf 'payload of a barcode that is never finished\\n' > "$sample_output"
            [ -n "$json_path" ] && printf '{}' > "$json_path"
            exit 0
            """)
        try makeManagedTool(root: runnerRoot, environment: "seqkit", executable: "seqkit", script: """
            #!/bin/sh
            case "$1" in
              version|--version) echo "seqkit v2.10.0" ;;
              stats) echo "seqkit stats failed" >&2; exit 1 ;;
              *) echo "unexpected seqkit invocation: $*" >&2; exit 1 ;;
            esac
            """)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("input.fastq")
        try Self.fastq([(name: "r1", sequence: "GTATCGTCGTGATTACA")]).write(to: input, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("demux-out", isDirectory: true)
        let kit = BarcodeKitDefinition(
            id: "custom-single-failing-stats",
            displayName: "Custom Single Failing Stats",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "GTATCGTCGT")]
        )

        do {
            _ = try await DemultiplexingPipeline(
                runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot, appIdentity: .preview)
            ).run(
                config: DemultiplexConfig(
                    inputURL: input,
                    barcodeKit: kit,
                    outputDirectory: output,
                    barcodeLocation: .fivePrime,
                    errorRate: 0.0,
                    minimumOverlap: 10,
                    trimBarcodes: true,
                    threads: 1
                ),
                progress: { _, _ in }
            )
            XCTFail("the statistics of BC01 fail")
        } catch is DemultiplexError {
        }

        XCTAssertEqual(visibleItems(in: output), [], "a failed run leaves no barcode folder in the output")
    }

    private func makeManagedTool(root: URL, environment: String, executable: String, script: String) throws {
        let directory = root.appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(executable)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
