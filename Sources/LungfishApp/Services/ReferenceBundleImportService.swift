// ReferenceBundleImportService.swift - Import standalone sequence files as .lungfishref bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let referenceImportLogger = Logger(subsystem: LogSubsystem.app, category: "ReferenceBundleImport")

/// Classification of an input file for sidebar/import-center routing.
public enum ReferenceImportClassification: Sendable, Equatable {
    /// Standalone sequence source that should become a new `.lungfishref` bundle.
    case standaloneReferenceSequence
    /// Annotation track source that should attach to an existing reference bundle.
    case annotationTrack
    /// Variant source that should attach to an existing reference bundle or use existing VCF flow.
    case variantTrack
    /// Alignment source that should attach to an existing reference bundle.
    case alignmentTrack
    /// Not a supported import source for bundle creation.
    case unsupported
}

/// Result of creating a `.lungfishref` bundle from an imported sequence file.
public struct ReferenceBundleImportResult: Sendable {
    /// URL to the created bundle.
    public let bundleURL: URL
    /// Effective bundle display name used during creation.
    public let bundleName: String
}

/// Errors thrown by `ReferenceBundleImportService`.
public enum ReferenceBundleImportError: Error, LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(URL)
    case noSequencesFound(URL)
    case decompressionFailed(String)
    case helperExecutableNotFound
    case helperLaunchFailed(String)
    case helperFailed(String)
    case helperProtocolError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Input file not found: \(url.lastPathComponent)"
        case .unsupportedFormat(let url):
            return "Unsupported reference import format: \(url.lastPathComponent)"
        case .noSequencesFound(let url):
            return "No sequences were found in \(url.lastPathComponent)"
        case .decompressionFailed(let message):
            return "Failed to decompress input: \(message)"
        case .helperExecutableNotFound:
            return "Could not locate application executable for reference import helper"
        case .helperLaunchFailed(let message):
            return "Failed to launch reference import helper: \(message)"
        case .helperFailed(let message):
            return "Reference import helper failed: \(message)"
        case .helperProtocolError(let message):
            return "Reference import helper protocol error: \(message)"
        }
    }
}

/// Imports sequence files as standalone `.lungfishref` bundles.
///
/// This service is used by both sidebar drag/drop import and Import Center
/// to ensure identical bundle output structure.
public final class ReferenceBundleImportService {
    @MainActor public static let shared = ReferenceBundleImportService()

    private init() {}

    /// Compression wrappers accepted for standalone reference inputs.
    public static let compressionExtensions: Set<String> = ["gz", "gzip", "bgz", "bz2", "xz", "zst", "zstd"]

    /// Sequence formats that should become standalone `.lungfishref` bundles.
    ///
    /// FASTQ is intentionally excluded because it uses `.lungfishfastq` bundles.
    public static let standaloneReferenceExtensions: Set<String> = [
        "fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn",
        "gb", "gbk", "genbank", "gbff", "embl",
    ]

    /// Annotation-like file formats that should be attached to existing references.
    public static let annotationExtensions: Set<String> = ["gff", "gff3", "gtf", "bed"]

    /// Variant-like file formats that should be attached to existing references.
    public static let variantExtensions: Set<String> = ["vcf", "bcf"]

    /// Alignment-like file formats that should be attached to existing references.
    public static let alignmentExtensions: Set<String> = ["bam", "sam", "cram"]

    /// All standalone reference extensions in sorted order for UI registration.
    public static var sortedStandaloneReferenceExtensions: [String] {
        standaloneReferenceExtensions.sorted()
    }

    /// Returns the normalized extension (peeking through compression wrappers).
    public static func normalizedExtension(for url: URL) -> String {
        var ext = url.pathExtension.lowercased()
        if compressionExtensions.contains(ext) {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        return ext
    }

    /// Classifies an input URL for import routing.
    public static func classify(_ url: URL) -> ReferenceImportClassification {
        let ext = normalizedExtension(for: url)

        if standaloneReferenceExtensions.contains(ext) {
            return .standaloneReferenceSequence
        }
        if annotationExtensions.contains(ext) {
            return .annotationTrack
        }
        if variantExtensions.contains(ext) {
            return .variantTrack
        }
        if alignmentExtensions.contains(ext) {
            return .alignmentTrack
        }
        return .unsupported
    }

    /// Returns `true` if the source should be imported as a standalone `.lungfishref` bundle.
    public static func isStandaloneReferenceSource(_ url: URL) -> Bool {
        classify(url) == .standaloneReferenceSequence
    }

    /// Launches the app executable in helper mode so GUI imports follow a CLI-like command path.
    public static func importAsReferenceBundleViaCLI(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ReferenceBundleImportResult {
        try await Task.detached(priority: .userInitiated) {
            try runReferenceImportViaHelper(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                preferredBundleName: preferredBundleName,
                progressHandler: progressHandler
            )
        }.value
    }

    /// Imports a supported standalone sequence source into `outputDirectory` as a `.lungfishref` bundle.
    @MainActor public func importAsReferenceBundle(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ReferenceBundleImportResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ReferenceBundleImportError.fileNotFound(sourceURL)
        }

        guard Self.isStandaloneReferenceSource(sourceURL) else {
            throw ReferenceBundleImportError.unsupportedFormat(sourceURL)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        OperationMarker.markInProgress(outputDirectory, detail: "Importing reference bundle\u{2026}")
        defer { OperationMarker.clearInProgress(outputDirectory) }

        let baseName = sanitizedBaseName(preferredBundleName ?? defaultBundleName(for: sourceURL))
        let bundleName = makeUniqueBundleName(base: baseName, in: outputDirectory)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-ref-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        progressHandler?(0.02, "Preparing reference input...")

        let prepared = try await prepareBuildInputs(
            sourceURL: sourceURL,
            bundleName: bundleName,
            tempDirectory: tempDirectory
        )

        let configuration = BuildConfiguration(
            name: bundleName,
            identifier: "org.lungfish.import.\(UUID().uuidString.lowercased())",
            fastaURL: prepared.fastaURL,
            annotationFiles: prepared.annotationInputs,
            outputDirectory: outputDirectory,
            source: prepared.sourceInfo,
            compressFASTA: true
        )

        let builder = NativeBundleBuilder()

        let bundleURL = try await builder.build(configuration: configuration) { _, progress, message in
            progressHandler?(progress, message)
        }

        referenceImportLogger.info(
            "Created reference bundle \(bundleURL.lastPathComponent, privacy: .public) from \(sourceURL.lastPathComponent, privacy: .public)"
        )

        return ReferenceBundleImportResult(bundleURL: bundleURL, bundleName: bundleName)
    }

    // MARK: - Helper IPC

    private struct HelperEvent: Decodable {
        let event: String
        let progress: Double?
        let message: String?
        let bundlePath: String?
        let bundleName: String?
        let error: String?
    }

    private struct HelperParseState: Sendable {
        var stdoutBuffer = Data()
        var helperError: String?
        var bundlePath: String?
        var bundleName: String?
    }

    private static func runReferenceImportViaHelper(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) throws -> ReferenceBundleImportResult {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw ReferenceBundleImportError.helperExecutableNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        var arguments = [
            "--reference-import-helper",
            "--input-file", sourceURL.path,
            "--output-dir", outputDirectory.path,
        ]
        if let preferredBundleName,
           !preferredBundleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--name", preferredBundleName])
        }
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())
        let stderrState = OSAllocatedUnfairLock(initialState: Data())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }

            guard let event = try? JSONDecoder().decode(HelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    parseState.withLock { state in
                        if state.helperError == nil {
                            state.helperError = text
                        }
                    }
                }
                return
            }

            switch event.event {
            case "progress", "started":
                if let progress = event.progress {
                    let message = event.message ?? "Importing reference..."
                    progressHandler?(max(0.0, min(1.0, progress)), message)
                }
            case "done":
                parseState.withLock { state in
                    state.bundlePath = event.bundlePath
                    state.bundleName = event.bundleName
                }
            case "error":
                parseState.withLock { state in
                    state.helperError = event.error ?? event.message ?? "Reference import helper failed"
                }
            default:
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrState.withLock { $0.append(data) }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw ReferenceBundleImportError.helperLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        if process.terminationStatus != 0 {
            let helperError = parseState.withLock { $0.helperError }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let fallback = "Helper exited with status \(process.terminationStatus)"
            let message = helperError ?? (stderrMessage.isEmpty ? fallback : stderrMessage)
            throw ReferenceBundleImportError.helperFailed(message)
        }

        let parsed = parseState.withLock { state -> (String?, String?) in
            (state.bundlePath, state.bundleName)
        }

        guard let bundlePath = parsed.0,
              !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReferenceBundleImportError.helperProtocolError("Missing bundle path in helper response")
        }

        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ReferenceBundleImportError.helperProtocolError(
                "Helper reported bundle path that does not exist: \(bundlePath)"
            )
        }

        let inferredName = parsed.1 ?? bundleURL.deletingPathExtension().lastPathComponent
        return ReferenceBundleImportResult(bundleURL: bundleURL, bundleName: inferredName)
    }

    // MARK: - Internal Helpers

    private struct PreparedBuildInputs {
        let fastaURL: URL
        let annotationInputs: [AnnotationInput]
        let sourceInfo: SourceInfo
    }

    private enum PreparedSourceKind {
        case fasta
        case genbank
    }

    @MainActor private func prepareBuildInputs(
        sourceURL: URL,
        bundleName: String,
        tempDirectory: URL
    ) async throws -> PreparedBuildInputs {
        let ext = Self.normalizedExtension(for: sourceURL)

        let kind: PreparedSourceKind
        if ["gb", "gbk", "genbank", "gbff", "embl"].contains(ext) {
            kind = .genbank
        } else if ["fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn"].contains(ext) {
            kind = .fasta
        } else {
            throw ReferenceBundleImportError.unsupportedFormat(sourceURL)
        }

        switch kind {
        case .fasta:
            return try prepareFastaInputs(sourceURL: sourceURL, bundleName: bundleName, tempDirectory: tempDirectory)
        case .genbank:
            return try await prepareGenBankInputs(sourceURL: sourceURL, bundleName: bundleName, tempDirectory: tempDirectory)
        }
    }

    @MainActor private func prepareFastaInputs(
        sourceURL: URL,
        bundleName: String,
        tempDirectory: URL
    ) throws -> PreparedBuildInputs {
        let fastaInput: URL
        if Self.compressionExtensions.contains(sourceURL.pathExtension.lowercased()) {
            let decompressed = tempDirectory.appendingPathComponent("input.fa")
            try decompressInput(sourceURL: sourceURL, outputURL: decompressed)
            fastaInput = decompressed
        } else {
            fastaInput = sourceURL
        }

        let sourceInfo = SourceInfo(
            organism: bundleName,
            assembly: bundleName,
            database: "Imported File",
            sourceURL: sourceURL,
            downloadDate: Date(),
            notes: "Imported from \(sourceURL.lastPathComponent)"
        )

        return PreparedBuildInputs(
            fastaURL: fastaInput,
            annotationInputs: [],
            sourceInfo: sourceInfo
        )
    }

    @MainActor private func prepareGenBankInputs(
        sourceURL: URL,
        bundleName: String,
        tempDirectory: URL
    ) async throws -> PreparedBuildInputs {
        let genBankInput: URL
        if Self.compressionExtensions.contains(sourceURL.pathExtension.lowercased()) {
            let decompressed = tempDirectory.appendingPathComponent("input.gb")
            try decompressInput(sourceURL: sourceURL, outputURL: decompressed)
            genBankInput = decompressed
        } else {
            genBankInput = sourceURL
        }

        let reader = try GenBankReader(url: genBankInput)
        let records = try await reader.readAll()
        guard !records.isEmpty else {
            throw ReferenceBundleImportError.noSequencesFound(sourceURL)
        }

        let sequences = records.map(\.sequence)
        guard !sequences.isEmpty else {
            throw ReferenceBundleImportError.noSequencesFound(sourceURL)
        }

        let fastaOutput = tempDirectory.appendingPathComponent("input.fa")
        try FASTAWriter(url: fastaOutput).write(sequences)

        let hasAnnotations = records.contains { !$0.annotations.isEmpty }
        let annotationInputs: [AnnotationInput] = hasAnnotations ? [
            AnnotationInput(
                url: genBankInput,
                name: "Imported Annotations",
                description: "Converted from \(sourceURL.lastPathComponent)",
                id: "imported_annotations",
                annotationType: .gene
            )
        ] : []

        let firstRecord = records.first
        let organism = firstRecord?.definition
            ?? firstRecord?.sequence.description
            ?? bundleName

        let sourceInfo = SourceInfo(
            organism: organism,
            assembly: bundleName,
            database: "Imported File",
            sourceURL: sourceURL,
            downloadDate: Date(),
            notes: "Imported from \(sourceURL.lastPathComponent)"
        )

        return PreparedBuildInputs(
            fastaURL: fastaOutput,
            annotationInputs: annotationInputs,
            sourceInfo: sourceInfo
        )
    }

    @MainActor private func makeUniqueBundleName(base: String, in directory: URL) -> String {
        var candidate = base
        var counter = 2

        while FileManager.default.fileExists(atPath: bundleURL(forBundleName: candidate, in: directory).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }

        return candidate
    }

    @MainActor private func bundleURL(forBundleName bundleName: String, in directory: URL) -> URL {
        let safeName = bundleName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safeName).lungfishref", isDirectory: true)
    }

    @MainActor private func defaultBundleName(for sourceURL: URL) -> String {
        var stripped = sourceURL
        while !stripped.pathExtension.isEmpty {
            stripped = stripped.deletingPathExtension()
        }
        let base = stripped.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Imported Reference" : base
    }

    @MainActor private func sanitizedBaseName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Imported Reference" }
        return trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    @MainActor private func decompressInput(sourceURL: URL, outputURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        fileManager.createFile(atPath: outputURL.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let wrapper = sourceURL.pathExtension.lowercased()
        let executable: String
        let arguments: [String]
        switch wrapper {
        case "gz", "gzip", "bgz":
            executable = "/usr/bin/gzip"
            arguments = ["-dc", sourceURL.path]
        case "bz2":
            executable = "/usr/bin/bzip2"
            arguments = ["-dc", sourceURL.path]
        case "xz":
            executable = "/usr/bin/xz"
            arguments = ["-dc", sourceURL.path]
        case "zst", "zstd":
            executable = "/usr/bin/env"
            arguments = ["zstd", "-dc", sourceURL.path]
        default:
            throw ReferenceBundleImportError.decompressionFailed("Unsupported wrapper '.\(wrapper)'")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ReferenceBundleImportError.decompressionFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "decompressor exited with code \(process.terminationStatus)"
            let message = stderr?.isEmpty == false ? stderr! : fallback
            throw ReferenceBundleImportError.decompressionFailed(message)
        }
    }
}
