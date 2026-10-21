// ScientificFileExportProvenance.swift - Canonical sidecars for app file exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore

public enum ScientificFileExportProvenance {
    public struct Request {
        public let workflowName: String
        public let toolName: String
        /// The tool's kind in the record, `gui` for an export the app writes in process and `cli` for a
        /// `lungfish-cli` leaf (``cliLeaf(workflowName:sourceURLs:outputURL:outputFormat:argv:explicitOptions:defaults:resolved:runClock:)``).
        public let toolKind: String
        public let sourceURLs: [URL]
        public let outputURL: URL
        public let outputFormat: FileFormat
        public let argv: [String]
        public let durableReplayArgv: [String]?
        public let explicitOptions: [String: ParameterValue]
        public let defaults: [String: ParameterValue]
        public let resolved: [String: ParameterValue]
        public let startedAt: Date
        public let completedAt: Date
        /// Times an export this process runs. The sidecar takes its end from
        /// the clock when it is written. `nil` for times recorded elsewhere.
        let runClock: ProvenanceRunClock?

        /// An export this process runs, timed by `runClock`. The caller names the tool and its kind, `gui` when
        /// the app writes the record in its own process and `cli` when a `lungfish-cli` process writes it.
        public init(
            workflowName: String,
            toolName: String,
            toolKind: String,
            sourceURLs: [URL],
            outputURL: URL,
            outputFormat: FileFormat,
            argv: [String],
            durableReplayArgv: [String]? = nil,
            explicitOptions: [String: ParameterValue] = [:],
            defaults: [String: ParameterValue] = [:],
            resolved: [String: ParameterValue] = [:],
            runClock: ProvenanceRunClock
        ) {
            self.init(
                workflowName: workflowName,
                toolName: toolName,
                toolKind: toolKind,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: outputFormat,
                argv: argv,
                durableReplayArgv: durableReplayArgv,
                explicitOptions: explicitOptions,
                defaults: defaults,
                resolved: resolved,
                startedAt: runClock.startedAt,
                completedAt: runClock.now,
                runClock: runClock
            )
        }

        /// An export whose start and end were recorded elsewhere. The caller names the tool and its kind, as above.
        public init(
            workflowName: String,
            toolName: String,
            toolKind: String,
            sourceURLs: [URL],
            outputURL: URL,
            outputFormat: FileFormat,
            argv: [String],
            durableReplayArgv: [String]? = nil,
            explicitOptions: [String: ParameterValue] = [:],
            defaults: [String: ParameterValue] = [:],
            resolved: [String: ParameterValue] = [:],
            startedAt: Date,
            completedAt: Date
        ) {
            self.init(
                workflowName: workflowName,
                toolName: toolName,
                toolKind: toolKind,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: outputFormat,
                argv: argv,
                durableReplayArgv: durableReplayArgv,
                explicitOptions: explicitOptions,
                defaults: defaults,
                resolved: resolved,
                startedAt: startedAt,
                completedAt: completedAt,
                runClock: nil
            )
        }

        /// The request of a `lungfish-cli` leaf that writes a viewer export (Phase 2.12, ARCH ruling X-3 and 1.4).
        /// The record names the tool ``CLICommandIdentity/executableName`` with kind `cli`, and its durable replay
        /// argv is the leaf's own canonical `argv`, which starts with the executable name.
        public static func cliLeaf(
            workflowName: String,
            sourceURLs: [URL],
            outputURL: URL,
            outputFormat: FileFormat,
            argv: [String],
            explicitOptions: [String: ParameterValue] = [:],
            defaults: [String: ParameterValue] = [:],
            resolved: [String: ParameterValue] = [:],
            runClock: ProvenanceRunClock
        ) -> Request {
            Request(
                workflowName: workflowName,
                toolName: CLICommandIdentity.executableName,
                toolKind: "cli",
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: outputFormat,
                argv: argv,
                durableReplayArgv: nil,
                explicitOptions: explicitOptions,
                defaults: defaults,
                resolved: resolved,
                startedAt: runClock.startedAt,
                completedAt: runClock.now,
                runClock: runClock
            )
        }

        private init(
            workflowName: String,
            toolName: String,
            toolKind: String,
            sourceURLs: [URL],
            outputURL: URL,
            outputFormat: FileFormat,
            argv: [String],
            durableReplayArgv: [String]?,
            explicitOptions: [String: ParameterValue],
            defaults: [String: ParameterValue],
            resolved: [String: ParameterValue],
            startedAt: Date,
            completedAt: Date,
            runClock: ProvenanceRunClock?
        ) {
            self.workflowName = workflowName
            self.toolName = toolName
            self.toolKind = toolKind
            self.sourceURLs = sourceURLs
            self.outputURL = outputURL
            self.outputFormat = outputFormat
            self.argv = argv
            self.durableReplayArgv = durableReplayArgv
            self.explicitOptions = explicitOptions
            self.defaults = defaults
            self.resolved = resolved
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.runClock = runClock
        }

        /// This request publishing other sources, replay argv and resolved
        /// options. It keeps the request's times and its clock.
        public func replacing(
            sourceURLs: [URL],
            durableReplayArgv: [String]?,
            resolved: [String: ParameterValue]
        ) -> Request {
            Request(
                workflowName: workflowName,
                toolName: toolName,
                toolKind: toolKind,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: outputFormat,
                argv: argv,
                durableReplayArgv: durableReplayArgv,
                explicitOptions: explicitOptions,
                defaults: defaults,
                resolved: resolved,
                startedAt: startedAt,
                completedAt: completedAt,
                runClock: runClock
            )
        }

        /// This request with its end read from its clock now. A request of
        /// recorded times keeps them.
        fileprivate func completedNow() -> Request {
            guard let runClock else { return self }
            return Request(
                workflowName: workflowName,
                toolName: toolName,
                toolKind: toolKind,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: outputFormat,
                argv: argv,
                durableReplayArgv: durableReplayArgv,
                explicitOptions: explicitOptions,
                defaults: defaults,
                resolved: resolved,
                startedAt: startedAt,
                completedAt: runClock.now,
                runClock: runClock
            )
        }
    }

    @discardableResult
    public static func write(_ request: Request) throws -> URL {
        let outputDescriptor = try ProvenanceFileDescriptor.file(
            url: request.outputURL,
            format: request.outputFormat,
            role: .output
        )
        let envelope = try envelope(for: request.completedNow(), outputDescriptor: outputDescriptor)

        do {
            return try ProvenanceWriter().write(
                envelope,
                toSidecar: ProvenanceRecorder.fileSidecarURL(for: request.outputURL)
            )
        } catch {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw error
        }
    }

    @discardableResult
    public static func writeAtomically(
        _ request: Request,
        writeOutput: (URL) throws -> Void
    ) throws -> URL {
        let fileManager = FileManager.default
        let outputURL = request.outputURL
        guard !isExistingDirectory(outputURL, fileManager: fileManager) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let outputDirectoryURL = outputURL.deletingLastPathComponent()
        let finalSidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let excludedSourcePaths = Set([
            outputURL.standardizedFileURL.path,
            finalSidecarURL.standardizedFileURL.path,
        ])
        let inputDescriptors = try request.sourceURLs.map {
            try inputDescriptor(for: $0, excluding: excludedSourcePaths)
        }
        let tempOutputURL = outputDirectoryURL.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID()).export.tmp")
        defer { try? fileManager.removeItem(at: tempOutputURL) }
        let sidecarArtifacts = ProvenancePublicationArtifacts.fileSidecarArtifacts(for: outputURL)
        let publication = try ScientificFilePublicationTransaction(
            protectedURLs: [outputURL] + sidecarArtifacts,
            fileDestinations: [outputURL] + sidecarArtifacts
        )
        do {
            try writeOutput(tempOutputURL)
            guard try tempOutputURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let tempRecord = ProvenanceRecorder.fileRecord(url: tempOutputURL, format: request.outputFormat, role: .output)
            let outputDescriptor = ProvenanceFileDescriptor(fileRecord: FileRecord(
                path: outputURL.standardizedFileURL.path, sha256: tempRecord.sha256,
                sizeBytes: tempRecord.sizeBytes, format: tempRecord.format, role: tempRecord.role))
            let completedRequest = request.completedNow()
            let envelope = envelope(for: completedRequest, inputDescriptors: inputDescriptors, outputDescriptor: outputDescriptor)
            try publication.publish(stagedURL: tempOutputURL, to: outputURL)
            try ProvenanceWriter(publicationMutationDidOccur: { try publication.observe($0) })
                .write(envelope, toSidecar: finalSidecarURL)
            publication.commit()
            return finalSidecarURL
        } catch {
            try publication.rollback(after: error)
        }
    }

    /// Writes a folder of files with one record inside it that names every file as an output, then publishes the
    /// folder by one exclusive rename (Phase 2.13 lane 13.30, the bulk form of `bundle export-graphic`). The record
    /// has the shape of the single-file transaction's, with `outputs` naming each file at its published path.
    /// `writeOutputs` writes the files into the staged folder it is given and returns their names in order. The
    /// folder must not exist. A throw from `writeOutputs`, such as a cancel, removes the staged folder, so no folder,
    /// file or record appears.
    @discardableResult
    public static func writeFolderAtomically(
        _ request: Request,
        writeOutputs: (URL) throws -> [String]
    ) throws -> URL {
        let fileManager = FileManager.default
        let folderURL = request.outputURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: folderURL.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folderURL.path])
        }
        let inputDescriptors = try request.sourceURLs.map {
            try inputDescriptor(for: $0, excluding: [folderURL.path])
        }
        let stagedURL = folderURL.deletingLastPathComponent()
            .appendingPathComponent(".\(folderURL.lastPathComponent).\(UUID()).export.tmp", isDirectory: true)
        try fileManager.createDirectory(at: stagedURL, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagedURL) }
        let names = try writeOutputs(stagedURL)
        guard !names.isEmpty, Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count,
              names.allSatisfy({ !$0.contains("/") && !$0.hasPrefix(".") }) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: stagedURL.path])
        }
        let outputDescriptors = try names.map { name -> ProvenanceFileDescriptor in
            let stagedFile = stagedURL.appendingPathComponent(name)
            guard try stagedFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: stagedFile.path])
            }
            let staged = ProvenanceRecorder.fileRecord(url: stagedFile, format: request.outputFormat, role: .output)
            return ProvenanceFileDescriptor(fileRecord: FileRecord(
                path: folderURL.appendingPathComponent(name).path, sha256: staged.sha256,
                sizeBytes: staged.sizeBytes, format: staged.format, role: staged.role))
        }
        let envelope = envelope(
            for: request.completedNow(), inputDescriptors: inputDescriptors, outputDescriptors: outputDescriptors
        )
        try ProvenanceWriter()
            .write(envelope, toSidecar: stagedURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        _ = try PortableRename.exclusive(stagedURL, to: folderURL)
        return folderURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    private static func isExistingDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func envelope(
        for request: Request,
        outputDescriptor: ProvenanceFileDescriptor
    ) throws -> ProvenanceEnvelope {
        let inputDescriptors = try request.sourceURLs.map { try inputDescriptor(for: $0) }
        return envelope(for: request, inputDescriptors: inputDescriptors, outputDescriptor: outputDescriptor)
    }

    private static func envelope(
        for request: Request,
        inputDescriptors: [ProvenanceFileDescriptor],
        outputDescriptor: ProvenanceFileDescriptor
    ) -> ProvenanceEnvelope {
        envelope(for: request, inputDescriptors: inputDescriptors, outputDescriptors: [outputDescriptor])
    }

    /// The record of one run. Its `output` is the first output, and `outputs` and `files` name every output.
    private static func envelope(
        for request: Request,
        inputDescriptors: [ProvenanceFileDescriptor],
        outputDescriptors: [ProvenanceFileDescriptor]
    ) -> ProvenanceEnvelope {
        let outputDescriptor = outputDescriptors[0]
        let toolVersion = WorkflowRun.currentAppVersion
        let step = ProvenanceStep(
            toolName: request.toolName,
            toolVersion: toolVersion,
            argv: request.argv,
            durableReplayArgv: request.durableReplayArgv ?? request.argv,
            resolvedOptions: request.resolved,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: request.completedAt.timeIntervalSince(request.startedAt),
            stderr: nil,
            startedAt: request.startedAt,
            completedAt: request.completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: request.startedAt,
            workflowName: request.workflowName,
            workflowVersion: toolVersion,
            toolName: request.toolName,
            toolVersion: toolVersion,
            tool: ProvenanceToolIdentity(name: request.toolName, version: toolVersion, kind: request.toolKind),
            argv: request.argv,
            durableReplayArgv: request.durableReplayArgv ?? request.argv,
            options: ProvenanceOptions(
                explicit: request.explicitOptions,
                defaults: request.defaults,
                resolvedDefaults: request.resolved
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputDescriptors + outputDescriptors,
            output: outputDescriptor,
            outputs: outputDescriptors,
            steps: [step],
            wallTimeSeconds: request.completedAt.timeIntervalSince(request.startedAt),
            exitStatus: 0,
            stderr: nil
        )
        return envelope
    }

    private static func inputDescriptor(
        for url: URL,
        excluding excludedAbsolutePaths: Set<String> = []
    ) throws -> ProvenanceFileDescriptor {
        let sourceProvenancePath = ProvenanceRecorder.findProvenanceEnvelope(for: url)?.sidecarURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let manifest = try ProvenanceFileHasher.directoryManifest(
                for: url,
                role: .input,
                excluding: excludedAbsolutePaths
            )
            return ProvenanceFileDescriptor(
                path: url.standardizedFileURL.path,
                checksumSHA256: directoryChecksum(from: manifest),
                fileSize: directorySize(from: manifest),
                format: .unknown,
                role: .input,
                sourceProvenancePath: sourceProvenancePath
            )
        }

        return ProvenanceFileDescriptor(
            fileRecord: ProvenanceRecorder.fileRecord(url: url, role: .input),
            sourceProvenancePath: sourceProvenancePath
        )
    }

    private static func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    descriptor.fileSize.map(String.init) ?? "0",
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }
}
