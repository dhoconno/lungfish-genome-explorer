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
      esac
      shift
    done
    if [ -z "$outdir" ]; then
      echo "missing --outdir" >&2
      exit 64
    fi
    mkdir -p "$outdir/top"
    printf 'sample\\torganism\\nS1\\tExample virus\\n' > "$outdir/top/S1.top_report.tsv"
    if [ -n "$trace" ]; then
      mkdir -p "$(dirname "$trace")"
      printf 'task_id\\tprocess\\tstatus\\n1\\tTAXTRIAGE\\tCOMPLETED\\n' > "$trace"
    fi
    echo "[aa/000001] Submitted process > TAXTRIAGE (S1)"
    echo "[aa/000001] Completed process > TAXTRIAGE (S1)"
    exit 0
    """
}
