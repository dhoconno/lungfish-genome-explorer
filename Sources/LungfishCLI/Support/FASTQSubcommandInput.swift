// FASTQSubcommandInput.swift - The one file a single-input fastq subcommand reads for the path it was given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The file a `fastq` subcommand reads for one input path, with the input
/// it came from, so a `.lungfishfastq` bundle means the same reads on the
/// command line as in the FASTQ operations dialog and on the dashboard (R3,
/// lane 1x).
///
/// A loose file is itself. A bundle resolves through
/// `FASTQCLIMaterializer.materialize`, the one-file resolution every
/// single-input consumer shares: a single-file bundle is its file in place,
/// a bundle that holds several files is every file joined in
/// `source-files.json` order, a `fullPaired` bundle is R1 and R2
/// interleaved, a `fullMixed` bundle is its files joined, and a virtual
/// derivative is its recipe applied to every file of its root. A file
/// inside a bundle is that file in place (a chunk of an ONT import, R1 of a
/// fullPaired bundle), except the preview of a virtual derivative, which is
/// not the data: the bundle is resolved instead, and a note says so.
///
/// Whatever was written for the run lives in a scratch folder that
/// ``cleanup()`` removes. The recorded command and the provenance name the
/// path the user gave, with the materialization or join as its own step.
struct FASTQSubcommandInput: Sendable {
    /// The path the user gave, as an absolute file URL.
    let originalURL: URL
    /// The file the tool reads.
    let executionURL: URL
    /// The bundle the execution file was resolved from, or nil for a loose file.
    let bundleURL: URL?
    /// When the execution file was written, for the materialization step.
    let materializationStartedAt: Date?
    let materializationEndedAt: Date?
    private let scratchDirectory: URL?

    /// Whether the tool reads a file written for this run rather than one on disk already.
    var wasMaterialized: Bool { materializationStartedAt != nil }

    /// Resolves `path` for `operationName` (the subcommand's name, for messages).
    ///
    /// - Parameter contextURL: a path near which the scratch folder is made,
    ///   normally the output, so a joined copy of a project's bundle lands on
    ///   the project's volume (`ProjectTempDirectory.createFromContext`).
    static func resolve(
        _ path: String,
        operationName: String,
        contextURL: URL,
        materializer: FASTQCLIMaterializer = FASTQCLIMaterializer(runner: .shared)
    ) async throws -> FASTQSubcommandInput {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.inputFileNotFound(path: path)
        }
        let originalURL = URL(fileURLWithPath: path)
        guard let enclosingBundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: originalURL),
              FASTQBundle.isBundleURL(enclosingBundleURL) else {
            return FASTQSubcommandInput(
                originalURL: originalURL,
                executionURL: originalURL,
                bundleURL: nil,
                materializationStartedAt: nil,
                materializationEndedAt: nil,
                scratchDirectory: nil
            )
        }
        if let message = CLISequenceInputMaterialization.unsupportedSequenceInputMessage(
            for: originalURL,
            operationName: operationName
        ) {
            throw CLISequenceInputMaterializationError.unsupportedSequenceInput(message)
        }

        let isBundlePath = enclosingBundleURL.standardizedFileURL.path == originalURL.standardizedFileURL.path
        if !isBundlePath {
            if let virtualBundleURL = SequenceInputResolver.unmaterializedDerivedBundleURL(for: originalURL) {
                // The only FASTQ inside a virtual derivative is its preview.
                FileHandle.standardError.write(Data(
                    "Note: \(originalURL.lastPathComponent) is the preview of the virtual bundle \(virtualBundleURL.lastPathComponent), not its reads. Reading the bundle instead.\n".utf8
                ))
            } else {
                // A file inside a bundle is read in place, as before.
                return FASTQSubcommandInput(
                    originalURL: originalURL,
                    executionURL: originalURL,
                    bundleURL: enclosingBundleURL,
                    materializationStartedAt: nil,
                    materializationEndedAt: nil,
                    scratchDirectory: nil
                )
            }
        }

        let scratchDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "fastq-\(operationName)-input-",
            contextURL: contextURL
        )
        do {
            let startedAt = Date()
            let executionURL = try await materializer.materialize(
                bundleURL: enclosingBundleURL,
                tempDirectory: scratchDirectory,
                progress: { message in
                    FileHandle.standardError.write(Data("\(message)\n".utf8))
                }
            )
            let endedAt = Date()
            let written = CanonicalFilePath.isPath(executionURL, within: scratchDirectory)
            if !written {
                try? FileManager.default.removeItem(at: scratchDirectory)
            }
            return FASTQSubcommandInput(
                originalURL: originalURL,
                executionURL: executionURL,
                bundleURL: enclosingBundleURL,
                materializationStartedAt: written ? startedAt : nil,
                materializationEndedAt: written ? endedAt : nil,
                scratchDirectory: written ? scratchDirectory : nil
            )
        } catch {
            try? FileManager.default.removeItem(at: scratchDirectory)
            throw error
        }
    }

    /// Resolves several paths in order, cleaning up the ones already
    /// resolved when a later one fails.
    static func resolve(
        _ paths: [String],
        operationName: String,
        contextURL: URL
    ) async throws -> [FASTQSubcommandInput] {
        var resolved: [FASTQSubcommandInput] = []
        do {
            for path in paths {
                resolved.append(try await resolve(path, operationName: operationName, contextURL: contextURL))
            }
        } catch {
            resolved.forEach { $0.cleanup() }
            throw error
        }
        return resolved
    }

    /// Removes the scratch folder, if one was made.
    func cleanup() {
        guard let scratchDirectory else { return }
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    /// The input records for provenance: a loose file as itself, a bundle as
    /// its aggregate, its manifest, its root files and recipe files, and
    /// the file the tool read, each with the bundle as its origin
    /// (`CLISequenceInputMaterialization.inputRecordsPreservingLineage`).
    func inputRecords() throws -> [FileRecord] {
        try CLISequenceInputMaterialization.inputRecordsPreservingLineage(
            originalInputURLs: [originalURL],
            executionInputURLs: [executionURL]
        )
    }

    /// The step that wrote the execution file, a `lungfish-cli fastq
    /// materialize` of a virtual bundle or a `cat` of a multi-file bundle's
    /// members, or none when the tool read a file already on disk.
    func materializationSteps() throws -> [ProvenanceStep] {
        guard let materializationStartedAt, let materializationEndedAt else { return [] }
        return try CLISequenceInputMaterialization.materializationProvenanceSteps(
            workflowVersion: WorkflowRun.currentAppVersion,
            originalInputURLs: [originalURL],
            executionInputURLs: [executionURL],
            startedAt: materializationStartedAt,
            endedAt: materializationEndedAt
        )
    }

    /// The bundle whose metadata describes the reads, for a pairing decision
    /// on a materialized copy that carries no sidecar, or nil when the tool
    /// reads the user's file in place.
    var pairingMetadataURL: URL? {
        wasMaterialized ? bundleURL : nil
    }
}

extension Array where Element == FASTQSubcommandInput {
    /// The input records of every input, in order, without repeats.
    func inputRecords() throws -> [FileRecord] {
        var seen = Set<String>()
        var records: [FileRecord] = []
        for input in self {
            for record in try input.inputRecords() where seen.insert(record.path).inserted {
                records.append(record)
            }
        }
        return records
    }

    /// The materialization steps of every input, in order.
    func materializationSteps() throws -> [ProvenanceStep] {
        try flatMap { try $0.materializationSteps() }
    }

    func cleanup() {
        forEach { $0.cleanup() }
    }
}
