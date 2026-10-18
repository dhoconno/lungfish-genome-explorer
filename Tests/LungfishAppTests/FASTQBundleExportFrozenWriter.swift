// FASTQBundleExportFrozenWriter.swift - The sidebar FASTQ export writer as AppDelegate held it at the 12.38 base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Side A of FASTQBundleExportCLIGUIParityReplayTests. The writer is the body of
// `AppDelegate.exportFASTQBundleForSidebar` and `makeFASTQExportProvenanceEnvelope` at add9b0713, frozen here since
// the lane deletes it from AppDelegate. It keeps the payload branches (copy, join the chunks' bytes, materialize and
// copy) and the record, and drops the atomic backup of an output that already exists, which no case has. A derived
// bundle goes through `FASTQCLIMaterializer`, which `FASTQDerivativeService.materializeDatasetFASTQ` wraps in one
// call, so the bytes are the app's.

import Foundation
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

enum FASTQBundleExportFrozenWriter {
    static func export(bundleURL: URL, outputURL: URL, isDerived: Bool) async throws {
        let runClock = ProvenanceRunClock()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stagedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).frozen.export")
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        var fastqURLs: [URL] = []
        if isDerived {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fastq-export-frozen-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            let materializedURL = try await FASTQCLIMaterializer(runner: NativeToolRunner.shared)
                .materialize(bundleURL: bundleURL, tempDirectory: tempDirectory)
            try FileManager.default.copyItem(at: materializedURL, to: stagedURL)
        } else {
            guard let urls = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), !urls.isEmpty else {
                throw NSError(domain: "com.lungfish.browser", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No FASTQ file found inside bundle"])
            }
            fastqURLs = urls
            if urls.count == 1 {
                try FileManager.default.copyItem(at: urls[0], to: stagedURL)
            } else {
                FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
                let outputHandle = try FileHandle(forWritingTo: stagedURL)
                defer { try? outputHandle.close() }
                for inputURL in urls {
                    let inputHandle = try FileHandle(forReadingFrom: inputURL)
                    defer { try? inputHandle.close() }
                    while true {
                        let chunk = try inputHandle.read(upToCount: 1 << 20) ?? Data()
                        if chunk.isEmpty { break }
                        try outputHandle.write(contentsOf: chunk)
                    }
                }
            }
        }

        let tempRecord = ProvenanceRecorder.fileRecord(url: stagedURL, format: .fastq, role: .output)
        let outputRecord = FileRecord(
            path: outputURL.standardizedFileURL.path,
            sha256: tempRecord.sha256,
            sizeBytes: tempRecord.sizeBytes,
            format: tempRecord.format,
            role: tempRecord.role
        )
        let envelope = makeEnvelope(
            sourceBundleURL: bundleURL,
            inputFASTQURLs: fastqURLs,
            outputURL: outputURL,
            outputRecord: outputRecord,
            isDerived: isDerived,
            startedAt: runClock.startedAt,
            completedAt: runClock.now
        )
        try FileManager.default.moveItem(at: stagedURL, to: outputURL)
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
    }

    /// `makeFASTQExportProvenanceEnvelope` of add9b0713.
    private static func makeEnvelope(
        sourceBundleURL: URL,
        inputFASTQURLs: [URL],
        outputURL: URL,
        outputRecord: FileRecord,
        isDerived: Bool,
        startedAt: Date,
        completedAt: Date
    ) -> ProvenanceEnvelope {
        var inputRecords: [FileRecord]
        if inputFASTQURLs.isEmpty {
            inputRecords = [ProvenanceRecorder.fileRecord(url: sourceBundleURL, format: .unknown, role: .input)]
        } else {
            inputRecords = inputFASTQURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            }
        }

        let sourceManifestURL = sourceBundleURL.appendingPathComponent(FASTQSourceFileManifest.filename)
        if FileManager.default.fileExists(atPath: sourceManifestURL.path) {
            inputRecords.append(ProvenanceRecorder.fileRecord(url: sourceManifestURL, format: .json, role: .input))
        }
        let derivedManifestURL = FASTQBundle.derivedManifestURL(in: sourceBundleURL)
        if FileManager.default.fileExists(atPath: derivedManifestURL.path) {
            inputRecords.append(ProvenanceRecorder.fileRecord(url: derivedManifestURL, format: .json, role: .input))
        }

        var argv = [
            "Lungfish Genome Explorer",
            "export-fastq",
            sourceBundleURL.path,
            "--output",
            outputURL.path,
        ]
        if isDerived {
            argv.append("--materialize-derived")
        }
        if inputFASTQURLs.count > 1 {
            argv.append(contentsOf: ["--source-chunks", "\(inputFASTQURLs.count)"])
        }

        let step = StepExecution(
            toolName: "Lungfish Genome Explorer FASTQ Export",
            toolVersion: WorkflowRun.currentAppVersion,
            command: argv,
            inputs: inputRecords,
            outputs: [outputRecord],
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(startedAt),
            startTime: startedAt,
            endTime: completedAt
        )
        let run = WorkflowRun(
            name: "FASTQ Export",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            steps: [step],
            parameters: [
                "sourceBundle": .file(sourceBundleURL),
                "output": .file(outputURL),
                "isDerived": .boolean(isDerived),
                "inputChunkCount": .integer(inputFASTQURLs.count),
                "outputGzipCompressed": .boolean(outputURL.isGzipCompressed),
            ]
        )
        return run.canonicalEnvelope()
    }
}
