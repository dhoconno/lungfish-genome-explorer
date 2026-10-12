// ClassificationPipeline+KrakenOutputCompaction.swift - The per-read output kept as gzip with its index
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ClassificationPipeline")

extension ClassificationPipeline {
    func compactKrakenOutputIfPossible(
        rawURL: URL,
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        dependsOn: [UUID]
    ) async -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rawURL.path) else { return nil }

        let compressedURL = rawURL.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedURL)
        let indexClock = ProvenanceRunClock()

        do {
            try? fm.removeItem(at: indexURL)
            try KrakenIndexDatabase.build(
                from: rawURL,
                to: indexURL,
                includeUnclassified: false
            )
            let indexCompletedAt = indexClock.now
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "lungfish-kraken2-index",
                toolVersion: WorkflowRun.currentAppVersion,
                command: [
                    CLICommandIdentity.executableName,
                    "internal",
                    "kraken2-index",
                    "--classified-only",
                    rawURL.path,
                    indexURL.path,
                ],
                inputs: [
                    ProvenanceRecorder.fileRecord(url: rawURL, format: .text, role: .input),
                ],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index),
                ],
                exitCode: 0,
                wallTime: indexCompletedAt.timeIntervalSince(indexClock.startedAt),
                dependsOn: dependsOn
            )

            let gzipClock = ProvenanceRunClock()
            try gzipCopy(source: rawURL, destination: compressedURL)
            let gzipCompletedAt = gzipClock.now
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "gzip",
                toolVersion: "system",
                command: gzipReplayCommand(source: rawURL, destination: compressedURL),
                inputs: [
                    ProvenanceRecorder.fileRecord(url: rawURL, format: .text, role: .input),
                ],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: compressedURL, format: .text, role: .output),
                ],
                exitCode: 0,
                wallTime: gzipCompletedAt.timeIntervalSince(gzipClock.startedAt),
                dependsOn: dependsOn
            )

            try fm.removeItem(at: rawURL)
            logger.info(
                "Compacted Kraken2 output to \(compressedURL.lastPathComponent, privacy: .public) and \(indexURL.lastPathComponent, privacy: .public)"
            )
            return compressedURL
        } catch {
            logger.warning("Failed to compact Kraken2 output; retaining raw output: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: compressedURL)
            try? fm.removeItem(at: indexURL)
        }
        return nil
    }

    private func gzipReplayCommand(source: URL, destination: URL) -> [String] {
        let command = "/usr/bin/gzip -c \(shellEscape(source.path)) > \(shellEscape(destination.path))"
        return ["/bin/sh", "-c", command]
    }

    private func gzipCopy(source: URL, destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destination)
        defer { outputHandle.closeFile() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = outputHandle
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw ClassificationPipelineError.kraken2Failed(
                exitCode: process.terminationStatus,
                stderr: stderrText
            )
        }
    }
}
