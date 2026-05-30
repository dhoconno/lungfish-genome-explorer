import Foundation
import CryptoKit
import LungfishIO

public struct TwelveSReferenceBundleBuildConfiguration: Equatable, Sendable {
    public let deduplicatedFASTA: URL
    public let midoriMetadataTSV: URL
    public let outputURL: URL
    public let name: String?
    public let sourceFiles: [URL]
    public let sourceDirectories: [URL]
    public let forceOverwrite: Bool
    public let argv: [String]

    public init(
        deduplicatedFASTA: URL,
        midoriMetadataTSV: URL,
        outputURL: URL,
        name: String? = nil,
        sourceFiles: [URL] = [],
        sourceDirectories: [URL] = [],
        forceOverwrite: Bool = false,
        argv: [String] = []
    ) {
        self.deduplicatedFASTA = deduplicatedFASTA.standardizedFileURL
        self.midoriMetadataTSV = midoriMetadataTSV.standardizedFileURL
        self.outputURL = outputURL.standardizedFileURL
        self.name = name
        self.sourceFiles = sourceFiles.map(\.standardizedFileURL)
        self.sourceDirectories = sourceDirectories.map(\.standardizedFileURL)
        self.forceOverwrite = forceOverwrite
        self.argv = argv
    }
}

public struct TwelveSReferenceBundleBuildResult: Equatable, Sendable {
    public let bundleURL: URL
    public let provenanceURL: URL
}

public enum TwelveSReferenceBundleBuildError: Error, LocalizedError, Equatable {
    case missingInput(String)
    case outputExists(String)
    case invalidOutputExtension(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let path):
            return "12S reference bundle input does not exist: \(path)"
        case .outputExists(let path):
            return "12S reference bundle output already exists: \(path)"
        case .invalidOutputExtension(let path):
            return "12S reference bundle output must end in .\(TwelveSReferenceBundle.directoryExtension): \(path)"
        }
    }
}

public struct TwelveSReferenceBundleBuilder: Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    public init() {}

    public func build(
        _ config: TwelveSReferenceBundleBuildConfiguration,
        progressHandler: ProgressHandler? = nil
    ) async throws -> TwelveSReferenceBundleBuildResult {
        let startedAt = Date()
        progressHandler?(0.02, "Validating 12S reference bundle inputs.")
        try validate(config)

        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            if config.forceOverwrite {
                try FileManager.default.removeItem(at: config.outputURL)
            } else {
                throw TwelveSReferenceBundleBuildError.outputExists(config.outputURL.path)
            }
        }
        progressHandler?(0.08, "Preparing 12S reference bundle directory.")
        try FileManager.default.createDirectory(at: config.outputURL, withIntermediateDirectories: true)
        do {
            let referenceRelativePath = referenceCopyName(for: config.deduplicatedFASTA)
            let referenceURL = config.outputURL.appendingPathComponent(referenceRelativePath)
            progressHandler?(0.18, "Copying deduplicated 12S reference FASTA.")
            try FileManager.default.copyItem(at: config.deduplicatedFASTA, to: referenceURL)

            let metadataURL = config.outputURL.appendingPathComponent("target-metadata.tsv")
            progressHandler?(0.35, "Building 12S target metadata.")
            _ = try await TwelveSReferenceMetadataBuilder().build(
                TwelveSReferenceMetadataBuildConfiguration(
                    deduplicatedFASTA: referenceURL,
                    midoriMetadataTSV: config.midoriMetadataTSV,
                    outputURL: metadataURL,
                    forceOverwrite: true,
                    argv: [
                        "lungfish-cli", "fastq", "12s-reference-metadata",
                        "--dedup-fasta", referenceURL.path,
                        "--midori-metadata", config.midoriMetadataTSV.path,
                        "--output", metadataURL.path,
                        "--force",
                    ]
                )
            )

            progressHandler?(0.58, "Copying 12S reference source files.")
            var sourceFiles: [TwelveSReferenceBundleSourceFile] = [
                TwelveSReferenceBundleSourceFile(
                    path: referenceRelativePath,
                    role: "deduplicated_fasta",
                    originalPath: config.deduplicatedFASTA.path
                ),
            ]
            sourceFiles.append(
                try copyBuildSource(
                    config.midoriMetadataTSV,
                    into: config.outputURL,
                    role: "midori_metadata"
                )
            )
            for url in config.sourceFiles + config.sourceDirectories {
                sourceFiles.append(try copyBuildSource(url, into: config.outputURL, role: "build_source"))
            }

            progressHandler?(0.76, "Computing 12S reference bundle metrics.")
            let metrics = try makeMetrics(referenceURL: referenceURL, metadataURL: metadataURL)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            progressHandler?(0.86, "Writing 12S reference bundle manifest.")
            let manifest = TwelveSReferenceBundleManifest(
                name: config.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? config.outputURL.deletingPathExtension().lastPathComponent,
                referenceFastaPath: referenceRelativePath,
                targetMetadataPath: metadataURL.lastPathComponent,
                sourceFiles: sourceFiles,
                metrics: metrics,
                provenancePath: ProvenanceWriter.provenanceFilename,
                createdAt: formatter.string(from: Date())
            )
            try TwelveSReferenceBundle.writeManifest(manifest, to: config.outputURL)
            progressHandler?(0.94, "Writing 12S reference bundle provenance.")
            let provenanceURL = try writeProvenance(
                config: config,
                bundleURL: config.outputURL,
                startedAt: startedAt,
                completedAt: Date()
            )
            progressHandler?(1.0, "12S reference bundle creation complete.")
            return TwelveSReferenceBundleBuildResult(
                bundleURL: config.outputURL.standardizedFileURL,
                provenanceURL: provenanceURL.standardizedFileURL
            )
        } catch {
            try? FileManager.default.removeItem(at: config.outputURL)
            throw error
        }
    }

    private func validate(_ config: TwelveSReferenceBundleBuildConfiguration) throws {
        guard config.outputURL.pathExtension.lowercased() == TwelveSReferenceBundle.directoryExtension else {
            throw TwelveSReferenceBundleBuildError.invalidOutputExtension(config.outputURL.path)
        }
        for input in [config.deduplicatedFASTA, config.midoriMetadataTSV] + config.sourceFiles + config.sourceDirectories {
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw TwelveSReferenceBundleBuildError.missingInput(input.path)
            }
        }
    }

    private func referenceCopyName(for url: URL) -> String {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".fa.gz") { return "reference.fa.gz" }
        if lower.hasSuffix(".fasta.gz") { return "reference.fasta.gz" }
        if lower.hasSuffix(".fna.gz") { return "reference.fna.gz" }
        let ext = url.pathExtension.isEmpty ? "fa" : url.pathExtension
        return "reference.\(ext)"
    }

    private func copyBuildSource(
        _ sourceURL: URL,
        into bundleURL: URL,
        role: String
    ) throws -> TwelveSReferenceBundleSourceFile {
        let sourcesURL = bundleURL.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        let destination = uniqueDestination(
            in: sourcesURL,
            proposedName: sourceURL.lastPathComponent.isEmpty ? "source" : sourceURL.lastPathComponent
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return TwelveSReferenceBundleSourceFile(
            path: relativePath(for: destination, in: bundleURL),
            role: role,
            originalPath: sourceURL.path
        )
    }

    private func uniqueDestination(in directory: URL, proposedName: String) -> URL {
        let sanitized = proposedName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        var candidate = directory.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...10_000 {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(sanitized)")
    }

    private func makeMetrics(referenceURL: URL, metadataURL: URL) throws -> TwelveSReferenceBundleMetrics {
        let referenceCount = try TwelveSReferenceIndex.load(from: referenceURL).records.count
        let rows = try loadTSVRows(from: metadataURL)
        let decoder = JSONDecoder()
        var alternateCount = 0
        for row in rows {
            guard let raw = row["alternate_matches_json"],
                  let data = raw.data(using: String.Encoding.utf8),
                  let matches = try? decoder.decode([TwelveSAlternateMatch].self, from: data) else {
                continue
            }
            alternateCount += matches.count
        }
        return TwelveSReferenceBundleMetrics(
            referenceCount: referenceCount,
            metadataRowCount: rows.count,
            taxidCount: rows.filter { ($0["taxid"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count,
            taxonGroupCount: rows.filter { ($0["taxon_group"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count,
            taxonomyCount: rows.filter { ($0["taxonomy"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count,
            alternateMatchCount: alternateCount
        )
    }

    private func writeProvenance(
        config: TwelveSReferenceBundleBuildConfiguration,
        bundleURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let argv = config.argv.isEmpty ? replayArgv(for: config) : config.argv
        var explicit: [String: ParameterValue] = [
            "deduplicatedFASTA": .file(config.deduplicatedFASTA),
            "midoriMetadataTSV": .file(config.midoriMetadataTSV),
            "output": .file(bundleURL),
            "forceOverwrite": .boolean(config.forceOverwrite),
        ]
        if let name = config.name {
            explicit["name"] = .string(name)
        }
        if !config.sourceFiles.isEmpty {
            explicit["sourceFiles"] = .array(config.sourceFiles.map { .file($0) })
        }
        if !config.sourceDirectories.isEmpty {
            explicit["sourceDirectories"] = .array(config.sourceDirectories.map { .file($0) })
        }

        var inputs = [
            try ProvenanceFileDescriptor.file(url: config.deduplicatedFASTA, format: .fasta, role: .reference),
            try ProvenanceFileDescriptor.file(url: config.midoriMetadataTSV, format: .text, role: .reference),
        ]
        for source in config.sourceFiles {
            inputs.append(try ProvenanceFileDescriptor.file(url: source, format: .unknown, role: .reference))
        }
        for source in config.sourceDirectories {
            inputs.append(try directoryDescriptor(url: source, role: .reference))
        }
        let outputs = try bundleOutputDescriptors(bundleURL)
        let step = ProvenanceStep(
            toolName: "lungfish fastq 12s-reference-bundle",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: commandLine(from: argv),
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "lungfish fastq 12s-reference-bundle",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(name: "lungfish-cli", version: WorkflowRun.currentAppVersion, kind: "cli"),
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: commandLine(from: argv),
            options: ProvenanceOptions(
                explicit: explicit,
                defaults: ["forceOverwrite": .boolean(false)],
                resolvedDefaults: [
                    "name": .string(config.name ?? bundleURL.deletingPathExtension().lastPathComponent),
                    "forceOverwrite": .boolean(config.forceOverwrite),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser),
            files: inputs + outputs,
            output: outputs.first,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
        return try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private func bundleOutputDescriptors(_ bundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        var descriptors = [try directoryDescriptor(url: bundleURL, role: .output)]
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return descriptors
        }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            descriptors.append(
                try ProvenanceFileDescriptor.file(url: url, format: fileFormat(for: url), role: .output)
            )
        }
        return descriptors
    }

    private func loadTSVRows(from url: URL) throws -> [[String: String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let headerLine = lines.first else { return [] }
        let headers = splitTSVLine(headerLine).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.dropFirst().map { line in
            let fields = splitTSVLine(line)
            var row: [String: String] = [:]
            for index in headers.indices where !headers[index].isEmpty {
                row[headers[index]] = index < fields.count ? fields[index] : ""
            }
            return row
        }
    }

    private func splitTSVLine(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    private func directoryDescriptor(url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: url, role: role)
        return ProvenanceFileDescriptor(
            path: url.standardizedFileURL.path,
            checksumSHA256: directoryChecksum(from: manifest),
            fileSize: directorySize(from: manifest),
            format: .unknown,
            role: role
        )
    }

    private func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
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

    private func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }

    private func fileFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "json": return .json
        case "fa", "fasta", "fna", "gz": return .fasta
        case "tsv", "txt", "log": return .text
        default: return .unknown
        }
    }

    private func replayArgv(for config: TwelveSReferenceBundleBuildConfiguration) -> [String] {
        var argv = [
            "lungfish-cli", "fastq", "12s-reference-bundle",
            "--dedup-fasta", config.deduplicatedFASTA.path,
            "--midori-metadata", config.midoriMetadataTSV.path,
            "--output", config.outputURL.path,
        ]
        if let name = config.name {
            argv += ["--name", name]
        }
        for file in config.sourceFiles {
            argv += ["--source-file", file.path]
        }
        for directory in config.sourceDirectories {
            argv += ["--source-directory", directory.path]
        }
        if config.forceOverwrite {
            argv.append("--force")
        }
        return argv
    }

    private func commandLine(from argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }

    private func relativePath(for url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func shellEscape(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\"$`!\\"))) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
