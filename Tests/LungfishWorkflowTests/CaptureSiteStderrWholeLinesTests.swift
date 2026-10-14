// CaptureSiteStderrWholeLinesTests.swift - A stderr capture that hit its limit reaches a caller as whole lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 FXS34, SWIFT's ruling R2 on S34. A ToolProcess capture over its limit keeps the last bytes of the
// stream, so it starts inside a line. On a tool that prints a project path on every line, that start is folder
// names without their root, which the sanitizer that rewrites paths cannot recognise. S34 dropped that first
// line where NativeToolRunner builds its result. These tests pin the five other sites that turn a
// ToolProcessResult into text that reaches a record: ProcessGATKCommandRunner, CondaManager.runTool, the
// streaming stdout runner of ManagedMappingPipeline, ProcessPBAANextflowRunner and ManagedToolSourceInstaller.
// Each runs a fake tool that prints the 5.08 MiB of path lines of NativeToolRunnerToolProcessTests, over the
// 4 MiB that a capture keeps by default.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class CaptureSiteStderrWholeLinesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // A limit that is a multiple of the line width would fall on a line start, and the capture could not tell
        // that from a cut inside a line.
        XCTAssertNotEqual(ToolProcessSpec.defaultStderrCaptureLimit % NoisyStderr.line(0).utf8.count, 0)
    }

    func testProcessGATKCommandRunnerKeepsWholeLinesOfStderrOverTheDefaultLimit() async throws {
        let fixture = try NoisyToolFixture()
        defer { fixture.remove() }
        let gatk = try fixture.install("fake_gatk.sh", script: "#!/bin/sh\n\(NoisyStderr.printAll)\n")

        let result = try await ProcessGATKCommandRunner(timeout: 30).run(
            GATKCommand(executable: gatk.path, arguments: [])
        )

        XCTAssertEqual(result.exitCode, 0)
        assertWholeLines(result.stderr, "GATK stderr")
    }

    func testCondaManagerRunToolKeepsWholeLinesOfStderrOverTheDefaultLimit() async throws {
        let fixture = try NoisyToolFixture()
        defer { fixture.remove() }

        let result = try await fixture.condaManager().runTool(name: "fake", environment: "fake", timeout: 30)

        XCTAssertEqual(result.exitCode, 0)
        assertWholeLines(result.stderr, "runTool stderr")
    }

    func testMappingStreamingStdoutKeepsWholeLinesOfStderrOverTheDefaultLimit() async throws {
        let fixture = try NoisyToolFixture()
        defer { fixture.remove() }
        let pipeline = ManagedMappingPipeline(condaManager: try fixture.condaManager())

        let result = try await pipeline.runCondaToolStreamingStdoutForTesting(
            executable: "mapper",
            arguments: [],
            environment: "mapper",
            workingDirectory: fixture.root,
            stdoutURL: fixture.root.appendingPathComponent("mapped.sam"),
            timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0)
        assertWholeLines(result.stderr, "mapper stderr")
    }

    func testPBAANextflowRunnerKeepsWholeLinesOfStderrOverTheDefaultLimit() async throws {
        let fixture = try NoisyToolFixture()
        defer { fixture.remove() }
        let nextflow = try fixture.install("fake_nextflow.sh", script: "#!/bin/sh\n\(NoisyStderr.printAll)\n")
        let runner = ProcessPBAANextflowRunner(homeDirectoryProvider: { fixture.root }, appIdentity: .preview)

        let result = try await runner.runProcess(
            executableURL: nextflow,
            arguments: [],
            workingDirectory: fixture.root,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(result.exitCode, 0)
        assertWholeLines(result.stderr, "Nextflow stderr")
    }

    func testManagedToolSourceInstallerRunKeepsWholeLinesOfStderrOverTheDefaultLimit() async throws {
        let fixture = try NoisyToolFixture()
        defer { fixture.remove() }
        let build = try fixture.install("fake_build.sh", script: "#!/bin/sh\n\(NoisyStderr.printAll)\n")

        let result = try await ManagedToolSourceInstaller.run(
            ManagedToolSourceInstaller.ProcessInvocation(executable: build, arguments: []),
            timeout: 30
        )

        XCTAssertEqual(result.exitStatus, 0)
        assertWholeLines(result.stderr, "build stderr")
    }

    /// Compares the stderr a site returned with the lines the default capture keeps whole, without printing
    /// either text, which are megabytes long. The message names the start of each, which is where a fragment shows.
    private func assertWholeLines(
        _ actual: String, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = NoisyStderr.lines(NoisyStderr.keptLines)
        XCTAssertTrue(
            actual == expected,
            "\(label) is \(actual.utf8.count) bytes starting \(actual.prefix(90).debugDescription), "
                + "expected \(expected.utf8.count) bytes starting \(expected.prefix(90).debugDescription)",
            file: file, line: line
        )
    }
}

/// The stderr of the fake tools. It mirrors `NativeToolRunnerToolProcessTests`, whose private helpers these
/// tests cannot reach: 48,000 lines of 111 bytes, a project path on every line.
private enum NoisyStderr {
    static let root = "/Users/analyst/Projects/Study.lungfish/Analyses/classify-1"
    static let lineCount = 48_000

    static func line(_ index: Int) -> String {
        String(format: "[bam_sort] %06ld writing to %@/part-%06ld.sorted.bam\n", index, root, index)
    }

    static func lines(_ range: Range<Int>) -> String {
        range.map(line).joined()
    }

    /// The lines the default capture keeps whole, which are the last ones that fit. The limit is not a multiple
    /// of the line width, so the capture also holds the end of the line before them.
    static var keptLines: Range<Int> {
        (lineCount - ToolProcessSpec.defaultStderrCaptureLimit / line(0).utf8.count)..<lineCount
    }

    /// The shell command of a tool that prints the lines 0 up to `lineCount` to stderr and nothing else.
    static var printAll: String {
        "/usr/bin/awk -v n=\(lineCount) 'BEGIN { for (i = 0; i < n; i++) printf \"[bam_sort] %06d writing to \(root)/part-%06d.sorted.bam\\n\", i, i > \"/dev/stderr\" }'"
    }
}

/// A temporary folder that holds fake tools.
private struct NoisyToolFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-site-stderr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func install(_ name: String, script: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A conda manager whose micromamba answers its version probe and then runs as the noisy tool.
    func condaManager() throws -> CondaManager {
        let micromamba = try install("micromamba", script: """
            #!/bin/sh
            if [ "$1" = '--version' ]; then echo 2.0.5-0; exit 0; fi
            \(NoisyStderr.printAll)
            """)
        return CondaManager(
            rootPrefix: root.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
