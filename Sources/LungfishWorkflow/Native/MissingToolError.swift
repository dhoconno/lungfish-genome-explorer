// MissingToolError.swift - One shape for "a required tool is not installed"
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The one wording for "this tool is missing" messages that several
/// pipelines share, so the GUI and `lungfish-cli` never print two different
/// hints for the same missing tool.
public enum MissingToolMessage {
    /// A mapper (minimap2, bwa-mem2, bowtie2) that the Read Mapping plugin
    /// pack installs. `ManagedMappingPipeline` and `Minimap2Pipeline` both
    /// use it, so a missing minimap2 reads the same from `lungfish-cli map`,
    /// the genotyping pipelines and the Import Center, and the CLI maps it to
    /// the documented exit status 126 through ``MissingToolError``.
    public static func readMappingTool(_ tool: String) -> String {
        "\(tool) is not installed. Install the Read Mapping plugin pack from the Plugin Manager, "
            + "or run `\(CLICommandIdentity.executableName) conda install --pack read-mapping`."
    }
}

/// An error whose cause is a required external tool that is not installed
/// or cannot be found.
///
/// The pipelines each have their own error enum with a "not installed"
/// case. Conforming those enums here lets a front end recognise the
/// condition without matching every enum: `lungfish-cli` maps any
/// ``MissingToolError`` with a non-nil ``missingToolName`` to its
/// documented exit status 126 ("a required tool is missing") and prints the
/// error's own message, instead of the generic workflow failure status 64.
public protocol MissingToolError: Error {
    /// The tool that is missing, or `nil` when this particular value of the
    /// conforming type is some other failure.
    var missingToolName: String? { get }
}

extension ManagedMappingPipelineError: MissingToolError {
    public var missingToolName: String? {
        if case .mapperNotInstalled(let tool) = self { return tool }
        return nil
    }
}

extension Minimap2PipelineError: MissingToolError {
    public var missingToolName: String? {
        if case .minimap2NotInstalled = self { return "minimap2" }
        return nil
    }
}

extension ClassificationPipelineError: MissingToolError {
    public var missingToolName: String? {
        switch self {
        case .kraken2NotInstalled: return "kraken2"
        case .brackenNotInstalled: return "bracken"
        default: return nil
        }
    }
}

extension EsVirituPipelineError: MissingToolError {
    public var missingToolName: String? {
        if case .esVirituNotInstalled = self { return "EsViritu" }
        return nil
    }
}

extension TaxTriagePipelineError: MissingToolError {
    public var missingToolName: String? {
        if case .nextflowNotInstalled = self { return "nextflow" }
        return nil
    }
}

extension FASTQIngestionError: MissingToolError {
    public var missingToolName: String? {
        if case .toolNotFound(let tool) = self { return tool }
        return nil
    }
}

extension NativeToolError: MissingToolError {
    public var missingToolName: String? {
        if case .toolNotFound(let tool) = self { return tool }
        return nil
    }
}

extension CondaError: MissingToolError {
    public var missingToolName: String? {
        if case .toolNotFound(let tool, _) = self { return tool }
        return nil
    }
}
