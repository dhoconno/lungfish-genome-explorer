// FASTQReadsExport.swift - The sidebar FASTQ bundle export that the app and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The sidebar's FASTQ bundle export (Phase 2.12 lane 12.38, ARCH ruling 1.1 row B4).
///
/// The sidebar writes the reads of a bundle as one FASTQ file. A bundle with one FASTQ file is copied, a bundle of
/// several source files is joined in manifest order, and a derived bundle is materialized and then copied. The app's
/// begin helper builds ``invocation(bundleURL:outputURL:isDerived:force:emitsEvents:)`` for the row and the runner,
/// and `lungfish-cli fastq export reads` rebuilds it, writes the file through ``write(_:to:outputIsGzip:progress:)``
/// and records the same inputs the in-app writer named (the bundle's FASTQ files, or the folder of a derived bundle,
/// and its two manifests).
public enum FASTQReadsExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row B4).
    public static let commandPath = ["fastq", "export", "reads"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish fastq export reads"
    /// The flag a derived bundle needs, as the in-app record spelled it.
    public static let materializeDerivedFlag = "--materialize-derived"

    /// The leaf's invocation for one bundle, with absolute standardized paths. The begin helper passes its
    /// `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        bundleURL: URL,
        outputURL: URL,
        isDerived: Bool,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: bundleURL.standardizedFileURL.path,
            leafArguments: isDerived ? [materializeDerivedFlag] : [],
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// What the export reads from a bundle.
    public struct Source: Sendable, Equatable {
        public let bundleURL: URL
        public let isDerived: Bool
        /// The FASTQ files of a physical bundle in order. Empty for a derived bundle.
        public let chunkURLs: [URL]
        /// The files the record names as inputs. A derived bundle names its folder.
        public let inputURLs: [URL]
    }

    /// A bundle the export cannot read.
    public enum SourceError: Error, LocalizedError, Equatable {
        case noFASTQ

        public var errorDescription: String? {
            "No FASTQ file found inside bundle"
        }
    }

    /// Reads which files the export will open, and the inputs its record names.
    public static func source(of bundleURL: URL) throws -> Source {
        let fileManager = FileManager.default
        let isDerived = FASTQBundle.isDerivedBundle(bundleURL)
        var chunkURLs: [URL] = []
        var inputURLs: [URL]
        if isDerived {
            inputURLs = [bundleURL]
        } else {
            guard let urls = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), !urls.isEmpty else {
                throw SourceError.noFASTQ
            }
            chunkURLs = urls
            inputURLs = urls
        }
        let sourceManifestURL = bundleURL.appendingPathComponent(FASTQSourceFileManifest.filename)
        if fileManager.fileExists(atPath: sourceManifestURL.path) {
            inputURLs.append(sourceManifestURL)
        }
        let derivedManifestURL = FASTQBundle.derivedManifestURL(in: bundleURL)
        if fileManager.fileExists(atPath: derivedManifestURL.path) {
            inputURLs.append(derivedManifestURL)
        }
        return Source(bundleURL: bundleURL, isDerived: isDerived, chunkURLs: chunkURLs, inputURLs: inputURLs)
    }

    /// Writes the reads to `stagedURL`. `outputIsGzip` is the final output's name, since a staged file carries none.
    public static func write(
        _ source: Source,
        to stagedURL: URL,
        outputIsGzip: Bool,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        if source.isDerived {
            // The scratch for the materialized reads is the project's own temp folder when the bundle is inside a
            // project, where the app kept it, since a materialized dataset can be many gigabytes. A bundle outside a
            // project gets the system temp folder.
            let tempDirectory = try ProjectTempDirectory.createFromContext(
                prefix: "fastq-export-", contextURL: source.bundleURL
            )
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            progress?("Materializing dataset...")
            let materializedURL = try await FASTQCLIMaterializer(runner: NativeToolRunner.shared).materialize(
                bundleURL: source.bundleURL,
                tempDirectory: tempDirectory,
                progress: progress
            )
            progress?("Writing to output file...")
            try FileManager.default.copyItem(at: materializedURL, to: stagedURL)
            return
        }
        if source.chunkURLs.count == 1 {
            progress?("Copying \(source.chunkURLs[0].lastPathComponent)...")
            try FileManager.default.copyItem(at: source.chunkURLs[0], to: stagedURL)
            return
        }
        progress?("Exporting \(source.chunkURLs.count) FASTQ chunks...")
        try await concatenate(source.chunkURLs, to: stagedURL, outputIsGzip: outputIsGzip)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func concatenate(_ inputURLs: [URL], to outputURL: URL, outputIsGzip: Bool) async throws {
        let allInputsAreGzip = inputURLs.allSatisfy(\.isGzipCompressed)
        let noInputsAreGzip = inputURLs.allSatisfy { !$0.isGzipCompressed }

        if outputIsGzip && allInputsAreGzip || !outputIsGzip && noInputsAreGzip {
            try concatenateBytes(inputURLs, to: outputURL)
            return
        }

        if outputIsGzip {
            let tempDirectory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            let uncompressedURL = tempDirectory.appendingPathComponent("reads.fastq")
            try await writeUncompressed(inputURLs, to: uncompressedURL)
            try await gzipFile(uncompressedURL, to: outputURL)
            return
        }

        try await writeUncompressed(inputURLs, to: outputURL)
    }

    private static func concatenateBytes(_ inputURLs: [URL], to outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for inputURL in inputURLs {
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            do {
                defer { try? inputHandle.close() }
                while true {
                    let chunk = try inputHandle.read(upToCount: 1 << 20) ?? Data()
                    if chunk.isEmpty { break }
                    try outputHandle.write(contentsOf: chunk)
                }
            }
        }
    }

    private static func writeUncompressed(_ inputURLs: [URL], to outputURL: URL) async throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for try await line in URL.multiFileLinesAutoDecompressing(inputURLs) {
            try outputHandle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// Compresses `inputURL` into `outputURL` with the system gzip, run through ``ToolProcess``.
    /// Cancelling the task stops the gzip tree and throws `CancellationError`, and no thread waits for the child.
    /// It is internal so `FASTQExportGzipCancelTests` can reach it.
    static func gzipFile(_ inputURL: URL, to outputURL: URL) async throws {
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(ToolProcessSpec(
                executableURL: URL(fileURLWithPath: "/usr/bin/gzip"),
                arguments: ["-c", inputURL.path],
                environment: ["PATH": "/usr/bin:/bin"],
                stdout: .file(outputURL),
                stderr: .discard,
                label: "gzip -c"
            ))
        } catch let error as ToolProcessError {
            if case .cancelled = error { throw CancellationError() }
            throw error
        }
        guard result.isSuccess else {
            throw NSError(
                domain: "com.lungfish.browser", code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "Compression failed for \(outputURL.lastPathComponent)."]
            )
        }
    }
}
