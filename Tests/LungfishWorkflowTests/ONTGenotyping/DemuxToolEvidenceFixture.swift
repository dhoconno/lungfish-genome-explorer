// DemuxToolEvidenceFixture.swift - A fake conda root and a two-sample cohort run for the demux tool evidence tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7, lane B5. The amplicon genotyping run launches minimap2, samtools and a pysam script from three
// managed conda environments. This fixture builds a conda root whose three tools are shell and Python
// stand-ins, so the whole pipeline runs in a few seconds and no real tool is needed. The report step is a
// stand-in too, so the fixture needs no openpyxl either. A test may write conda-meta records into the
// environments, to say which package version the environment that ran holds.

import Foundation
import LungfishIO
@testable import LungfishWorkflow

struct DemuxToolEvidenceFixture {
    /// One step of the run's records, with the record file it was read from.
    struct RecordedStep {
        /// The record's path below the output folder.
        let file: String
        let step: [String: Any]

        var toolName: String { step["toolName"] as? String ?? "" }
        var toolVersion: String? { step["toolVersion"] as? String }
        var managedToolID: String? { step["managedToolID"] as? String }
        var evidence: [String: Any]? { step["toolVersionEvidence"] as? [String: Any] }
    }

    /// The five step names the demux pipeline wrote with a literal `unknown` version before lane B5.
    static let managedToolStepNames: Set<String> = [
        "minimap2", "samtools sort", "samtools merge", "samtools index", "pysam retained-read demux filter",
    ]

    let root: URL
    let condaRoot: URL
    let outputDirectory: URL
    private let micromamba: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemuxToolEvidenceFixture-\(UUID().uuidString)", isDirectory: true)
        condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        outputDirectory = root.appendingPathComponent("miseq-cohort.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: condaRoot, withIntermediateDirectories: true)
        micromamba = try Self.writeFakeTools(into: condaRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes the conda-meta record of one package into an environment. The record holds host paths
    /// under the fixture root, as a real record does, so a test can check none reaches a step.
    func writeCondaMeta(environment: String, package: String, version: String, build: String) throws {
        try CondaMetaRecordWriter.write(
            environment: condaRoot.appendingPathComponent("envs/\(environment)", isDirectory: true),
            package: package, version: version, build: build)
    }

    /// Runs the pipeline on two Illumina sample bundles, the shape of the genotype golden.
    @discardableResult
    func runCohort() async throws -> ONTBarcodeDemuxGenotypingResult {
        let reference = root.appendingPathComponent("reference.fa")
        try """
        >A1_063_01
        ACGTACGT
        >14_M1_DQA1_24_03
        ACGTACGT

        """.write(to: reference, atomically: true, encoding: .utf8)
        let samples = try ["DW001", "DW002"].map { try makeSampleBundle(named: $0) }
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: samples,
            referenceSourceURL: reference,
            outputDirectory: outputDirectory,
            outputName: "miseq-cohort",
            analysisName: "MiSeqCohort",
            threads: 2,
            sortThreads: 1,
            minSupport: 1,
            mode: .illuminaPaired,
            readType: .illumina
        )
        let micromamba = micromamba
        return try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { micromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)
    }

    /// Every step of the five managed tool names in every provenance record the run wrote, the main
    /// record, the bundle copy and each output's own record. The legacy dictionary record is read
    /// separately with ``legacyRecordSteps()``.
    func managedToolSteps() throws -> [RecordedStep] {
        var found: [RecordedStep] = []
        let enumerator = FileManager.default.enumerator(at: outputDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            guard name == "lungfish-provenance.json" || name.hasSuffix(".lungfish-provenance.json") else { continue }
            let relative = String(url.path.dropFirst(outputDirectory.path.count + 1))
            for step in try steps(in: url) where Self.managedToolStepNames.contains(step["toolName"] as? String ?? "") {
                found.append(RecordedStep(file: relative, step: step))
            }
        }
        return found.sorted { ($0.file, $0.toolName) < ($1.file, $1.toolName) }
    }

    /// The steps of the legacy `retained-demux-genotyping-provenance.json`, a dictionary record that
    /// holds no version key.
    func legacyRecordSteps() throws -> [[String: Any]] {
        try steps(in: outputDirectory.appendingPathComponent("retained-demux-genotyping-provenance.json"))
    }

    private func steps(in url: URL) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?["steps"] as? [[String: Any]] ?? []
    }

    private func makeSampleBundle(named name: String) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let sequence = "ACGTACGT"
        try "@\(name):1:1:1:1:1:1\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
            .write(to: bundle.appendingPathComponent("\(name).fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    // MARK: - Fake tools

    /// Writes the stand-in tools into `condaRoot` and returns the stand-in micromamba.
    private static func writeFakeTools(into condaRoot: URL) throws -> URL {
        let bin = condaRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let micromambaScript = """
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
          echo "test-micromamba"
          exit 0
        fi
        if [ "${1:-}" != "run" ]; then
          echo "unsupported micromamba invocation: $*" >&2
          exit 2
        fi
        shift
        env_name="$2"
        shift 2
        tool="$1"
        shift
        exec "$MAMBA_ROOT_PREFIX/envs/$env_name/bin/$tool" "$@"
        """
        let bundled = condaRoot.deletingLastPathComponent().appendingPathComponent("bundled-micromamba")
        try writeExecutable(micromambaScript, to: bundled)
        try writeExecutable(micromambaScript, to: bin.appendingPathComponent("micromamba"))

        try writeExecutable(
            """
            #!/bin/sh
            set -eu
            uses_stdin=0
            for argument in "$@"; do
              if [ "$argument" = "-" ]; then uses_stdin=1; fi
            done
            if [ "$uses_stdin" -eq 1 ]; then cat >/dev/null; fi
            printf '@HD\\tVN:1.6\\n'
            """,
            to: try toolURL(condaRoot, environment: "minimap2", name: "minimap2")
        )
        try writeExecutable(
            """
            #!/bin/sh
            set -eu
            command="$1"
            shift
            if [ "$command" = "sort" ]; then
              output=""
              while [ "$#" -gt 0 ]; do
                case "$1" in
                  -o) output="$2"; shift 2 ;;
                  *) shift ;;
                esac
              done
              cat >/dev/null
              printf 'BAM' > "$output"
              exit 0
            fi
            if [ "$command" = "merge" ]; then
              output=""
              while [ "$#" -gt 0 ]; do
                case "$1" in
                  -f) shift ;;
                  *) if [ -z "$output" ]; then output="$1"; fi; shift ;;
                esac
              done
              printf 'BAM' > "$output"
              exit 0
            fi
            if [ "$command" = "index" ]; then
              printf 'BAI' > "$1.bai"
              exit 0
            fi
            echo "unsupported samtools command: $command" >&2
            exit 2
            """,
            to: try toolURL(condaRoot, environment: "samtools", name: "samtools")
        )
        for environment in ["pysam", "openpyxl"] {
            try writeExecutable(fakePython, to: try toolURL(condaRoot, environment: environment, name: "python"))
        }
        return bundled
    }

    private static func toolURL(_ condaRoot: URL, environment: String, name: String) throws -> URL {
        let bin = condaRoot.appendingPathComponent("envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return bin.appendingPathComponent(name)
    }

    private static func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Stands in for the pysam filter script and the openpyxl renderer. It writes the filter outputs the
    /// pipeline expects and a renderer summary the Excel export accepts.
    private static let fakePython = #"""
    #!/usr/bin/env python3
    import json
    import os
    import sys

    def option(name, default=None):
        if name not in sys.argv:
            return default
        return sys.argv[sys.argv.index(name) + 1]

    script = os.path.basename(sys.argv[1]) if len(sys.argv) > 1 else ""
    if script == "renderer.py":
        with open(sys.argv[3], "wb") as handle:
            handle.write(b"workbook")
        print(json.dumps({
            "pythonExecutable": sys.executable, "pythonVersion": "3.12.0", "openpyxlVersion": "3.1.5",
            "platform": "test",
            "renderer": {"schemaVersion": 1, "sheets": [{"name": "Genotypes", "rowCount": 1, "cellCount": 1}]},
        }))
        sys.exit(0)
    if script == "filter-demux-retained-bam.py":
        output_dir = option("--output-dir")
        prefix = option("--prefix")
        os.makedirs(output_dir, exist_ok=True)
        outputs = {
            "bam": os.path.join(output_dir, f"{prefix}.retained.demuxed.bam"),
            "bai": os.path.join(output_dir, f"{prefix}.retained.demuxed.bam.bai"),
            "genotypes": os.path.join(output_dir, f"{prefix}.retained_demux_genotypes.csv"),
            "samples": os.path.join(output_dir, f"{prefix}.retained_demux_samples.csv"),
            "stats": os.path.join(output_dir, f"{prefix}.retained_demux_stats.json"),
            "provenance": os.path.join(output_dir, "retained-demux-genotyping-provenance.json"),
        }
        with open(outputs["bam"], "w") as handle:
            handle.write("retained bam\n")
        with open(outputs["bai"], "w") as handle:
            handle.write("retained bai\n")
        with open(outputs["genotypes"], "w") as handle:
            handle.write("sample,genotype,passed_alignments,passed_unique_reads\n")
            handle.write("DW001,A1_063_01,1,1\n")
        with open(outputs["samples"], "w") as handle:
            handle.write("sample,passed_alignments,passed_unique_reads\n")
            handle.write("DW001,1,1\n")
        stats = {
            "totalInputReads": 1, "totalAlignments": 1, "passedAlignments": 1,
            "retainedQueryNamesBeforeDemux": 1, "retainedUniqueReads": 1,
            "retainedUniquePercentOfTotalReads": 100.0, "assignedUniqueRetainedReads": 1,
            "unassignedUniqueRetainedReads": 0,
        }
        with open(outputs["stats"], "w") as handle:
            json.dump(stats, handle)
        with open(outputs["provenance"], "w") as handle:
            json.dump({"argv": sys.argv, "exitStatus": 0}, handle)
        print(json.dumps(stats))
        sys.exit(0)
    print(f"unsupported fake python script: {script}", file=sys.stderr)
    sys.exit(2)
    """#
}
