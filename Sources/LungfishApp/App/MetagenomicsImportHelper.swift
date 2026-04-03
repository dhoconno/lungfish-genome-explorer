// MetagenomicsImportHelper.swift - Headless helper-mode importer for classifier result directories
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Helper-mode entrypoint used by GUI imports to execute metagenomics imports
/// in a subprocess using the same shared service as `lungfish-cli import`.
public enum MetagenomicsImportHelper {
    private struct Event: Codable {
        let event: String
        let progress: Double?
        let message: String?
        let resultPath: String?
        let sampleName: String?
        let totalReads: Int?
        let speciesCount: Int?
        let virusCount: Int?
        let taxonCount: Int?
        let fetchedReferenceCount: Int?
        let createdBAM: Bool?
        let fileCount: Int?
        let reportEntryCount: Int?
        let error: String?
    }

    public static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.contains("--metagenomics-import-helper") else { return nil }

        guard let kindRaw = value(for: "--kind", in: arguments),
              let kind = MetagenomicsImportKind(rawValue: kindRaw.lowercased()),
              let inputPath = value(for: "--input-path", in: arguments),
              let outputDirPath = value(for: "--output-dir", in: arguments)
        else {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                resultPath: nil,
                sampleName: nil,
                totalReads: nil,
                speciesCount: nil,
                virusCount: nil,
                taxonCount: nil,
                fetchedReferenceCount: nil,
                createdBAM: nil,
                fileCount: nil,
                reportEntryCount: nil,
                error: "Missing required helper arguments: --kind, --input-path, --output-dir"
            ))
            return 2
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputDirectory = URL(fileURLWithPath: outputDirPath)
        let secondaryInputURL = value(for: "--secondary-input", in: arguments).map {
            URL(fileURLWithPath: $0)
        }
        let preferredName = value(for: "--name", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = preferredName?.isEmpty == true ? nil : preferredName
        let fetchReferences = boolValue(
            for: "--fetch-references",
            in: arguments,
            defaultValue: true
        )

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
                    message: "Starting import...",
                    resultPath: nil,
                    sampleName: nil,
                    totalReads: nil,
                    speciesCount: nil,
                    virusCount: nil,
                    taxonCount: nil,
                    fetchedReferenceCount: nil,
                    createdBAM: nil,
                    fileCount: nil,
                    reportEntryCount: nil,
                    error: nil
                ))

                switch kind {
                case .kraken2:
                    let result = try MetagenomicsImportService.importKraken2(
                        kreportURL: inputURL,
                        outputDirectory: outputDirectory,
                        outputFileURL: secondaryInputURL,
                        preferredName: normalizedName
                    ) { progress, message in
                        emit(Event(
                            event: "progress",
                            progress: max(0.0, min(1.0, progress)),
                            message: message,
                            resultPath: nil,
                            sampleName: nil,
                            totalReads: nil,
                            speciesCount: nil,
                            virusCount: nil,
                            taxonCount: nil,
                            fetchedReferenceCount: nil,
                            createdBAM: nil,
                            fileCount: nil,
                            reportEntryCount: nil,
                            error: nil
                        ))
                    }

                    emit(Event(
                        event: "done",
                        progress: 1.0,
                        message: "Imported Kraken2 result: \(formatNumber(result.totalReads)) reads, \(result.speciesCount) species",
                        resultPath: result.resultDirectory.path,
                        sampleName: nil,
                        totalReads: result.totalReads,
                        speciesCount: result.speciesCount,
                        virusCount: nil,
                        taxonCount: nil,
                        fetchedReferenceCount: nil,
                        createdBAM: nil,
                        fileCount: nil,
                        reportEntryCount: nil,
                        error: nil
                    ))

                case .esviritu:
                    let result = try MetagenomicsImportService.importEsViritu(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        preferredName: normalizedName
                    ) { progress, message in
                        emit(Event(
                            event: "progress",
                            progress: max(0.0, min(1.0, progress)),
                            message: message,
                            resultPath: nil,
                            sampleName: nil,
                            totalReads: nil,
                            speciesCount: nil,
                            virusCount: nil,
                            taxonCount: nil,
                            fetchedReferenceCount: nil,
                            createdBAM: nil,
                            fileCount: nil,
                            reportEntryCount: nil,
                            error: nil
                        ))
                    }

                    emit(Event(
                        event: "done",
                        progress: 1.0,
                        message: "Imported EsViritu result: \(result.importedFileCount) files, \(result.virusCount) detections",
                        resultPath: result.resultDirectory.path,
                        sampleName: nil,
                        totalReads: nil,
                        speciesCount: nil,
                        virusCount: result.virusCount,
                        taxonCount: nil,
                        fetchedReferenceCount: nil,
                        createdBAM: nil,
                        fileCount: result.importedFileCount,
                        reportEntryCount: nil,
                        error: nil
                    ))

                case .taxtriage:
                    let result = try MetagenomicsImportService.importTaxTriage(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        preferredName: normalizedName
                    ) { progress, message in
                        emit(Event(
                            event: "progress",
                            progress: max(0.0, min(1.0, progress)),
                            message: message,
                            resultPath: nil,
                            sampleName: nil,
                            totalReads: nil,
                            speciesCount: nil,
                            virusCount: nil,
                            taxonCount: nil,
                            fetchedReferenceCount: nil,
                            createdBAM: nil,
                            fileCount: nil,
                            reportEntryCount: nil,
                            error: nil
                        ))
                    }

                    emit(Event(
                        event: "done",
                        progress: 1.0,
                        message: "Imported TaxTriage result: \(result.importedFileCount) files",
                        resultPath: result.resultDirectory.path,
                        sampleName: nil,
                        totalReads: nil,
                        speciesCount: nil,
                        virusCount: nil,
                        taxonCount: nil,
                        fetchedReferenceCount: nil,
                        createdBAM: nil,
                        fileCount: result.importedFileCount,
                        reportEntryCount: result.reportEntryCount,
                        error: nil
                    ))

                case .naomgs:
                    let result = try await MetagenomicsImportService.importNaoMgs(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        sampleName: nil,
                        fetchReferences: fetchReferences,
                        preferredName: normalizedName
                    ) { progress, message in
                        emit(Event(
                            event: "progress",
                            progress: max(0.0, min(1.0, progress)),
                            message: message,
                            resultPath: nil,
                            sampleName: nil,
                            totalReads: nil,
                            speciesCount: nil,
                            virusCount: nil,
                            taxonCount: nil,
                            fetchedReferenceCount: nil,
                            createdBAM: nil,
                            fileCount: nil,
                            reportEntryCount: nil,
                            error: nil
                        ))
                    }

                    emit(Event(
                        event: "done",
                        progress: 1.0,
                        message: "Imported NAO-MGS result: \(formatNumber(result.totalHitReads)) reads, \(result.taxonCount) taxa",
                        resultPath: result.resultDirectory.path,
                        sampleName: result.sampleName,
                        totalReads: result.totalHitReads,
                        speciesCount: nil,
                        virusCount: nil,
                        taxonCount: result.taxonCount,
                        fetchedReferenceCount: result.fetchedReferenceCount,
                        createdBAM: result.createdBAM,
                        fileCount: nil,
                        reportEntryCount: nil,
                        error: nil
                    ))
                }
            } catch {
                exitState.value = 1
                let partialPath: String?
                if case .importAborted(let dir, _) = error as? MetagenomicsImportError {
                    partialPath = dir.path
                } else {
                    partialPath = nil
                }
                emit(Event(
                    event: "error",
                    progress: nil,
                    message: nil,
                    resultPath: partialPath,
                    sampleName: nil,
                    totalReads: nil,
                    speciesCount: nil,
                    virusCount: nil,
                    taxonCount: nil,
                    fetchedReferenceCount: nil,
                    createdBAM: nil,
                    fileCount: nil,
                    reportEntryCount: nil,
                    error: error.localizedDescription
                ))
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitState.value
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else {
            return nil
        }
        return arguments[flagIndex + 1]
    }

    private static func boolValue(
        for flag: String,
        in arguments: [String],
        defaultValue: Bool
    ) -> Bool {
        guard let raw = value(for: flag, in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return defaultValue
        }
    }

    private static func emit(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if let outputData = line.data(using: .utf8) {
            FileHandle.standardOutput.write(outputData)
        }
    }

    private static func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
