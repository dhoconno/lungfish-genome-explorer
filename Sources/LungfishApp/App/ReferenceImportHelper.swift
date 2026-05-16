// ReferenceImportHelper.swift - Headless helper-mode reference importer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Helper-mode entrypoint used by the GUI process to import standalone
/// reference sequence files as `.lungfishref` bundles in a subprocess.
public enum ReferenceImportHelper {
    public typealias ImportAction = @MainActor @Sendable (
        _ sourceURL: URL,
        _ outputDirectory: URL,
        _ preferredBundleName: String?,
        _ progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> ReferenceBundleImportResult

    private struct Event: Codable {
        let event: String
        let progress: Double?
        let message: String?
        let bundlePath: String?
        let bundleName: String?
        let error: String?
    }

    public static func runIfRequested(
        arguments: [String],
        importAction: ImportAction? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) -> Int32? {
        guard arguments.contains("--reference-import-helper") else { return nil }

        guard let inputPath = value(for: "--input-file", in: arguments),
              let outputDirPath = value(for: "--output-dir", in: arguments)
        else {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                bundlePath: nil,
                bundleName: nil,
                error: "Missing required helper arguments: --input-file and --output-dir"
            ))
            return 2
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputDirectory = URL(fileURLWithPath: outputDirPath)
        let preferredName = value(for: "--name", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = preferredName?.isEmpty == true ? nil : preferredName

        final class ExitCodeBox: @unchecked Sendable {
            private let lock = NSLock()
            var value: Int32 = 0
            var isFinished = false

            func finish(with exitCode: Int32) {
                lock.lock()
                value = exitCode
                isFinished = true
                lock.unlock()
            }

            func snapshot() -> (isFinished: Bool, value: Int32) {
                lock.lock()
                defer { lock.unlock() }
                return (isFinished, value)
            }
        }

        let exitState = ExitCodeBox()

        Task { @MainActor in
            do {
                emit(Event(
                    event: "started",
                    progress: 0.0,
                    message: "Starting reference import helper...",
                    bundlePath: nil,
                    bundleName: nil,
                    error: nil
                ))

                let action = importAction ?? defaultImportAction
                let result = try await action(inputURL, outputDirectory, bundleName) { progress, message in
                    progressHandler?(progress, message)
                    emit(Event(
                        event: "progress",
                        progress: max(0.0, min(1.0, progress)),
                        message: message,
                        bundlePath: nil,
                        bundleName: nil,
                        error: nil
                    ))
                }

                emit(Event(
                    event: "done",
                    progress: 1.0,
                    message: "Reference import complete",
                    bundlePath: result.bundleURL.path,
                    bundleName: result.bundleName,
                    error: nil
                ))
                exitState.finish(with: 0)
            } catch {
                emit(Event(
                    event: "error",
                    progress: nil,
                    message: nil,
                    bundlePath: nil,
                    bundleName: nil,
                    error: error.localizedDescription
                ))
                exitState.finish(with: 1)
            }
        }

        while true {
            let snapshot = exitState.snapshot()
            if snapshot.isFinished {
                return snapshot.value
            }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else {
            return nil
        }
        return arguments[flagIndex + 1]
    }

    private static func emit(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if let outputData = line.data(using: .utf8) {
            FileHandle.standardOutput.write(outputData)
        }
    }

    @MainActor
    private static func defaultImportAction(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> ReferenceBundleImportResult {
        try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            preferredBundleName: preferredBundleName,
            progressHandler: progressHandler
        )
    }
}
