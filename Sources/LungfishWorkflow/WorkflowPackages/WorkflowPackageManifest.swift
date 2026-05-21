import Foundation

public enum WorkflowPackageRunnerKind: String, Codable, Sendable, CaseIterable {
    case nextflow
    case snakemake
    case command
}

public enum WorkflowPackageRuntimeKind: String, Codable, Sendable, CaseIterable {
    case none
    case conda
    case docker
}

public enum WorkflowPackageBundleType: String, Codable, Sendable, CaseIterable {
    case lungfishref
    case lungfishfastq
    case lungfishbam
    case lungfishvcf
    case lungfishmsa
    case lungfishtree
    case lungfishproject
}

public enum WorkflowPackageMaturity: String, Codable, Sendable, CaseIterable {
    case core
    case specialized
    case experimental
    case user
}

public struct WorkflowPackageRunner: Codable, Sendable, Equatable {
    public let kind: WorkflowPackageRunnerKind
    public let entrypoint: String
    public let commandTemplate: [String]?

    public init(
        kind: WorkflowPackageRunnerKind,
        entrypoint: String,
        commandTemplate: [String]? = nil
    ) {
        self.kind = kind
        self.entrypoint = entrypoint
        self.commandTemplate = commandTemplate
    }
}

public struct WorkflowPackageRuntime: Codable, Sendable, Equatable {
    public let kind: WorkflowPackageRuntimeKind
    public let environmentFile: String?
    public let containerImage: String?

    public init(
        kind: WorkflowPackageRuntimeKind = .none,
        environmentFile: String? = nil,
        containerImage: String? = nil
    ) {
        self.kind = kind
        self.environmentFile = environmentFile
        self.containerImage = containerImage
    }
}

public struct WorkflowPackageInput: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bundleTypes: [WorkflowPackageBundleType]
    public let required: Bool

    public init(
        id: String,
        name: String,
        bundleTypes: [WorkflowPackageBundleType],
        required: Bool = true
    ) {
        self.id = id
        self.name = name
        self.bundleTypes = bundleTypes
        self.required = required
    }
}

public struct WorkflowPackageOutput: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bundleType: WorkflowPackageBundleType
    public let pathTemplate: String

    public init(
        id: String,
        name: String,
        bundleType: WorkflowPackageBundleType,
        pathTemplate: String
    ) {
        self.id = id
        self.name = name
        self.bundleType = bundleType
        self.pathTemplate = pathTemplate
    }
}

public struct WorkflowPackageTemplateMetadata: Codable, Sendable, Equatable {
    public let stepCount: Int
    public let summary: String?

    public init(stepCount: Int, summary: String? = nil) {
        self.stepCount = stepCount
        self.summary = summary
    }
}

public struct WorkflowPackageManifest: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let author: String?
    public let category: String
    public let maturity: WorkflowPackageMaturity
    public let description: String?
    public let runner: WorkflowPackageRunner
    public let runtime: WorkflowPackageRuntime
    public let inputs: [WorkflowPackageInput]
    public let outputs: [WorkflowPackageOutput]
    public let requiredPluginPackIDs: [String]
    public let template: WorkflowPackageTemplateMetadata?

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        version: String,
        author: String? = nil,
        category: String,
        maturity: WorkflowPackageMaturity = .user,
        description: String? = nil,
        runner: WorkflowPackageRunner,
        runtime: WorkflowPackageRuntime = WorkflowPackageRuntime(),
        inputs: [WorkflowPackageInput],
        outputs: [WorkflowPackageOutput],
        requiredPluginPackIDs: [String] = [],
        template: WorkflowPackageTemplateMetadata? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.category = category
        self.maturity = maturity
        self.description = description
        self.runner = runner
        self.runtime = runtime
        self.inputs = inputs
        self.outputs = outputs
        self.requiredPluginPackIDs = requiredPluginPackIDs
        self.template = template
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case version
        case author
        case category
        case maturity
        case description
        case runner
        case runtime
        case inputs
        case outputs
        case requiredPluginPackIDs
        case template
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        category = try container.decode(String.self, forKey: .category)
        maturity = try container.decodeIfPresent(WorkflowPackageMaturity.self, forKey: .maturity) ?? .user
        description = try container.decodeIfPresent(String.self, forKey: .description)
        runner = try container.decode(WorkflowPackageRunner.self, forKey: .runner)
        runtime = try container.decodeIfPresent(WorkflowPackageRuntime.self, forKey: .runtime) ?? WorkflowPackageRuntime()
        inputs = try container.decode([WorkflowPackageInput].self, forKey: .inputs)
        outputs = try container.decode([WorkflowPackageOutput].self, forKey: .outputs)
        requiredPluginPackIDs = try container.decodeIfPresent([String].self, forKey: .requiredPluginPackIDs) ?? []
        template = try container.decodeIfPresent(WorkflowPackageTemplateMetadata.self, forKey: .template)
    }
}

public struct WorkflowPackageValidationResult: Sendable, Equatable {
    public let packageURL: URL
    public let manifestURL: URL
    public let manifest: WorkflowPackageManifest
    public let warnings: [String]

    public init(
        packageURL: URL,
        manifestURL: URL,
        manifest: WorkflowPackageManifest,
        warnings: [String] = []
    ) {
        self.packageURL = packageURL.standardizedFileURL
        self.manifestURL = manifestURL.standardizedFileURL
        self.manifest = manifest
        self.warnings = warnings
    }
}

public enum WorkflowPackageValidationError: Error, LocalizedError, Equatable {
    case invalidPackageExtension(String)
    case missingPackage(URL)
    case missingManifest
    case unsupportedSchemaVersion(Int)
    case emptyWorkflowID
    case emptyRunnerEntrypoint
    case missingRunnerEntrypoint(String)
    case missingRuntimeFile(String)
    case missingInputs
    case missingOutputs
    case emptyInputBundleTypes(String)
    case unpinnedContainerImage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPackageExtension(let ext):
            return "Workflow packages must use .lungfishflowpkg directories; found .\(ext)."
        case .missingPackage(let url):
            return "Workflow package does not exist: \(url.path)"
        case .missingManifest:
            return "Workflow package is missing manifest.json."
        case .unsupportedSchemaVersion(let version):
            return "Unsupported workflow package schema version: \(version)."
        case .emptyWorkflowID:
            return "Workflow package id cannot be empty."
        case .emptyRunnerEntrypoint:
            return "Workflow package runner entrypoint cannot be empty."
        case .missingRunnerEntrypoint(let entrypoint):
            return "Workflow package runner entrypoint is missing: \(entrypoint)."
        case .missingRuntimeFile(let path):
            return "Workflow package runtime file is missing: \(path)."
        case .missingInputs:
            return "Workflow package must declare at least one input."
        case .missingOutputs:
            return "Workflow package must declare at least one output."
        case .emptyInputBundleTypes(let inputID):
            return "Workflow package input \(inputID) must declare at least one bundle type."
        case .unpinnedContainerImage(let image):
            return "Workflow package container images must be pinned by digest or local build identity: \(image)."
        }
    }
}

public enum WorkflowPackageValidator {
    public static let packageExtension = "lungfishflowpkg"
    public static let manifestFilename = "manifest.json"

    public static func validatePackage(at packageURL: URL) throws -> WorkflowPackageValidationResult {
        let packageURL = packageURL.standardizedFileURL
        guard packageURL.pathExtension.lowercased() == packageExtension else {
            throw WorkflowPackageValidationError.invalidPackageExtension(packageURL.pathExtension)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkflowPackageValidationError.missingPackage(packageURL)
        }

        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw WorkflowPackageValidationError.missingManifest
        }

        let manifest = try JSONDecoder().decode(
            WorkflowPackageManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try validate(manifest, in: packageURL)

        return WorkflowPackageValidationResult(
            packageURL: packageURL,
            manifestURL: manifestURL,
            manifest: manifest
        )
    }

    private static func validate(_ manifest: WorkflowPackageManifest, in packageURL: URL) throws {
        guard manifest.schemaVersion == 1 else {
            throw WorkflowPackageValidationError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowPackageValidationError.emptyWorkflowID
        }
        guard !manifest.runner.entrypoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowPackageValidationError.emptyRunnerEntrypoint
        }
        guard FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent(manifest.runner.entrypoint).path
        ) else {
            throw WorkflowPackageValidationError.missingRunnerEntrypoint(manifest.runner.entrypoint)
        }
        guard !manifest.inputs.isEmpty else {
            throw WorkflowPackageValidationError.missingInputs
        }
        for input in manifest.inputs where input.bundleTypes.isEmpty {
            throw WorkflowPackageValidationError.emptyInputBundleTypes(input.id)
        }
        guard !manifest.outputs.isEmpty else {
            throw WorkflowPackageValidationError.missingOutputs
        }

        if manifest.runtime.kind == .conda,
           let environmentFile = manifest.runtime.environmentFile,
           !FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(environmentFile).path) {
            throw WorkflowPackageValidationError.missingRuntimeFile(environmentFile)
        }

        if manifest.runtime.kind == .docker,
           let image = manifest.runtime.containerImage,
           !isPinnedContainerImage(image) {
            throw WorkflowPackageValidationError.unpinnedContainerImage(image)
        }
    }

    private static func isPinnedContainerImage(_ image: String) -> Bool {
        image.contains("@sha256:") || image.hasPrefix("local:")
    }
}
