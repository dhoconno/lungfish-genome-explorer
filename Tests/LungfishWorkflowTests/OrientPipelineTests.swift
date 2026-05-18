import XCTest
@testable import LungfishWorkflow

final class OrientPipelineTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrientPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTabbedOutput(at url: URL) throws -> String {
        let longReadID = String(repeating: "A", count: 70_000)
        let content = [
            "\(longReadID)\t+\tref1",
            "read-2\t-\tref1",
            "read-3\t?\t*",
            "read-4\t+\tref2",
        ].joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return longReadID
    }

    func testCreateOrientMapStreamsLargeTabbedOutput() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tabbedOutput = tempDir.appendingPathComponent("orient-results.tsv")
        let longReadID = try makeTabbedOutput(at: tabbedOutput)
        let outputURL = tempDir.appendingPathComponent("orient-map.tsv")

        let pipeline = OrientPipeline()
        let counts = try pipeline.createOrientMap(from: tabbedOutput, to: outputURL)

        XCTAssertEqual(counts.forwardCount, 2)
        XCTAssertEqual(counts.rcCount, 1)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("\(longReadID)\t+\n"))
        XCTAssertTrue(content.contains("read-2\t-\n"))
        XCTAssertFalse(content.contains("read-3\t"))
    }

    func testParseOrientResultsCountsChunkedAndTrailingRecords() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tabbedOutput = tempDir.appendingPathComponent("orient-results.tsv")
        _ = try makeTabbedOutput(at: tabbedOutput)

        let pipeline = OrientPipeline()
        let counts = try pipeline.parseOrientResults(tabbedOutput)

        XCTAssertEqual(counts.forward, 2)
        XCTAssertEqual(counts.rc, 1)
        XCTAssertEqual(counts.unmatched, 1)
    }

    func testRunWritesCanonicalProvenanceSidecar() async throws {
        let fixture = try VsearchFixture()
        defer { fixture.cleanup() }

        let projectURL = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let inputURL = projectURL.appendingPathComponent("reads.fastq")
        let referenceURL = projectURL.appendingPathComponent("reference.fa")
        try "@read-1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = OrientPipeline(runner: fixture.runner)
        let result = try await pipeline.run(
            config: OrientConfig(
                inputURL: inputURL,
                referenceURL: referenceURL,
                wordLength: 11,
                dbMask: "none",
                qMask: "none",
                saveUnoriented: true,
                threads: 2,
                extraArguments: ["--id", "0.97"]
            )
        )

        let sidecarURL = result.orientedFASTQ
            .deletingLastPathComponent()
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish orient")
        XCTAssertEqual(envelope.toolName, "vsearch")
        XCTAssertEqual(envelope.toolVersion, "2.30.5")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertNotNil(envelope.wallTimeSeconds)
        XCTAssertEqual(envelope.options.resolvedDefaults["wordLength"]?.integerValue, 11)
        XCTAssertEqual(envelope.options.resolvedDefaults["dbMask"]?.stringValue, "none")
        XCTAssertEqual(envelope.options.resolvedDefaults["qMask"]?.stringValue, "none")
        XCTAssertEqual(envelope.options.resolvedDefaults["saveUnoriented"]?.booleanValue, true)
        XCTAssertEqual(envelope.options.resolvedDefaults["threads"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.explicit["forwardCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.explicit["reverseComplementedCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.explicit["unmatchedCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["forwardCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["reverseComplementedCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["unmatchedCount"]?.integerValue, 1)
        XCTAssertTrue(envelope.argv.contains("--orient"))
        XCTAssertTrue(envelope.argv.contains(inputURL.path))
        XCTAssertTrue(envelope.files.contains { $0.path == inputURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.files.contains { $0.path == referenceURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.outputs.contains { $0.path == result.orientedFASTQ.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.outputs.contains { $0.path == result.tabbedOutput.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.outputs.contains { $0.path == result.unorientedFASTQ?.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertEqual(envelope.steps.map(\.toolName), ["vsearch"])
        XCTAssertEqual(envelope.steps.first?.exitStatus, 0)
        XCTAssertEqual(envelope.steps.first?.stderr, "vsearch completed\n")

        let legacyRun = envelope.legacyWorkflowRun()
        XCTAssertEqual(legacyRun.parameters["forwardCount"]?.integerValue, 1)
        XCTAssertEqual(legacyRun.parameters["reverseComplementedCount"]?.integerValue, 1)
        XCTAssertEqual(legacyRun.parameters["unmatchedCount"]?.integerValue, 1)
    }

    func testRunWritesFailureProvenanceWhenVsearchFails() async throws {
        let fixture = try VsearchFixture(exitCode: 7)
        defer { fixture.cleanup() }

        let projectURL = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let inputURL = projectURL.appendingPathComponent("reads.fastq")
        let referenceURL = projectURL.appendingPathComponent("reference.fa")
        try "@read-1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = OrientPipeline(runner: fixture.runner)
        do {
            _ = try await pipeline.run(
                config: OrientConfig(
                    inputURL: inputURL,
                    referenceURL: referenceURL,
                    saveUnoriented: true
                )
            )
            XCTFail("Expected vsearch failure")
        } catch OrientPipelineError.vsearchFailed {
            // Expected.
        }

        let workDirs = try FileManager.default.contentsOfDirectory(
            at: projectURL.appendingPathComponent(".tmp", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("lungfish-orient-") }
        let workDir = try XCTUnwrap(workDirs.first)
        let sidecarURL = workDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(envelope.exitStatus, 7)
        XCTAssertEqual(envelope.steps.first?.exitStatus, 7)
        XCTAssertEqual(envelope.steps.first?.stderr, "vsearch failed\n")
        XCTAssertTrue(envelope.steps.first?.argv.contains(inputURL.path) == true)
    }

    func testRunWritesFailureProvenanceWhenVsearchThrowsBeforeExitStatus() async throws {
        let fixture = try VsearchFixture(installExecutable: false)
        defer { fixture.cleanup() }

        let projectURL = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let inputURL = projectURL.appendingPathComponent("reads.fastq")
        let referenceURL = projectURL.appendingPathComponent("reference.fa")
        try "@read-1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = OrientPipeline(runner: fixture.runner)
        do {
            _ = try await pipeline.run(
                config: OrientConfig(
                    inputURL: inputURL,
                    referenceURL: referenceURL,
                    saveUnoriented: true
                )
            )
            XCTFail("Expected vsearch launch failure")
        } catch OrientPipelineError.vsearchFailed {
            // Expected.
        }

        let workDirs = try FileManager.default.contentsOfDirectory(
            at: projectURL.appendingPathComponent(".tmp", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("lungfish-orient-") }
        let workDir = try XCTUnwrap(workDirs.first)
        let sidecarURL = workDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(envelope.exitStatus, -1)
        XCTAssertEqual(envelope.steps.first?.exitStatus, -1)
        XCTAssertTrue(envelope.steps.first?.stderr?.contains("vsearch") == true)
        XCTAssertTrue(envelope.steps.first?.argv.contains(inputURL.path) == true)
        XCTAssertTrue(envelope.outputs.isEmpty)
        XCTAssertTrue(envelope.steps.first?.outputs.isEmpty == true)
    }

    func testRunWritesFailureProvenanceWhenOrientResultsCannotBeParsed() async throws {
        let fixture = try VsearchFixture(writeTabbedOutput: false)
        defer { fixture.cleanup() }

        let projectURL = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let inputURL = projectURL.appendingPathComponent("reads.fastq")
        let referenceURL = projectURL.appendingPathComponent("reference.fa")
        try "@read-1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = OrientPipeline(runner: fixture.runner)
        do {
            _ = try await pipeline.run(
                config: OrientConfig(
                    inputURL: inputURL,
                    referenceURL: referenceURL,
                    saveUnoriented: true
                )
            )
            XCTFail("Expected orient result parsing failure")
        } catch {
            // Expected.
        }

        let workDirs = try FileManager.default.contentsOfDirectory(
            at: projectURL.appendingPathComponent(".tmp", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("lungfish-orient-") }
        let workDir = try XCTUnwrap(workDirs.first)
        let sidecarURL = workDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(envelope.exitStatus, -1)
        XCTAssertEqual(envelope.steps.first?.exitStatus, 0)
        XCTAssertTrue(envelope.stderr?.isEmpty == false)
        XCTAssertTrue(envelope.steps.first?.argv.contains(inputURL.path) == true)
        let outputPaths = envelope.outputs.map(\.path)
        XCTAssertTrue(outputPaths.contains { $0.hasSuffix("oriented.fastq") })
        XCTAssertTrue(outputPaths.contains { $0.hasSuffix("unoriented.fastq") })
        XCTAssertFalse(outputPaths.contains { $0.hasSuffix("orient-results.tsv") })
        let stepOutputPaths = envelope.steps.first?.outputs.map(\.path) ?? []
        XCTAssertTrue(stepOutputPaths.contains { $0.hasSuffix("oriented.fastq") })
        XCTAssertTrue(stepOutputPaths.contains { $0.hasSuffix("unoriented.fastq") })
        XCTAssertFalse(stepOutputPaths.contains { $0.hasSuffix("orient-results.tsv") })
    }

    func testRehydratorRewritesFinalArgvAndAvoidsPathPrefixCollisions() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source", isDirectory: true)
        let finalDir = tempDir.appendingPathComponent("final", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)

        let sourceInput = tempDir.appendingPathComponent("source/input.fastq")
        let finalInput = tempDir.appendingPathComponent("final/input.fastq")
        let sourceOutput = tempDir.appendingPathComponent("source/out.fastq")
        let sourceOutputWithPrefix = tempDir.appendingPathComponent("source/out.fastq.extra")
        let sourceOutputWithUnmappedSuffix = tempDir.appendingPathComponent("source/out.fastq.extra.idx")
        let finalOutput = finalDir.appendingPathComponent("out.fastq")
        let finalOutputWithPrefix = finalDir.appendingPathComponent("out.fastq.extra")
        for url in [
            sourceInput,
            finalInput,
            sourceOutput,
            sourceOutputWithPrefix,
            sourceOutputWithUnmappedSuffix,
            finalOutput,
            finalOutputWithPrefix,
        ] {
            try "data\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let exactArgv = [
            "tool",
            sourceOutputWithPrefix.path,
            "--input=\(sourceInput.path)",
            sourceOutput.path,
            sourceOutputWithUnmappedSuffix.path,
        ]
        let rewrittenArgv = [
            "tool",
            finalOutputWithPrefix.path,
            "--input=\(finalInput.path)",
            finalOutput.path,
            sourceOutputWithUnmappedSuffix.path,
        ]
        let envelope = ProvenanceEnvelope(
            workflowName: "test rehydrate",
            toolName: "tool",
            argv: exactArgv,
            reproducibleCommand: exactArgv.map(shellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: [
                    "input": .file(sourceInput),
                    "string": .string("reads \(sourceInput.path)"),
                    "array": .array([.file(sourceOutput), .string(sourceOutputWithPrefix.path)]),
                    "dictionary": .dictionary(["nested": .string(sourceOutput.path)]),
                    "unmappedPrefix": .string(sourceOutputWithUnmappedSuffix.path),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: "tool"),
            files: [
                ProvenanceFileDescriptor(path: sourceInput.path, format: .fastq, role: .input),
                ProvenanceFileDescriptor(path: sourceOutput.path, format: .fastq, role: .output),
                ProvenanceFileDescriptor(path: sourceOutputWithPrefix.path, format: .fastq, role: .output),
            ],
            outputs: [
                ProvenanceFileDescriptor(path: sourceOutput.path, format: .fastq, role: .output),
                ProvenanceFileDescriptor(path: sourceOutputWithPrefix.path, format: .fastq, role: .output),
            ],
            steps: [
                ProvenanceStep(
                    toolName: "tool",
                    argv: exactArgv,
                    inputs: [ProvenanceFileDescriptor(path: sourceInput.path, format: .fastq, role: .input)],
                    outputs: [
                        ProvenanceFileDescriptor(path: sourceOutput.path, format: .fastq, role: .output),
                        ProvenanceFileDescriptor(path: sourceOutputWithPrefix.path, format: .fastq, role: .output),
                    ],
                    exitStatus: 0
                ),
            ],
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: sourceDir)

        let rehydrated = try ProvenanceRehydrator.rehydrate(
            sourceDirectory: sourceDir,
            finalDirectory: finalDir,
            pathMap: [
                sourceInput.path: finalInput.path,
                sourceOutput.path: finalOutput.path,
                sourceOutputWithPrefix.path: finalOutputWithPrefix.path,
            ]
        )

        XCTAssertEqual(rehydrated.argv, exactArgv)
        let reproducibleArguments = try AdvancedCommandLineOptions.parse(rehydrated.reproducibleCommand)
        XCTAssertTrue(reproducibleArguments.contains(finalOutputWithPrefix.path))
        XCTAssertFalse(reproducibleArguments.contains(sourceOutputWithPrefix.path))
        XCTAssertTrue(reproducibleArguments.contains(sourceOutputWithUnmappedSuffix.path))
        XCTAssertEqual(rehydrated.options.explicit["input"]?.fileValue?.path, finalInput.path)
        XCTAssertEqual(rehydrated.options.explicit["string"]?.stringValue, "reads \(finalInput.path)")
        XCTAssertEqual(rehydrated.options.explicit["array"]?.arrayValue?.first?.fileValue?.path, finalOutput.path)
        XCTAssertEqual(rehydrated.options.explicit["dictionary"]?.dictionaryValue?["nested"]?.stringValue, finalOutput.path)
        XCTAssertEqual(rehydrated.options.explicit["unmappedPrefix"]?.stringValue, sourceOutputWithUnmappedSuffix.path)

        let rawJSON = try jsonObject(at: finalDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        XCTAssertEqual(rawJSON["argv"] as? [String], exactArgv)
        let durableReplayArgv = try XCTUnwrap(rawJSON["durableReplayArgv"] as? [String])
        XCTAssertEqual(durableReplayArgv, rewrittenArgv)
        let stepsJSON = try XCTUnwrap(rawJSON["steps"] as? [[String: Any]])
        XCTAssertEqual(stepsJSON.first?["argv"] as? [String], exactArgv)
        XCTAssertEqual(stepsJSON.first?["durableReplayArgv"] as? [String], durableReplayArgv)
    }
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private struct VsearchFixture {
    let root: URL
    let runner: NativeToolRunner

    init(exitCode: Int32 = 0, installExecutable: Bool = true, writeTabbedOutput: Bool = true) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "vsearch-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let vsearchDir = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/vsearch/bin", isDirectory: true)
        try fm.createDirectory(at: vsearchDir, withIntermediateDirectories: true)

        if installExecutable {
            let scriptURL = vsearchDir.appendingPathComponent("vsearch")
            try Self.scriptBody(
                exitCode: exitCode,
                writeTabbedOutput: writeTabbedOutput
            ).write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func scriptBody(exitCode: Int32, writeTabbedOutput: Bool) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "vsearch v2.30.5"
          exit 0
        fi

        fastqout=""
        tabbedout=""
        notmatched=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --fastqout)
              fastqout="$2"
              shift 2
              ;;
            --tabbedout)
              tabbedout="$2"
              shift 2
              ;;
            --notmatched)
              notmatched="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done

        if [ -n "$fastqout" ]; then
          printf '@read-1\\nACGT\\n+\\nIIII\\n' > "$fastqout"
        fi
        if [ \(writeTabbedOutput ? 1 : 0) -eq 1 ] && [ -n "$tabbedout" ]; then
          printf 'read-1\\t+\\tref\\nread-2\\t-\\tref\\nread-3\\t?\\t*\\n' > "$tabbedout"
        fi
        if [ -n "$notmatched" ]; then
          printf '@read-3\\nTTTT\\n+\\nIIII\\n' > "$notmatched"
        fi
        if [ \(exitCode) -ne 0 ]; then
          printf 'vsearch failed\\n' >&2
          exit \(exitCode)
        fi
        printf 'vsearch completed\\n' >&2
        exit 0
        """
    }
}
