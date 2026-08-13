// AlignmentReadExtractionPublisher.swift - Atomic final publication boundary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Publishes a completed alignment-read staging transaction. It never exposes
/// a transaction payload as a final result: bundles are built in a hidden
/// sibling directory and standalone files are installed with their canonical
/// provenance sidecar as one rollback-safe pair.
public final class AlignmentReadExtractionPublisher: @unchecked Sendable {
    private let beforeFinalInstall: (@Sendable () throws -> Void)?
    private let promotionEvent: (@Sendable (AlignmentReadExtractionPromotionEvent) throws -> Void)?

    /// The injection point is intentionally at the final-install boundary so
    /// callers can exercise rollback without corrupting a real destination.
    public init(beforeFinalInstall: (@Sendable () throws -> Void)? = nil) {
        self.beforeFinalInstall = beforeFinalInstall
        self.promotionEvent = nil
    }

    /// A test-only fault boundary for failures that happen after an existing
    /// destination has been backed up. Keeping this initializer internal lets
    /// Workflow tests exercise incomplete rollback without expanding the
    /// public publication API or depending on platform-specific file faults.
    init(
        beforeFinalInstall: (@Sendable () throws -> Void)? = nil,
        promotionEvent: @escaping @Sendable (AlignmentReadExtractionPromotionEvent) throws -> Void
    ) {
        self.beforeFinalInstall = beforeFinalInstall
        self.promotionEvent = promotionEvent
    }

    public func publish(
        _ request: AlignmentReadExtractionPublicationRequest
    ) throws -> AlignmentReadExtractionPublicationResult {
        do {
            try Task.checkCancellation()
            switch request.destination {
            case .bundle:
                return try publishBundle(request)
            case .file:
                return try publishFile(request)
            }
        } catch is CancellationError {
            let record = publicationRecord(
                request: request,
                finalOutputs: [],
                startedAt: Date(),
                completedAt: Date(),
                exitStatus: nil,
                stderr: "Cancelled before publication completed."
            )
            request.transaction.appendExecutionRecord(record)
            let failure = AlignmentReadExtractionFailure(
                kind: .cancelled,
                message: "Alignment read extraction was cancelled.",
                executionRecords: request.transaction.executionRecords
            )
            request.transaction.cleanup()
            throw failure
        } catch let failure as AlignmentReadExtractionFailure {
            request.transaction.cleanup()
            throw failure
        } catch {
            let now = Date()
            let record = publicationRecord(
                request: request,
                finalOutputs: [],
                startedAt: now,
                completedAt: now,
                exitStatus: 1,
                stderr: error.localizedDescription
            )
            request.transaction.appendExecutionRecord(record)
            let failure = AlignmentReadExtractionFailure(
                kind: .publicationFailed,
                message: "Could not publish alignment read extraction: \(error.localizedDescription)",
                executionRecords: request.transaction.executionRecords
            )
            request.transaction.cleanup()
            throw failure
        }
    }

    private func publishBundle(
        _ request: AlignmentReadExtractionPublicationRequest
    ) throws -> AlignmentReadExtractionPublicationResult {
        let fileManager = FileManager.default
        let finalBundleURL = request.destination.finalURL
        guard finalBundleURL.pathExtension.lowercased() == FASTQBundle.directoryExtension else {
            throw AlignmentReadExtractionFailure(
                kind: .publicationFailed,
                message: "Alignment read bundles must end in .\(FASTQBundle.directoryExtension).",
                executionRecords: request.transaction.executionRecords
            )
        }

        let startedAt = Date()
        let publicationStagingURL = siblingStagingDirectory(for: finalBundleURL)
        do {
            try fileManager.createDirectory(
                at: finalBundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: publicationStagingURL,
                withIntermediateDirectories: false
            )

            let copied = try copyPayloads(
                from: request.transaction,
                toBundle: publicationStagingURL,
                finalBundleURL: finalBundleURL
            )
            let metadataURL = publicationStagingURL.appendingPathComponent("extraction-metadata.json")
            try writeBundleMetadata(
                to: metadataURL,
                request: request,
                finalPayloadURLs: copied.finalURLs,
                stagingToFinal: copied.mapping
            )

            let payloadDescriptors = try zip(
                copied.physicalURLs,
                copied.finalURLs
            ).enumerated().map { index, pair in
                try publishedDescriptor(
                    physicalURL: pair.0,
                    finalURL: pair.1,
                    format: request.transaction.stagedFiles[index].format,
                    originURL: request.transaction.stagedFiles[index].stagedURL
                )
            }
            let finalMetadataURL = finalBundleURL.appendingPathComponent("extraction-metadata.json")
            let metadataDescriptor = try publishedDescriptor(
                physicalURL: metadataURL,
                finalURL: finalMetadataURL,
                format: .json,
                originURL: metadataURL
            )
            let finalOutputs = payloadDescriptors + [metadataDescriptor]
            let completedAt = Date()
            let record = publicationRecord(
                request: request,
                finalOutputs: finalOutputs,
                startedAt: startedAt,
                completedAt: completedAt,
                exitStatus: 0,
                stderr: nil
            )
            let finalRecords = finalExecutionRecords(
                request.transaction.executionRecords + [record],
                transactionRoot: request.transaction.stagingDirectoryURL,
                stagingToFinal: copied.mapping
            )
            let envelope = try provenanceEnvelope(
                request: request,
                finalOutputs: finalOutputs,
                finalRecords: finalRecords,
                stagingToFinal: copied.mapping,
                startedAt: request.transaction.startedAt,
                completedAt: completedAt
            )
            _ = try ProvenanceWriter(signingProvider: nil).write(
                envelope,
                to: publicationStagingURL
            )

            try beforeFinalInstall?()
            try promoteDirectory(publicationStagingURL, to: finalBundleURL)
            request.transaction.appendExecutionRecord(record)
            request.transaction.cleanup()
            return AlignmentReadExtractionPublicationResult(
                finalURL: finalBundleURL,
                outputURLs: copied.finalURLs,
                provenanceURL: finalBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename),
                readCount: request.transaction.readCount,
                pairedEnd: request.transaction.pairedEnd,
                recordsWithoutSequence: request.transaction.recordsWithoutSequence,
                missingSequenceMessage: request.transaction.missingSequenceMessage,
                executionRecords: finalRecords
            )
        } catch let failure as AlignmentReadExtractionFailure {
            try? fileManager.removeItem(at: publicationStagingURL)
            throw failure
        } catch {
            try? fileManager.removeItem(at: publicationStagingURL)
            let completedAt = Date()
            let record = publicationRecord(
                request: request,
                finalOutputs: [],
                startedAt: startedAt,
                completedAt: completedAt,
                exitStatus: 1,
                stderr: error.localizedDescription
            )
            request.transaction.appendExecutionRecord(record)
            throw AlignmentReadExtractionFailure(
                kind: .publicationFailed,
                message: "Could not publish alignment read bundle: \(error.localizedDescription)",
                executionRecords: request.transaction.executionRecords
            )
        }
    }

    private func publishFile(
        _ request: AlignmentReadExtractionPublicationRequest
    ) throws -> AlignmentReadExtractionPublicationResult {
        let fileManager = FileManager.default
        let finalURL = request.destination.finalURL
        guard request.transaction.stagedFiles.count == 1 else {
            throw AlignmentReadExtractionFailure(
                kind: .publicationFailed,
                message: "Standalone alignment extraction requires exactly one staged payload.",
                executionRecords: request.transaction.executionRecords
            )
        }

        let startedAt = Date()
        let stagedPayloadURL = siblingStagingFile(for: finalURL)
        let stagedSidecarURL = ProvenanceRecorder.fileSidecarURL(for: stagedPayloadURL)
        do {
            try fileManager.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: request.transaction.stagedFiles[0].stagedURL, to: stagedPayloadURL)

            let finalDescriptor = try publishedDescriptor(
                physicalURL: stagedPayloadURL,
                finalURL: finalURL,
                format: request.transaction.stagedFiles[0].format,
                originURL: request.transaction.stagedFiles[0].stagedURL
            )
            let completedAt = Date()
            let record = publicationRecord(
                request: request,
                finalOutputs: [finalDescriptor],
                startedAt: startedAt,
                completedAt: completedAt,
                exitStatus: 0,
                stderr: nil
            )
            let mapping = [request.transaction.stagedFiles[0].stagedURL.path: finalURL.path]
            let finalRecords = finalExecutionRecords(
                request.transaction.executionRecords + [record],
                transactionRoot: request.transaction.stagingDirectoryURL,
                stagingToFinal: mapping
            )
            let envelope = try provenanceEnvelope(
                request: request,
                finalOutputs: [finalDescriptor],
                finalRecords: finalRecords,
                stagingToFinal: mapping,
                startedAt: request.transaction.startedAt,
                completedAt: completedAt
            )
            _ = try ProvenanceWriter(signingProvider: nil).write(
                envelope,
                toSidecar: stagedSidecarURL
            )

            try beforeFinalInstall?()
            try promoteFilePair(
                stagedPayloadURL: stagedPayloadURL,
                stagedSidecarURL: stagedSidecarURL,
                finalURL: finalURL
            )
            request.transaction.appendExecutionRecord(record)
            request.transaction.cleanup()
            return AlignmentReadExtractionPublicationResult(
                finalURL: finalURL,
                outputURLs: [finalURL],
                provenanceURL: ProvenanceRecorder.fileSidecarURL(for: finalURL),
                readCount: request.transaction.readCount,
                pairedEnd: request.transaction.pairedEnd,
                recordsWithoutSequence: request.transaction.recordsWithoutSequence,
                missingSequenceMessage: request.transaction.missingSequenceMessage,
                executionRecords: finalRecords
            )
        } catch {
            try? fileManager.removeItem(at: stagedPayloadURL)
            try? fileManager.removeItem(at: stagedSidecarURL)
            let completedAt = Date()
            let record = publicationRecord(
                request: request,
                finalOutputs: [],
                startedAt: startedAt,
                completedAt: completedAt,
                exitStatus: 1,
                stderr: error.localizedDescription
            )
            request.transaction.appendExecutionRecord(record)
            throw AlignmentReadExtractionFailure(
                kind: .publicationFailed,
                message: "Could not publish alignment read file: \(error.localizedDescription)",
                executionRecords: request.transaction.executionRecords
            )
        }
    }

    private func copyPayloads(
        from transaction: AlignmentReadExtractionTransaction,
        toBundle stagingBundleURL: URL,
        finalBundleURL: URL
    ) throws -> (physicalURLs: [URL], finalURLs: [URL], mapping: [String: String]) {
        var physicalURLs: [URL] = []
        var finalURLs: [URL] = []
        var mapping: [String: String] = [:]
        for file in transaction.stagedFiles {
            let physicalURL = try FASTQBundle.validatedBundleMemberURL(
                for: file.relativeFinalPath,
                in: stagingBundleURL,
                field: "alignmentReadExtraction.relativeFinalPath"
            )
            let finalURL = try FASTQBundle.validatedBundleMemberURL(
                for: file.relativeFinalPath,
                in: finalBundleURL,
                field: "alignmentReadExtraction.relativeFinalPath"
            )
            try FileManager.default.createDirectory(
                at: physicalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: file.stagedURL, to: physicalURL)
            physicalURLs.append(physicalURL)
            finalURLs.append(finalURL)
            mapping[file.stagedURL.path] = finalURL.path
        }
        return (physicalURLs, finalURLs, mapping)
    }

    private func writeBundleMetadata(
        to url: URL,
        request: AlignmentReadExtractionPublicationRequest,
        finalPayloadURLs: [URL],
        stagingToFinal: [String: String]
    ) throws {
        let metadata = PublishedBundleMetadata(
            workflowName: request.provenance.workflowName,
            readCount: request.transaction.readCount,
            pairedEnd: request.transaction.pairedEnd,
            recordsWithoutSequence: request.transaction.recordsWithoutSequence,
            missingSequenceMessage: request.transaction.missingSequenceMessage,
            payloadPaths: finalPayloadURLs.map(\.path),
            stagingToFinal: stagingToFinal
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    private func provenanceEnvelope(
        request: AlignmentReadExtractionPublicationRequest,
        finalOutputs: [ProvenanceFileDescriptor],
        finalRecords: [AlignmentReadExtractionExecutionRecord],
        stagingToFinal: [String: String],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let inputs = try request.provenance.inputURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, role: .input)
        }
        var resolved = request.provenance.resolvedDefaults
        resolved["readCount"] = .integer(request.transaction.readCount)
        resolved["pairedEnd"] = .boolean(request.transaction.pairedEnd)
        resolved["recordsWithoutSequence"] = .integer(request.transaction.recordsWithoutSequence)
        resolved["missingSequenceMessage"] = request.transaction.missingSequenceMessage.map(ParameterValue.string) ?? .null
        resolved["stagingToFinalMapping"] = .dictionary(
            stagingToFinal.mapValues(ParameterValue.string)
        )
        resolved["publicationMode"] = .string(
            request.destination.finalURL.pathExtension.lowercased() == FASTQBundle.directoryExtension
                ? "hidden-sibling-directory-rename-with-rollback"
                : "paired-file-rollback-safe-publication"
        )

        let steps = finalRecords.map(provenanceStep)
        let files = deduplicatedDescriptors(
            inputs + finalOutputs + steps.flatMap { $0.inputs + $0.outputs }
        )
        let stderr = finalRecords.compactMap(\.stderr).filter { !$0.isEmpty }.joined(separator: "\n")
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: request.provenance.workflowName,
            workflowVersion: request.provenance.workflowVersion,
            toolName: request.provenance.toolName,
            toolVersion: request.provenance.toolVersion,
            tool: .init(
                name: request.provenance.toolName,
                version: request.provenance.toolVersion,
                kind: "app"
            ),
            argv: request.provenance.argv,
            durableReplayArgv: request.provenance.durableReplayArgv,
            reproducibleCommand: request.provenance.argv.map(shellEscape).joined(separator: " "),
            options: .init(
                explicit: request.provenance.explicitOptions,
                defaults: request.provenance.defaults,
                resolvedDefaults: resolved
            ),
            runtimeIdentity: request.provenance.runtimeIdentity,
            files: files,
            output: finalOutputs.first,
            outputs: finalOutputs,
            steps: steps,
            wallTimeSeconds: max(0, completedAt.timeIntervalSince(startedAt)),
            exitStatus: 0,
            stderr: stderr.isEmpty ? nil : stderr
        )
    }

    private func finalExecutionRecords(
        _ records: [AlignmentReadExtractionExecutionRecord],
        transactionRoot: URL,
        stagingToFinal: [String: String]
    ) -> [AlignmentReadExtractionExecutionRecord] {
        records.map { record in
            let inputs = record.inputs.compactMap {
                finalDescriptor(
                    $0,
                    transactionRoot: transactionRoot,
                    stagingToFinal: stagingToFinal,
                    isOutput: false
                )
            }
            let outputs = record.outputs.compactMap {
                finalDescriptor(
                    $0,
                    transactionRoot: transactionRoot,
                    stagingToFinal: stagingToFinal,
                    isOutput: true
                )
            }
            return AlignmentReadExtractionExecutionRecord(
                stage: record.stage,
                workflowName: record.workflowName,
                workflowVersion: record.workflowVersion,
                toolName: record.toolName,
                toolVersion: record.toolVersion,
                executablePath: record.executablePath,
                executableChecksumSHA256: record.executableChecksumSHA256,
                argv: record.argv,
                durableReplayArgv: record.durableReplayArgv,
                reproducibleCommand: record.reproducibleCommand,
                visibleOptions: record.visibleOptions,
                resolvedDefaults: record.resolvedDefaults,
                runtimeIdentity: record.runtimeIdentity,
                inputs: inputs,
                outputs: outputs,
                exitStatus: record.exitStatus,
                startedAt: record.startedAt,
                completedAt: record.completedAt,
                stderr: record.stderr
            )
        }
    }

    private func finalDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        transactionRoot: URL,
        stagingToFinal: [String: String],
        isOutput: Bool
    ) -> ProvenanceFileDescriptor? {
        if let finalPath = stagingToFinal[descriptor.path] {
            return ProvenanceFileDescriptor(
                path: finalPath,
                checksumSHA256: descriptor.checksumSHA256,
                fileSize: descriptor.fileSize,
                format: descriptor.format,
                role: descriptor.role,
                originPath: descriptor.path,
                sourceProvenancePath: descriptor.sourceProvenancePath
            )
        }
        let transactionPath = transactionRoot.standardizedFileURL.path
        if descriptor.path == transactionPath || descriptor.path.hasPrefix(transactionPath + "/") {
            // Intermediate transaction artifacts are recorded in exact argv,
            // but cannot become durable output descriptors.
            return nil
        }
        if isOutput, descriptor.path.contains(".staging") {
            return nil
        }
        return descriptor
    }

    private func provenanceStep(
        _ record: AlignmentReadExtractionExecutionRecord
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: record.toolName,
            toolVersion: record.toolVersion,
            argv: record.argv,
            durableReplayArgv: record.durableReplayArgv,
            reproducibleCommand: record.reproducibleCommand,
            resolvedOptions: record.visibleOptions.merging(record.resolvedDefaults) { _, resolved in resolved },
            runtimeIdentity: record.runtimeIdentity,
            inputs: record.inputs,
            outputs: record.outputs,
            exitStatus: record.exitStatus,
            wallTimeSeconds: record.wallTimeSeconds,
            stderr: record.stderr,
            startedAt: record.startedAt,
            completedAt: record.completedAt
        )
    }

    private func publicationRecord(
        request: AlignmentReadExtractionPublicationRequest,
        finalOutputs: [ProvenanceFileDescriptor],
        startedAt: Date,
        completedAt: Date,
        exitStatus: Int?,
        stderr: String?
    ) -> AlignmentReadExtractionExecutionRecord {
        let destination = request.destination.finalURL
        return AlignmentReadExtractionExecutionRecord(
            stage: .publication,
            toolName: "lungfish alignment extraction publisher",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "Lungfish.app", "alignment", "extract", "publish",
                "--destination", destination.path,
            ],
            durableReplayArgv: [
                "Lungfish.app", "alignment", "extract", "publish",
                "--destination", destination.path,
            ],
            visibleOptions: [
                "destination": .file(destination),
            ],
            resolvedDefaults: [
                "atomicPublication": .boolean(true),
            ],
            inputs: [],
            outputs: finalOutputs,
            exitStatus: exitStatus,
            startedAt: startedAt,
            completedAt: completedAt,
            stderr: stderr
        )
    }

    private func publishedDescriptor(
        physicalURL: URL,
        finalURL: URL,
        format: FileFormat?,
        originURL: URL
    ) throws -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: finalURL.standardizedFileURL.path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: physicalURL),
            fileSize: try ProvenanceFileHasher.fileSize(of: physicalURL),
            format: format,
            role: .output,
            originPath: originURL.standardizedFileURL.path
        )
    }

    private func promoteDirectory(_ stagingURL: URL, to finalURL: URL) throws {
        let fileManager = FileManager.default
        let backupURL = siblingBackupURL(for: finalURL)
        var movedExisting = false
        var installedNew = false
        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.moveItem(at: finalURL, to: backupURL)
                movedExisting = true
            }
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            installedNew = true
            try promotionEvent?(.directoryAfterInstall)
            if movedExisting {
                try fileManager.removeItem(at: backupURL)
            }
        } catch {
            var rollbackErrors: [String] = []
            if installedNew, fileManager.fileExists(atPath: finalURL.path) {
                do { try fileManager.removeItem(at: finalURL) }
                catch { rollbackErrors.append("remove new bundle: \(error.localizedDescription)") }
            }
            if movedExisting, fileManager.fileExists(atPath: backupURL.path) {
                do {
                    try promotionEvent?(.directoryBeforeBackupRestore)
                    try fileManager.moveItem(at: backupURL, to: finalURL)
                }
                catch { rollbackErrors.append("restore previous bundle: \(error.localizedDescription)") }
            }
            if rollbackErrors.isEmpty {
                throw error
            }
            throw AlignmentReadExtractionRollbackError(
                message: "Publication failed and rollback was incomplete: \(rollbackErrors.joined(separator: "; "))"
            )
        }
    }

    private func promoteFilePair(
        stagedPayloadURL: URL,
        stagedSidecarURL: URL,
        finalURL: URL
    ) throws {
        let fileManager = FileManager.default
        let finalSidecarURL = ProvenanceRecorder.fileSidecarURL(for: finalURL)
        let backupPayloadURL = siblingBackupURL(for: finalURL)
        let backupSidecarURL = siblingBackupURL(for: finalSidecarURL)
        var payloadBackedUp = false
        var sidecarBackedUp = false
        var payloadInstalled = false
        var sidecarInstalled = false

        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.moveItem(at: finalURL, to: backupPayloadURL)
                payloadBackedUp = true
            }
            if fileManager.fileExists(atPath: finalSidecarURL.path) {
                try fileManager.moveItem(at: finalSidecarURL, to: backupSidecarURL)
                sidecarBackedUp = true
            }
            try fileManager.moveItem(at: stagedPayloadURL, to: finalURL)
            payloadInstalled = true
            try promotionEvent?(.fileAfterPayloadInstall)
            try fileManager.moveItem(at: stagedSidecarURL, to: finalSidecarURL)
            sidecarInstalled = true
            if payloadBackedUp { try fileManager.removeItem(at: backupPayloadURL) }
            if sidecarBackedUp { try fileManager.removeItem(at: backupSidecarURL) }
        } catch {
            var rollbackErrors: [String] = []
            if sidecarInstalled, fileManager.fileExists(atPath: finalSidecarURL.path) {
                do { try fileManager.removeItem(at: finalSidecarURL) }
                catch { rollbackErrors.append("remove new sidecar: \(error.localizedDescription)") }
            }
            if payloadInstalled, fileManager.fileExists(atPath: finalURL.path) {
                do { try fileManager.removeItem(at: finalURL) }
                catch { rollbackErrors.append("remove new file: \(error.localizedDescription)") }
            }
            if payloadBackedUp, fileManager.fileExists(atPath: backupPayloadURL.path) {
                do {
                    try promotionEvent?(.fileBeforePayloadBackupRestore)
                    try fileManager.moveItem(at: backupPayloadURL, to: finalURL)
                }
                catch { rollbackErrors.append("restore previous file: \(error.localizedDescription)") }
            }
            if sidecarBackedUp, fileManager.fileExists(atPath: backupSidecarURL.path) {
                do {
                    try promotionEvent?(.fileBeforeSidecarBackupRestore)
                    try fileManager.moveItem(at: backupSidecarURL, to: finalSidecarURL)
                }
                catch { rollbackErrors.append("restore previous sidecar: \(error.localizedDescription)") }
            }
            if rollbackErrors.isEmpty {
                throw error
            }
            throw AlignmentReadExtractionRollbackError(
                message: "File publication failed and rollback was incomplete: \(rollbackErrors.joined(separator: "; "))"
            )
        }
    }

    private func siblingStagingDirectory(for finalURL: URL) -> URL {
        let parent = finalURL.deletingLastPathComponent()
        let base = finalURL.deletingPathExtension().lastPathComponent
        return parent.appendingPathComponent(
            ".\(base).alignment-extract-staging-\(UUID().uuidString).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
    }

    private func siblingStagingFile(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.lastPathComponent).alignment-extract-staging-\(UUID().uuidString)"
        )
    }

    private func siblingBackupURL(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.lastPathComponent).alignment-extract-backup-\(UUID().uuidString)"
        )
    }

    private func deduplicatedDescriptors(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        return descriptors.filter { descriptor in
            seen.insert("\(descriptor.role.rawValue)\u{0}\(descriptor.path)").inserted
        }
    }
}

enum AlignmentReadExtractionPromotionEvent: Sendable, Equatable {
    case directoryAfterInstall
    case directoryBeforeBackupRestore
    case fileAfterPayloadInstall
    case fileBeforePayloadBackupRestore
    case fileBeforeSidecarBackupRestore
}

private struct AlignmentReadExtractionRollbackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct PublishedBundleMetadata: Codable {
    let workflowName: String
    let readCount: Int
    let pairedEnd: Bool
    let recordsWithoutSequence: Int
    let missingSequenceMessage: String?
    let payloadPaths: [String]
    let stagingToFinal: [String: String]
}
