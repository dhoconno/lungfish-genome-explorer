// ContainerToolPlugin.swift - Container tool plugin model definition
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ContainerToolPlugin

/// Defines a containerized bioinformatics tool that can be executed via Apple Containerization.
///
/// `ContainerToolPlugin` provides a declarative way to define bioinformatics tools that run
/// inside containers. Each plugin specifies:
/// - The container image to use (e.g., "biocontainers/samtools:1.18")
/// - Available commands and their argument templates
/// - Input/output specifications for file handling
/// - Resource requirements for container allocation
///
/// ## Example
///
/// ```swift
/// let samtools = ContainerToolPlugin(
///     id: "samtools",
///     name: "SAMtools",
///     description: "Tools for manipulating SAM/BAM/CRAM files",
///     imageReference: "biocontainers/samtools:1.18",
///     commands: [
///         "faidx": CommandTemplate(
///             executable: "samtools",
///             arguments: ["faidx", "${INPUT}"],
///             description: "Index a FASTA file"
///         ),
///         "view": CommandTemplate(
///             executable: "samtools",
///             arguments: ["view", "-b", "${INPUT}", "-o", "${OUTPUT}"],
///             description: "Convert SAM to BAM"
///         )
///     ],
///     inputs: [PluginInput(name: "input", type: .file, required: true)],
///     outputs: [PluginOutput(name: "output", type: .file)],
///     resources: ResourceRequirements(cpuCount: 4, memoryGB: 4)
/// )
/// ```
///
/// ## Thread Safety
///
/// `ContainerToolPlugin` is `Sendable` and can be safely passed across actor boundaries.
public struct ContainerToolPlugin: Codable, Sendable, Identifiable, Equatable {
    // MARK: - Properties
    
    /// Unique identifier for this plugin (e.g., "samtools", "bcftools").
    public let id: String
    
    /// Human-readable name for display.
    public let name: String
    
    /// Description of the tool's purpose.
    public let description: String
    
    /// OCI image reference (e.g., "docker.io/condaforge/mambaforge:latest").
    ///
    /// This should be a fully qualified image reference including the registry
    /// and tag. For arm64 support, prefer multi-arch images like mambaforge.
    public let imageReference: String
    
    /// Optional setup commands to run when the container starts.
    ///
    /// These commands are executed before the main tool command and can be used
    /// to install tools dynamically. This is useful when using a base image like
    /// mambaforge where tools need to be installed via conda/mamba.
    ///
    /// Example: `["mamba", "install", "-y", "-c", "bioconda", "samtools=1.18"]`
    public let setupCommands: [[String]]?
    
    /// Available commands and their templates.
    ///
    /// Keys are command names (e.g., "faidx", "view"), values are `CommandTemplate`
    /// instances that define how to construct the command line.
    public let commands: [String: CommandTemplate]
    
    /// Input specifications for the tool.
    public let inputs: [PluginInput]
    
    /// Output specifications for the tool.
    public let outputs: [PluginOutput]
    
    /// Resource requirements for container execution.
    public let resources: ResourceRequirements
    
    /// Category for organizing plugins in the UI.
    public let category: PluginCategory
    
    /// Version of the tool (from the container image).
    public let version: String?
    
    /// URL to the tool's documentation.
    public let documentationURL: URL?
    
    // MARK: - Initialization
    
    /// Creates a new container tool plugin.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - name: Human-readable name
    ///   - description: Tool description
    ///   - imageReference: OCI image reference
    ///   - commands: Available commands
    ///   - inputs: Input specifications
    ///   - outputs: Output specifications
    ///   - resources: Resource requirements
    ///   - category: Plugin category
    ///   - version: Tool version
    ///   - documentationURL: Documentation URL
    ///   - setupCommands: Commands to run before the main command (e.g., to install tools)
    public init(
        id: String,
        name: String,
        description: String,
        imageReference: String,
        commands: [String: CommandTemplate],
        inputs: [PluginInput] = [],
        outputs: [PluginOutput] = [],
        resources: ResourceRequirements = .default,
        category: PluginCategory = .general,
        version: String? = nil,
        documentationURL: URL? = nil,
        setupCommands: [[String]]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageReference = imageReference
        self.commands = commands
        self.inputs = inputs
        self.outputs = outputs
        self.resources = resources
        self.category = category
        self.version = version
        self.documentationURL = documentationURL
        self.setupCommands = setupCommands
    }
}

// MARK: - CommandTemplate

/// Defines a command template for a container tool.
///
/// Command templates use placeholder variables that are substituted at runtime:
/// - `${INPUT}` - Primary input file path
/// - `${OUTPUT}` - Primary output file path
/// - `${INPUT_DIR}` - Input directory path
/// - `${OUTPUT_DIR}` - Output directory path
/// - `${PARAM_name}` - Custom parameter value
///
/// ## Example
///
/// ```swift
/// let faidxCommand = CommandTemplate(
///     executable: "samtools",
///     arguments: ["faidx", "${INPUT}"],
///     description: "Index a FASTA file"
/// )
/// ```
public struct CommandTemplate: Codable, Sendable, Equatable {
    /// The executable name or path inside the container.
    public let executable: String
    
    /// Command arguments with placeholder variables.
    public let arguments: [String]
    
    /// Human-readable description of what this command does.
    public let description: String
    
    /// Working directory inside the container (optional).
    public let workingDirectory: String?
    
    /// Environment variables to set for this command.
    public let environment: [String: String]
    
    /// Whether this command creates output files.
    public let producesOutput: Bool
    
    /// Creates a new command template.
    ///
    /// - Parameters:
    ///   - executable: The executable name
    ///   - arguments: Command arguments with placeholders
    ///   - description: Command description
    ///   - workingDirectory: Working directory (optional)
    ///   - environment: Environment variables
    ///   - producesOutput: Whether output files are created
    public init(
        executable: String,
        arguments: [String],
        description: String = "",
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        producesOutput: Bool = true
    ) {
        self.executable = executable
        self.arguments = arguments
        self.description = description
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.producesOutput = producesOutput
    }
    
    /// Resolves the command template with the given parameters.
    ///
    /// - Parameter parameters: Dictionary of parameter names to values
    /// - Returns: Array of resolved command arguments including the executable
    public func resolve(with parameters: [String: String]) -> [String] {
        var resolved = [executable]
        
        for arg in arguments {
            var resolvedArg = arg
            
            // Replace all placeholders
            for (key, value) in parameters {
                resolvedArg = resolvedArg.replacingOccurrences(
                    of: "${\(key)}",
                    with: value
                )
            }
            
            resolved.append(resolvedArg)
        }
        
        return resolved
    }
}

// MARK: - PluginInput

/// Defines an input specification for a container tool plugin.
public struct PluginInput: Codable, Sendable, Equatable, Identifiable {
    /// Unique name for this input (used in templates as ${INPUT_name}).
    public let name: String
    
    /// Unique identifier (same as name).
    public var id: String { name }
    
    /// The type of input.
    public let type: PluginIOType
    
    /// Whether this input is required.
    public let required: Bool
    
    /// Human-readable description.
    public let description: String
    
    /// Accepted file extensions (for file inputs).
    public let acceptedExtensions: [String]
    
    /// Default value (for optional inputs).
    public let defaultValue: String?
    
    /// Creates a new plugin input specification.
    public init(
        name: String,
        type: PluginIOType,
        required: Bool = true,
        description: String = "",
        acceptedExtensions: [String] = [],
        defaultValue: String? = nil
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.acceptedExtensions = acceptedExtensions
        self.defaultValue = defaultValue
    }
}

// MARK: - PluginOutput

/// Defines an output specification for a container tool plugin.
public struct PluginOutput: Codable, Sendable, Equatable, Identifiable {
    /// Unique name for this output (used in templates as ${OUTPUT_name}).
    public let name: String
    
    /// Unique identifier (same as name).
    public var id: String { name }
    
    /// The type of output.
    public let type: PluginIOType
    
    /// Human-readable description.
    public let description: String
    
    /// File extension for the output (for file outputs).
    public let fileExtension: String?
    
    /// Creates a new plugin output specification.
    public init(
        name: String,
        type: PluginIOType,
        description: String = "",
        fileExtension: String? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.fileExtension = fileExtension
    }
}

// MARK: - PluginIOType

/// Types of input/output for container tool plugins.
public enum PluginIOType: String, Codable, Sendable {
    /// A single file.
    case file
    
    /// A directory.
    case directory
    
    /// A string value.
    case string
    
    /// An integer value.
    case integer
    
    /// A floating-point value.
    case number
    
    /// A boolean flag.
    case boolean
    
    /// Multiple files (glob pattern).
    case fileList
}

// MARK: - ResourceRequirements

/// Resource requirements for container execution.
///
/// Specifies CPU, memory, and other resource limits for running a container.
/// These values are used to configure the container before execution.
public struct ResourceRequirements: Codable, Sendable, Equatable {
    /// Number of CPU cores to allocate.
    public let cpuCount: Int?
    
    /// Memory in gigabytes.
    public let memoryGB: Int?
    
    /// Disk space in gigabytes (for temporary files).
    public let diskGB: Int?
    
    /// Whether GPU access is required.
    public let requiresGPU: Bool
    
    /// Default resource requirements for typical bioinformatics tools.
    public static let `default` = ResourceRequirements(
        cpuCount: nil,  // Use system default
        memoryGB: 4,
        diskGB: nil,
        requiresGPU: false
    )
    
    /// Minimal resources for quick operations.
    public static let minimal = ResourceRequirements(
        cpuCount: 1,
        memoryGB: 1,
        diskGB: nil,
        requiresGPU: false
    )
    
    /// High-performance resources for intensive operations.
    public static let highPerformance = ResourceRequirements(
        cpuCount: nil,  // Use all available
        memoryGB: 16,
        diskGB: 50,
        requiresGPU: false
    )
    
    /// Creates new resource requirements.
    public init(
        cpuCount: Int? = nil,
        memoryGB: Int? = nil,
        diskGB: Int? = nil,
        requiresGPU: Bool = false
    ) {
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.requiresGPU = requiresGPU
    }
}

// MARK: - PluginCategory

/// Categories for organizing container tool plugins.
public enum PluginCategory: String, Codable, Sendable, CaseIterable {
    /// General-purpose tools.
    case general
    
    /// Sequence alignment and mapping tools.
    case alignment
    
    /// Variant calling and analysis tools.
    case variants
    
    /// Sequence assembly tools.
    case assembly
    
    /// File format conversion tools.
    case conversion
    
    /// Indexing and preprocessing tools.
    case indexing
    
    /// Quality control tools.
    case qualityControl
    
    /// Annotation tools.
    case annotation
    
    /// Visualization tools.
    case visualization
    
    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .general: return "General"
        case .alignment: return "Alignment"
        case .variants: return "Variants"
        case .assembly: return "Assembly"
        case .conversion: return "Conversion"
        case .indexing: return "Indexing"
        case .qualityControl: return "Quality Control"
        case .annotation: return "Annotation"
        case .visualization: return "Visualization"
        }
    }
}

// MARK: - PluginExecutionResult

/// Result of executing a container tool plugin command.
public struct PluginExecutionResult: Sendable {
    /// Exit code from the container process.
    public let exitCode: Int32
    
    /// Standard output from the process.
    public let stdout: String
    
    /// Standard error from the process.
    public let stderr: String
    
    /// Paths to output files created by the command.
    public let outputFiles: [URL]
    
    /// Execution duration in seconds.
    public let duration: TimeInterval
    
    /// Whether the execution was successful (exit code 0).
    public var isSuccess: Bool {
        exitCode == 0
    }
    
    /// Creates a new execution result.
    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        outputFiles: [URL] = [],
        duration: TimeInterval = 0
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputFiles = outputFiles
        self.duration = duration
    }
}
