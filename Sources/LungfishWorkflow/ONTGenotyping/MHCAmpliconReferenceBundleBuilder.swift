import Foundation
import CryptoKit
import LungfishIO

public struct MHCAmpliconReferenceBundleDefinitionInput: Equatable, Sendable {
    public let definition: GenotypeHaplotypeDefinitionSet
    public let sourceURL: URL?
    public let sourceDescription: String?
    public let sourceScope: String?

    public init(
        definition: GenotypeHaplotypeDefinitionSet,
        sourceURL: URL? = nil,
        sourceDescription: String? = nil,
        sourceScope: String? = nil
    ) {
        self.definition = definition
        self.sourceURL = sourceURL?.standardizedFileURL
        self.sourceDescription = sourceDescription
        self.sourceScope = sourceScope
    }
}

public struct MHCAmpliconReferenceBundleBuildConfiguration: Equatable, Sendable {
    public let referenceFASTA: URL
    public let haplotypeDefinitionURLs: [URL]
    public let haplotypeDefinitionInputs: [MHCAmpliconReferenceBundleDefinitionInput]
    public let outputURL: URL
    public let name: String?
    public let defaultHaplotypeDefinitionID: String?
    public let sourceFiles: [URL]
    public let sourceDirectories: [URL]
    public let forceOverwrite: Bool
    public let argv: [String]
    public let provenanceWorkflowName: String

    public init(
        referenceFASTA: URL,
        haplotypeDefinitionURLs: [URL],
        haplotypeDefinitionInputs: [MHCAmpliconReferenceBundleDefinitionInput] = [],
        outputURL: URL,
        name: String? = nil,
        defaultHaplotypeDefinitionID: String? = nil,
        sourceFiles: [URL] = [],
        sourceDirectories: [URL] = [],
        forceOverwrite: Bool = false,
        argv: [String] = [],
        provenanceWorkflowName: String = "lungfish fastq mhc-reference-bundle"
    ) {
        self.referenceFASTA = referenceFASTA.standardizedFileURL
        self.haplotypeDefinitionURLs = haplotypeDefinitionURLs.map(\.standardizedFileURL)
        self.haplotypeDefinitionInputs = haplotypeDefinitionInputs
        self.outputURL = outputURL.standardizedFileURL
        self.name = name
        self.defaultHaplotypeDefinitionID = defaultHaplotypeDefinitionID
        self.sourceFiles = sourceFiles.map(\.standardizedFileURL)
        self.sourceDirectories = sourceDirectories.map(\.standardizedFileURL)
        self.forceOverwrite = forceOverwrite
        self.argv = argv
        self.provenanceWorkflowName = provenanceWorkflowName
    }
}

public struct MHCAmpliconReferenceBundleBuildResult: Equatable, Sendable {
    public let bundleURL: URL
    public let provenanceURL: URL
}

public enum MHCAmpliconReferenceBundleBuildError: Error, LocalizedError, Equatable {
    case missingInput(String)
    case outputExists(String)
    case invalidOutputExtension(String)
    case missingHaplotypeDefinition
    case invalidDefaultHaplotypeDefinition(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let path):
            return "MHC reference bundle input does not exist: \(path)"
        case .outputExists(let path):
            return "MHC reference bundle output already exists: \(path)"
        case .invalidOutputExtension(let path):
            return "MHC reference bundle output must end in .\(MHCAmpliconReferenceBundle.directoryExtension): \(path)"
        case .missingHaplotypeDefinition:
            return "MHC reference bundle creation requires at least one haplotype definition JSON file."
        case .invalidDefaultHaplotypeDefinition(let id):
            return "Default haplotype definition is not present in the bundle inputs: \(id)"
        }
    }
}

public struct MHCAmpliconReferenceBundleBuilder: Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    public init() {}

    public func build(
        _ config: MHCAmpliconReferenceBundleBuildConfiguration,
        progressHandler: ProgressHandler? = nil
    ) async throws -> MHCAmpliconReferenceBundleBuildResult {
        let startedAt = Date()
        progressHandler?(0.02, "Validating MHC reference bundle inputs.")
        let definitionInputs = try validate(config)

        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            if config.forceOverwrite {
                try FileManager.default.removeItem(at: config.outputURL)
            } else {
                throw MHCAmpliconReferenceBundleBuildError.outputExists(config.outputURL.path)
            }
        }

        progressHandler?(0.10, "Preparing MHC reference bundle directory.")
        try FileManager.default.createDirectory(at: config.outputURL, withIntermediateDirectories: true)
        do {
            progressHandler?(0.24, "Copying MHC reference FASTA.")
            let referenceRelativePath = referenceCopyName(for: config.referenceFASTA)
            let referenceURL = config.outputURL.appendingPathComponent(referenceRelativePath)
            try FileManager.default.copyItem(at: config.referenceFASTA, to: referenceURL)

            progressHandler?(0.42, "Copying haplotype definitions.")
            let haplotypeDirectory = config.outputURL.appendingPathComponent("haplotypes", isDirectory: true)
            try FileManager.default.createDirectory(at: haplotypeDirectory, withIntermediateDirectories: true)
            var embeddedDefinitions: [(input: ResolvedDefinitionInput, path: String)] = []
            for input in definitionInputs {
                let definition = input.definition
                let filename = "\(safeFileName(definition.id)).lungfishhaplotypedef.json"
                let destination = uniqueDestination(in: haplotypeDirectory, proposedName: filename)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(definition).write(to: destination, options: .atomic)
                embeddedDefinitions.append((input, relativePath(for: destination, in: config.outputURL)))
            }
            let haplotypePaths = embeddedDefinitions.map(\.path)

            progressHandler?(0.58, "Copying MHC reference source files.")
            var sourceFiles: [MHCAmpliconReferenceBundleSourceFile] = [
                MHCAmpliconReferenceBundleSourceFile(
                    path: referenceRelativePath,
                    role: "reference_fasta",
                    originalPath: config.referenceFASTA.path
                ),
            ]
            for embedded in embeddedDefinitions {
                if let sourceURL = embedded.input.sourceURL {
                    sourceFiles.append(try copyBuildSource(sourceURL, into: config.outputURL, role: "haplotype_definition_source"))
                } else {
                    sourceFiles.append(MHCAmpliconReferenceBundleSourceFile(
                        path: embedded.path,
                        role: "haplotype_definition_source",
                        originalPath: embedded.input.sourceDescription
                    ))
                }
            }
            for source in config.sourceFiles + config.sourceDirectories {
                sourceFiles.append(try copyBuildSource(source, into: config.outputURL, role: "build_source"))
            }

            progressHandler?(0.76, "Writing MHC reference bundle manifest.")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let defaultDefinitionID = config.defaultHaplotypeDefinitionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? definitionInputs.first?.definition.id
            let manifest = MHCAmpliconReferenceBundleManifest(
                name: config.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? config.outputURL.deletingPathExtension().lastPathComponent,
                referenceFastaPath: referenceRelativePath,
                haplotypeDefinitionPaths: haplotypePaths,
                defaultHaplotypeDefinitionID: defaultDefinitionID,
                sourceFiles: sourceFiles,
                metrics: MHCAmpliconReferenceBundleMetrics(
                    referenceCount: try FASTAReader(url: referenceURL).readHeadersSync().count,
                    haplotypeDefinitionCount: definitionInputs.count
                ),
                provenancePath: ProvenanceWriter.provenanceFilename,
                createdAt: formatter.string(from: Date())
            )
            try MHCAmpliconReferenceBundle.writeManifest(manifest, to: config.outputURL)

            progressHandler?(0.92, "Writing MHC reference bundle provenance.")
            let provenanceURL = try writeProvenance(
                config: config,
                definitionInputs: definitionInputs,
                bundleURL: config.outputURL,
                startedAt: startedAt,
                completedAt: Date()
            )
            progressHandler?(1.0, "MHC reference bundle creation complete.")
            return MHCAmpliconReferenceBundleBuildResult(
                bundleURL: config.outputURL.standardizedFileURL,
                provenanceURL: provenanceURL.standardizedFileURL
            )
        } catch {
            try? FileManager.default.removeItem(at: config.outputURL)
            throw error
        }
    }

    private struct ResolvedDefinitionInput {
        let definition: GenotypeHaplotypeDefinitionSet
        let sourceURL: URL?
        let sourceDescription: String?
        let sourceScope: String?
    }

    private func validate(
        _ config: MHCAmpliconReferenceBundleBuildConfiguration
    ) throws -> [ResolvedDefinitionInput] {
        guard config.outputURL.pathExtension.lowercased() == MHCAmpliconReferenceBundle.directoryExtension else {
            throw MHCAmpliconReferenceBundleBuildError.invalidOutputExtension(config.outputURL.path)
        }
        guard !config.haplotypeDefinitionURLs.isEmpty || !config.haplotypeDefinitionInputs.isEmpty else {
            throw MHCAmpliconReferenceBundleBuildError.missingHaplotypeDefinition
        }
        for input in [config.referenceFASTA] + config.haplotypeDefinitionURLs + config.sourceFiles + config.sourceDirectories {
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw MHCAmpliconReferenceBundleBuildError.missingInput(input.path)
            }
        }
        for input in config.haplotypeDefinitionInputs {
            if let sourceURL = input.sourceURL,
               !FileManager.default.fileExists(atPath: sourceURL.path) {
                throw MHCAmpliconReferenceBundleBuildError.missingInput(sourceURL.path)
            }
        }
        let fileInputs = try config.haplotypeDefinitionURLs.map { url in
            let data = try Data(contentsOf: url)
            return ResolvedDefinitionInput(
                definition: try JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data),
                sourceURL: url,
                sourceDescription: url.path,
                sourceScope: nil
            )
        }
        let resolvedInputs = fileInputs + config.haplotypeDefinitionInputs.map { input in
            ResolvedDefinitionInput(
                definition: input.definition,
                sourceURL: input.sourceURL,
                sourceDescription: input.sourceDescription,
                sourceScope: input.sourceScope
            )
        }
        if let defaultID = config.defaultHaplotypeDefinitionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultID.isEmpty,
           !resolvedInputs.contains(where: { $0.definition.id == defaultID }) {
            throw MHCAmpliconReferenceBundleBuildError.invalidDefaultHaplotypeDefinition(defaultID)
        }
        return resolvedInputs
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
    ) throws -> MHCAmpliconReferenceBundleSourceFile {
        let sourcesURL = bundleURL.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        let destination = uniqueDestination(
            in: sourcesURL,
            proposedName: sourceURL.lastPathComponent.isEmpty ? "source" : sourceURL.lastPathComponent
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return MHCAmpliconReferenceBundleSourceFile(
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
        guard !FileManager.default.fileExists(atPath: candidate.path) else {
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
        return candidate
    }

    private func writeProvenance(
        config: MHCAmpliconReferenceBundleBuildConfiguration,
        definitionInputs: [ResolvedDefinitionInput],
        bundleURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let argv = config.argv.isEmpty ? replayArgv(for: config) : config.argv
        var explicit: [String: ParameterValue] = [
            "referenceFASTA": .file(config.referenceFASTA),
            "haplotypeDefinitionSources": .array(definitionInputs.map(definitionSourceParameter(_:))),
            "output": .file(bundleURL),
            "forceOverwrite": .boolean(config.forceOverwrite),
        ]
        if let name = config.name {
            explicit["name"] = .string(name)
        }
        if let defaultID = config.defaultHaplotypeDefinitionID {
            explicit["defaultHaplotypeDefinitionID"] = .string(defaultID)
        }
        if !config.sourceFiles.isEmpty {
            explicit["sourceFiles"] = .array(config.sourceFiles.map { .file($0) })
        }
        if !config.sourceDirectories.isEmpty {
            explicit["sourceDirectories"] = .array(config.sourceDirectories.map { .file($0) })
        }
        var inputs = [
            try ProvenanceFileDescriptor.file(url: config.referenceFASTA, format: .fasta, role: .reference),
        ]
        for url in definitionInputs.compactMap(\.sourceURL) {
            inputs.append(try ProvenanceFileDescriptor.file(url: url, format: .json, role: .reference))
        }
        for url in config.sourceFiles {
            inputs.append(try ProvenanceFileDescriptor.file(url: url, format: .unknown, role: .reference))
        }
        for url in config.sourceDirectories {
            inputs.append(try directoryDescriptor(url: url, role: .reference))
        }
        let outputs = try bundleOutputDescriptors(bundleURL)
        let step = ProvenanceStep(
            toolName: config.provenanceWorkflowName,
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
            workflowName: config.provenanceWorkflowName,
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

    private func definitionSourceParameter(_ input: ResolvedDefinitionInput) -> ParameterValue {
        var fields: [String: ParameterValue] = [
            "definitionID": .string(input.definition.id),
            "assayID": .string(input.definition.assayID),
            "speciesCode": .string(input.definition.speciesCode),
        ]
        if let sourceURL = input.sourceURL {
            fields["sourcePath"] = .file(sourceURL)
        }
        if let sourceDescription = input.sourceDescription {
            fields["sourceDescription"] = .string(sourceDescription)
        }
        if let sourceScope = input.sourceScope {
            fields["scope"] = .string(sourceScope)
        }
        return .dictionary(fields)
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

    private func replayArgv(for config: MHCAmpliconReferenceBundleBuildConfiguration) -> [String] {
        var argv = [
            "lungfish-cli", "fastq", "mhc-reference-bundle",
            "--reference-fasta", config.referenceFASTA.path,
            "--output", config.outputURL.path,
        ]
        for definition in config.haplotypeDefinitionURLs {
            argv += ["--haplotype-definition", definition.path]
        }
        for input in config.haplotypeDefinitionInputs {
            argv += ["--definition", input.definition.id]
            if let sourceScope = input.sourceScope {
                argv += ["--scope", sourceScope]
            }
        }
        if let name = config.name {
            argv += ["--name", name]
        }
        if let defaultID = config.defaultHaplotypeDefinitionID {
            argv += ["--default-haplotype-definition", defaultID]
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

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let name = String(scalars).trimmingCharacters(in: .init(charactersIn: ".-_"))
        return name.isEmpty ? "haplotype-definition" : name
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
