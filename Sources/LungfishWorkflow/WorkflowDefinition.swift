// WorkflowDefinition.swift - Workflow definition model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation

// MARK: - WorkflowEngineType

/// Supported workflow engine types.
///
/// Lungfish supports multiple workflow engines, each with their own
/// syntax and capabilities. The engine type determines how workflows
/// are executed and monitored.
public enum WorkflowEngineType: String, Sendable, Codable, CaseIterable {
    /// Nextflow workflow engine (https://nextflow.io)
    case nextflow

    /// Snakemake workflow engine (https://snakemake.github.io)
    case snakemake

    /// Common Workflow Language (CWL)
    case cwl

    /// Workflow Description Language (WDL)
    case wdl

    /// Shell script (bash/sh)
    case shell

    /// Custom/unknown engine
    case custom

    /// The executable name for this engine.
    public var executableName: String {
        switch self {
        case .nextflow: return "nextflow"
        case .snakemake: return "snakemake"
        case .cwl: return "cwltool"
        case .wdl: return "cromwell"
        case .shell: return "bash"
        case .custom: return ""
        }
    }

    /// File extensions associated with this engine type.
    public var fileExtensions: Set<String> {
        switch self {
        case .nextflow: return ["nf"]
        case .snakemake: return ["smk", "snakefile"]
        case .cwl: return ["cwl"]
        case .wdl: return ["wdl"]
        case .shell: return ["sh", "bash"]
        case .custom: return []
        }
    }

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .nextflow: return "Nextflow"
        case .snakemake: return "Snakemake"
        case .cwl: return "Common Workflow Language"
        case .wdl: return "Workflow Description Language"
        case .shell: return "Shell Script"
        case .custom: return "Custom"
        }
    }

    /// SF Symbol icon name for this engine.
    public var iconName: String {
        switch self {
        case .nextflow: return "arrow.triangle.branch"
        case .snakemake: return "arrow.triangle.swap"
        case .cwl: return "doc.text"
        case .wdl: return "doc.text"
        case .shell: return "terminal"
        case .custom: return "gearshape"
        }
    }
}

// MARK: - WorkflowDefinition

/// A workflow definition describing a pipeline to execute.
///
/// WorkflowDefinition contains all metadata about a workflow including
/// its location, type, parameters, and execution requirements.
///
/// ## Engine Detection
///
/// The engine type can be automatically detected from the workflow file:
///
/// ```swift
/// let definition = WorkflowDefinition(path: workflowURL)
/// print(definition.engineType) // .nextflow, .snakemake, etc.
/// ```
///
/// ## Example
///
/// ```swift
/// let workflow = WorkflowDefinition(
///     path: URL(fileURLWithPath: "/pipelines/rnaseq/main.nf"),
///     name: "RNA-seq Analysis",
///     description: "Process RNA-seq data with DESeq2"
/// )
/// ```
public struct WorkflowDefinition: Sendable, Codable, Identifiable, Hashable {

    // MARK: - Properties

    /// Unique identifier for this workflow definition.
    public let id: UUID

    /// Path to the workflow definition file.
    public let path: URL

    /// Human-readable name for the workflow.
    public var name: String

    /// Description of what the workflow does.
    public var description: String

    /// The workflow engine type.
    public var engineType: WorkflowEngineType

    /// Working directory for workflow execution.
    ///
    /// If nil, uses the workflow's parent directory.
    public var workDirectory: URL?

    /// Path to the workflow schema file (e.g., nextflow_schema.json).
    public var schemaPath: URL?

    /// Path to the default configuration file.
    public var configPath: URL?

    /// Version of the workflow (if available).
    public var version: String?

    /// Author or maintainer of the workflow.
    public var author: String?

    /// Repository URL for the workflow.
    public var repositoryURL: URL?

    /// Whether this is an nf-core pipeline.
    public var isNfCore: Bool

    /// Minimum engine version required.
    public var minimumEngineVersion: String?

    /// Container profile to use by default.
    public var defaultProfile: ExecutionProfile?

    /// Additional workflow metadata.
    public var metadata: [String: String]

    /// Date this definition was created/imported.
    public let createdAt: Date

    /// Date this definition was last modified.
    public var modifiedAt: Date

    // MARK: - Initialization

    /// Creates a new workflow definition.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - path: Path to the workflow definition file
    ///   - name: Human-readable name (defaults to filename)
    ///   - description: Description of the workflow
    ///   - engineType: Engine type (auto-detected if nil)
    ///   - workDirectory: Working directory for execution
    public init(
        id: UUID = UUID(),
        path: URL,
        name: String? = nil,
        description: String = "",
        engineType: WorkflowEngineType? = nil,
        workDirectory: URL? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name ?? path.deletingPathExtension().lastPathComponent
        self.description = description
        self.engineType = engineType ?? Self.detectEngineType(from: path)
        self.workDirectory = workDirectory
        self.schemaPath = nil
        self.configPath = nil
        self.version = nil
        self.author = nil
        self.repositoryURL = nil
        self.isNfCore = false
        self.minimumEngineVersion = nil
        self.defaultProfile = nil
        self.metadata = [:]
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    // MARK: - Engine Detection

    /// Detects the workflow engine type from a file path.
    ///
    /// - Parameter path: Path to the workflow file
    /// - Returns: The detected engine type, or `.custom` if unknown
    public static func detectEngineType(from path: URL) -> WorkflowEngineType {
        let filename = path.lastPathComponent.lowercased()
        let ext = path.pathExtension.lowercased()

        // Check file extension first
        for engine in WorkflowEngineType.allCases {
            if engine.fileExtensions.contains(ext) {
                return engine
            }
        }

        // Check filename patterns
        if filename == "snakefile" || filename.hasPrefix("snakefile") {
            return .snakemake
        }

        if filename == "main.nf" || filename.hasSuffix(".nf") {
            return .nextflow
        }

        return .custom
    }

    /// Attempts to detect additional workflow metadata.
    ///
    /// This method scans the workflow directory for schema files,
    /// configuration files, and nf-core markers.
    ///
    /// - Returns: Updated workflow definition with detected metadata
    public func detectMetadata() -> WorkflowDefinition {
        var updated = self
        let directory = path.deletingLastPathComponent()
        let fileManager = FileManager.default

        // Look for nextflow_schema.json
        let schemaURL = directory.appendingPathComponent("nextflow_schema.json")
        if fileManager.fileExists(atPath: schemaURL.path) {
            updated.schemaPath = schemaURL
        }

        // Look for nextflow.config
        let configURL = directory.appendingPathComponent("nextflow.config")
        if fileManager.fileExists(atPath: configURL.path) {
            updated.configPath = configURL
        }

        // Check for nf-core markers
        let nfCoreYAML = directory.appendingPathComponent(".nf-core.yml")
        if fileManager.fileExists(atPath: nfCoreYAML.path) {
            updated.isNfCore = true
        }

        updated.modifiedAt = Date()
        return updated
    }

    // MARK: - Computed Properties

    /// The effective working directory for this workflow.
    ///
    /// Returns `workDirectory` if set, otherwise the workflow's parent directory.
    public var effectiveWorkDirectory: URL {
        workDirectory ?? path.deletingLastPathComponent()
    }

    /// Whether the workflow file exists.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// Whether this workflow has a schema file for parameter UI.
    public var hasSchema: Bool {
        if let schema = schemaPath {
            return FileManager.default.fileExists(atPath: schema.path)
        }
        return false
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: WorkflowDefinition, rhs: WorkflowDefinition) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ExecutionProfile

/// Execution profile for workflow runs.
///
/// Profiles determine how processes are executed, including
/// container usage and resource allocation.
public enum ExecutionProfile: String, Sendable, Codable, CaseIterable {
    /// Run processes locally without containers
    case local

    /// Use Docker containers
    case docker

    /// Use Apptainer (Singularity) containers
    case apptainer

    /// Use Podman containers
    case podman

    /// Use Conda environments
    case conda

    /// Use Mamba environments
    case mamba

    /// Submit to SLURM cluster
    case slurm

    /// Submit to PBS/Torque cluster
    case pbs

    /// Submit to SGE cluster
    case sge

    /// Submit to LSF cluster
    case lsf

    /// Run in test mode with minimal resources
    case test

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .local: return "Local"
        case .docker: return "Docker"
        case .apptainer: return "Apptainer"
        case .podman: return "Podman"
        case .conda: return "Conda"
        case .mamba: return "Mamba"
        case .slurm: return "SLURM"
        case .pbs: return "PBS"
        case .sge: return "SGE"
        case .lsf: return "LSF"
        case .test: return "Test"
        }
    }

    /// Whether this profile requires a container runtime
    public var requiresContainer: Bool {
        switch self {
        case .docker, .apptainer, .podman:
            return true
        default:
            return false
        }
    }
}

// MARK: - WorkflowSource

/// Source location for a workflow.
///
/// Workflows can come from local files, remote URLs, or
/// workflow registries like nf-core.
public enum WorkflowSource: Sendable, Codable, Hashable {
    /// Local file path
    case local(URL)

    /// Remote Git repository
    case git(url: URL, revision: String?)

    /// nf-core pipeline
    case nfCore(name: String, revision: String?)

    /// Generic URL
    case url(URL)

    /// Human-readable description of the source
    public var displayDescription: String {
        switch self {
        case .local(let url):
            return url.lastPathComponent
        case .git(let url, let revision):
            if let rev = revision {
                return "\(url.lastPathComponent)@\(rev)"
            }
            return url.lastPathComponent
        case .nfCore(let name, let revision):
            if let rev = revision {
                return "nf-core/\(name)@\(rev)"
            }
            return "nf-core/\(name)"
        case .url(let url):
            return url.absoluteString
        }
    }
}
