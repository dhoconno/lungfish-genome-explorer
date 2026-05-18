import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class ClassificationPipelineProvenanceSourceTests: XCTestCase {
    func testKraken2ProvenanceRecordsChecksummedFiles() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        let pipeline = ClassificationPipeline(condaManager: fixture.condaManager)

        let result = try await pipeline.classify(config: config)

        XCTAssertEqual(result.reportURL.standardizedFileURL, config.reportURL.standardizedFileURL)
        XCTAssertEqual(result.outputURL.standardizedFileURL, config.outputURL.standardizedFileURL)

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        XCTAssertEqual(provenance.name, "Metagenomics Classification")
        XCTAssertEqual(provenance.status, .completed)
        let krakenStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "kraken2" })

        XCTAssertEqual(krakenStep.exitCode, 0)
        XCTAssertNotNil(krakenStep.wallTime)
        XCTAssertTrue(krakenStep.command.contains("kraken2"))
        XCTAssertTrue(krakenStep.command.contains(config.reportURL.path))
        XCTAssertTrue(krakenStep.command.contains(config.outputURL.path))
        XCTAssertTrue(
            krakenStep.inputs.contains {
                $0.path == config.inputFiles[0].path && $0.format == .fastq && $0.role == .input
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
        XCTAssertTrue(
            krakenStep.outputs.contains {
                $0.path == config.reportURL.path && $0.format == .text && $0.role == .report
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
        XCTAssertTrue(
            krakenStep.outputs.contains {
                $0.path == config.outputURL.path && $0.format == .text && $0.role == .output
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
    }

    func testBrackenFailedOutputIsOnlyRecordedWhenProduced() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenExitCode: 42)
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        let pipeline = ClassificationPipeline(condaManager: fixture.condaManager)

        let result = try await pipeline.profile(config: config)

        XCTAssertNil(result.brackenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.brackenURL.path))

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        XCTAssertEqual(provenance.name, "Metagenomics Profiling")
        XCTAssertEqual(provenance.status, .completed)
        let brackenStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "bracken" })

        XCTAssertEqual(brackenStep.exitCode, 42)
        XCTAssertEqual(brackenStep.outputs, [])
        XCTAssertTrue(brackenStep.command.contains(config.brackenURL.path))
        XCTAssertTrue(brackenStep.inputs.contains {
            $0.path == config.reportURL.path && $0.format == .text && $0.role == .input
                && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertEqual(brackenStep.stderr, "synthetic bracken failure\n")
    }
}

private struct FakeClassificationCondaFixture {
    let root: URL
    let condaManager: CondaManager
    private let brackenExitCode: Int32

    init(brackenExitCode: Int32 = 0) throws {
        self.brackenExitCode = brackenExitCode
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "classification-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let bundledMicromamba = root.appendingPathComponent("bundled-micromamba")
        try Self.scriptBody(brackenExitCode: brackenExitCode)
            .write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)

        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeConfig() throws -> ClassificationConfig {
        let dbURL = root.appendingPathComponent("kraken-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: dbURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }

        let readsURL = root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)

        return ClassificationConfig(
            inputFiles: [readsURL],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databasePath: dbURL,
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
    }

    private static func scriptBody(brackenExitCode: Int32) -> String {
        """
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
        case "$tool" in
          kraken2)
            if [ "$1" = "--version" ]; then
              echo "Kraken version 2.1.3"
              exit 0
            fi
            report=""
            output=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --report)
                  shift
                  report="$1"
                  ;;
                --output)
                  shift
                  output="$1"
                  ;;
              esac
              shift
            done
            mkdir -p "$(dirname "$report")" "$(dirname "$output")"
            cat > "$report" <<'REPORT'
        100.00\t1\t0\tR\t1\troot
        100.00\t1\t1\tS\t562\t  Escherichia coli
        REPORT
            printf 'C\tread1\t562\t4\t0:4\n' > "$output"
            echo "processed 1 sequence" >&2
            exit 0
            ;;
          bracken)
            if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then
              echo "bracken 2.9"
              exit 0
            fi
            if [ "\(brackenExitCode)" -ne 0 ]; then
              echo "synthetic bracken failure" >&2
              exit \(brackenExitCode)
            fi
            output=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                shift
                output="$1"
              fi
              shift
            done
            mkdir -p "$(dirname "$output")"
            printf 'name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads\nEscherichia coli\t562\tS\t1\t0\t1\t1.0\n' > "$output"
            exit 0
            ;;
          *)
            echo "unexpected tool: $tool" >&2
            exit 64
            ;;
        esac
        """
    }
}
