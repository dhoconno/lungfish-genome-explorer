// PortableStorageStepTests.swift - The storage step through a recording launcher, with no tool installed (CHTC lane K2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import Synchronization
import LungfishPortable

/// A launcher that records each launch and stands in for the tools: clumpify copies `in=` to `out=` and the
/// compressor copies its input to its stdout file, so the step's split, join and counts run on real files.
private final class RecordingToolLauncher: PortableToolLauncher {
    typealias Record = PortableToolRun

    let launches = Mutex<[PortableToolLaunch]>([])
    let failingStatus: Int32?

    init(failingStatus: Int32? = nil) {
        self.failingStatus = failingStatus
    }

    func executableURL(for tool: PortableStorageTool) async throws -> URL {
        URL(fileURLWithPath: "/image/bin/\(tool.rawValue)")
    }

    func run(_ launch: PortableToolLaunch) async throws -> PortableToolOutcome {
        launches.withLock { $0.append(launch) }
        let now = Date()
        if let failingStatus {
            return PortableToolOutcome(
                exitCode: failingStatus, isSuccess: false, stdout: "",
                stderr: "java.lang.OutOfMemoryError: Java heap space", startTime: now, endTime: now
            )
        }
        func value(_ key: String) -> String? {
            launch.arguments.first { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
        }
        switch launch.tool {
        case .clumpify:
            try FileManager.default.copyItem(atPath: try XCTUnwrap(value("in=")), toPath: try XCTUnwrap(value("out=")))
        case .bgzip, .pigz:
            try FileManager.default.copyItem(
                atPath: try XCTUnwrap(launch.arguments.last), toPath: try XCTUnwrap(launch.standardOutput).path
            )
        case .reformat, .trimGalore:
            XCTFail("the clumpify route starts no \(launch.tool.rawValue)")
        }
        return PortableToolOutcome(exitCode: 0, isSuccess: true, stdout: "", stderr: "", startTime: now, endTime: now)
    }

    func record(_ run: PortableToolRun) async -> PortableToolRun { run }
}

/// Plain files need no child, so a test that starts one fails.
private struct NoChildLauncher: PortableChildLauncher {
    struct Refused: Error {}
    func start(_ request: PortableChildRequest) throws -> any PortableChild { throw Refused() }
}

final class PortableStorageStepTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableStorageStep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func record(_ name: String) -> String {
        "@\(name)\nACGTACGTAC\n+\nIIIIIIIIII\n"
    }

    private func run(
        in root: URL, inputs: [URL], heapGB: Int = 3, compressor: PortableCompressor? = .bgzip
    ) -> PortableStorageStep<RecordingToolLauncher>.ClumpifyRun {
        PortableStorageStep<RecordingToolLauncher>.ClumpifyRun(
            inputs: inputs, output: root.appendingPathComponent("stored.fastq"), workingDirectory: root,
            heapGB: heapGB, threads: 2, qualityBinning: .illumina4, environment: ["PATH": "/image/bin"],
            compressor: compressor
        )
    }

    func testAutoCompressorKeepsBgzipThenPigzOrder() async {
        let both = await PortableCompressor.firstInstalled { _ in true }
        let onlyPigz = await PortableCompressor.firstInstalled { $0 == .pigz }
        let onlyBgzip = await PortableCompressor.firstInstalled { $0 == .bgzip }
        let neither = await PortableCompressor.firstInstalled { _ in false }
        XCTAssertEqual(both, .bgzip, "bgzip comes first when both are installed")
        XCTAssertEqual(onlyPigz, .pigz)
        XCTAssertEqual(onlyBgzip, .bgzip)
        XCTAssertNil(neither)
        XCTAssertEqual(PortableCompressor.bgzip.streamArguments(threads: 4), ["-@", "4", "-c"])
        XCTAssertEqual(PortableCompressor.pigz.streamArguments(threads: 4), ["-p", "4", "-c"])
    }

    func testMixedFileRunsTwoClumpifyLaunchesAndTheCompressorThroughTheLauncher() async throws {
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        let names = ["merged0", "merged1", "p0/1", "p0/2", "p1/1", "p1/2"]
        try names.map(record).joined().write(to: input, atomically: true, encoding: .utf8)
        let launcher = RecordingToolLauncher()
        let step = PortableStorageStep(launcher: launcher, childLauncher: NoChildLauncher())

        let records = try await step.clumpify(run(in: root, inputs: [input]), progress: { _, _ in })

        let launches = launcher.launches.withLock { $0 }
        XCTAssertEqual(launches.map(\.tool), [.clumpify, .clumpify, .bgzip])
        XCTAssertEqual(records.map(\.executableURL.lastPathComponent), ["clumpify", "clumpify", "bgzip"])
        for launch in launches.prefix(2) {
            XCTAssertEqual(launch.environment?["_JAVA_OPTIONS"], "-Xmx3g")
            XCTAssertEqual(launch.environment?["PATH"], "/image/bin", "the step's PATH is its caller's")
            XCTAssertEqual(launch.workingDirectory, root)
            for flag in ["-Xmx3g", "-eoom", "ow=t", "reorder", "groups=auto", "pigz=t", "zl=4", "threads=2",
                         "quantize=0,8,13,22,27,32,37"] {
                XCTAssertTrue(launch.arguments.contains(flag), "\(flag) in \(launch.arguments)")
            }
        }
        XCTAssertEqual(launches[0].arguments.last(where: { $0.hasPrefix("interleaved=") }), "interleaved=t")
        XCTAssertEqual(launches[1].arguments.last(where: { $0.hasPrefix("interleaved=") }), "interleaved=f")
        XCTAssertEqual(Array(launches[2].arguments.prefix(3)), ["-@", "2", "-c"])
        XCTAssertEqual(launches[2].standardOutput, root.appendingPathComponent("stored.fastq"))
        let stored = try String(contentsOf: root.appendingPathComponent("stored.fastq"), encoding: .utf8)
        XCTAssertEqual(stored.components(separatedBy: "\n").filter { $0.hasPrefix("@") }.count, 6)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["mixed.fastq", "stored.fastq"],
            "the scratch halves go with the run"
        )
    }

    func testClumpifyOutOfMemoryStatusFailsAsOutOfMemory() async throws {
        let root = try makeRoot()
        let r1 = root.appendingPathComponent("a_R1.fastq")
        let r2 = root.appendingPathComponent("a_R2.fastq")
        try record("p0/1").write(to: r1, atomically: true, encoding: .utf8)
        try record("p0/2").write(to: r2, atomically: true, encoding: .utf8)
        let step = PortableStorageStep(
            launcher: RecordingToolLauncher(failingStatus: BBToolsOutOfMemory.exitStatus), childLauncher: NoChildLauncher()
        )
        do {
            _ = try await step.clumpify(run(in: root, inputs: [r1, r2], heapGB: 5), progress: { _, _ in })
            XCTFail("an out-of-memory status must fail the step")
        } catch let error as PortableStorageError {
            guard case .outOfMemory(let tool, let arguments) = error else {
                return XCTFail("expected outOfMemory, got \(error)")
            }
            XCTAssertEqual(tool, "clumpify.sh")
            XCTAssertTrue(arguments.contains("-Xmx5g"))
            XCTAssertTrue(arguments.contains(BBToolsOutOfMemory.flag))
        }
    }

    func testCompressWithNoCompressorRefusesBeforeAnyLaunch() async throws {
        let root = try makeRoot()
        let input = root.appendingPathComponent("plain.fastq")
        try record("r0").write(to: input, atomically: true, encoding: .utf8)
        let launcher = RecordingToolLauncher()
        let step = PortableStorageStep(launcher: launcher, childLauncher: NoChildLauncher())
        do {
            _ = try await step.compress(
                input: input, output: root.appendingPathComponent("out.fastq.gz"), compressor: nil, threads: 2,
                progress: { _, _ in }
            )
            XCTFail("a step with no compressor must refuse")
        } catch let error as PortableStorageError {
            XCTAssertEqual(error, .compressorNotFound)
        }
        XCTAssertTrue(launcher.launches.withLock { $0 }.isEmpty)
    }

    /// The plan and the step read a file's size from `attributesOfItem`. A failed cast reads 0, which would cut the
    /// clumpify and compress deadlines to their floors for a large input, so the Linux tier checks the size is read.
    func testEstimatedUncompressedInputBytesReadsFileSizeOnLinux() throws {
        let root = try makeRoot()
        let plain = root.appendingPathComponent("a.fastq")
        let gzipped = root.appendingPathComponent("b.fastq.gz")
        try Data(repeating: 0x41, count: 10).write(to: plain)
        try Data(repeating: 0x42, count: 10).write(to: gzipped)
        // A plain file counts once and a gzip file four times: 10 + 4 * 10.
        XCTAssertEqual(PortableStoragePlan.estimatedUncompressedInputBytes(for: [plain, gzipped]), 50)
    }
}
