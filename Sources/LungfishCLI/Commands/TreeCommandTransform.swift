// TreeCommandTransform.swift - Shared writer for tree reroot, extract-subtree and relabel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Fails, without truncating, when the output's last path component is longer than macOS allows.
func validateOutputNameLength(_ outputURL: URL) throws {
    let name = outputURL.lastPathComponent
    let bytes = name.utf8.count
    guard bytes <= FileNameBudget.maxComponentBytes else {
        throw ValidationError("Output name '\(name)' is \(bytes) bytes. macOS allows at most \(FileNameBudget.maxComponentBytes) bytes per file or folder name. Choose a shorter --output.")
    }
}

func executeTreeTransform(
    bundlePath: String,
    outputPath: String,
    toolName: String,
    argv: [String],
    globalOptions: GlobalOptions,
    emit: @escaping (String) -> Void,
    transform: (PhylogeneticTreeBundle, URL, PhylogeneticTreeBundleTransformProvenance) throws -> PhylogeneticTreeBundle
) throws {
    let emitter = CLIEventEmitter(
        enabled: globalOptions.outputFormat == .json,
        emit: emit
    )
    let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    emitter.emitStart(message: "Starting tree transform.")
    // Only remove an output this run created. Refusing to overwrite must leave an existing bundle alone.
    var createdOutput = false
    do {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ValidationError("Input tree bundle not found: \(bundleURL.path)")
        }
        try validateOutputNameLength(outputURL)
        guard FileManager.default.fileExists(atPath: outputURL.path) == false else {
            throw ValidationError("Output bundle already exists: \(outputURL.path)")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        createdOutput = true
        emitter.emitProgress(0.25, message: "Loading tree bundle.")
        let bundle = try PhylogeneticTreeBundle.load(from: bundleURL)
        emitter.emitProgress(0.65, message: "Writing transformed tree bundle.")
        _ = try transform(
            bundle,
            outputURL,
            PhylogeneticTreeBundleTransformProvenance(
                toolName: toolName,
                argv: argv,
                command: treeCLIShellCommand(argv)
            )
        )
        emitter.emitComplete(output: outputURL.path)
        if globalOptions.outputFormat != .json && !globalOptions.quiet {
            emit("Wrote tree bundle: \(outputURL.path)")
            emit("Provenance: \(outputURL.appendingPathComponent(".lungfish-provenance.json").path)")
        }
    } catch {
        emitter.emitFailed(treeCommandErrorDescription(error))
        if createdOutput { try? FileManager.default.removeItem(at: outputURL) }
        throw error
    }
}
