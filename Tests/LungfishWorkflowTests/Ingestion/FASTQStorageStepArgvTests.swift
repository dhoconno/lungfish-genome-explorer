// FASTQStorageStepArgvTests.swift - The storage argv stays the same through the portable seam (CHTC lane K2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// K2 moves the storage step behind a launcher seam so the Mac import and the Linux executor run one step. This test
// pins every argv the in-process import records for that step, clumpify, Trim Galore, the reformat.sh interleave and
// the compressor, on a paired and a mixed fixture. It passes at the base and after the move, so the move changes no
// argv, `pigz=t`, `zl=4` and `-eoom` included.

import XCTest
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO
import LungfishTestSupport

final class FASTQStorageStepArgvTests: XCTestCase {

    private let illumina4 = "quantize=0,8,13,22,27,32,37"

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageArgv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// The tools both routes start, each by the path the record names, and the compressor today's order picks.
    private struct Tools {
        var names: [String: String]
        var compressor: NativeTool
    }

    private func requireTools() async throws -> Tools {
        let runner = NativeToolRunner.shared
        var names: [String: String] = [:]
        let scripts: [(NativeTool, String)] = [
            (.clumpify, "<clumpify.sh>"), (.reformat, "<reformat.sh>"), (.trimGalore, "<trim_galore>"),
        ]
        for (tool, name) in scripts {
            guard let url = try? await runner.toolPath(for: tool) else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
                throw XCTSkip("unreachable")
            }
            names[url.path] = name
        }
        let compressor: NativeTool
        if let bgzip = try? await runner.toolPath(for: .bgzip) {
            compressor = .bgzip
            names[bgzip.path] = "<compressor>"
        } else if let pigz = try? await runner.toolPath(for: .pigz) {
            compressor = .pigz
            names[pigz.path] = "<compressor>"
        } else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
            throw XCTSkip("unreachable")
        }
        return Tools(names: names, compressor: compressor)
    }

    /// Writes `count` read pairs of 100 bases with quality 40 into an R1 and an R2 file.
    private func writePaired(in root: URL, count: Int) throws -> (r1: URL, r2: URL) {
        var state: UInt64 = 20_261_022
        func base() -> Character {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return ["A", "C", "G", "T"][Int(state >> 62)]
        }
        var r1 = "", r2 = ""
        let quality = String(repeating: "I", count: 100)
        for index in 0..<count {
            r1 += "@pair\(index)/1\n\(String((0..<100).map { _ in base() }))\n+\n\(quality)\n"
            r2 += "@pair\(index)/2\n\(String((0..<100).map { _ in base() }))\n+\n\(quality)\n"
        }
        let url1 = root.appendingPathComponent("sample_R1.fastq")
        let url2 = root.appendingPathComponent("sample_R2.fastq")
        try r1.write(to: url1, atomically: true, encoding: .utf8)
        try r2.write(to: url2, atomically: true, encoding: .utf8)
        return (url1, url2)
    }

    private func store(
        _ inputs: [URL], pairing: FASTQIngestionConfig.PairingMode, tool: ClumpingTool, in directory: URL
    ) async throws -> FASTQIngestionResult {
        try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: inputs,
                pairingMode: pairing,
                outputDirectory: directory,
                threads: 2,
                deleteOriginals: false,
                qualityBinning: .illumina4,
                compressionLevel: .balanced,
                clumpingTool: tool,
                clumpifyHeapGB: 2
            ),
            progress: { _, _ in }
        )
    }

    /// Every recorded argv with the run folder, the scratch folder names and the tool paths replaced by names.
    private func recordedArgv(_ result: FASTQIngestionResult, root: URL, tools: Tools) throws -> [[String]] {
        let uuid = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )
        return result.provenanceSteps.map { step in
            step.command.map { token in
                if let name = tools.names[token] { return name }
                // Trim Galore's outputs are found by listing its folder, and the listing names the temporary
                // folder through `/private` in some runs and not in others, at the base as after the move.
                let rooted = token
                    .replacingOccurrences(of: "/private" + root.path, with: "<root>")
                    .replacingOccurrences(of: root.path, with: "<root>")
                return uuid.stringByReplacingMatches(
                    in: rooted, range: NSRange(rooted.startIndex..., in: rooted), withTemplate: "<id>"
                )
            }
        }
    }

    private func clumpifyArgv(in input: String, out: String, tail: [String]) -> [String] {
        ["<clumpify.sh>", "in=\(input)", "out=\(out)", "-Xmx2g", "-eoom", "ow=t", "reorder", "groups=auto",
         "pigz=t", "zl=4", "threads=2"] + tail + [illumina4]
    }

    private func compressorArgv(_ tools: Tools, input: String, output: String) -> [String] {
        ["<compressor>", tools.compressor == .bgzip ? "-@" : "-p", "2", "-c", input, ">", output]
    }

    private func trimGaloreArgv(outputDirectory: String, tail: [String]) -> [String] {
        let memoryBytes = ClumpingTool.clumpifyHeapBytes(
            physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        )
        return ["<trim_galore>", "--clumpify", "--compression", "4", "--cores", "2",
                "--memory", "\(max(1, memoryBytes / 1_073_741_824))G", "--output_dir", outputDirectory] + tail
    }

    private func reformatArgv(in1: String, in2: String, out: String) -> [String] {
        ["<reformat.sh>", "in1=\(in1)", "in2=\(in2)", "out=\(out)", "ow=t", "pigz=t", "zl=4", "threads=2",
         "interleaved=t"]
    }

    func testStorageStepArgvUnchangedThroughPortableSeam() async throws {
        let tools = try await requireTools()
        let root = try makeRoot()
        let paired = try writePaired(in: root, count: 40)
        let mixed = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: mixed, pairs: 8, merged: 6)

        let bbPaired = try await store(
            [paired.r1, paired.r2], pairing: .pairedEnd, tool: .bbtools, in: root.appendingPathComponent("bb-paired")
        )
        XCTAssertEqual(try recordedArgv(bbPaired, root: root, tools: tools), [
            clumpifyArgv(
                in: "<root>/sample_R1.fastq", out: "<root>/bb-paired/sample.fastq.gz",
                tail: ["in2=<root>/sample_R2.fastq", "interleaved=t"]
            ),
        ], "bbtools on R1 and R2")

        let bbMixed = try await store(
            [mixed], pairing: .interleaved, tool: .bbtools, in: root.appendingPathComponent("bb-mixed")
        )
        let bbSplit = "<root>/bb-mixed/.clumpify-split-<id>"
        XCTAssertEqual(try recordedArgv(bbMixed, root: root, tools: tools), [
            clumpifyArgv(in: "\(bbSplit)/pairs.fastq", out: "\(bbSplit)/pairs.clumped.fastq", tail: ["interleaved=t"]),
            clumpifyArgv(
                in: "\(bbSplit)/unpaired.fastq", out: "\(bbSplit)/unpaired.clumped.fastq", tail: ["interleaved=f"]
            ),
            compressorArgv(tools, input: "\(bbSplit)/combined.fastq", output: "<root>/bb-mixed/mixed.fastq.gz"),
        ], "bbtools on a file of pairs and merged reads")

        let tgPaired = try await store(
            [paired.r1, paired.r2], pairing: .pairedEnd, tool: .trimGalore, in: root.appendingPathComponent("tg-paired")
        )
        let tgOut = "<root>/tg-paired/trim-galore-<id>"
        XCTAssertEqual(try recordedArgv(tgPaired, root: root, tools: tools), [
            trimGaloreArgv(
                outputDirectory: tgOut, tail: ["--paired", "<root>/sample_R1.fastq", "<root>/sample_R2.fastq"]
            ),
            reformatArgv(
                in1: "\(tgOut)/sample_R1_val_1.fq", in2: "\(tgOut)/sample_R2_val_2.fq",
                out: "<root>/tg-paired/sample.fastq.gz"
            ),
        ], "Trim Galore on R1 and R2")

        let tgMixed = try await store(
            [mixed], pairing: .interleaved, tool: .trimGalore, in: root.appendingPathComponent("tg-mixed")
        )
        let tgSplit = "<root>/tg-mixed/.trim-galore-split-<id>"
        XCTAssertEqual(try recordedArgv(tgMixed, root: root, tools: tools), [
            trimGaloreArgv(
                outputDirectory: "\(tgSplit)/pairs-out",
                tail: ["--paired", "\(tgSplit)/pairs-in/mixed_R1.fastq", "\(tgSplit)/pairs-in/mixed_R2.fastq"]
            ),
            reformatArgv(
                in1: "\(tgSplit)/pairs-out/mixed_R1_val_1.fq", in2: "\(tgSplit)/pairs-out/mixed_R2_val_2.fq",
                out: "\(tgSplit)/pairs.trimmed.fastq"
            ),
            trimGaloreArgv(outputDirectory: "\(tgSplit)/unpaired-out", tail: ["\(tgSplit)/unpaired.fastq"]),
            compressorArgv(tools, input: "\(tgSplit)/combined.fastq", output: "<root>/tg-mixed/mixed.fastq.gz"),
        ], "Trim Galore on a file of pairs and merged reads")
    }
}
