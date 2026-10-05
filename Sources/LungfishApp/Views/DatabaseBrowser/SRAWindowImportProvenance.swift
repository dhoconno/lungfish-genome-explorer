// SRAWindowImportProvenance.swift - The provenance the window writes for one SRA run it imported
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Writes the provenance of one SRA run the window downloaded and imported.
/// Internal, not private, so tests can read what it records.
///
/// `stagedReadCounts` gives the reads each staged file held for a run that
/// imported unpaired reads beside its pairs, recorded under
/// `stagingInputReadCounts`. Any other run passes nil and records nothing new.
func writeGUISRAFASTQImportProvenance(
    accession: String,
    readRecord: ENAReadRecord?,
    downloadSource: String,
    preferredSource: SRADownloadSourcePreference = .ena,
    enaDownloadSteps: [StepExecution],
    toolkitDownloadTraces: [SRAService.FASTQDownloadStepTrace],
    cliArguments: [String],
    cliStartedAt: Date,
    cliCompletedAt: Date,
    stagedFASTQFiles: [URL],
    stagedReadCounts: [URL: Int]? = nil,
    finalFASTQURL: URL,
    bundleURL: URL,
    platform: String,
    recipeName: String?,
    qualityBinning: String,
    optimizeStorage: Bool,
    compressionLevel: String
) throws {
    let existingCLIProvenance = ProvenanceRecorder.load(from: bundleURL)
    var steps = enaDownloadSteps

    steps.append(contentsOf: toolkitDownloadTraces.map { trace in
        StepExecution(
            toolName: trace.toolName,
            toolVersion: trace.toolVersion,
            command: trace.command,
            inputs: trace.inputs.map {
                FileRecord(path: $0, format: sraGUIInputFormat(for: $0), role: .input)
            },
            outputs: trace.outputs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
            },
            exitCode: trace.exitCode,
            wallTime: trace.wallTime,
            stderr: trace.stderr,
            startTime: trace.startedAt,
            endTime: trace.completedAt
        )
    })

    if let existingCLIProvenance {
        steps.append(contentsOf: existingCLIProvenance.steps)
    } else {
        steps.append(
            StepExecution(
                toolName: CLICommandIdentity.executableName,
                toolVersion: WorkflowRun.currentAppVersion,
                command: [CLIImportRunner.cliBinaryPath()?.path ?? CLICommandIdentity.executableName] + cliArguments,
                inputs: stagedFASTQFiles.map {
                    ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
                },
                outputs: [
                    ProvenanceRecorder.fileRecord(url: finalFASTQURL, format: .fastq, role: .output)
                ],
                exitCode: 0,
                wallTime: cliCompletedAt.timeIntervalSince(cliStartedAt),
                stderr: nil,
                dependsOn: steps.map(\.id),
                startTime: cliStartedAt,
                endTime: cliCompletedAt
            )
        )
    }

    var parameters: [String: ParameterValue] = [
        "workflow": .string("gui-sra-fastq-import"),
        "accession": .string(accession),
        "downloadSource": .string(downloadSource),
        // The window's "Download source" setting. The window records `import
        // fastq`, not `fetch sra download`, so the choice is kept here.
        "preferredSource": .string(preferredSource.rawValue),
        "enaFastqURLs": .array((readRecord?.fastqHTTPURLs ?? []).map { .string($0.absoluteString) }),
        "cliCommand": .string(CLIImportRunner.commandLine(arguments: cliArguments)),
        "platform": .string(platform),
        "recipe": recipeName.map { .string($0) } ?? .null,
        "qualityBinning": .string(qualityBinning),
        "optimizeStorage": .boolean(optimizeStorage),
        "compression": .string(compressionLevel),
        "containerRuntime": .string("none"),
        // Every SRA Toolkit source ran in the managed sra-tools environment.
        "condaEnvironment": .string(
            SRAFASTQDownloadSource(rawValue: downloadSource)?.usesSRAToolkit == true ? "managed sra-tools" : "none"
        ),
        "stagingInputs": .array(stagedFASTQFiles.map { .string($0.standardizedFileURL.path) }),
        "finalBundlePath": .string(bundleURL.standardizedFileURL.path),
        "finalFASTQPath": .string(finalFASTQURL.standardizedFileURL.path)
    ]
    if let stagedReadCounts {
        parameters["stagingInputReadCounts"] = .dictionary(Dictionary(
            stagedReadCounts.map { ($0.key.standardizedFileURL.path, ParameterValue.integer($0.value)) },
            uniquingKeysWith: { first, _ in first }
        ))
    }
    if let existingCLIProvenance {
        parameters["preservedCLIProvenanceID"] = .string(existingCLIProvenance.id.uuidString)
        parameters["preservedCLIWorkflowName"] = .string(existingCLIProvenance.name)
    }

    let run = WorkflowRun(
        name: "gui-sra-fastq-import",
        startTime: steps.first?.startTime ?? cliStartedAt,
        endTime: cliCompletedAt,
        status: .completed,
        appVersion: WorkflowRun.currentAppVersion,
        hostOS: WorkflowRun.currentHostOS,
        steps: steps,
        parameters: parameters
    )

    try run.writeSidecar(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
}

private func sraGUIInputFormat(for path: String) -> FileFormat? {
    let lowercase = path.lowercased()
    if lowercase.hasSuffix(".fastq") || lowercase.hasSuffix(".fq")
        || lowercase.hasSuffix(".fastq.gz") || lowercase.hasSuffix(".fq.gz") {
        return .fastq
    }
    return lowercase.hasSuffix(".sra") ? .unknown : nil
}
