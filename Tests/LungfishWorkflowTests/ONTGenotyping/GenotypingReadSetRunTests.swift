// GenotypingReadSetRunTests.swift - A whole genotyping run maps every read of its inputs and records how it got them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each test runs `ONTBarcodeDemuxGenotypingPipeline` the way
// `lungfish-cli fastq genotype` does, with stand-in minimap2, samtools,
// bbmerge and Python. The stand-in minimap2 keeps the reads it was handed,
// so a test sees exactly which reads were genotyped. Virtual inputs are
// materialized by the managed seqkit, so those tests skip without it.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class GenotypingReadSetRunTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotyping-read-set-runs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - ONT: a virtual demultiplexed barcode

    /// `fastq genotype <barcode01> --mode ont-sample-bundles --read-type ont`.
    /// Before: the run mapped the barcode's preview, r2 and r3, so four of
    /// its six reads were never genotyped.
    func testAVirtualDemultiplexedONTBarcodeIsGenotypedFromItsMaterializedReadsNotItsPreview() async throws {
        try await GenotypingVirtualInputFixtures.requireSeqkit()
        let barcode = try GenotypingVirtualInputFixtures.makeONTDemuxedBarcode(in: root)
        let run = try makeRun(
            inputs: [barcode.barcodeBundle],
            name: "ont-barcode",
            mode: .ontSampleBundles,
            readType: .ont
        )

        _ = try await run.pipeline.run(run.request)

        let mapped = try mappedReads(run)
        XCTAssertEqual(mapped, barcode.barcodeReads.map { "barcode01|\($0)" })
        XCTAssertNotEqual(mapped, barcode.previewReads.map { "barcode01|\($0)" })
    }

    // MARK: - Illumina: provenance of a planned input

    /// L5c. Before: the run mapped the merged reads x1 to x3 only, and its
    /// envelope recorded no step for the unmerged pair it dropped. Now the
    /// pair and the merged reads reach the merger as one stream, and the
    /// envelope records the interleave with its counts.
    func testAMergeDerivativeRunMapsEveryReadAndRecordsTheInterleaveStep() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let run = try makeRun(inputs: [fixtures.mergeDerivative], name: "merge", mode: .illuminaPaired, readType: .illumina)

        _ = try await run.pipeline.run(run.request)

        // The stand-in bbmerge merges the one unmerged pair into one record,
        // and the merged reads pass through the merger untouched.
        XCTAssertEqual(try mappedReads(run), ["merge|u1/1", "merge|x1", "merge|x2", "merge|x3"])

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: run.request.outputDirectory))
        let interleave = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "Lungfish Read-Set Interleave" },
            "steps: \(envelope.steps.map(\.toolName))"
        )
        XCTAssertEqual(interleave.resolvedOptions["pairs"], .integer(1))
        XCTAssertEqual(interleave.resolvedOptions["singleReads"], .integer(3))
        XCTAssertEqual(
            Set(interleave.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }),
            ["unmerged_R1.fastq", "unmerged_R2.fastq", "merged.fastq"]
        )

        let provenance = try jsonObject(at: run.request.provenanceURL)
        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        let preparation = try XCTUnwrap(options["sampleBundleInputPreparation"] as? [String: Any])
        let plans = try XCTUnwrap(preparation["readSetPlans"] as? [[String: Any]], "\(preparation.keys.sorted())")
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?["sample"] as? String, "merge")
    }

    /// L2, the shape of the `genotype` golden. Its one file is read in
    /// place, so the run records no read-set step and no plan.
    func testAnInterleavedRootRunRecordsNoReadSetStepOrPlan() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let run = try makeRun(inputs: [fixtures.interleavedRoot], name: "interleaved", mode: .illuminaPaired, readType: .illumina)

        _ = try await run.pipeline.run(run.request)

        XCTAssertEqual(try mappedReads(run), ["interleaved|i1/1", "interleaved|i2/1"], "the stand-in bbmerge keeps R1 of each pair")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: run.request.outputDirectory))
        XCTAssertFalse(envelope.steps.contains { $0.toolName.hasPrefix("Lungfish Read-Set") }, "\(envelope.steps.map(\.toolName))")
        let provenance = try jsonObject(at: run.request.provenanceURL)
        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        let preparation = try XCTUnwrap(options["sampleBundleInputPreparation"] as? [String: Any])
        XCTAssertNil(preparation["readSetPlans"])
        XCTAssertEqual(
            preparation["sourceFASTQs"] as? [String],
            [fixtures.interleavedRoot.appendingPathComponent("reads.fastq").standardizedFileURL.path]
        )
    }

    // MARK: - Run harness

    private struct Run {
        let request: ONTBarcodeDemuxGenotypingRunRequest
        let pipeline: ONTBarcodeDemuxGenotypingPipeline
        /// Every read the stand-in minimap2 was handed, in order.
        let mappedReadsURL: URL
    }

    private func makeRun(
        inputs: [URL],
        name: String,
        mode: AmpliconGenotypingMode,
        readType: AmpliconGenotypingReadType
    ) throws -> Run {
        let runRoot = root.appendingPathComponent("run-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let condaRoot = runRoot.appendingPathComponent("conda", isDirectory: true)
        let mappedReadsURL = runRoot.appendingPathComponent("mapped-reads.fastq")
        let bundledMicromamba = try makeStandInCondaRoot(at: condaRoot, mappedReadsPath: mappedReadsURL.path)
        let referenceFASTA = runRoot.appendingPathComponent("reference.fa")
        try ">allele1\nACGTACGTAC\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: inputs,
            referenceSourceURL: referenceFASTA,
            outputDirectory: runRoot.appendingPathComponent("\(name).lungfishgenotype", isDirectory: true),
            outputName: name,
            analysisName: name,
            threads: 1,
            sortThreads: 1,
            minSupport: 1,
            mode: mode,
            readType: readType
        )
        let pipeline = ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        )
        return Run(request: request, pipeline: pipeline, mappedReadsURL: mappedReadsURL)
    }

    /// The identifiers of the reads minimap2 was handed.
    private func mappedReads(_ run: Run) throws -> [String] {
        try ReadSetFixtures.readNames(in: run.mappedReadsURL).map { String($0.split(separator: " ")[0]) }
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// Stand-in tools for one run. minimap2 appends every read it is handed
    /// (stdin or query files) to `mappedReadsPath`. bbmerge collapses each
    /// interleaved pair into its R1 record. The filter writes fixed genotype
    /// rows, and the workbook renderer runs the managed openpyxl Python.
    private func makeStandInCondaRoot(at root: URL, mappedReadsPath: String) throws -> URL {
        let fm = FileManager.default
        let micromamba = #"""
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
            """#
        let bundledMicromamba = root.deletingLastPathComponent().appendingPathComponent("bundled-micromamba")
        try fm.createDirectory(at: root.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try writeExecutable(micromamba, to: bundledMicromamba)
        try writeExecutable(micromamba, to: root.appendingPathComponent("bin/micromamba"))

        let quotedCapture = "'" + mappedReadsPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try writeTool(at: root, environment: "minimap2", name: "minimap2", script: #"""
            #!/bin/sh
            set -eu
            capture=\#(quotedCapture)
            seen_reference=0
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -x|-t|-R) shift 2 ;;
                -) cat >> "$capture"; shift ;;
                -*) shift ;;
                *)
                  if [ "$seen_reference" -eq 0 ]; then
                    seen_reference=1
                  else
                    case "$1" in
                      *.gz) gzip -dc "$1" >> "$capture" ;;
                      *) cat "$1" >> "$capture" ;;
                    esac
                  fi
                  shift
                  ;;
              esac
            done
            printf '@HD\tVN:1.6\n'
            """#)
        try writeTool(at: root, environment: "bbtools", name: "bbmerge.sh", script: #"""
            #!/bin/sh
            set -eu
            input=""
            merged=""
            unmerged=""
            for argument in "$@"; do
              case "$argument" in
                in=*) input="${argument#in=}" ;;
                out=*) merged="${argument#out=}" ;;
                outu=*) unmerged="${argument#outu=}" ;;
              esac
            done
            awk 'NR % 8 == 1 { sub(/ .*$/, "", $0); print } NR % 8 == 2 || NR % 8 == 3 || NR % 8 == 4 { print }' \
              "$input" > "$merged"
            : > "$unmerged"
            echo "stand-in bbmerge merged pairs" >&2
            """#)
        try writeTool(at: root, environment: "samtools", name: "samtools", script: #"""
            #!/bin/sh
            set -eu
            command="$1"
            shift
            output=""
            case "$command" in
              sort)
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    -o) output="$2"; shift 2 ;;
                    *) shift ;;
                  esac
                done
                cat >/dev/null
                printf 'BAM' > "$output"
                ;;
              merge)
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    -f) shift ;;
                    *) if [ -z "$output" ]; then output="$1"; fi; shift ;;
                  esac
                done
                printf 'BAM' > "$output"
                ;;
              index) printf 'BAI' > "$1.bai" ;;
              *) echo "unsupported samtools command: $command" >&2; exit 2 ;;
            esac
            """#)
        let python = #"""
            #!/usr/bin/env python3
            import json
            import os
            import sys

            def option(name):
                return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None

            script = os.path.basename(sys.argv[1]) if len(sys.argv) > 1 else ""
            if script == "renderer.py":
                real_python = os.environ.get("LUNGFISH_TEST_PYTHON", os.path.expanduser("~/.lungfish/conda/envs/openpyxl/bin/python3"))
                os.execv(real_python, [real_python] + sys.argv[1:])
            if script == "filter-demux-retained-bam.py":
                output_dir = option("--output-dir")
                prefix = option("--prefix")
                os.makedirs(output_dir, exist_ok=True)
                def path(suffix):
                    return os.path.join(output_dir, prefix + suffix)
                with open(path(".retained.demuxed.bam"), "w") as handle:
                    handle.write("retained bam\n")
                with open(path(".retained.demuxed.bam.bai"), "w") as handle:
                    handle.write("retained bai\n")
                with open(path(".retained_demux_genotypes.csv"), "w") as handle:
                    handle.write("sample,genotype,passed_alignments,passed_unique_reads\nDW472,allele1,1,1\n")
                with open(path(".retained_demux_samples.csv"), "w") as handle:
                    handle.write("sample,passed_alignments,passed_unique_reads\nDW472,1,1\n")
                stats = {
                    "totalInputReads": 1, "totalAlignments": 1, "passedAlignments": 1,
                    "retainedQueryNamesBeforeDemux": 1, "retainedUniqueReads": 1,
                    "retainedUniquePercentOfTotalReads": 100.0,
                    "assignedUniqueRetainedReads": 1, "unassignedUniqueRetainedReads": 0,
                }
                with open(path(".retained_demux_stats.json"), "w") as handle:
                    json.dump(stats, handle)
                with open(os.path.join(output_dir, "retained-demux-genotyping-provenance.json"), "w") as handle:
                    json.dump({"argv": sys.argv, "exitStatus": 0}, handle)
                print(json.dumps(stats))
                sys.exit(0)
            print("unsupported stand-in python script: " + script, file=sys.stderr)
            sys.exit(2)
            """#
        for environment in ["pysam", "openpyxl"] {
            try writeTool(at: root, environment: environment, name: "python", script: python)
        }
        return bundledMicromamba
    }

    private func writeTool(at root: URL, environment: String, name: String, script: String) throws {
        let bin = root.appendingPathComponent("envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(script, to: bin.appendingPathComponent(name))
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
