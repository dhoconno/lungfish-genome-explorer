// ENAFastaSubcommand.swift - Fetch FASTA from ENA
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Fetch FASTA from ENA
struct ENAFastaSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fasta",
        abstract: "Fetch sequence in FASTA format from ENA"
    )

    @Argument(help: "Accession number")
    var accession: String

    @Option(
        name: .customLong("save-to"),
        help: "Output file path"
    )
    var saveTo: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let runClock = ProvenanceRunClock()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Fetching FASTA for \(accession) from ENA..."))
        }

        let service = ENAService()

        do {
            let fasta = try await service.fetchFASTA(accession: accession)

            if let outputPath = saveTo {
                do {
                    try writeENAFastaOutputWithProvenance(
                        content: fasta,
                        outputURL: URL(fileURLWithPath: outputPath),
                        startedAt: runClock.startedAt,
                        completedAt: runClock.now
                    )
                } catch {
                    throw CLIError.outputWriteFailed(path: outputPath, reason: error.localizedDescription)
                }
                if !globalOptions.quiet {
                    print(formatter.success("Saved to \(outputPath)"))
                }
            } else {
                print(fasta)
            }

            if globalOptions.outputFormat == .json {
                let result = ENAFastaResult(
                    accession: accession,
                    outputFile: saveTo,
                    length: fasta.split(separator: "\n").filter { !$0.hasPrefix(">") }.joined().count
                )
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            }
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.networkError(reason: "ENA fetch failed: \(error.localizedDescription)")
        }
    }

    static func provenanceSidecarURL(for outputURL: URL) -> URL {
        ProvenanceRecorder.fileSidecarURL(for: outputURL)
    }

    func writeENAFastaOutputWithProvenance(
        content: String,
        outputURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let fm = FileManager.default
        guard !Self.isExistingDirectory(outputURL, fileManager: fm) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let outputDirectoryURL = outputURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let tempOutputURL = outputDirectoryURL
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(token).tmp")
        let tempProvenanceURL = outputDirectoryURL
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(token).lungfish-provenance.tmp")
        let finalProvenanceURL = Self.provenanceSidecarURL(for: outputURL)
        let backupOutputURL = outputDirectoryURL
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(token).backup")
        let backupProvenanceURL = outputDirectoryURL
            .appendingPathComponent(".\(finalProvenanceURL.lastPathComponent).\(token).backup")
        var outputBackedUp = false
        var provenanceBackedUp = false
        var outputInstalled = false

        do {
            try content.write(to: tempOutputURL, atomically: true, encoding: .utf8)
            let tempRecord = ProvenanceRecorder.fileRecord(url: tempOutputURL, format: .fasta, role: .output)
            let remoteInputRecord = FileRecord(
                path: "ena://fasta/\(accession)",
                sha256: tempRecord.sha256,
                sizeBytes: tempRecord.sizeBytes,
                format: .fasta,
                role: .input
            )
            let finalOutputRecord = FileRecord(
                path: outputURL.standardizedFileURL.path,
                sha256: tempRecord.sha256,
                sizeBytes: tempRecord.sizeBytes,
                format: tempRecord.format,
                role: tempRecord.role
            )
            let provenanceEnvelope = try enaFastaProvenanceEnvelope(
                outputURL: outputURL,
                inputRecord: remoteInputRecord,
                outputRecord: finalOutputRecord,
                startedAt: startedAt,
                completedAt: completedAt
            )
            try ProvenanceWriter(signingProvider: nil).write(provenanceEnvelope, toSidecar: tempProvenanceURL)

            if fm.fileExists(atPath: outputURL.path) {
                try fm.moveItem(at: outputURL, to: backupOutputURL)
                outputBackedUp = true
            }
            if fm.fileExists(atPath: finalProvenanceURL.path) {
                try fm.moveItem(at: finalProvenanceURL, to: backupProvenanceURL)
                provenanceBackedUp = true
            }

            try fm.moveItem(at: tempOutputURL, to: outputURL)
            outputInstalled = true
            try fm.moveItem(at: tempProvenanceURL, to: finalProvenanceURL)

            try? fm.removeItem(at: backupOutputURL)
            try? fm.removeItem(at: backupProvenanceURL)
        } catch {
            if outputInstalled {
                try? fm.removeItem(at: outputURL)
            }
            if outputBackedUp {
                try? fm.moveItem(at: backupOutputURL, to: outputURL)
            }
            if provenanceBackedUp {
                try? fm.moveItem(at: backupProvenanceURL, to: finalProvenanceURL)
            }
            try? fm.removeItem(at: tempOutputURL)
            try? fm.removeItem(at: tempProvenanceURL)
            throw error
        }
    }

    private static func isExistingDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func enaFastaProvenanceEnvelope(
        outputURL: URL,
        inputRecord: FileRecord,
        outputRecord: FileRecord,
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let command = enaFastaFetchCommand(outputPath: outputURL.path)
        let inputDescriptor = ProvenanceFileDescriptor(fileRecord: inputRecord)
        let outputDescriptor = ProvenanceFileDescriptor(fileRecord: outputRecord)
        let step = ProvenanceStep(
            toolName: "ena-fetch-fasta",
            toolVersion: "ENA Browser API",
            argv: command,
            durableReplayArgv: command,
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let parameters = enaFastaParameters(outputURL: outputURL)
        let legacyRun = WorkflowRun(
            name: "ena-fasta-fetch",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            appVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
            hostOS: WorkflowRun.currentHostOS,
            steps: [StepExecution(
                toolName: "ena-fetch-fasta",
                toolVersion: "ENA Browser API",
                command: command,
                inputs: [inputRecord],
                outputs: [outputRecord],
                exitCode: 0,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: nil,
                startTime: startedAt,
                endTime: completedAt
            )],
            parameters: parameters
        )
        let defaults = enaFastaDefaults()
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "ena-fasta-fetch",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "ena-fetch-fasta",
            toolVersion: "ENA Browser API",
            argv: command,
            durableReplayArgv: command,
            reproducibleCommand: command.map(fetchShellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: parameters,
                defaults: defaults,
                resolvedDefaults: resolvedProvenanceOptions(explicit: parameters, defaults: defaults)
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0,
            legacyWorkflowRun: legacyRun
        )
    }

    private func enaFastaParameters(outputURL: URL) -> [String: ParameterValue] {
        [
            "accession": .string(accession),
            "saveTo": .string(outputURL.standardizedFileURL.path),
            "outputFormat": .string(globalOptions.outputFormat.rawValue),
            "quiet": .boolean(globalOptions.quiet),
            "endpoint": .string("https://www.ebi.ac.uk/ena/browser/api/fasta"),
            "containerRuntime": .string("none"),
            "condaEnvironment": .string("none")
        ]
    }

    private func enaFastaDefaults() -> [String: ParameterValue] {
        [
            "saveTo": .null,
            "outputFormat": .string(OutputFormat.text.rawValue),
            "quiet": .boolean(false),
            "endpoint": .string("https://www.ebi.ac.uk/ena/browser/api/fasta"),
            "containerRuntime": .string("none"),
            "condaEnvironment": .string("none")
        ]
    }

    private func enaFastaFetchCommand(outputPath: String) -> [String] {
        var command = [
            CLICommandIdentity.executableName, "fetch", "ena", "fasta", accession,
            "--save-to", outputPath,
            "--format", globalOptions.outputFormat.rawValue
        ]
        if globalOptions.quiet {
            command.append("--quiet")
        }
        return command
    }

}
