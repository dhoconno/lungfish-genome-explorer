// RNASeqQuantSubcommand+PlanWrite.swift - The run of `rnaseq quant --write-plan` and its image pins (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishPortable
import LungfishWorkflow

extension RNASeqCommand.QuantSubcommand {
    /// The words of a cancelled plan.
    static let planCancelledMessage = "The quant plan was cancelled. No plan folder was written."

    /// Runs the plan and prints its summary. One SIGTERM cancels it, writes nothing and exits 125.
    func runPlan() async throws {
        let command = self
        let outcome = await runCancellingOnSIGTERM { () async throws -> RNASeqIndexPlanSubcommand.PlanSummary in
            try await command.writePlanFolder()
        }
        switch outcome {
        case .success(let summary):
            if globalOptions.outputFormat == .json {
                print(summary.json)
            } else if !globalOptions.quiet {
                summary.lines.forEach { print($0) }
            }
        case .failure(let error):
            let isCancel = error is CancellationError
            let words = isCancel ? Self.planCancelledMessage : CLIFailureWords.describe(error)
            FileHandle.standardError.write(Data((isCancel ? "\(words)\n" : "Error: \(words)\n").utf8))
            if isCancel { throw CLIExitCode.cancelled.exitCode }
            throw (error is CocoaError ? CLIExitCode.workflowError : CLIExitCode.inputError).exitCode
        }
    }

    /// The pins and the image record of the files the options name, else the app's, as `rnaseq index-plan` reads them. A tool
    /// manifest that is not the one `image.json` pins is refused.
    func imagePins() throws -> (SalmonPlanPins, ExecutorPlanImageRecord) {
        let options = planOptions, defaults = ImportFastqPlanDefaults.bundled()
        guard let manifestPath = options.executorManifest ?? defaults.executorManifest?.path else {
            throw SalmonPlanError(ImportFastqPlanDefaults.noExecutorSentence)
        }
        guard let imagePath = options.image ?? defaults.image?.path,
              let toolsPath = options.imageToolManifest ?? defaults.imageToolManifest?.path else {
            throw SalmonPlanError(ImportFastqPlanDefaults.noImageSentence)
        }
        func read<Value>(_ path: String, _ option: String, _ expected: String, _ decode: (Data) throws -> Value) throws -> Value {
            do {
                return try decode(Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                throw SalmonPlanError("The file \(path) given to \(option) is not \(expected).")
            }
        }
        let executor = try read(manifestPath, "--executor-manifest", "a manifest.json, so name the manifest.json beside the executor you built") {
            try JSONDecoder().decode(ExecutorPlanExecutorManifest.self, from: $0)
        }
        let (bytes, tools) = try read(toolsPath, "--image-tool-manifest", "a tool manifest, so name the tool manifest that image.json pins") {
            ($0, try ImageToolManifest.decode($0))
        }
        let record = try read(imagePath, "--image", "an image.json, so name the image.json written when the image was built") {
            try JSONDecoder().decode(ExecutorPlanImageRecord.self, from: $0)
        }
        let pin = PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count))
        guard record.imageManifest == pin else {
            throw SalmonPlanError("The tool manifest \(toolsPath) is not the one \(imagePath) pins, so name the manifest of that image.")
        }
        let pins = try SalmonPlanPins(
            executor: executor.sourceFile(besideManifestAt: URL(fileURLWithPath: manifestPath)), executorBuild: executor.build,
            imageManifest: pin, toolManifest: tools)
        return (pins, record)
    }
}
