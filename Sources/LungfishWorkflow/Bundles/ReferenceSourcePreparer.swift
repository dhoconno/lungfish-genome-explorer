import Foundation
import LungfishCore
import LungfishIO

public struct ReferenceImportWarning: Codable, Equatable, Hashable, Sendable {
    public let category: String
    public let code: String
    public let message: String
    public let recordIdentifier: String?
    public let featureType: String?
    public let recordFieldKey: String?
    public let sourceLocation: String?
    public let lineNumber: Int?

    public init(
        category: String,
        code: String = "recoverable_import_warning",
        message: String,
        recordIdentifier: String? = nil,
        featureType: String? = nil,
        recordFieldKey: String? = nil,
        sourceLocation: String? = nil,
        lineNumber: Int? = nil
    ) {
        self.category = category
        self.code = code
        self.message = message
        self.recordIdentifier = recordIdentifier
        self.featureType = featureType
        self.recordFieldKey = recordFieldKey
        self.sourceLocation = sourceLocation
        self.lineNumber = lineNumber
    }

    public var bundleWarning: BundleWarning {
        BundleWarning(
            category: category,
            code: code,
            message: message,
            recordIdentifier: recordIdentifier,
            featureType: featureType,
            recordFieldKey: recordFieldKey,
            sourceLocation: sourceLocation,
            lineNumber: lineNumber
        )
    }
}

public struct PreparedReferenceSource: Sendable {
    public let fastaURL: URL
    public let annotationInputs: [AnnotationInput]
    public let sourceInfo: SourceInfo
    public let sequenceNames: [String]
    public let warnings: [ReferenceImportWarning]
    public let recordStoreURL: URL?

    public init(
        fastaURL: URL,
        annotationInputs: [AnnotationInput],
        sourceInfo: SourceInfo,
        sequenceNames: [String],
        warnings: [ReferenceImportWarning],
        recordStoreURL: URL? = nil
    ) {
        self.fastaURL = fastaURL
        self.annotationInputs = annotationInputs
        self.sourceInfo = sourceInfo
        self.sequenceNames = sequenceNames
        self.warnings = warnings
        self.recordStoreURL = recordStoreURL
    }
}

public struct ReferenceSourcePreparer: Sendable {
    /// Finds the managed xz and zstd that decompress a `.xz`, `.zst` or `.zstd` wrapper (lane 13.17 M3).
    private let runner: NativeToolRunner

    public init(runner: NativeToolRunner = .shared) {
        self.runner = runner
    }

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
            try await decompressInput(sourceURL: sourceURL, outputURL: decompressed)
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
            try await decompressInput(sourceURL: sourceURL, outputURL: decompressed)
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
        let recordStoreURL = tempDirectory.appendingPathComponent("genbank_records.sqlite")
        try GenBankRecordDatabase.create(records: recovery.records, at: recordStoreURL)
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
        let mappedWarnings = recovery.warnings.map {
            let isRecordFieldWarning = $0.recordFieldKey != nil
            return ReferenceImportWarning(
                category: isRecordFieldWarning
                    ? "genbank.record-field.recovery"
                    : "genbank.feature.recovery",
                code: isRecordFieldWarning
                    ? "malformed_record_field"
                    : "invalid_feature_location",
                message: $0.message,
                recordIdentifier: $0.recordIdentifier,
                featureType: $0.featureType,
                recordFieldKey: $0.recordFieldKey,
                sourceLocation: $0.sourceLocation,
                lineNumber: $0.lineNumber
            )
        }
        var seenWarnings: Set<ReferenceImportWarning> = []
        let warnings = mappedWarnings.filter { seenWarnings.insert($0).inserted }

        return PreparedReferenceSource(
            fastaURL: fastaOutput,
            annotationInputs: annotationInputs,
            sourceInfo: sourceInfo(sourceURL: sourceURL, bundleName: bundleName, organism: organism),
            sequenceNames: sequences.map(\.name),
            warnings: warnings,
            recordStoreURL: recordStoreURL
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

    /// Decompresses `sourceURL` into `outputURL` on `ToolProcess`, which ends the child and waits for it
    /// when the calling task is cancelled, so a cancel is acted on while a large file decompresses
    /// (A48 M3 review, Fix 1). The child writes straight into `outputURL`.
    private func decompressInput(sourceURL: URL, outputURL: URL) async throws {
        let wrapper = sourceURL.pathExtension.lowercased()

        /// The managed tool, or a failed decompression in Lungfish's own words when it is not installed.
        func managed(_ tool: NativeTool) async throws -> URL {
            do {
                return try await runner.toolPath(for: tool)
            } catch let error as NativeToolError {
                if case .toolNotFound = error {
                    throw ReferenceBundleImportError.decompressionFailed(
                        "\(tool.rawValue) is not installed, and a .\(wrapper) file needs it. Lungfish installs it "
                            + "with its Required Setup. In the app, open the Welcome window and click Install, or "
                            + "run lungfish-cli tools update --apply --yes --required-only."
                    )
                }
                throw ReferenceBundleImportError.decompressionFailed(error.localizedDescription)
            }
        }

        let executable: URL
        let environment: [String: String]
        switch wrapper {
        case "gz", "gzip", "bgz":
            executable = URL(fileURLWithPath: "/usr/bin/gzip")
            environment = ToolProcessSpec.inheritedEnvironment()
        case "bz2":
            executable = URL(fileURLWithPath: "/usr/bin/bzip2")
            environment = ToolProcessSpec.inheritedEnvironment()
        case "xz":
            executable = try await managed(.xz)
            environment = [:]
        case "zst", "zstd":
            executable = try await managed(.zstd)
            environment = [:]
        default:
            throw ReferenceBundleImportError.decompressionFailed("Unsupported wrapper '.\(wrapper)'")
        }

        // gzip and bzip2 get the caller's environment, as the processes they replace did. The managed xz and
        // zstd get an empty one, since a conda build finds its libraries through its own rpath.
        let spec = ToolProcessSpec(
            executableURL: executable,
            arguments: ["-dc", sourceURL.path],
            environment: environment,
            stdout: .file(outputURL),
            label: "decompress .\(wrapper)"
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch ToolProcessError.cancelled {
            throw CancellationError()
        } catch {
            throw ReferenceBundleImportError.decompressionFailed(error.localizedDescription)
        }
        // A child the cancel ended is the cancel, and never a failed decompression.
        try Task.checkCancellation()
        guard result.isSuccess else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReferenceBundleImportError.decompressionFailed(
                !stderr.isEmpty
                    ? stderr
                    : (result.incompleteOutputReason ?? "decompressor exited with code \(result.status)")
            )
        }
    }
}
