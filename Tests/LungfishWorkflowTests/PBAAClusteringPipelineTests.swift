import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class PBAAClusteringPipelineTests: XCTestCase {
    func testProcessRunnerUsesManagedNextflowWhenPATHDoesNotContainNextflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-managed-nextflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let managedBin = home
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("conda", isDirectory: true)
            .appendingPathComponent("envs", isDirectory: true)
            .appendingPathComponent("nextflow", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        let managedNextflow = managedBin.appendingPathComponent("nextflow")
        try """
        #!/bin/bash
        set -euo pipefail
        params=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -params-file)
              params="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        outdir="$(/usr/bin/sed -n 's/.*"outdir" : "\\([^"]*\\)".*/\\1/p' "$params" | /usr/bin/sed 's#\\\\/#/#g' | /usr/bin/head -n 1)"
        prefix="$(/usr/bin/sed -n 's/.*"prefix" : "\\([^"]*\\)".*/\\1/p' "$params" | /usr/bin/sed 's#\\\\/#/#g' | /usr/bin/head -n 1)"
        /bin/mkdir -p "$outdir"
        /usr/bin/printf "%s\\n" "$PATH" > "$outdir/launch-path.txt"
        /usr/bin/printf ">cluster1_ReadCount-4\\nACGT\\n" > "$outdir/${prefix}_passed_cluster_sequences.fasta"
        /usr/bin/printf "managed nextflow\\n"
        """.write(to: managedNextflow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: managedNextflow.path
        )

        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "sample"
        )

        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalPATH {
                setenv("PATH", originalPATH, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let runner = ProcessPBAANextflowRunner(homeDirectoryProvider: { home })
        let result = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)

        XCTAssertEqual(try String(contentsOf: result.passedConsensusFASTAURL, encoding: .utf8), ">cluster1_ReadCount-4\nACGT\n")
        XCTAssertEqual(result.rawOutputDirectory.path, request.rawPBAAOutputDirectory.path)
        let launchPath = try String(
            contentsOf: result.rawOutputDirectory.appendingPathComponent("launch-path.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(launchPath.components(separatedBy: ":").contains("/usr/local/bin"))
    }

    func testProcessRunnerTerminatesNextflowProcessPromptlyWhenTaskIsCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-cancel-nextflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let managedBin = home
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("conda", isDirectory: true)
            .appendingPathComponent("envs", isDirectory: true)
            .appendingPathComponent("nextflow", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        let managedNextflow = managedBin.appendingPathComponent("nextflow")
        let pidFile = root.appendingPathComponent("nextflow.pid")

        // A stub "nextflow" that reports its own PID, then sleeps far longer
        // than the test should ever have to wait — if cancellation wiring
        // works, the process is killed almost immediately instead of the
        // test blocking until this sleep completes.
        try """
        #!/bin/bash
        /usr/bin/printf "%s" "$$" > "\(pidFile.path)"
        exec /bin/sleep 300
        """.write(to: managedNextflow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: managedNextflow.path
        )

        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "sample"
        )
        let workflowDirectory = root.appendingPathComponent("workflow", isDirectory: true)
        try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)

        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalPATH {
                setenv("PATH", originalPATH, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let runner = ProcessPBAANextflowRunner(homeDirectoryProvider: { home })

        let task = Task {
            try await runner.run(request: request, workflowDirectory: workflowDirectory)
        }

        // Wait for the stub process to actually start and record its PID.
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard FileManager.default.fileExists(atPath: pidFile.path) else {
            task.cancel()
            _ = try? await task.value
            XCTFail("stub nextflow process never wrote its PID file within the deadline")
            return
        }
        let pidString = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(
            Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
            "pid file contents were not a valid PID: \(pidString)"
        )
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: pid), "stub nextflow process should have started")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate as an error")
        } catch is CancellationError {
            // expected
        } catch {
            // Some paths surface CancellationError wrapped differently; accept
            // any thrown error here since the real assertion is prompt process
            // termination below.
        }

        // The process must be terminated promptly (well under its 300s sleep),
        // proving the Task cancellation was wired to the child process.
        let terminationDeadline = Date().addingTimeInterval(5)
        var stillRunning = ProcessTreeTerminator.processExists(pid: pid)
        while stillRunning, Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            stillRunning = ProcessTreeTerminator.processExists(pid: pid)
        }
        XCTAssertFalse(stillRunning, "nextflow process (pid \(pid)) should be terminated promptly after Task cancellation")
    }

    func testPipelineImportsPassedFastaAsReferenceBundleAndWritesProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-pipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let passed = raw.appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta")
            try ">cluster1\nACGT\n".write(to: passed, atomically: true, encoding: .utf8)
            try ">failed1\nTGCA\n".write(
                to: raw.appendingPathComponent("\(request.prefix)_failed_cluster_sequences.fasta"),
                atomically: true,
                encoding: .utf8
            )
            try "read_id\tcluster\nr1\tcluster1\n".write(
                to: raw.appendingPathComponent("\(request.prefix)_read_info.txt"),
                atomically: true,
                encoding: .utf8
            )
            try Data([0x42, 0x41, 0x4d]).write(
                to: raw.appendingPathComponent("\(request.prefix)_reads_to_clusters.bam")
            )
            return PBAANextflowRunResult(exitCode: 0, stdout: "ok", stderr: "", rawOutputDirectory: raw)
        }

        let output = root.appendingPathComponent("out", isDirectory: true)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: output,
            outputName: "sample",
            threads: 4,
            seed: 7,
            extraArgumentsText: "--min-cluster-read-count 2"
        )

        let result = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)

        XCTAssertEqual(result.referenceBundleURL.pathExtension, "lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.referenceBundleURL.path))
        XCTAssertEqual(result.passedConsensusFASTAURL.lastPathComponent, "sample_passed_cluster_sequences.fasta")

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result.referenceBundleURL))
        XCTAssertEqual(envelope.workflowName, "pbAA Amplicon Clustering")
        XCTAssertEqual(envelope.workflowVersion, PBAAContainerPins.workflowSchemaVersion)
        XCTAssertEqual(envelope.argv, [
            CLICommandIdentity.executableName, "fastq", "pbaa-cluster",
            reads.standardizedFileURL.path,
            "--guide", guide.standardizedFileURL.path,
            "--output-dir", output.standardizedFileURL.path,
            "--output-name", "sample",
            "--threads", "4",
            "--seed", "7",
            "--extra-args", "--min-cluster-read-count 2",
        ])
        XCTAssertEqual(envelope.runtimeIdentity.containerImage, PBAAContainerPins.pbaa.reference)
        XCTAssertEqual(envelope.runtimeIdentity.containerDigest, PBAAContainerPins.pbaa.expectedDigest)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.explicit["extraArguments"], .array([.string("--min-cluster-read-count"), .string("2")]))

        let manifest = try BundleManifest.load(from: result.referenceBundleURL)
        let genomePath = try XCTUnwrap(manifest.genome?.path)
        let finalPayloadURL = result.referenceBundleURL.appendingPathComponent(genomePath)
        XCTAssertTrue(envelope.outputs.contains { $0.path == finalPayloadURL.path })

        let rawEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result.rawOutputDirectory))
        XCTAssertEqual(rawEnvelope.id, envelope.id)
        for expectedRawOutput in [
            "sample_passed_cluster_sequences.fasta",
            "sample_failed_cluster_sequences.fasta",
            "sample_read_info.txt",
            "sample_reads_to_clusters.bam",
        ] {
            let outputURL = result.rawOutputDirectory.appendingPathComponent(expectedRawOutput)
            let descriptor = try XCTUnwrap(envelope.outputs.first { $0.path == outputURL.path })
            XCTAssertNotNil(descriptor.checksumSHA256, expectedRawOutput)
            XCTAssertNotNil(descriptor.fileSize, expectedRawOutput)
            XCTAssertTrue(rawEnvelope.outputs.contains { $0.path == outputURL.path }, expectedRawOutput)
        }
    }

    func testFailedNextflowRunWritesRawOutputProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-failed-nextflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "sample"
        )
        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.rawPBAAOutputDirectory
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            try "partial diagnostic\n".write(
                to: raw.appendingPathComponent("nextflow-partial.log"),
                atomically: true,
                encoding: .utf8
            )
            return PBAANextflowRunResult(
                exitCode: 42,
                stdout: "",
                stderr: "container failed",
                rawOutputDirectory: raw,
                argv: ["nextflow", "run", "main.nf"]
            )
        }

        do {
            _ = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)
            XCTFail("Expected Nextflow failure")
        } catch PBAAClusteringError.nextflowFailed(let status, let stderr) {
            XCTAssertEqual(status, 42)
            XCTAssertEqual(stderr, "container failed")
        }

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: request.rawPBAAOutputDirectory))
        XCTAssertEqual(envelope.workflowName, "pbAA Amplicon Clustering")
        XCTAssertEqual(envelope.exitStatus, 42)
        XCTAssertEqual(envelope.stderr, "container failed")
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "nextflow" && $0.exitStatus == 42 })
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == request.rawPBAAOutputDirectory.appendingPathComponent("nextflow-partial.log").path
        })
    }

    func testProvenanceWriteFailureRemovesImportedReferenceBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-provenance-write-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let output = root.appendingPathComponent("out", isDirectory: true)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: output,
            outputName: "sample"
        )
        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.rawPBAAOutputDirectory
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let passed = raw.appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta")
            try ">cluster1\nACGT\n".write(to: passed, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: raw.appendingPathComponent(ProvenanceRecorder.provenanceFilename, isDirectory: true),
                withIntermediateDirectories: true
            )
            return PBAANextflowRunResult(exitCode: 0, stdout: "ok", stderr: "", rawOutputDirectory: raw)
        }

        do {
            _ = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)
            XCTFail("Expected provenance write failure")
        } catch {
            let bundles = (try? FileManager.default.contentsOfDirectory(
                at: output,
                includingPropertiesForKeys: [.isDirectoryKey]
            ))?
                .filter { $0.pathExtension == "lungfishref" } ?? []
            XCTAssertTrue(bundles.isEmpty, "Final PBAA reference bundle must not remain without provenance: \(bundles)")
        }
    }

    func testPipelineFailsWhenPassedFastaIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: raw.appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta").path,
                contents: Data()
            )
            return PBAANextflowRunResult(exitCode: 0, stdout: "ok", stderr: "", rawOutputDirectory: raw)
        }

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "sample"
        )

        do {
            _ = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)
            XCTFail("Expected empty passed FASTA failure")
        } catch PBAAClusteringError.emptyPassedConsensusFASTA(let url) {
            XCTAssertEqual(url.lastPathComponent, "sample_passed_cluster_sequences.fasta")
        }
    }
}

private struct StubPBAANextflowRunner: PBAANextflowRunning {
    let handler: @Sendable (PBAAClusteringRunRequest, URL) async throws -> PBAANextflowRunResult

    func run(request: PBAAClusteringRunRequest, workflowDirectory: URL) async throws -> PBAANextflowRunResult {
        try await handler(request, workflowDirectory)
    }
}
