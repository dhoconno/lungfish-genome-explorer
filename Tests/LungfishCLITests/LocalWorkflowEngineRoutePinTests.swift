// LocalWorkflowEngineRoutePinTests.swift - A local `workflow run` launches its engine through WorkflowEngineProcess.run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A31 (plan N7, QA 1, census row 24).

import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// The engine route of a local `lungfish-cli workflow run` (census row 24, fact ruling F6).
///
/// The command resolves the engine with ``WorkflowEngineLaunch`` and runs it through ``WorkflowEngineProcess/run(executableURL:arguments:environment:workingDirectory:stdoutFileName:stderrFileName:)``,
/// which gives the engine its output in two log files of its working directory. No workflow runner actor of
/// `LungfishWorkflow` takes part. This pin runs the real ``ProcessLocalWorkflowProcessRunner`` on a stand-in engine, so
/// it holds before `NextflowRunner` goes and on the head that deletes it (A31 passes it on both).
final class LocalWorkflowEngineRoutePinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "local-workflow-engine-route")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A stand-in for the managed Nextflow. It records how it was started, writes the output the run expects, and
    /// prints one line to each stream.
    private func installStandInEngine() throws -> URL {
        let script = root.appendingPathComponent("stand-in-nextflow.sh")
        try """
        #!/bin/sh
        {
          echo "arguments: $*"
          echo "directory: $(pwd -P)"
          if [ -f .lungfish-workflow-stdout.log ]; then echo "stdout-log: present"; fi
          if [ -f .lungfish-workflow-stderr.log ]; then echo "stderr-log: present"; fi
          echo "launch-variable: $STAND_IN_ENGINE"
        } > "$ENGINE_MARKER"
        printf 'stand-in result\\n' > "$RESULT_FILE"
        echo "stand-in engine stdout line"
        echo "stand-in engine stderr line" >&2
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A launch that runs `script` through `/bin/sh`. The argument prefix makes it a non-managed launch, so no managed
    /// launcher is repaired and nothing in the real tool root is touched.
    private func resolver(for script: URL, environment: [String: String]) -> WorkflowEngineLaunchResolver {
        let launch = WorkflowEngineLaunch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            argumentPrefix: [script.path],
            environment: ["PATH": "/usr/bin:/bin"].merging(environment) { _, new in new }
        )
        return { _, _ in launch }
    }

    private func fields(of marker: URL) throws -> [String: String] {
        var fields: [String: String] = [:]
        for line in try String(contentsOf: marker, encoding: .utf8).split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    func testALocalRunLaunchesItsEngineThroughWorkflowEngineProcess() async throws {
        let workflow = root.appendingPathComponent("main.nf")
        try "// invented fixture, never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let input = root.appendingPathComponent("input.txt")
        try "local input".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("results", isDirectory: true)
        let expectedOutput = output.appendingPathComponent("result.txt")
        let request = LocalWorkflowRunRequest(
            workflowURL: workflow, engine: .nextflow, inputURLs: [input], outputDirectory: output,
            expectedOutputURLs: [expectedOutput], params: ["label": "p24"], cpus: 2)
        let bundle = root.appendingPathComponent("run.lungfishrun")
        let marker = root.appendingPathComponent("engine-marker.txt")
        let runner = ProcessLocalWorkflowProcessRunner(
            homeDirectory: root,
            resolveLaunch: resolver(
                for: try installStandInEngine(),
                environment: ["ENGINE_MARKER": marker.path, "RESULT_FILE": expectedOutput.path, "STAND_IN_ENGINE": "p24"]))

        let command = try RunSubcommand.parse(Array(request.cliArguments(bundlePath: bundle).dropFirst(2)) + ["--quiet"])
        try await command.run(localRunner: runner)

        // The engine ran with the argv of the request, in the results folder, on the launch's environment, and with
        // both log files of WorkflowEngineProcess.run open in that folder.
        let seen = try fields(of: marker)
        XCTAssertEqual(seen["arguments"], request.processLaunch.arguments.joined(separator: " "))
        XCTAssertEqual(
            seen["directory"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            output.resolvingSymlinksInPath().path)
        XCTAssertEqual(seen["launch-variable"], "p24")
        XCTAssertEqual(seen["stdout-log"], "present")
        XCTAssertEqual(seen["stderr-log"], "present")
        // The two logs are read and removed when the engine ends.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertTrue(leftovers.contains("result.txt"), "\(leftovers)")
        XCTAssertEqual(leftovers.filter { $0.hasPrefix(".lungfish-workflow-") }, [])
        // What WorkflowEngineProcess.run read comes back as the run bundle's logs, and the exit status as its record.
        let manifest = try LocalWorkflowRunBundleStore.read(from: bundle)
        XCTAssertEqual(manifest.executionStatus, .completed)
        XCTAssertEqual(manifest.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: bundle.appendingPathComponent("logs/stdout.log"), encoding: .utf8),
            "stand-in engine stdout line\n")
        XCTAssertEqual(
            try String(contentsOf: bundle.appendingPathComponent("logs/stderr.log"), encoding: .utf8),
            "stand-in engine stderr line\n")
        XCTAssertNotNil(try ProvenanceEnvelopeReader.loadCanonical(from: bundle))
    }
}
