// VCFImportHelper.swift - Headless helper-mode VCF importer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

/// Helper-mode entrypoint used by the GUI process to import VCF out-of-process.
///
/// Invoked by launching the same app executable with `--vcf-import-helper` and
/// passing import parameters as command-line options.  Also supports
/// `--vcf-resume-helper` to finish an interrupted import (index creation only).
public enum VCFImportHelper {
    private static func phaseMessage(_ phase: Int, _ total: Int, _ message: String) -> String {
        "Phase \(phase)/\(total): \(message)"
    }

    private struct Event: Codable {
        let event: String
        let progress: Double?
        let message: String?
        let variantCount: Int?
        let error: String?
        let profile: String?
    }

    private static func configureDebugLogging(arguments: [String]) -> URL? {
        guard let rawPath = value(for: "--debug-log-path", in: arguments) else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    private static func appendDebugLog(_ message: String, debugLogURL: URL?) {
        guard let debugLogURL else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let rssText: String
        if let rssMB = currentResidentMemoryMB() {
            rssText = " rss=\(rssMB)MB"
        } else {
            rssText = ""
        }
        let line = "\(timestamp) pid=\(getpid())\(rssText) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: debugLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: debugLogURL, options: .atomic)
        }
    }

    private static func currentResidentMemoryMB() -> UInt64? {
#if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size) / (1024 * 1024)
#else
        return nil
#endif
    }

    public static func runIfRequested(arguments: [String]) -> Int32? {
        let debugLogURL = configureDebugLogging(arguments: arguments)
        let helperLabel = value(for: "--helper-label", in: arguments) ?? "root"
        appendDebugLog(
            "helper-entry label=\(helperLabel) args=\(arguments.joined(separator: " "))",
            debugLogURL: debugLogURL
        )

        if arguments.contains("--vcf-materialize-helper") {
            return runMaterialize(arguments: arguments)
        }
        if arguments.contains("--vcf-resume-helper") {
            return runResume(arguments: arguments)
        }
        guard arguments.contains("--vcf-import-helper") else { return nil }

        guard let vcfPath = value(for: "--vcf-path", in: arguments),
              let outputDBPath = value(for: "--output-db-path", in: arguments)
        else {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: "Missing required helper arguments: --vcf-path and --output-db-path",
                profile: nil
            ))
            return 2
        }

        let requestedProfile = parseProfile(value(for: "--import-profile", in: arguments)) ?? .auto
        let sourceFile = value(for: "--source-file", in: arguments)
            ?? URL(fileURLWithPath: vcfPath).lastPathComponent
        let targetChromosome = value(for: "--chromosome", in: arguments)
        let quietProgress = arguments.contains("--quiet-progress")
        appendDebugLog(
            "import-start profile=\(requestedProfile.rawValue) targetChromosome=\(targetChromosome ?? "nil") quietProgress=\(quietProgress)",
            debugLogURL: debugLogURL
        )

        if let debugPath = value(for: "--debug-log-path", in: arguments),
           !debugPath.isEmpty {
            emit(Event(
                event: "progress",
                progress: 0.0,
                message: "Debug log: \(debugPath)",
                variantCount: nil,
                error: nil,
                profile: nil
            ))
        }

        emit(Event(
            event: "started",
            progress: 0.0,
            message: phaseMessage(1, 4, "Starting helper import"),
            variantCount: nil,
            error: nil,
            profile: requestedProfile.rawValue
        ))

        do {
            let vcfURL = URL(fileURLWithPath: vcfPath)
            let outputDBURL = URL(fileURLWithPath: outputDBPath)
            let variantCount: Int

            if let targetChromosome, !targetChromosome.isEmpty {
                appendDebugLog("import-mode=single-chromosome chrom=\(targetChromosome)", debugLogURL: debugLogURL)
                variantCount = try runSingleChromosomeImport(
                    vcfURL: vcfURL,
                    outputDBURL: outputDBURL,
                    sourceFile: sourceFile,
                    importProfile: requestedProfile,
                    chromosome: targetChromosome,
                    emitProgress: !quietProgress,
                    debugLogURL: debugLogURL
                )
            } else {
                let contigs = try VariantDatabase.contigsInVCFHeader(url: vcfURL, maxChromosomes: 512)
                appendDebugLog("header-contigs count=\(contigs.count)", debugLogURL: debugLogURL)
                let shouldUsePerChromosome = shouldUsePerChromosomeSubprocess(
                    vcfURL: vcfURL,
                    requestedProfile: requestedProfile,
                    contigCount: contigs.count
                )
                if contigs.isEmpty || !shouldUsePerChromosome {
                    // Fallback to a standard single-pass helper import when contig metadata
                    // is missing or the input does not meet per-chromosome thresholds.
                    let reason = contigs.isEmpty ? "no-contigs" : "below-size-threshold"
                    appendDebugLog("import-mode=single-pass-fallback (\(reason))", debugLogURL: debugLogURL)
                    variantCount = try runSingleChromosomeImport(
                        vcfURL: vcfURL,
                        outputDBURL: outputDBURL,
                        sourceFile: sourceFile,
                        importProfile: requestedProfile,
                        chromosome: nil,
                        emitProgress: !quietProgress,
                        debugLogURL: debugLogURL
                    )
                } else {
                    appendDebugLog(
                        "import-mode=per-chromosome-subprocess contigs=\(contigs.count) reason=large-vcf",
                        debugLogURL: debugLogURL
                    )
                    variantCount = try runPerChromosomeSubprocessImport(
                        vcfURL: vcfURL,
                        outputDBURL: outputDBURL,
                        sourceFile: sourceFile,
                        importProfile: requestedProfile,
                        chromosomes: contigs,
                        debugLogURL: debugLogURL
                    )
                }
            }

            emit(Event(
                event: "done",
                progress: 1.0,
                message: phaseMessage(4, 4, "Import complete"),
                variantCount: variantCount,
                error: nil,
                profile: requestedProfile.rawValue
            ))
            appendDebugLog("import-complete variants=\(variantCount)", debugLogURL: debugLogURL)
            return 0
        } catch let error as VariantDatabaseError {
            if case .cancelled = error {
                appendDebugLog("import-cancelled", debugLogURL: debugLogURL)
                emit(Event(
                    event: "cancelled",
                    progress: nil,
                    message: "Import cancelled",
                    variantCount: nil,
                    error: nil,
                    profile: requestedProfile.rawValue
                ))
                return 125
            }

            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: error.localizedDescription,
                profile: requestedProfile.rawValue
            ))
            appendDebugLog("import-error VariantDatabaseError=\(error.localizedDescription)", debugLogURL: debugLogURL)
            return 1
        } catch {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: error.localizedDescription,
                profile: nil
            ))
            appendDebugLog("import-error Error=\(error.localizedDescription)", debugLogURL: debugLogURL)
            return 1
        }
    }

    private static func shouldUsePerChromosomeSubprocess(
        vcfURL: URL,
        requestedProfile: VCFImportProfile,
        contigCount: Int
    ) -> Bool {
        if requestedProfile == .ultraLowMemory {
            return true
        }

        // Prefer the per-chromosome subprocess pipeline for large compressed VCFs
        // or very high-contig inputs; smaller VCFs can stay on single-pass import.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: vcfURL.path)[.size] as? Int64) ?? 0
        let perChromosomeSizeThreshold: Int64 = 1_000_000_000  // 1 GB
        if fileSize >= perChromosomeSizeThreshold {
            return true
        }
        if contigCount >= 128 {
            return true
        }
        return false
    }

    // MARK: - Import Helpers

    private static func runSingleChromosomeImport(
        vcfURL: URL,
        outputDBURL: URL,
        sourceFile: String,
        importProfile: VCFImportProfile,
        chromosome: String?,
        emitProgress: Bool,
        debugLogURL: URL?
    ) throws -> Int {
        appendDebugLog(
            "single-import start chrom=\(chromosome ?? "all") profile=\(importProfile.rawValue) outputDB=\(outputDBURL.lastPathComponent)",
            debugLogURL: debugLogURL
        )
        let count = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: outputDBURL,
            parseGenotypes: true,
            sourceFile: sourceFile,
            progressHandler: { progress, message in
                guard emitProgress else { return }
                let msg: String
                if let chromosome {
                    msg = phaseMessage(2, 4, "[\(chromosome)] \(message)")
                } else {
                    msg = phaseMessage(2, 4, message)
                }
                emit(Event(
                    event: "progress",
                    progress: max(0.0, min(1.0, progress)),
                    message: msg,
                    variantCount: nil,
                    error: nil,
                    profile: nil
                ))
            },
            shouldCancel: nil,
            importProfile: importProfile,
            deferIndexBuild: true,
            partitionByChromosome: false,
            onlyChromosome: chromosome
        )
        appendDebugLog(
            "single-import complete chrom=\(chromosome ?? "all") variants=\(count)",
            debugLogURL: debugLogURL
        )
        return count
    }

    private static func runPerChromosomeSubprocessImport(
        vcfURL: URL,
        outputDBURL: URL,
        sourceFile: String,
        importProfile: VCFImportProfile,
        chromosomes: [String],
        debugLogURL: URL?
    ) throws -> Int {
        guard !chromosomes.isEmpty else {
            appendDebugLog(
                "per-chromosome-import requested with empty chromosome list; falling back to single pass",
                debugLogURL: debugLogURL
            )
            return try runSingleChromosomeImport(
                vcfURL: vcfURL,
                outputDBURL: outputDBURL,
                sourceFile: sourceFile,
                importProfile: importProfile,
                chromosome: nil,
                emitProgress: true,
                debugLogURL: debugLogURL
            )
        }

        guard vcfURL.pathExtension.lowercased() == "gz" else {
            appendDebugLog(
                "per-chromosome mode requires bgzip-compressed input; falling back to single-pass import",
                debugLogURL: debugLogURL
            )
            return try runSingleChromosomeImport(
                vcfURL: vcfURL,
                outputDBURL: outputDBURL,
                sourceFile: sourceFile,
                importProfile: importProfile,
                chromosome: nil,
                emitProgress: true,
                debugLogURL: debugLogURL
            )
        }

        let fm = FileManager.default
        let bcftoolsPath = try findToolExecutable(named: "bcftools")
        let tempDir = outputDBURL.deletingLastPathComponent()
        let outputStem = outputDBURL.deletingPathExtension().lastPathComponent
        let effectiveImportProfile = resolveStablePerChromosomeImportProfile(
            requested: importProfile,
            sourceVCFURL: vcfURL
        )
        let pendingSemaphore = DispatchSemaphore(value: 2)
        let importerQueue = OperationQueue()
        importerQueue.maxConcurrentOperationCount = 1
        importerQueue.qualityOfService = .userInitiated
        let state = PerChromosomeImportState()
        var splitError: Error?

        appendDebugLog(
            "per-chromosome-subprocess start requestedChromosomeCount=\(chromosomes.count) outputDB=\(outputDBURL.path) bcftools=\(bcftoolsPath) requestedProfile=\(importProfile.rawValue) effectiveProfile=\(effectiveImportProfile.rawValue)",
            debugLogURL: debugLogURL
        )
        emit(Event(
            event: "progress",
            progress: 0.01,
            message: phaseMessage(1, 4, "Preparing indexed source VCF..."),
            variantCount: nil,
            error: nil,
            profile: nil
        ))

        let createdSourceIndex = try ensureIndexedVCFGzip(
            vcfURL: vcfURL,
            bcftoolsPath: bcftoolsPath,
            debugLogURL: debugLogURL
        )
        defer {
            if let createdSourceIndex {
                try? fm.removeItem(at: createdSourceIndex)
            }
        }

        for (chromosomeIndex, chromosome) in chromosomes.enumerated() {
            if let error = state.error() {
                splitError = error
                break
            }

            pendingSemaphore.wait()

            if let error = state.error() {
                pendingSemaphore.signal()
                splitError = error
                break
            }

            let splitProgress = 0.02 + (Double(chromosomeIndex) / Double(max(chromosomes.count, 1))) * 0.18
            emit(Event(
                event: "progress",
                progress: max(0.0, min(1.0, splitProgress)),
                message: phaseMessage(1, 4, "Creating shard \(chromosomeIndex + 1) of \(chromosomes.count): \(chromosome)"),
                variantCount: nil,
                error: nil,
                profile: nil
            ))

            let token = safeFilenameToken(chromosome)
            let shardURL = tempDir.appendingPathComponent("\(outputStem).split.\(chromosomeIndex).\(token).vcf.gz")

            let variantCount: Int
            do {
                variantCount = try createIndexedChromosomeShard(
                    sourceVCFURL: vcfURL,
                    chromosome: chromosome,
                    shardURL: shardURL,
                    bcftoolsPath: bcftoolsPath,
                    debugLogURL: debugLogURL
                )
            } catch {
                pendingSemaphore.signal()
                state.setErrorIfNeeded(error)
                splitError = error
                break
            }

            guard variantCount > 0 else {
                pendingSemaphore.signal()
                removeChromosomeShardArtifacts(shardURL: shardURL)
                emit(Event(
                    event: "progress",
                    progress: max(0.0, min(1.0, splitProgress)),
                    message: phaseMessage(1, 4, "Skipping empty chromosome shard: \(chromosome)"),
                    variantCount: nil,
                    error: nil,
                    profile: nil
                ))
                continue
            }

            importerQueue.addOperation { [state] in
                defer { pendingSemaphore.signal() }

                if state.error() != nil {
                    removeChromosomeShardArtifacts(shardURL: shardURL)
                    return
                }

                let snapshot = state.snapshotForNextImport()
                let isFirstImport = snapshot.isFirstImport
                let importedBefore = snapshot.importedBefore
                let totalForProgress = max(chromosomes.count, 1)
                let importStart = 0.20 + (Double(importedBefore) / Double(totalForProgress)) * 0.75

                emit(Event(
                    event: "progress",
                    progress: max(0.0, min(1.0, importStart)),
                    message: phaseMessage(2, 4, "Importing chromosome \(chromosome) (\(variantCount) variants)"),
                    variantCount: nil,
                    error: nil,
                    profile: nil
                ))

                let targetDBURL: URL = {
                    if isFirstImport { return outputDBURL }
                    return tempDir.appendingPathComponent("\(outputStem).part.\(chromosomeIndex).\(token).db")
                }()

                do {
                    let chromCount = try runChromosomeChildImport(
                        vcfURL: shardURL,
                        outputDBURL: targetDBURL,
                        sourceFile: sourceFile,
                        importProfile: effectiveImportProfile,
                        chromosomeLabel: chromosome,
                        onlyChromosome: chromosome,
                        quietProgress: true,
                        debugLogURL: debugLogURL,
                        progressHandler: { childProgress, childMessage in
                            let mapped = importStart + max(0.0, min(1.0, childProgress)) * (0.75 / Double(totalForProgress))
                            emit(Event(
                                event: "progress",
                                progress: max(0.0, min(1.0, mapped)),
                                message: phaseMessage(2, 4, "[\(chromosome)] \(childMessage)"),
                                variantCount: nil,
                                error: nil,
                                profile: nil
                            ))
                        }
                    )

                    removeChromosomeShardArtifacts(shardURL: shardURL)

                    if isFirstImport {
                        state.recordFirstImport(variantCount: chromCount)
                        try setMetadataValue(at: outputDBURL, key: "import_state", value: "inserting")
                        try setMetadataValue(at: outputDBURL, key: "import_partition_mode", value: "helper-subprocess-per-chromosome")
                    } else {
                        defer { removeTemporaryDatabaseArtifacts(dbURL: targetDBURL) }
                        let merged = try VariantDatabase.mergeImportedDatabase(into: outputDBURL, from: targetDBURL)
                        state.recordMergedImport(variantCount: merged)
                        try setMetadataValue(at: outputDBURL, key: "import_state", value: "inserting")
                    }

                    let importedAfter = state.importedCount()
                    let finished = 0.20 + (Double(importedAfter) / Double(totalForProgress)) * 0.75
                    emit(Event(
                        event: "progress",
                        progress: max(0.0, min(1.0, finished)),
                        message: phaseMessage(2, 4, "Imported chromosome \(chromosome)"),
                        variantCount: nil,
                        error: nil,
                        profile: nil
                    ))
                } catch {
                    removeChromosomeShardArtifacts(shardURL: shardURL)
                    if !isFirstImport {
                        removeTemporaryDatabaseArtifacts(dbURL: targetDBURL)
                    }
                    state.setErrorIfNeeded(error)
                }
            }
        }

        importerQueue.waitUntilAllOperationsAreFinished()

        if let splitError {
            throw splitError
        }
        if let error = state.error() {
            throw error
        }
        guard state.hasImportedAnyShard() else {
            appendDebugLog(
                "no non-empty chromosome shards created; falling back to single-pass import",
                debugLogURL: debugLogURL
            )
            return try runSingleChromosomeImport(
                vcfURL: vcfURL,
                outputDBURL: outputDBURL,
                sourceFile: sourceFile,
                importProfile: importProfile,
                chromosome: nil,
                emitProgress: true,
                debugLogURL: debugLogURL
            )
        }

        try setMetadataValue(at: outputDBURL, key: "import_state", value: "indexing")
        emit(Event(
            event: "progress",
            progress: 0.95,
            message: phaseMessage(3, 4, "Insert phase complete; preparing SQLite index build..."),
            variantCount: nil,
            error: nil,
            profile: nil
        ))
        let importedTotal = state.totalImportedCount()
        if let final = try? VariantDatabase(url: outputDBURL).totalCount(),
           (final > 0 || importedTotal == 0) {
            appendDebugLog("per-chromosome-subprocess complete finalCount=\(final)", debugLogURL: debugLogURL)
            return final
        }
        appendDebugLog(
            "per-chromosome-subprocess finalCount probe returned 0; using tracked merged total \(importedTotal)",
            debugLogURL: debugLogURL
        )
        appendDebugLog("per-chromosome-subprocess complete totalImported=\(importedTotal)", debugLogURL: debugLogURL)
        return importedTotal
    }

    private static func resolveStablePerChromosomeImportProfile(
        requested: VCFImportProfile,
        sourceVCFURL: URL
    ) -> VCFImportProfile {
        guard requested == .auto else { return requested }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sourceVCFURL.path)[.size] as? Int64) ?? 0
        let inputGiB = Double(max(0, fileSize)) / Double(1 << 30)
        let physicalRAMGiB = Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)

        if inputGiB >= 5.0 || (inputGiB >= 2.0 && physicalRAMGiB <= 16.0) {
            return .ultraLowMemory
        }
        if physicalRAMGiB <= 12.0 || inputGiB >= 1.5 {
            return .lowMemory
        }
        return .fast
    }

    private final class PerChromosomeImportState: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingError: Error?
        private var totalImported = 0
        private var importedShardCount = 0
        private var firstImported = false

        func error() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return pendingError
        }

        func setErrorIfNeeded(_ error: Error) {
            lock.lock()
            if pendingError == nil {
                pendingError = error
            }
            lock.unlock()
        }

        func snapshotForNextImport() -> (isFirstImport: Bool, importedBefore: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (!firstImported, importedShardCount)
        }

        func recordFirstImport(variantCount: Int) {
            lock.lock()
            totalImported = variantCount
            importedShardCount += 1
            firstImported = true
            lock.unlock()
        }

        func recordMergedImport(variantCount: Int) {
            lock.lock()
            totalImported += variantCount
            importedShardCount += 1
            lock.unlock()
        }

        func importedCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return importedShardCount
        }

        func hasImportedAnyShard() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstImported
        }

        func totalImportedCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return totalImported
        }
    }

    private static func removeChromosomeShardArtifacts(shardURL: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: shardURL)
        try? fm.removeItem(at: URL(fileURLWithPath: shardURL.path + ".csi"))
        try? fm.removeItem(at: URL(fileURLWithPath: shardURL.path + ".tbi"))
    }

    private static func removeTemporaryDatabaseArtifacts(dbURL: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: dbURL)
        try? fm.removeItem(at: dbURL.appendingPathExtension("journal"))
        try? fm.removeItem(at: dbURL.appendingPathExtension("wal"))
        try? fm.removeItem(at: dbURL.appendingPathExtension("shm"))
    }

    private static func ensureIndexedVCFGzip(
        vcfURL: URL,
        bcftoolsPath: String,
        debugLogURL: URL?
    ) throws -> URL? {
        let fm = FileManager.default
        let csiURL = URL(fileURLWithPath: vcfURL.path + ".csi")
        let tbiURL = URL(fileURLWithPath: vcfURL.path + ".tbi")

        if fm.fileExists(atPath: csiURL.path) || fm.fileExists(atPath: tbiURL.path) {
            appendDebugLog("source-index exists for \(vcfURL.lastPathComponent)", debugLogURL: debugLogURL)
            return nil
        }

        appendDebugLog("source-index creating for \(vcfURL.lastPathComponent)", debugLogURL: debugLogURL)
        _ = try runExternalTool(
            executablePath: bcftoolsPath,
            arguments: ["index", "--csi", "-f", vcfURL.path],
            label: "bcftools index source",
            debugLogURL: debugLogURL
        )

        if fm.fileExists(atPath: csiURL.path) {
            return csiURL
        }
        if fm.fileExists(atPath: tbiURL.path) {
            return tbiURL
        }
        return nil
    }

    private static func createIndexedChromosomeShard(
        sourceVCFURL: URL,
        chromosome: String,
        shardURL: URL,
        bcftoolsPath: String,
        debugLogURL: URL?
    ) throws -> Int {
        let fm = FileManager.default
        let csiURL = URL(fileURLWithPath: shardURL.path + ".csi")
        let tbiURL = URL(fileURLWithPath: shardURL.path + ".tbi")
        try? fm.removeItem(at: shardURL)
        try? fm.removeItem(at: csiURL)
        try? fm.removeItem(at: tbiURL)

        _ = try runExternalTool(
            executablePath: bcftoolsPath,
            arguments: [
                "view",
                "--regions", chromosome,
                "-Oz",
                "-o", shardURL.path,
                sourceVCFURL.path
            ],
            label: "bcftools view \(chromosome)",
            debugLogURL: debugLogURL
        )

        _ = try runExternalTool(
            executablePath: bcftoolsPath,
            arguments: ["index", "--csi", "-f", shardURL.path],
            label: "bcftools index shard \(chromosome)",
            debugLogURL: debugLogURL
        )

        let nrecordsOutput = try runExternalTool(
            executablePath: bcftoolsPath,
            arguments: ["index", "--nrecords", shardURL.path],
            label: "bcftools index --nrecords \(chromosome)",
            debugLogURL: debugLogURL
        )

        let tokens = nrecordsOutput
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .compactMap { Int($0) }
        let recordCount = tokens.first ?? 0

        appendDebugLog(
            "shard-created chrom=\(chromosome) records=\(recordCount) file=\(shardURL.lastPathComponent)",
            debugLogURL: debugLogURL
        )
        return recordCount
    }

    private static func runExternalTool(
        executablePath: String,
        arguments: [String],
        label: String,
        debugLogURL: URL?
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        appendDebugLog("tool-start \(label): \(executablePath) \(arguments.joined(separator: " "))", debugLogURL: debugLogURL)
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        appendDebugLog(
            "tool-exit \(label) status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")",
            debugLogURL: debugLogURL
        )

        guard process.terminationStatus == 0 else {
            let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let signalSuffix: String
            if process.terminationReason == .uncaughtSignal {
                signalSuffix = " (signal \(process.terminationStatus)\(signalName(for: process.terminationStatus).map { " \($0)" } ?? ""))"
            } else {
                signalSuffix = ""
            }
            throw VariantDatabaseError.createFailed(
                errorText.isEmpty
                    ? "\(label) failed with status \(process.terminationStatus)\(signalSuffix)"
                    : "\(label) failed: \(errorText)"
            )
        }

        return stdout
    }

    private static func findToolExecutable(named tool: String) throws -> String {
        guard let nativeTool = NativeTool(rawValue: tool),
              let managedPath = BundleBuildHelpers.managedToolExecutablePath(nativeTool)
        else {
            throw VariantDatabaseError.createFailed(
                "\(tool) not found in the managed Lungfish tool environment"
            )
        }
        return managedPath
    }

    private static func runChromosomeChildImport(
        vcfURL: URL,
        outputDBURL: URL,
        sourceFile: String,
        importProfile: VCFImportProfile,
        chromosomeLabel: String,
        onlyChromosome: String?,
        quietProgress: Bool,
        debugLogURL: URL?,
        progressHandler: @escaping (Double, String) -> Void
    ) throws -> Int {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw VariantDatabaseError.createFailed("Could not locate application executable for chromosome helper import")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var childArguments: [String] = [
            "--vcf-import-helper",
            "--vcf-path", vcfURL.path,
            "--output-db-path", outputDBURL.path,
            "--source-file", sourceFile,
            "--import-profile", importProfile.rawValue,
            "--helper-label", "chrom:\(chromosomeLabel)",
        ]
        if let onlyChromosome, !onlyChromosome.isEmpty {
            childArguments.append(contentsOf: ["--chromosome", onlyChromosome])
        }
        if quietProgress {
            childArguments.append("--quiet-progress")
        }
        if let debugPath = debugLogURL?.path {
            childArguments.append(contentsOf: ["--debug-log-path", debugPath])
        }
        process.arguments = childArguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        appendDebugLog(
            "chromosome-child-launch chrom=\(chromosomeLabel) inputVCF=\(vcfURL.lastPathComponent) outputDB=\(outputDBURL.lastPathComponent)",
            debugLogURL: debugLogURL
        )
        progressHandler(0.0, phaseMessage(2, 4, "Launching helper subprocess"))

        try process.run()
        process.waitUntilExit()

        let reasonText: String = {
            switch process.terminationReason {
            case .exit:
                return "exit"
            case .uncaughtSignal:
                return "signal"
            @unknown default:
                return "unknown"
            }
        }()
        appendDebugLog(
            "chromosome-child-exit chrom=\(chromosomeLabel) status=\(process.terminationStatus) reason=\(reasonText)",
            debugLogURL: debugLogURL
        )

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        var helperError: String?
        var variantCount: Int?
        for line in stdoutData.split(separator: 0x0A) {
            guard !line.isEmpty else { continue }
            let lineData = Data(line)
            if let event = try? JSONDecoder().decode(Event.self, from: lineData) {
                switch event.event {
                case "progress":
                    progressHandler(
                        max(0.0, min(1.0, event.progress ?? 0.0)),
                        event.message ?? phaseMessage(2, 4, "Importing...")
                    )
                case "done":
                    if let count = event.variantCount {
                        variantCount = count
                    }
                case "error":
                    helperError = event.error ?? event.message ?? "Chromosome helper import failed"
                default:
                    break
                }
                continue
            }

            if let text = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               helperError == nil {
                helperError = text
            }
        }

        guard process.terminationStatus == 0 else {
            let stderrMessage = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let signalSuffix: String
            if process.terminationReason == .uncaughtSignal {
                signalSuffix = " (signal \(process.terminationStatus)\(signalName(for: process.terminationStatus).map { " \($0)" } ?? ""))"
            } else {
                signalSuffix = ""
            }
            let message = helperError
                ?? (stderrMessage?.isEmpty == false
                    ? stderrMessage!
                    : "Chromosome helper (\(chromosomeLabel)) exited with status \(process.terminationStatus)\(signalSuffix)")
            throw VariantDatabaseError.createFailed(message)
        }

        if let variantCount {
            progressHandler(1.0, phaseMessage(2, 4, "Helper subprocess complete"))
            return variantCount
        }
        return (try? VariantDatabase(url: outputDBURL).totalCount()) ?? 0
    }

    private static func safeFilenameToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let filtered = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return filtered.isEmpty ? "chrom" : filtered
    }

    private static func signalName(for code: Int32) -> String? {
        switch code {
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGTRAP: return "SIGTRAP"
        case SIGINT: return "SIGINT"
        default: return nil
        }
    }

    private static func setMetadataValue(at dbURL: URL, key: String, value: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed("Failed to open database metadata for update: \(msg)")
        }
        defer { sqlite3_close(db) }

        let escapedKey = key.replacingOccurrences(of: "'", with: "''")
        let escapedValue = value.replacingOccurrences(of: "'", with: "''")
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(
            db,
            "INSERT OR REPLACE INTO db_metadata (key, value) VALUES ('\(escapedKey)', '\(escapedValue)')",
            nil,
            nil,
            &err
        )
        if let err {
            let msg = String(cString: err)
            sqlite3_free(err)
            throw VariantDatabaseError.createFailed("Failed to update db_metadata.\(key): \(msg)")
        }
    }

    // MARK: - Resume Mode

    private static func runResume(arguments: [String]) -> Int32 {
        guard let dbPath = value(for: "--output-db-path", in: arguments) else {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: "Missing required argument: --output-db-path",
                profile: nil
            ))
            return 2
        }

        emit(Event(
            event: "started",
            progress: 0.0,
            message: phaseMessage(3, 4, "Resuming interrupted import"),
            variantCount: nil,
            error: nil,
            profile: nil
        ))

        do {
            let variantCount = try VariantDatabase.resumeImport(
                existingDBURL: URL(fileURLWithPath: dbPath),
                progressHandler: { progress, message in
                    emit(Event(
                        event: "progress",
                        progress: max(0.0, min(1.0, progress)),
                        message: phaseMessage(3, 4, message),
                        variantCount: nil,
                        error: nil,
                        profile: nil
                    ))
                },
                shouldCancel: nil
            )

            emit(Event(
                event: "done",
                progress: 1.0,
                message: phaseMessage(3, 4, "Resume complete"),
                variantCount: variantCount,
                error: nil,
                profile: nil
            ))
            return 0
        } catch let error as VariantDatabaseError {
            if case .cancelled = error {
                emit(Event(event: "cancelled", progress: nil, message: "Resume cancelled", variantCount: nil, error: nil, profile: nil))
                return 125
            }
            emit(Event(event: "error", progress: nil, message: nil, variantCount: nil, error: error.localizedDescription, profile: nil))
            return 1
        } catch {
            emit(Event(event: "error", progress: nil, message: nil, variantCount: nil, error: error.localizedDescription, profile: nil))
            return 1
        }
    }

    // MARK: - Materialize Mode

    private static func runMaterialize(arguments: [String]) -> Int32 {
        guard let dbPath = value(for: "--output-db-path", in: arguments) else {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: "Missing required argument: --output-db-path",
                profile: nil
            ))
            return 2
        }

        emit(Event(
            event: "started",
            progress: 0.0,
            message: phaseMessage(4, 4, "Materializing INFO fields"),
            variantCount: nil,
            error: nil,
            profile: nil
        ))

        do {
            let eavCount = try VariantDatabase.materializeVariantInfo(
                existingDBURL: URL(fileURLWithPath: dbPath),
                progressHandler: { progress, message in
                    emit(Event(
                        event: "progress",
                        progress: max(0.0, min(1.0, progress)),
                        message: phaseMessage(4, 4, message),
                        variantCount: nil,
                        error: nil,
                        profile: nil
                    ))
                },
                shouldCancel: nil
            )

            emit(Event(
                event: "done",
                progress: 1.0,
                message: phaseMessage(4, 4, "Materialization complete"),
                variantCount: eavCount,
                error: nil,
                profile: nil
            ))
            return 0
        } catch let error as VariantDatabaseError {
            if case .cancelled = error {
                emit(Event(event: "cancelled", progress: nil, message: "Materialization cancelled", variantCount: nil, error: nil, profile: nil))
                return 125
            }
            emit(Event(event: "error", progress: nil, message: nil, variantCount: nil, error: error.localizedDescription, profile: nil))
            return 1
        } catch {
            emit(Event(event: "error", progress: nil, message: nil, variantCount: nil, error: error.localizedDescription, profile: nil))
            return 1
        }
    }

    // MARK: - Helpers

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parseProfile(_ raw: String?) -> VCFImportProfile? {
        guard let raw else { return nil }
        if let profile = VCFImportProfile(rawValue: raw) {
            return profile
        }
        switch raw.lowercased() {
        case "low", "low-memory", "low_memory":
            return .lowMemory
        case "fast":
            return .fast
        case "auto":
            return .auto
        case "ultra-low-memory", "ultra_low_memory", "ultralow":
            return .ultraLowMemory
        default:
            return nil
        }
    }

    private static func emit(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
