// FastqCommand+Provenance.swift - The provenance records the fastq subcommands write
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Provenance recorders

func recordFASTQNativeToolProvenance(
    workflowName: String,
    nativeTool: NativeTool,
    cliArguments: [String],
    nativeArguments: [String],
    result: NativeToolResult,
    inputURLs: [URL],
    outputURLs: [URL],
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    inputRecords: [FileRecord]? = nil,
    outputRecords: [FileRecord]? = nil,
    stepID: UUID = UUID(),
    stepInputs: [FileRecord]? = nil,
    stepOutputs: [FileRecord]? = nil,
    extraSteps: [ProvenanceStep] = [],
    startedAt: Date
) async throws {
    guard let firstOutputURL = outputURLs.first else { return }
    let completedAt = Date()
    let toolVersion = await NativeToolRunner.shared.getToolVersion(nativeTool) ?? "unknown"
    let stepCommand = result.arguments.isEmpty
        ? [nativeTool.executableName] + nativeArguments
        : result.arguments

    var resolved = parameters
    for (key, value) in defaults where resolved[key] == nil {
        resolved[key] = value
    }

    try await CLIProvenanceSupport.recordSingleStepRun(
        name: workflowName,
        parameters: parameters,
        defaults: defaults,
        resolved: resolved,
        toolName: nativeTool.rawValue,
        toolVersion: toolVersion,
        command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
        stepID: stepID,
        stepCommand: stepCommand,
        stepInputs: stepInputs,
        stepOutputs: stepOutputs,
        extraSteps: extraSteps,
        inputs: inputRecords ?? inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) },
        outputs: outputRecords ?? outputURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
        exitCode: result.exitCode,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: result.stderr,
        status: result.isSuccess ? .completed : .failed,
        outputDirectory: firstOutputURL.deletingLastPathComponent()
    )
}

@discardableResult
func recordFASTQMergeProvenance(
    cliArguments: [String],
    nativeArguments: [String],
    bbmergeResult: NativeToolResult,
    gzipResult: FASTQGzipProvenanceResult?,
    inputURL: URL,
    bbmergeOutputURLs: [URL],
    finalOutputURL: URL,
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    inputRecords: [FileRecord]? = nil,
    materializationSteps: [ProvenanceStep] = [],
    concatenateWallTime: TimeInterval = 0,
    startedAt: Date
) async throws -> ProvenanceEnvelope {
    let completedAt = Date()
    let toolVersion = await NativeToolRunner.shared.getToolVersion(.bbmerge) ?? "unknown"
    let bbmergeCommand = bbmergeResult.arguments.isEmpty
        ? [NativeTool.bbmerge.executableName] + nativeArguments
        : bbmergeResult.arguments
    let inputRecords = inputRecords ?? [ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)]
    let finalOutputRecord = ProvenanceRecorder.fileRecord(url: finalOutputURL, format: .fastq, role: .output)
    let bbmergeOutputRecords = bbmergeOutputURLs
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }

    let bbmergeStepID = UUID()
    let concatenateStepID = UUID()
    let concatenatedURL = gzipResult?.inputURL ?? finalOutputURL
    let concatenateInputs = bbmergeOutputRecords.map { ProvenanceFileDescriptor(fileRecord: $0).withRole(.input) }
    let concatenateOutput = try ProvenanceFileDescriptor.file(
        url: concatenatedURL,
        format: .fastq,
        role: .output
    )
    let concatenatedInputPaths = bbmergeOutputRecords.map(\.path)
    let concatenateShell = "cat "
        + concatenatedInputPaths.map(shellEscape).joined(separator: " ")
        + " > "
        + shellEscape(concatenatedURL.path)
    var extraSteps = [
        ProvenanceStep(
            id: concatenateStepID,
            toolName: "lungfish fastq merge concatenate",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: ["/bin/sh", "-lc", concatenateShell],
            inputs: concatenateInputs,
            outputs: [concatenateOutput],
            exitStatus: 0,
            wallTimeSeconds: concatenateWallTime,
            dependsOn: [bbmergeStepID],
            startedAt: completedAt.addingTimeInterval(-concatenateWallTime),
            completedAt: completedAt
        ),
    ]

    if let gzipResult {
        let gzipInput = try ProvenanceFileDescriptor.file(
            url: gzipResult.inputURL,
            format: .fastq,
            role: .input
        )
        let gzipOutput = try ProvenanceFileDescriptor.file(
            url: gzipResult.outputURL,
            format: .fastq,
            role: .output
        )
        extraSteps.append(
            ProvenanceStep(
                toolName: gzipResult.command.first ?? "/usr/bin/gzip",
                toolVersion: "system",
                argv: gzipResult.command,
                inputs: [gzipInput],
                outputs: [gzipOutput],
                exitStatus: Int(gzipResult.exitCode),
                wallTimeSeconds: gzipResult.wallTime,
                stderr: gzipResult.stderr,
                dependsOn: [concatenateStepID],
                startedAt: completedAt.addingTimeInterval(-gzipResult.wallTime),
                completedAt: completedAt
            )
        )
    }

    return try await CLIProvenanceSupport.recordSingleStepRun(
        name: "lungfish fastq merge",
        parameters: parameters,
        defaults: defaults,
        toolName: NativeTool.bbmerge.rawValue,
        toolVersion: toolVersion,
        command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
        stepID: bbmergeStepID,
        stepCommand: bbmergeCommand,
        stepInputs: inputRecords,
        stepOutputs: bbmergeOutputRecords,
        extraSteps: extraSteps + materializationSteps,
        inputs: inputRecords,
        outputs: [finalOutputRecord],
        exitCode: bbmergeResult.exitCode,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: bbmergeResult.stderr,
        status: bbmergeResult.isSuccess && (gzipResult?.exitCode ?? 0) == 0 ? .completed : .failed,
        outputDirectory: finalOutputURL.deletingLastPathComponent()
    )
}

@discardableResult
func recordFASTQCountedMergeProvenance(
    cliArguments: [String],
    nativeArguments: [String],
    bbmergeResult: NativeToolResult,
    inputURL: URL,
    bbmergeOutputURLs: [URL],
    countedResult: CountedFASTQMaterializationResult,
    finalOutputURL: URL,
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    inputRecords: [FileRecord]? = nil,
    materializationSteps: [ProvenanceStep] = [],
    startedAt: Date
) async throws -> ProvenanceEnvelope {
    let completedAt = Date()
    let toolVersion = await NativeToolRunner.shared.getToolVersion(.bbmerge) ?? "unknown"
    let bbmergeCommand = bbmergeResult.arguments.isEmpty
        ? [NativeTool.bbmerge.executableName] + nativeArguments
        : bbmergeResult.arguments
    let inputRecords = inputRecords ?? [ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)]
    let finalOutputRecord = ProvenanceRecorder.fileRecord(url: finalOutputURL, format: .fastq, role: .output)
    let bbmergeOutputRecords = bbmergeOutputURLs
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }

    let bbmergeStepID = UUID()
    let countedStepID = UUID()
    let countedInputs = bbmergeOutputRecords
        .map { ProvenanceFileDescriptor(fileRecord: $0).withRole(.input) }
    let countedOutput = ProvenanceFileDescriptor(fileRecord: countedResult.materializedOutput)
    let countedCommand = [CLICommandIdentity.executableName, "fastq"] + cliArguments

    var extraSteps = [
        ProvenanceStep(
            id: countedStepID,
            toolName: "lungfish fastq merge count-duplicates",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: countedCommand,
            inputs: countedInputs,
            outputs: [countedOutput],
            exitStatus: 0,
            dependsOn: [bbmergeStepID],
            startedAt: completedAt,
            completedAt: completedAt
        ),
    ]

    if let compression = countedResult.compression {
        extraSteps.append(
            ProvenanceStep(
                toolName: compression.command.first ?? "/usr/bin/gzip",
                toolVersion: "system",
                argv: compression.command,
                inputs: [ProvenanceFileDescriptor(fileRecord: compression.input).withRole(.input)],
                outputs: [ProvenanceFileDescriptor(fileRecord: compression.output).withRole(.output)],
                exitStatus: Int(compression.exitCode),
                wallTimeSeconds: compression.wallTime,
                stderr: compression.stderr,
                dependsOn: [countedStepID],
                startedAt: completedAt.addingTimeInterval(-compression.wallTime),
                completedAt: completedAt
            )
        )
    }

    return try await CLIProvenanceSupport.recordSingleStepRun(
        name: "lungfish fastq merge",
        parameters: parameters,
        defaults: defaults,
        toolName: NativeTool.bbmerge.rawValue,
        toolVersion: toolVersion,
        command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
        stepID: bbmergeStepID,
        stepCommand: bbmergeCommand,
        stepInputs: inputRecords,
        stepOutputs: bbmergeOutputRecords,
        extraSteps: extraSteps + materializationSteps,
        inputs: inputRecords,
        outputs: [finalOutputRecord],
        exitCode: bbmergeResult.exitCode,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: bbmergeResult.stderr,
        status: bbmergeResult.isSuccess && (countedResult.compression?.exitCode ?? 0) == 0 ? .completed : .failed,
        outputDirectory: finalOutputURL.deletingLastPathComponent()
    )
}

func recordFASTQSwiftToolProvenance(
    workflowName: String,
    cliArguments: [String],
    inputURLs: [URL],
    outputURLs: [URL],
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    inputRecords: [FileRecord]? = nil,
    extraSteps: [ProvenanceStep] = [],
    outputFormat: FileFormat = .fastq,
    startedAt: Date
) async throws {
    guard let firstOutputURL = outputURLs.first else { return }
    let completedAt = Date()
    let command = [CLICommandIdentity.executableName, "fastq"] + cliArguments
    var resolved = parameters
    for (key, value) in defaults where resolved[key] == nil {
        resolved[key] = value
    }

    try await CLIProvenanceSupport.recordSingleStepRun(
        name: workflowName,
        parameters: parameters,
        defaults: defaults,
        resolved: resolved,
        toolName: workflowName,
        toolVersion: WorkflowRun.currentAppVersion,
        command: command,
        stepCommand: command,
        extraSteps: extraSteps,
        inputs: inputRecords ?? inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) },
        outputs: outputURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ProvenanceRecorder.fileRecord(url: $0, format: outputFormat, role: .output) },
        exitCode: 0,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: nil,
        status: .completed,
        outputDirectory: firstOutputURL.deletingLastPathComponent()
    )
}

func provenanceRecords(
    for url: URL,
    format: FileFormat? = nil,
    role: FileRole
) -> [FileRecord] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return [ProvenanceRecorder.fileRecord(url: url, format: format, role: role)]
    }
    guard isDirectory.boolValue else {
        return [ProvenanceRecorder.fileRecord(url: url, format: format, role: role)]
    }
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return [ProvenanceRecorder.fileRecord(url: url, format: format, role: role)]
    }
    return enumerator
        .compactMap { item -> URL? in
            guard let fileURL = item as? URL,
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return fileURL
        }
        .sorted { $0.path < $1.path }
        .map { ProvenanceRecorder.fileRecord(url: $0, format: format, role: role) }
}
