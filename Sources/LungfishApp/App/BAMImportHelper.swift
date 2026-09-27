// BAMImportHelper.swift - Headless helper-mode BAM importer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Helper-mode entrypoint used by the GUI process to import BAM/CRAM/SAM files
/// into an existing `.lungfishref` bundle in a subprocess.
public enum BAMImportHelper {
    private struct Event: Codable {
        let event: String
        let progress: Double?
        let message: String?
        let mappedReads: Int64?
        let unmappedReads: Int64?
        let sampleCount: Int?
        let indexWasCreated: Bool?
        let wasSorted: Bool?
        let error: String?
    }

    public static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.contains("--bam-import-helper") else { return nil }

        guard let bamPath = value(for: "--bam-path", in: arguments),
              let bundlePath = value(for: "--bundle-path", in: arguments)
        else {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                mappedReads: nil,
                unmappedReads: nil,
                sampleCount: nil,
                indexWasCreated: nil,
                wasSorted: nil,
                error: "Missing required helper arguments: --bam-path and --bundle-path"
            ))
            return 2
        }

        let bamURL = URL(fileURLWithPath: bamPath)
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let name = value(for: "--name", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trackName = (name?.isEmpty == true) ? nil : name

        final class ExitCodeBox: @unchecked Sendable {
            var value: Int32 = 0
        }

        let semaphore = DispatchSemaphore(value: 0)
        let exitState = ExitCodeBox()

        Task.detached(priority: .userInitiated) {
            do {
                emit(Event(
                    event: "started",
                    progress: 0.0,
                    message: "Starting alignment import helper...",
                    mappedReads: nil,
                    unmappedReads: nil,
                    sampleCount: nil,
                    indexWasCreated: nil,
                    wasSorted: nil,
                    error: nil
                ))

                let result = try await BAMImportService.importBAM(
                    bamURL: bamURL,
                    bundleURL: bundleURL,
                    name: trackName
                ) { progress, message in
                    emit(Event(
                        event: "progress",
                        progress: max(0.0, min(1.0, progress)),
                        message: message,
                        mappedReads: nil,
                        unmappedReads: nil,
                        sampleCount: nil,
                        indexWasCreated: nil,
                        wasSorted: nil,
                        error: nil
                    ))
                }

                emit(Event(
                    event: "done",
                    progress: 1.0,
                    message: "Alignment import complete",
                    mappedReads: result.mappedReads,
                    unmappedReads: result.unmappedReads,
                    sampleCount: result.sampleNames.count,
                    indexWasCreated: result.indexWasCreated,
                    wasSorted: result.wasSorted,
                    error: nil
                ))
            } catch {
                exitState.value = 1
                emit(Event(
                    event: "error",
                    progress: nil,
                    message: nil,
                    mappedReads: nil,
                    unmappedReads: nil,
                    sampleCount: nil,
                    indexWasCreated: nil,
                    wasSorted: nil,
                    error: error.localizedDescription
                ))
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitState.value
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else {
            return nil
        }
        return arguments[idx + 1]
    }

    private static func emit(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        if let outputData = line.data(using: .utf8) {
            FileHandle.standardOutput.write(outputData)
        }
    }
}

