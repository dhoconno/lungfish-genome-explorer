// CLIDeduplicatedBundleSupport.swift - Runs the bundle deduplicate-alignments workflow for the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum CLIDeduplicatedBundleSupport {
    @discardableResult
    static func run(
        sourceBundlePath: String,
        outputBundlePath: String?,
        outputFormat: OutputFormat,
        quiet: Bool,
        command: [String],
        emit: @escaping (String) -> Void
    ) async throws -> AlignmentDuplicateService.WorkflowResult {
        let sourceBundleURL = URL(fileURLWithPath: sourceBundlePath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: sourceBundleURL.path, isDirectory: &isDirectory) else {
            throw CLIError.inputFileNotFound(path: sourceBundleURL.path)
        }
        guard isDirectory.boolValue, sourceBundleURL.pathExtension == "lungfishref" else {
            throw CLIError.validationFailed(errors: ["Source must be a .lungfishref bundle directory: \(sourceBundleURL.path)"])
        }

        let outputBundleURL = outputBundlePath.map { URL(fileURLWithPath: $0) }
        if let outputBundleURL, FileManager.default.fileExists(atPath: outputBundleURL.path) {
            throw CLIError.outputWriteFailed(path: outputBundleURL.path, reason: "Path already exists")
        }

        let startedAt = Date()
        let result = try await AlignmentDuplicateService.createDeduplicatedBundle(
            from: sourceBundleURL,
            outputBundleURL: outputBundleURL
        )

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish bundle deduplicate-alignments",
            parameters: [
                "sourceBundle": .file(sourceBundleURL),
                "outputBundle": outputBundleURL.map { .file($0) } ?? .null,
                "processedTracks": .integer(result.processedTracks),
                "newTrackIds": .array(result.newTrackIds.map(ParameterValue.string)),
            ],
            defaults: [
                "outputBundle": .null,
            ],
            resolved: [
                "sourceBundle": .file(sourceBundleURL),
                "outputBundle": .file(result.bundleURL),
                "processedTracks": .integer(result.processedTracks),
                "newTrackIds": .array(result.newTrackIds.map(ParameterValue.string)),
            ],
            toolName: "lungfish bundle deduplicate-alignments",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: provenanceRecords(for: sourceBundleURL, role: .input),
            outputs: provenanceRecords(for: result.bundleURL, role: .output),
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: result.bundleURL,
            writeFileSidecars: false
        )

        if outputFormat == .json {
            if let line = encodeJSONOutput(result) {
                emit(line)
            }
            return result
        }
        guard !quiet else { return result }
        emit("Deduplicated bundle: \(result.bundleURL.path)")
        emit("Processed tracks: \(result.processedTracks)")
        return result
    }

    private static func encodeJSONOutput(_ result: AlignmentDuplicateService.WorkflowResult) -> String? {
        let summary = JSONOutput(
            bundlePath: result.bundleURL.path,
            processedTracks: result.processedTracks,
            newTrackIds: result.newTrackIds
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(summary) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private struct JSONOutput: Encodable {
        let bundlePath: String
        let processedTracks: Int
        let newTrackIds: [String]
    }
}
