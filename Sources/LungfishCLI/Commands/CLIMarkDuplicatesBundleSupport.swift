// CLIMarkDuplicatesBundleSupport.swift - Runs the bundle mark-duplicates workflow for the CLI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum CLIMarkDuplicatesBundleSupport {
    @discardableResult
    static func run(
        bundlePath: String,
        outputFormat: OutputFormat,
        quiet: Bool,
        command: [String],
        emit: @escaping (String) -> Void
    ) async throws -> AlignmentDuplicateService.WorkflowResult {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory) else {
            throw CLIError.inputFileNotFound(path: bundleURL.path)
        }
        guard isDirectory.boolValue, bundleURL.pathExtension == "lungfishref" else {
            throw CLIError.validationFailed(errors: ["Bundle must be a .lungfishref bundle directory: \(bundleURL.path)"])
        }

        let runClock = ProvenanceRunClock()
        let result = try await AlignmentDuplicateService.markDuplicatesInBundle(bundleURL: bundleURL)

        let parameters: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "processedTracks": .integer(result.processedTracks),
            "newTrackIds": .array(result.newTrackIds.map(ParameterValue.string)),
            "retainedTrackIds": .array(result.retainedTrackIds.map(ParameterValue.string)),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish bundle mark-duplicates",
            parameters: parameters,
            defaults: [:],
            resolved: parameters,
            toolName: "lungfish bundle mark-duplicates",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: provenanceRecords(for: bundleURL, role: .input),
            outputs: provenanceRecords(
                for: bundleURL.appendingPathComponent(AlignmentDuplicateService.markedRelativeDirectory, isDirectory: true),
                role: .output
            ),
            exitCode: 0,
            wallTime: runClock.elapsed,
            stderr: nil,
            status: .completed,
            outputDirectory: result.bundleURL,
            writeFileSidecars: false
        )

        if outputFormat == .json {
            let summary = JSONOutput(
                bundlePath: result.bundleURL.path,
                processedTracks: result.processedTracks,
                newTrackIds: result.newTrackIds,
                retainedTrackIds: result.retainedTrackIds
            )
            if let data = try? JSONEncoder().encode(summary), let line = String(data: data, encoding: .utf8) {
                emit(line)
            }
            return result
        }
        guard !quiet else { return result }
        emit("Bundle: \(result.bundleURL.path)")
        emit("Processed tracks: \(result.processedTracks)")
        emit("Marked tracks added: \(result.newTrackIds.joined(separator: ", "))")
        emit("Original tracks kept as [unmarked]: \(result.retainedTrackIds.joined(separator: ", "))")
        return result
    }

    private struct JSONOutput: Encodable {
        let bundlePath: String
        let processedTracks: Int
        let newTrackIds: [String]
        let retainedTrackIds: [String]
    }
}
