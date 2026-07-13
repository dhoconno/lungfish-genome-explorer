import Foundation
import LungfishCore
import LungfishIO

public struct ReferenceImportWarning: Codable, Equatable, Sendable {
    public let category: String
    public let message: String
    public let recordIdentifier: String?
    public let featureType: String?
    public let sourceLocation: String?

    public init(
        category: String,
        message: String,
        recordIdentifier: String? = nil,
        featureType: String? = nil,
        sourceLocation: String? = nil
    ) {
        self.category = category
        self.message = message
        self.recordIdentifier = recordIdentifier
        self.featureType = featureType
        self.sourceLocation = sourceLocation
    }
}

public struct PreparedReferenceSource: Sendable {
    public let fastaURL: URL
    public let annotationInputs: [AnnotationInput]
    public let sourceInfo: SourceInfo
    public let sequenceNames: [String]
    public let warnings: [ReferenceImportWarning]

    public init(
        fastaURL: URL,
        annotationInputs: [AnnotationInput],
        sourceInfo: SourceInfo,
        sequenceNames: [String],
        warnings: [ReferenceImportWarning]
    ) {
        self.fastaURL = fastaURL
        self.annotationInputs = annotationInputs
        self.sourceInfo = sourceInfo
        self.sequenceNames = sequenceNames
        self.warnings = warnings
    }
}

public struct ReferenceSourcePreparer: Sendable {
    public init() {}

    public func prepare(
        sourceURL: URL,
        bundleName: String,
        tempDirectory: URL
    ) async throws -> PreparedReferenceSource {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let ext = ReferenceBundleImportService.normalizedExtension(for: sourceURL)

        if ["gb", "gbk", "genbank", "gbff", "embl"].contains(ext) {
            return try await prepareGenBank(
                sourceURL: sourceURL,
                bundleName: bundleName,
                tempDirectory: tempDirectory
            )
        }
        if ["fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn"].contains(ext) {
            return try await prepareFASTA(
                sourceURL: sourceURL,
                bundleName: bundleName,
                tempDirectory: tempDirectory
            )
        }
        throw ReferenceBundleImportError.unsupportedFormat(sourceURL)
    }

    private func prepareFASTA(
        sourceURL: URL,
        bundleName: String,
        tempDirectory: URL
    ) async throws -> PreparedReferenceSource {
        let fastaInput: URL
        if ReferenceBundleImportService.compressionExtensions.contains(sourceURL.pathExtension.lowercased()) {
            let decompressed = tempDirectory.appendingPathComponent("input.fa")
            try decompressInput(sourceURL: sourceURL, outputURL: decompressed)
            fastaInput = decompressed
        } else {
            fastaInput = sourceURL
        }

        let sequences = try await FASTAReader(url: fastaInput).readAll()
        guard !sequences.isEmpty else {
            throw ReferenceBundleImportError.noSequencesFound(sourceURL)
        }
        return PreparedReferenceSource(
            fastaURL: fastaInput,
            annotationInputs: [],
            sourceInfo: sourceInfo(sourceURL: sourceURL, bundleName: bundleName, organism: bundleName),
            sequenceNames: sequences.map(\.name),
            warnings: []
        )
    }

    private func prepareGenBank(
        sourceURL: URL,
        bundleName: String,
        tempDirectory: URL
    ) async throws -> PreparedReferenceSource {
        let genBankInput: URL
        if ReferenceBundleImportService.compressionExtensions.contains(sourceURL.pathExtension.lowercased()) {
            let decompressed = tempDirectory.appendingPathComponent("input.gb")
            try decompressInput(sourceURL: sourceURL, outputURL: decompressed)
            genBankInput = decompressed
        } else {
            genBankInput = sourceURL
        }

        let recovery = try await GenBankReader(url: genBankInput).readAllRecoveringAnnotations()
        let sequences = recovery.records.map(\.sequence)
        guard !sequences.isEmpty else {
            throw ReferenceBundleImportError.noSequencesFound(sourceURL)
        }

        let fastaOutput = tempDirectory.appendingPathComponent("input.fa")
        try FASTAWriter(url: fastaOutput).write(sequences)
        let hasAnnotations = recovery.records.contains { !$0.annotations.isEmpty }
        let annotationInputs = hasAnnotations ? [
            AnnotationInput(
                url: genBankInput,
                name: "Imported Annotations",
                description: "Converted from \(sourceURL.lastPathComponent)",
                id: "imported_annotations",
                annotationType: .gene
            )
        ] : []
        let organism = recovery.records.first?.definition
            ?? recovery.records.first?.sequence.description
            ?? bundleName

        return PreparedReferenceSource(
            fastaURL: fastaOutput,
            annotationInputs: annotationInputs,
            sourceInfo: sourceInfo(sourceURL: sourceURL, bundleName: bundleName, organism: organism),
            sequenceNames: sequences.map(\.name),
            warnings: recovery.warnings.map {
                ReferenceImportWarning(
                    category: "genbank.annotation.skipped",
                    message: $0.message,
                    recordIdentifier: $0.recordIdentifier,
                    featureType: $0.featureType,
                    sourceLocation: $0.sourceLocation
                )
            }
        )
    }

    private func sourceInfo(sourceURL: URL, bundleName: String, organism: String) -> SourceInfo {
        SourceInfo(
            organism: organism,
            assembly: bundleName,
            database: "Imported File",
            sourceURL: sourceURL,
            downloadDate: Date(),
            notes: "Imported from \(sourceURL.lastPathComponent)"
        )
    }

    private func decompressInput(sourceURL: URL, outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
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
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReferenceBundleImportError.decompressionFailed(
                stderr?.isEmpty == false ? stderr! : "decompressor exited with code \(process.terminationStatus)"
            )
        }
    }
}
