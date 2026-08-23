import XCTest
@testable import LungfishWorkflow

final class TaxTriagePipelineProvenanceSourceTests: XCTestCase {
    func testTaxTriagePipelineRecordsCanonicalRunProvenance() async throws {
        let fixture = try FakeTaxTriageRuntimeFixture()
        defer { fixture.cleanup() }

        let fastqURL = fixture.root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        let outputURL = fixture.root.appendingPathComponent("taxtriage-output", isDirectory: true)
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "S1", fastq1: fastqURL, platform: .illumina)
            ],
            outputDirectory: outputURL,
            profile: "conda",
            revision: "fixture-revision"
        )
        let pipeline = TaxTriagePipeline(
            condaManager: fixture.condaManager,
            homeDirectoryProvider: { fixture.home }
        )

        let result = try await pipeline.run(config: config)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.outputDirectory.standardizedFileURL, outputURL.standardizedFileURL)

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: outputURL))
        XCTAssertEqual(provenance.name, "TaxTriage")
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.parameters["workflow"], .string("taxtriage"))
        XCTAssertEqual(provenance.parameters["sample_count"], .integer(1))
        XCTAssertEqual(provenance.parameters["profile"], .string("conda"))

        let step = try XCTUnwrap(provenance.steps.first { $0.toolName == "TaxTriage" })
        XCTAssertEqual(step.toolVersion, "fixture-revision")
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertNotNil(step.wallTime)
        XCTAssertTrue(step.command.contains { $0.hasSuffix("/micromamba") || $0 == "micromamba" })
        XCTAssertTrue(step.command.contains("nextflow"))
        XCTAssertTrue(step.command.contains("--input"))
        XCTAssertTrue(step.command.contains(config.samplesheetURL.path))
        XCTAssertTrue(step.command.contains("--outdir"))
        XCTAssertTrue(step.command.contains(outputURL.path))
        XCTAssertTrue(step.inputs.contains {
            $0.path == fastqURL.path && $0.format == .fastq && $0.role == .input
                && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertTrue(step.outputs.contains {
            $0.path.hasSuffix("S1.top_report.tsv") && $0.role == .output
                && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertTrue(step.outputs.contains {
            $0.path.hasSuffix("taxtriage-result.json") && $0.role == .output
                && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("download").path),
            "TaxTriage should prune downloaded taxonomy/reference intermediates after collecting durable outputs."
        )
    }

    func testTaxTriagePipelineFailsWhenResultOrProvenanceCannotBeSaved() async throws {
        let fixture = try FakeTaxTriageRuntimeFixture()
        defer { fixture.cleanup() }

        let fastqURL = fixture.root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        let outputURL = fixture.root.appendingPathComponent("taxtriage-output", isDirectory: true)
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "S1", fastq1: fastqURL, platform: .illumina)
            ],
            outputDirectory: outputURL,
            profile: "conda",
            revision: "fixture-revision"
        )
        let pipeline = TaxTriagePipeline(
            condaManager: fixture.condaManager,
            homeDirectoryProvider: { fixture.home }
        )

        setenv("LUNGFISH_TAXTRIAGE_FAKE_READONLY_OUTPUT", "1", 1)
        defer { unsetenv("LUNGFISH_TAXTRIAGE_FAKE_READONLY_OUTPUT") }

        do {
            _ = try await pipeline.run(config: config)
            XCTFail("TaxTriage should fail closed when result/provenance sidecars cannot be saved")
        } catch TaxTriagePipelineError.pipelineFailed(let exitCode, let stderr, _) {
            XCTAssertEqual(exitCode, -1)
            XCTAssertTrue(stderr.contains("Failed to save TaxTriage result metadata"))
        } catch {
            XCTFail("Expected TaxTriage persistence failure, got \(error)")
        }
    }
}

extension TaxTriagePipelineProvenanceSourceTests {

    /// Nextflow needs POSIX file locks for `.nextflow/cache` and its work tree.
    /// exFAT project volumes do not provide them, so the launch must happen from
    /// local scratch while `--outdir` still points at the project result dir.
    func testTaxTriageLaunchesFromLocalScratchWhilePublishingToResultDirectory() async throws {
        let fixture = try FakeTaxTriageRuntimeFixture()
        defer { fixture.cleanup() }

        let recordURL = fixture.root.appendingPathComponent("launch-record.txt")
        setenv("LUNGFISH_TAXTRIAGE_FAKE_LAUNCH_RECORD", recordURL.path, 1)
        defer { unsetenv("LUNGFISH_TAXTRIAGE_FAKE_LAUNCH_RECORD") }

        let fastqURL = fixture.root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        let outputURL = fixture.root.appendingPathComponent("taxtriage-output", isDirectory: true)
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S1", fastq1: fastqURL, platform: .illumina)],
            outputDirectory: outputURL,
            profile: "conda",
            revision: "fixture-revision"
        )
        let pipeline = TaxTriagePipeline(
            condaManager: fixture.condaManager,
            homeDirectoryProvider: { fixture.home }
        )

        let result = try await pipeline.run(config: config)
        XCTAssertEqual(result.exitCode, 0)

        let record = try String(contentsOf: recordURL, encoding: .utf8)
        let fields = Dictionary(
            uniqueKeysWithValues: record
                .split(separator: "\n")
                .compactMap { line -> (String, String)? in
                    guard let separator = line.firstIndex(of: "=") else { return nil }
                    return (String(line[line.startIndex..<separator]), String(line[line.index(after: separator)...]))
                }
        )

        let launchPWD = try XCTUnwrap(fields["pwd"])
        let workDir = try XCTUnwrap(fields["workdir"])
        let outdir = try XCTUnwrap(fields["outdir"])
        let outputPath = outputURL.standardizedFileURL.path

        XCTAssertFalse(
            URL(fileURLWithPath: launchPWD).standardizedFileURL.path.hasPrefix(outputPath),
            "Nextflow must not be launched from the project result directory (pwd=\(launchPWD))"
        )
        XCTAssertFalse(workDir.isEmpty, "-w must be passed so the work tree is lock-capable")
        XCTAssertFalse(
            URL(fileURLWithPath: workDir).standardizedFileURL.path.hasPrefix(outputPath),
            "The Nextflow work tree must not live in the project result directory"
        )
        XCTAssertEqual(
            URL(fileURLWithPath: outdir).standardizedFileURL.path,
            outputPath,
            "Published results must still land in the caller's result directory"
        )

        // Scratch is cleaned up after a successful run.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: workDir).path),
            "The scratch work tree must be removed once the run finishes"
        )

        // The recorded launch metadata reflects the real directories.
        let metadata = try String(
            contentsOf: outputURL.appendingPathComponent("taxtriage-launch-command.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(metadata.contains("nextflow_work_directory: \(workDir)"))
        XCTAssertFalse(metadata.contains("working_directory: \(outputPath)\n"))
    }
}

private struct FakeTaxTriageRuntimeFixture {
    let root: URL
    let home: URL
    let condaManager: CondaManager

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "taxtriage-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let nextflowURL = home
            .appendingPathComponent(".lungfish/conda/envs/nextflow/bin", isDirectory: true)
            .appendingPathComponent("nextflow")
        try fm.createDirectory(at: nextflowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.nextflowScript.write(to: nextflowURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nextflowURL.path)

        let bundledMicromamba = root.appendingPathComponent("bundled-micromamba")
        try Self.micromambaScript.write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)

        let managedMicromamba = root
            .appendingPathComponent("conda/bin", isDirectory: true)
            .appendingPathComponent("micromamba")
        try fm.createDirectory(at: managedMicromamba.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.micromambaScript.write(to: managedMicromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedMicromamba.path)

        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func cleanup() {
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private static let nextflowScript = """
    #!/bin/sh
    if [ "$1" = "-version" ] || [ "$1" = "--version" ]; then
      echo "nextflow version 24.10.0"
      exit 0
    fi
    echo "fake nextflow should be launched through micromamba in this test" >&2
    exit 64
    """

    private static let micromambaScript = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "micromamba 2.0.0"
      exit 0
    fi
    if [ "$1" != "run" ]; then
      echo "unexpected micromamba invocation: $*" >&2
      exit 64
    fi
    shift
    if [ "$1" = "-n" ]; then
      shift
      shift
    fi
    tool="$1"
    shift
    if [ "$tool" != "nextflow" ]; then
      echo "unexpected tool: $tool" >&2
      exit 64
    fi
    outdir=""
    trace=""
    workdir=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --outdir)
          shift
          outdir="$1"
          ;;
        -with-trace)
          shift
          trace="$1"
          ;;
        -w)
          shift
          workdir="$1"
          ;;
      esac
      shift
    done
    if [ -n "${LUNGFISH_TAXTRIAGE_FAKE_LAUNCH_RECORD:-}" ]; then
      printf 'pwd=%s\\nworkdir=%s\\noutdir=%s\\n' "$PWD" "$workdir" "$outdir" \\
        > "$LUNGFISH_TAXTRIAGE_FAKE_LAUNCH_RECORD"
    fi
    if [ -z "$outdir" ]; then
      echo "missing --outdir" >&2
      exit 64
    fi
    mkdir -p "$outdir/top"
    mkdir -p "$outdir/download"
    printf 'sample\\torganism\\nS1\\tExample virus\\n' > "$outdir/top/S1.top_report.tsv"
    printf 'large taxonomy names dump\\n' > "$outdir/download/names.dmp"
    printf 'large taxonomy nodes dump\\n' > "$outdir/download/nodes.dmp"
    printf '>ref\\nACGT\\n' > "$outdir/download/S1.dwnld.references.fasta"
    if [ -n "$trace" ]; then
      mkdir -p "$(dirname "$trace")"
      printf 'task_id\\tprocess\\tstatus\\n1\\tTAXTRIAGE\\tCOMPLETED\\n' > "$trace"
    fi
    if [ "${LUNGFISH_TAXTRIAGE_FAKE_READONLY_OUTPUT:-0}" = "1" ]; then
      chmod 0555 "$outdir"
    fi
    echo "[aa/000001] Submitted process > TAXTRIAGE (S1)"
    echo "[aa/000001] Completed process > TAXTRIAGE (S1)"
    exit 0
    """
}
