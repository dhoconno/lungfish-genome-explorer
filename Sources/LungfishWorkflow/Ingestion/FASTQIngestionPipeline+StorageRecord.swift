// FASTQIngestionPipeline+StorageRecord.swift - What a Mac storage step records of its writer, level and groups
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The keys a Mac storage step records in its `resolvedOptions` about how its stored gzip was written (C4-10, ARCH N3
/// conditions 2 and 3, BIO N3), under the names the node's `ExecutorStorageDetails` gives the same facts. Each key sits
/// on the step whose launch it describes, so the two `clumpify.sh` steps of a mixed file each state their own groups.
/// A key is absent when it does not apply, as the node leaves out a nil field.
enum FASTQStorageRecordKey {
    /// The program that wrote the stored gzip: `name` alone for BBTools' own writer and for a compress step, which is
    /// its own writer, and for a `bgzip` BBTools started also `tool`, in the node's `ExecutorToolRecord` form, and
    /// `arguments`, the argv BBTools gives it, which the node does not record.
    static let writer = "writer"
    /// The `zl=` of the BBTools argv, the level the stored gzip has. A compress step passes no level and has none.
    static let effectiveCompressionLevel = "effectiveCompressionLevel"
    static let clumpifyGroups = "clumpifyGroups"
    static let clumpifyMemoryEstimateLine = "clumpifyMemoryEstimateLine"
    static let clumpifyMemoryAvailableLine = "clumpifyMemoryAvailableLine"
}

extension FASTQIngestionPipeline {

    /// The record keys of a launch the storage step accepted: the writer probe the step ran right before a BBTools
    /// launch that writes the stored gzip, clumpify's lines for a `clumpify.sh` launch and the program's name for a
    /// `bgzip` or `pigz` compress step. Nil when none applies, as for the writer probe's own launch.
    static func storageResolvedOptions(of run: PortableToolRun) -> [String: ParameterValue]? {
        let tool = run.launch.tool
        let ownTool = run.launch.executable == nil
        return storageResolvedOptions(
            writerProbe: run.writerProbe,
            clumpifyLog: tool == .clumpify && ownTool ? PortableClumpifyLog(run.outcome.stderr) : nil,
            compressor: (tool == .bgzip || tool == .pigz) && ownTool ? NativeToolStorageLauncher.recordName(tool) : nil
        )
    }

    /// The record keys of one storage launch, nil when none applies.
    static func storageResolvedOptions(
        writerProbe: PortableBBToolsWriterProbe? = nil,
        clumpifyLog: PortableClumpifyLog? = nil,
        compressor: String? = nil
    ) -> [String: ParameterValue]? {
        var options: [String: ParameterValue] = [:]
        if let writerProbe {
            options[FASTQStorageRecordKey.writer] = writerValue(writerProbe)
            options[FASTQStorageRecordKey.effectiveCompressionLevel] = .integer(writerProbe.effectiveCompressionLevel)
        } else if let compressor {
            options[FASTQStorageRecordKey.writer] = .dictionary(["name": .string(compressor)])
        }
        if let clumpifyLog {
            options[FASTQStorageRecordKey.clumpifyGroups] = clumpifyLog.groups.map(ParameterValue.integer)
            options[FASTQStorageRecordKey.clumpifyMemoryEstimateLine] = clumpifyLog.memoryEstimate
                .map(ParameterValue.string)
            options[FASTQStorageRecordKey.clumpifyMemoryAvailableLine] = clumpifyLog.memoryAvailable
                .map(ParameterValue.string)
        }
        return options.isEmpty ? nil : options
    }

    /// The `writer` value of a probe. A `bgzip` that answered is named in the node's tool form: the version its own
    /// `bgzip -h` stated, read on this Mac (`observed`), no build, since `bgzip -h` states none, and its path. A
    /// probe that read no version records an empty version from `unknown`, which the parity test fails (XC-4 B).
    static func writerValue(_ probe: PortableBBToolsWriterProbe) -> ParameterValue {
        switch probe.writer {
        case .nativeBGZF:
            return .dictionary(["name": .string(probe.writer.name)])
        case .bgzip(let executable, let arguments):
            return .dictionary([
                "name": .string(probe.writer.name),
                "tool": .dictionary([
                    "id": .string("bgzip"),
                    "version": .string(probe.version ?? ""),
                    "build": .string(""),
                    "path": .string(executable.path),
                    "versionSource": .string(probe.version == nil ? "unknown" : "observed"),
                ]),
                "arguments": .array(arguments.map(ParameterValue.string)),
            ])
        }
    }

    /// The writer probe of the binning route's `reformat.sh`, run with the environment `NativeToolRunner` gives
    /// `reformat.sh` when its caller names none, so the probe tests the very `PATH` it reads (ARCH N3 condition 1).
    /// Nil for an output whose name does not end in `.gz`, which BBTools writes as plain text through no bgzip (the ONT
    /// chunk pass writes plain chunks), and for an argv with no `zl=`.
    func reformatWriterProbe(arguments: [String], outputFile: URL, threads: Int) async throws -> PortableBBToolsWriterProbe? {
        guard outputFile.pathExtension.lowercased() == "gz",
              let level = PortableStorageStep<NativeToolStorageLauncher>.compressionLevel(of: arguments) else {
            return nil
        }
        let environment = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: runner.homeDirectory,
            existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            appIdentity: runner.appIdentity
        )
        return try await storageStep.probeBBToolsWriter(
            environment: environment, compressionLevel: level, threads: max(1, threads)
        )
    }

    /// The record of the binning route's `reformat.sh` launch, with what its writer probe found.
    func reformatStep(
        command: [String], config: FASTQIngestionConfig, outputFile: URL, result: NativeToolResult,
        clock: ProvenanceRunClock, completedAt: Date, writerProbe: PortableBBToolsWriterProbe?
    ) async -> (step: StepExecution, evidence: ToolVersionEvidence) {
        let evidence = await versionEvidence(for: .reformat)
        let step = StepExecution(
            toolName: "reformat.sh",
            toolVersion: evidence.recordedString,
            command: command,
            resolvedOptions: Self.storageResolvedOptions(writerProbe: writerProbe),
            inputs: config.inputFiles.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            },
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: completedAt.timeIntervalSince(clock.startedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            managedToolID: NativeTool.reformat.managedToolID, toolVersionEvidence: evidence,
            startTime: clock.startedAt,
            endTime: completedAt
        )
        return (step, evidence)
    }
}
