// FASTQStorageStepBgzipShimTests.swift - Clumpify calls the bgzip on its PATH, as the writer probe says (CHTC lane K2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The writer probe (BIO ruling N3) says BBTools 40.02 writes BGZF through the first `bgzip` on its `PATH` that answers
// `bgzip -h`, calls it as `bgzip -c -f -l <zl> -@ <threads>`, and writes with its own BGZF writer when none answers.
// The probe's unit test proves that against a fake launcher only. This test starts the real `clumpify.sh` with a
// logging `bgzip` shim first on `PATH` and reads what BBTools called, so the probe's two claims, the exit status that
// counts as an answer and the thread count in the argv, rest on the tool and not on a guess.

import XCTest
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport

/// Starts every tool by its path with the environment the step gives it, so a shim first on `PATH` stays first.
/// `NativeToolRunner.run` would rebuild `PATH` with the bbtools `bin` ahead of the caller's, which puts a shim behind
/// the real `bgzip`.
private struct StepEnvironmentLauncher: PortableToolLauncher {
    typealias Record = PortableToolRun

    func executableURL(for tool: PortableStorageTool) async throws -> URL {
        try await NativeToolRunner.shared.toolPath(for: NativeToolStorageLauncher.nativeTool(tool))
    }

    func run(_ launch: PortableToolLaunch) async throws -> PortableToolOutcome {
        let executable: URL
        if let named = launch.executable {
            executable = named
        } else {
            executable = try await executableURL(for: launch.tool)
        }
        let startTime = Date()
        let result = try await NativeToolRunner.shared.runProcess(
            executableURL: executable,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory,
            environment: launch.environment,
            timeout: launch.timeout,
            toolName: NativeToolStorageLauncher.recordName(launch.tool)
        )
        return PortableToolOutcome(
            exitCode: result.exitCode, isSuccess: result.isSuccess, stdout: result.stdout, stderr: result.stderr,
            startTime: startTime, endTime: Date()
        )
    }

    func record(_ run: PortableToolRun) async -> PortableToolRun { run }
}

final class FASTQStorageStepBgzipShimTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageBgzipShim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func requireManagedTools() async throws {
        for tool in [NativeTool.clumpify, .bgzip] {
            guard (try? await NativeToolRunner.shared.toolPath(for: tool)) != nil else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
                throw XCTSkip("unreachable")
            }
        }
    }

    /// One interleaved file of `count` pairs of 100 bases, named `pair<N>/1` and `pair<N>/2` alternately, so the step
    /// scans it as an interleaved file and counts the stored file against the scan.
    private func writeInterleaved(in root: URL, count: Int) throws -> URL {
        var state: UInt64 = 20_261_023
        func base() -> Character {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return ["A", "C", "G", "T"][Int(state >> 62)]
        }
        let quality = String(repeating: "I", count: 100)
        var text = ""
        for index in 0..<count {
            for mate in 1...2 {
                text += "@pair\(index)/\(mate)\n\(String((0..<100).map { _ in base() }))\n+\n\(quality)\n"
            }
        }
        let url = root.appendingPathComponent("pairs.fastq")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A `bgzip` that logs its arguments, exits 1 on `-h` when `answersHelp` is false, and otherwise runs the real one.
    private func writeShim(in directory: URL, log: URL, realBgzip: URL, answersHelp: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n"
        if !answersHelp { script += "case \"$1\" in -h) exit 1;; esac\n" }
        script += "exec '\(realBgzip.path)' \"$@\"\n"
        let shim = directory.appendingPathComponent("bgzip")
        try script.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    }

    private func calls(in log: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func truncate(_ log: URL) throws {
        try Data().write(to: log)
    }

    func testClumpifyCallsTheBgzipOnItsPath() async throws {
        try await requireManagedTools()
        let root = try makeRoot()
        let pairs = try writeInterleaved(in: root, count: 40)
        let baseEnvironment = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: "/usr/bin:/bin:/usr/sbin:/sbin"
        )
        let basePath = baseEnvironment["PATH"] ?? ""
        // The real bgzip is read before the shim folder joins PATH, so the shim has something to run.
        guard let realBgzip = PortableStorageStep<StepEnvironmentLauncher>.firstExecutable(
            named: "bgzip", onPath: basePath
        ) else {
            try ToolAvailability.skipOrFail("No bgzip is on the BBTools PATH")
            throw XCTSkip("unreachable")
        }
        let step = PortableStorageStep(launcher: StepEnvironmentLauncher(), childLauncher: ToolProcessChildLauncher())

        // Phase A, the probe and BBTools agree. The probe names the shim and BBTools calls it the way the probe says.
        let answeringDirectory = root.appendingPathComponent("answering", isDirectory: true)
        let answeringLog = root.appendingPathComponent("answering.log")
        try writeShim(in: answeringDirectory, log: answeringLog, realBgzip: realBgzip, answersHelp: true)
        var answeringEnvironment = baseEnvironment
        answeringEnvironment["PATH"] = answeringDirectory.path + ":" + basePath

        let probe = try await step.probeBBToolsWriter(environment: answeringEnvironment, compressionLevel: 4, threads: 2)
        XCTAssertEqual(
            probe.writer,
            .bgzip(
                executable: answeringDirectory.appendingPathComponent("bgzip"),
                arguments: ["-c", "-f", "-l", "4", "-@", "2"]
            )
        )
        XCTAssertEqual(try calls(in: answeringLog), ["-h"])
        try truncate(answeringLog)

        _ = try await step.clumpify(
            .init(
                inputs: [pairs], output: root.appendingPathComponent("stored.fastq.gz"), workingDirectory: root,
                heapGB: 2, threads: 2, qualityBinning: .illumina4, environment: answeringEnvironment,
                compressor: .bgzip
            ),
            progress: { _, _ in }
        )
        let answered = try calls(in: answeringLog)
        XCTAssertTrue(answered.contains("-h"), "shim saw \(answered)")
        XCTAssertTrue(answered.contains("-c -f -l 4 -@ 2"), "shim saw \(answered)")
        for line in answered where line != "-h" {
            XCTAssertTrue(line.hasPrefix("-c -f -l 4 -@ "), "unexpected bgzip call \(line) in \(answered)")
        }

        // Phase B, a bgzip that does not answer. The probe names BBTools' own writer and BBTools never calls bgzip to
        // compress, while the step still ends without error.
        let silentDirectory = root.appendingPathComponent("silent", isDirectory: true)
        let silentLog = root.appendingPathComponent("silent.log")
        try writeShim(in: silentDirectory, log: silentLog, realBgzip: realBgzip, answersHelp: false)
        var silentEnvironment = baseEnvironment
        silentEnvironment["PATH"] = silentDirectory.path + ":" + basePath

        let nativeProbe = try await step.probeBBToolsWriter(
            environment: silentEnvironment, compressionLevel: 4, threads: 2
        )
        XCTAssertEqual(nativeProbe, PortableBBToolsWriterProbe(writer: .nativeBGZF, effectiveCompressionLevel: 4))
        try truncate(silentLog)

        _ = try await step.clumpify(
            .init(
                inputs: [pairs], output: root.appendingPathComponent("stored-native.fastq.gz"),
                workingDirectory: root, heapGB: 2, threads: 2, qualityBinning: .illumina4,
                environment: silentEnvironment, compressor: .bgzip
            ),
            progress: { _, _ in }
        )
        let silent = try calls(in: silentLog)
        XCTAssertTrue(silent.contains("-h"), "shim saw \(silent)")
        XCTAssertFalse(silent.contains { $0.hasPrefix("-c") }, "shim saw \(silent)")
    }
}
