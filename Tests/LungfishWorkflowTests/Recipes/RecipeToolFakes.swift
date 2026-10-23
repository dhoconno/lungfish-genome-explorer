// RecipeToolFakes.swift - Stand-in fastp, deacon and seqkit for in-process recipe runs, shared by plan and engine tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
@testable import LungfishWorkflow

/// Stand-ins for fastp, deacon and seqkit under `root/.lungfish/conda/envs`, which copy each input to its output
/// (gzipping a plain one) and write the reports. deacon and seqkit take their inputs as the arguments just before
/// `-o`. Shared by `ExecutorPlanEmitterTests` and the frozen argv of `RecipeEngineTests` (K4 part A QA fix 1).
enum RecipeToolFakes {
    static func runner(root: URL) throws -> NativeToolRunner {
        let put = #"put() { if /usr/bin/gzip -t "$1" 2>/dev/null; then /bin/cp "$1" "$2"; else /usr/bin/gzip -c "$1" > "$2"; fi; }"#
        let scripts: [(env: String, name: String, body: String)] = [
            ("fastp", "fastp", """
            if [ "${1:-}" = "--version" ]; then echo "fastp 1.0.1"; exit 0; fi
            in1=""; in2=""; o1=""; o2=""; m=""; report=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -i) in1="$2"; shift 2 ;; -I) in2="$2"; shift 2 ;;
                -o|--out1) o1="$2"; shift 2 ;; -O|--out2) o2="$2"; shift 2 ;;
                --merged_out) m="$2"; shift 2 ;; -j) report="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            [ -n "$o1" ] && put "$in1" "$o1"
            [ -n "$o2" ] && put "$in2" "$o2"
            [ -n "$m" ] && put "$in1" "$m"
            printf '%s\\n' '{"summary":{"before_filtering":{"total_reads":4}}}' > "$report"
            """),
            ("deacon", "deacon", """
            case "${1:-}" in --version|-V) echo "deacon 0.13.2"; exit 0 ;; esac
            p2=""; p1=""; in1=""; in2=""; o1=""; o2=""; summary=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) in1="$p2"; in2="$p1"; o1="$2"; shift 2 ;; -O) o2="$2"; shift 2 ;;
                --summary) summary="$2"; shift 2 ;;
                *) p2="$p1"; p1="$1"; shift ;;
              esac
            done
            put "$in1" "$o1"; put "$in2" "$o2"; printf '{}\\n' > "$summary"
            """),
            ("seqkit", "seqkit", """
            case "${1:-}" in version|--version) echo "seqkit v2.10.0"; exit 0 ;; esac
            p1=""; src=""; out=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) src="$p1"; out="$2"; shift 2 ;;
                *) p1="$1"; shift ;;
              esac
            done
            put "$src" "$out"
            """),
        ]
        for script in scripts {
            let bin = root.appendingPathComponent(".lungfish/conda/envs/\(script.env)/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent(script.name)
            try "#!/bin/sh\nset -eu\n\(put)\n\(script.body)\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .preview)
    }

    /// `root/inputs/R1.fastq` and `R2.fastq`, copies of `pair`, and an empty `root/work`.
    static func layOutWorkRoot(root: URL, _ pair: [URL]) throws -> (input: StepInput, work: URL) {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let r1 = inputs.appendingPathComponent("R1.fastq")
        let r2 = inputs.appendingPathComponent("R2.fastq")
        if !FileManager.default.fileExists(atPath: r1.path) {
            try FileManager.default.copyItem(at: pair[0], to: r1)
            try FileManager.default.copyItem(at: pair[1], to: r2)
        }
        return (StepInput(r1: r1, r2: r2, format: .pairedR1R2), work)
    }

    /// Each recorded tool run's argv with the tool's path dropped, `root` removed and the fused report's per-run UUID
    /// taken out, after asserting its pattern.
    static func recordedArguments(_ result: RecipeExecutionResult, root: URL) -> [[String]] {
        result.stepRecords.compactMap(\.commandArguments).map { recorded in
            var argv = recorded
            if argv.first?.hasPrefix("/") == true { argv.removeFirst() }
            return argv.map { argument in
                let relative = argument.replacingOccurrences(of: root.path + "/", with: "")
                guard relative.hasPrefix("work/sample_fused_fastp_report_") else { return relative }
                XCTAssertNotNil(relative.range(of: #"^work/sample_fused_fastp_report_[0-9A-F-]{36}\.json$"#, options: .regularExpression))
                return "work/sample_fused_fastp_report.json"
            }
        }
    }
}
