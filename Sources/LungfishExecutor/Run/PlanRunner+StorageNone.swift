// PlanRunner+StorageNone.swift - The storage route none of run --plan, as the Mac import runs it (CHTC lane K4, M4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

extension PlanRunner {
    /// The storage route `none` as `FASTQIngestionPipeline` runs it on the Mac. With a binning scheme `reformat.sh`
    /// quantizes and writes the gzip output with the argv of `reformatQuantize`, after the writer probe BBTools runs,
    /// so the record names the writer (tally-r2 K4-14). With no binning the compressor alone writes one plain file.
    /// Two files with no binning, or one gzip file, which the Mac interleaves in Swift or keeps as it is, fail the step
    /// with a reason, since this build has no plan form for them.
    static func storeWithoutClumping(
        plan: ExecutionPlan, step: PlanStep, inputs: [URL], output: URL, root: URL, environment: [String: String],
        storage: PortableStorageStep<ExecutorToolLauncher>, launcher: ExecutorToolLauncher, compressor: PortableCompressor?
    ) async throws {
        let settings = plan.storage
        if let quantize = PortableStoragePlan.quantizeArgument(for: settings.qualityBinning) {
            guard inputs.count == 1 || inputs.count == 2 else {
                throw ExecutorSpawn.Failure(reason: "Step \(step.id) bins one file or one pair, and the plan names \(inputs.count) files.")
            }
            _ = try await storage.probeBBToolsWriter(
                environment: environment, compressionLevel: settings.compressionLevel, threads: settings.threads
            )
            let arguments = reformatQuantizeArguments(
                inputs: inputs, output: output, compressionLevel: settings.compressionLevel, threads: settings.threads,
                quantize: quantize
            )
            let outcome = try await launcher.run(PortableToolLaunch(
                tool: .reformat, arguments: arguments, workingDirectory: root, environment: environment,
                timeout: step.deadlineSeconds
            ))
            guard outcome.isSuccess else {
                throw PortableStorageError.storageFailed(
                    "reformat.sh stopped with status \(outcome.exitCode). "
                        + String(outcome.stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw PortableStorageError.storageFailed("reformat.sh completed without producing output.")
            }
            return
        }
        guard inputs.count == 1 else {
            throw ExecutorSpawn.Failure(
                reason: inputs.count == 2
                    ? "Step \(step.id) stores two files with no clumping and no binning, which the Mac interleaves in its own "
                        + "process. This executor build has no plan form for that route."
                    : "Step \(step.id) stores \(inputs.count) files with no clumping and no binning. That route stores one plain file."
            )
        }
        guard inputs[0].pathExtension != "gz" else {
            throw ExecutorSpawn.Failure(
                reason: "Step \(step.id) stores a gzip file with no clumping and no binning, which the Mac keeps as it is. "
                    + "This executor build has no plan form for that route."
            )
        }
        _ = try await storage.compress(
            input: inputs[0], output: output, compressor: compressor, threads: settings.threads,
            timeout: step.deadlineSeconds, progress: { _, _ in }
        )
    }

    /// The argv of the Mac's `FASTQIngestionPipeline.reformatQuantize`: one file is quantized record by record in its
    /// own order with `interleaved=f`, and two files are interleaved into one output.
    static func reformatQuantizeArguments(
        inputs: [URL], output: URL, compressionLevel: Int, threads: Int, quantize: String
    ) -> [String] {
        var arguments = ["in=\(inputs[0].path)"]
        if inputs.count == 2 { arguments.append("in2=\(inputs[1].path)") }
        arguments += ["out=\(output.path)", "ow=t", "pigz=t", "zl=\(compressionLevel)", "threads=\(max(1, threads))"]
        arguments.append(inputs.count == 2 ? "interleaved=t" : "interleaved=f")
        arguments.append(quantize)
        return arguments
    }
}
