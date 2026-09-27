// MissingToolError.swift - One shape for "a required tool is not installed"
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
