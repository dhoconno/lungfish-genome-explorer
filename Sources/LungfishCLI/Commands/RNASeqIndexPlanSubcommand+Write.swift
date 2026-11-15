// RNASeqIndexPlanSubcommand+Write.swift - The run of `rnaseq index-plan` (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishPortable
import LungfishWorkflow

extension RNASeqIndexPlanSubcommand {
    /// What a written plan folder says to the person: the text lines and the JSON document.
    struct PlanSummary: Sendable {
        var lines: [String]
        var json: String
    }

    func run() async throws {
        let command = self
        let outcome = await runCancellingOnSIGTERM { () throws -> PlanSummary in try command.writePlan() }
        switch outcome {
        case .success(let summary):
            if globalOptions.outputFormat == .json {
                print(summary.json)
            } else if !globalOptions.quiet {
                summary.lines.forEach { print($0) }
            }
        case .failure(let error):
            let isCancel = error is CancellationError
            let words = isCancel ? Self.cancelledMessage : CLIFailureWords.describe(error)
            FileHandle.standardError.write(Data((isCancel ? "\(words)\n" : "Error: \(words)\n").utf8))
            if isCancel { throw CLIExitCode.cancelled.exitCode }
            throw (error is CocoaError ? CLIExitCode.workflowError : CLIExitCode.inputError).exitCode
        }
    }

    private static func read<Value>(_ path: String, option: String, expected: String, _ decode: (Data) throws -> Value) throws -> Value {
        do {
            return try decode(Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw STARIndexError("The file \(path) given to \(option) is not \(expected).")
        }
    }

    /// The pins and the image record of the files the options name, else the app's. A tool manifest that is not the one
    /// `image.json` pins is refused.
    private func imagePins(star version: STARIndexVersion) throws -> (STARIndexPlanPins, ExecutorPlanImageRecord) {
        let defaults = ImportFastqPlanDefaults.bundled()
        guard let manifestPath = executorManifest ?? defaults.executorManifest?.path else {
            throw STARIndexError(ImportFastqPlanDefaults.noExecutorSentence)
        }
        guard let imagePath = image ?? defaults.image?.path, let toolsPath = imageToolManifest ?? defaults.imageToolManifest?.path else {
            throw STARIndexError(ImportFastqPlanDefaults.noImageSentence)
        }
        let executor = try Self.read(manifestPath, option: "--executor-manifest",
                                     expected: "a manifest.json, so name the manifest.json beside the executor you built") {
            try JSONDecoder().decode(ExecutorPlanExecutorManifest.self, from: $0)
        }
        let (bytes, tools) = try Self.read(toolsPath, option: "--image-tool-manifest",
                                           expected: "a tool manifest, so name the tool manifest that image.json pins") {
            ($0, try ImageToolManifest.decode($0))
        }
        let record = try Self.read(imagePath, option: "--image",
                                   expected: "an image.json, so name the image.json written when the image was built") {
            try JSONDecoder().decode(ExecutorPlanImageRecord.self, from: $0)
        }
        let pin = PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count))
        guard record.imageManifest == pin else {
            throw STARIndexError("The tool manifest \(toolsPath) is not the one \(imagePath) pins, so name the manifest of that image.")
        }
        let pins = try STARIndexPlanPins(
            executor: executor.sourceFile(besideManifestAt: URL(fileURLWithPath: manifestPath)), executorBuild: executor.build,
            imageManifest: pin, toolManifest: tools, star: version)
        return (pins, record)
    }

    /// Refuses, plans and writes the submit folder. A cancel before the write leaves nothing, and one after it removes the folder.
    func writePlan() throws -> PlanSummary {
        let output = outputURL
        guard let version = STARIndexVersion(rawValue: star) else {
            throw STARIndexError("--star is \(STARIndexVersion.allCases.map(\.rawValue).joined(separator: " or ")), not \(star).")
        }
        guard stagingFolder.hasPrefix("/") else { throw STARIndexError("--staging-folder must be an absolute path.") }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw STARIndexError("The plan folder \(output.lastPathComponent) already exists, so name a new folder or remove this one.")
        }
        let setFolder = try Self.setFolder(for: setReference, storageRoot: storageRoot)
        let (pins, record) = try imagePins(star: version)
        let made = try STARIndexPlan.make(STARIndexPlanRequest(setFolder: setFolder, star: version, pins: pins))
        let figures = try STARIndexSubmit.figures(
            for: try ReferenceSetManifest.load(from: setFolder), memoryMiB: requestMemoryMiB, cpus: requestCPUs, diskGiB: requestDiskGiB)
        let layout = ExecutorPlanStagingLayout(folder: stagingFolder, batch: output.lastPathComponent)
        try ViewerExportLeaf.checkpointAfterStaging()
        let batch = try STARIndexSubmit.write(
            made, figures: figures, image: record, layout: layout, requirements: jobRequirements, into: output)
        do { try Task.checkCancellation() } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        var lines = ["Wrote the plan folder \(batch.folder.path) for the STAR index \(made.key.folderName) of the set \(made.key.setID)."]
        for file in batch.files { lines.append("  \(file.size) bytes  \(file.stagingPath)" + (file.source.map { "  from \($0)" } ?? "")) }
        lines.append("The job asks for \(figures.memoryMiB) MiB of memory, \(figures.cpus) CPUs and \(figures.diskGiB) GiB of disk.")
        let facts: [String: Any] = [
            "setID": made.key.setID, "key": made.key.folderName, "star": version.rawValue, "output": output.path,
            "genomeSAindexNbases": made.key.genomeSAindexNbases, "memoryMiB": figures.memoryMiB, "cpus": figures.cpus,
            "diskGiB": figures.diskGiB,
        ]
        let json = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .withoutEscapingSlashes])
        return PlanSummary(lines: lines, json: String(decoding: json, as: UTF8.self))
    }
}
