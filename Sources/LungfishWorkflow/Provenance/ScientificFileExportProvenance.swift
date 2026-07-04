// ScientificFileExportProvenance.swift - Canonical sidecars for app file exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum ScientificFileExportProvenance {
    public struct Request {
        public let workflowName: String
        public let toolName: String
        public let sourceURLs: [URL]
        public let outputURL: URL
        public let outputFormat: FileFormat
        public let argv: [String]
        public let explicitOptions: [String: ParameterValue]
        public let defaults: [String: ParameterValue]
        public let resolved: [String: ParameterValue]
        public let startedAt: Date
        public let completedAt: Date

        public init(
            workflowName: String,
            toolName: String = "Lungfish.app",
            sourceURLs: [URL],
            outputURL: URL,
            outputFormat: FileFormat,
            argv: [String],
            explicitOptions: [String: ParameterValue] = [:],
            defaults: [String: ParameterValue] = [:],
            resolved: [String: ParameterValue] = [:],
            startedAt: Date,
            completedAt: Date = Date()
        ) {
            self.workflowName = workflowName
            self.toolName = toolName
            self.sourceURLs = sourceURLs
            self.outputURL = outputURL
            self.outputFormat = outputFormat
            self.argv = argv
            self.explicitOptions = explicitOptions
            self.defaults = defaults
            self.resolved = resolved
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }

    @discardableResult
    public static func write(_ request: Request) throws -> URL {
        let inputDescriptors = try request.sourceURLs.map { try inputDescriptor(for: $0) }
        let outputDescriptor = try ProvenanceFileDescriptor.file(
            url: request.outputURL,
            format: request.outputFormat,
            role: .output
        )
        let toolVersion = WorkflowRun.currentAppVersion
        let step = ProvenanceStep(
            toolName: request.toolName,
            toolVersion: toolVersion,
            argv: request.argv,
            durableReplayArgv: request.argv,
            inputs: inputDescriptors,
            outputs: [outputDescriptor],
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
            tool: ProvenanceToolIdentity(name: request.toolName, version: toolVersion, kind: "gui"),
            argv: request.argv,
            durableReplayArgv: request.argv,
            options: ProvenanceOptions(
                explicit: request.explicitOptions,
                defaults: request.defaults,
                resolvedDefaults: request.resolved
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputDescriptors + [outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: request.completedAt.timeIntervalSince(request.startedAt),
            exitStatus: 0,
            stderr: nil
        )

        do {
            return try ProvenanceWriter(signingProvider: nil).write(
                envelope,
                toSidecar: ProvenanceRecorder.fileSidecarURL(for: request.outputURL)
            )
        } catch {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw error
        }
    }

    private static func inputDescriptor(for url: URL) throws -> ProvenanceFileDescriptor {
        let sourceProvenancePath = ProvenanceRecorder.findProvenanceEnvelope(for: url)?.sidecarURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let manifest = try ProvenanceFileHasher.directoryManifest(for: url, role: .input)
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
