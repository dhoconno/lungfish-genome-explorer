// MappingCommandBuilder.swift - Tool-specific command construction for read mapping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct ManagedMappingCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: String?
    public let nativeTool: NativeTool?
    public let workingDirectory: URL

    public init(
        executable: String,
        arguments: [String],
        environment: String?,
        nativeTool: NativeTool? = nil,
        workingDirectory: URL
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.nativeTool = nativeTool
        self.workingDirectory = workingDirectory
    }

    public var shellCommand: String {
        ([executable] + arguments).map(shellEscape).joined(separator: " ")
    }
}

public enum MappingCommandBuilder {
    public static func buildCommand(
        for request: MappingRunRequest,
        referenceLocator: ReferenceLocator? = nil
    ) throws -> ManagedMappingCommand {
        let resolvedReference = referenceLocator ?? .live(for: request)
        let rawAlignmentURL = rawAlignmentURL(for: request)

        switch request.tool {
        case .minimap2:
            return try buildMinimap2Command(
                for: request,
                rawAlignmentURL: rawAlignmentURL,
                referenceURL: resolvedReference.referenceURL
            )
        case .bwaMem2:
            return try buildBwaMem2Command(
                for: request,
                indexPrefixURL: resolvedReference.indexPrefixURL
            )
        case .bowtie2:
            return buildBowtie2Command(
                for: request,
                rawAlignmentURL: rawAlignmentURL,
                indexPrefixURL: resolvedReference.indexPrefixURL
            )
        case .bbmap:
            return try buildBBMapCommand(
                for: request,
                rawAlignmentURL: rawAlignmentURL,
                referenceURL: resolvedReference.referenceURL
            )
        }
    }

    public static func rawAlignmentURL(for request: MappingRunRequest) -> URL {
        request.outputDirectory.appendingPathComponent("\(request.sampleName).raw.sam")
    }

    public static func liveReferenceLocator(for request: MappingRunRequest) -> ReferenceLocator {
        .live(for: request)
    }

    private static func buildMinimap2Command(
        for request: MappingRunRequest,
        rawAlignmentURL: URL,
        referenceURL: URL
    ) throws -> ManagedMappingCommand {
        let mode = try mode(for: request)
        var arguments = [
            "-a",
            "-x", mode.commandPresetValue ?? "sr",
            "-t", String(request.threads),
            "-R", readGroupHeader(sampleName: request.sampleName, platform: platformName(for: mode)),
        ]
        if !request.includeSecondary {
            arguments.append("--secondary=no")
        }
        arguments.append(referenceURL.path)
        arguments.append(contentsOf: request.inputFASTQURLs.map(\.path))
        arguments += ["-o", rawAlignmentURL.path]
        arguments += request.advancedArguments

        return ManagedMappingCommand(
            executable: "minimap2",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory
        )
    }

    private static func buildBwaMem2Command(
        for request: MappingRunRequest,
        indexPrefixURL: URL
    ) throws -> ManagedMappingCommand {
        var arguments = [
            "mem",
            "-t", String(request.threads),
            "-R", readGroupHeader(sampleName: request.sampleName, platform: "ILLUMINA"),
            indexPrefixURL.path,
        ]
        arguments.append(contentsOf: request.inputFASTQURLs.map(\.path))
        arguments += request.advancedArguments

        return ManagedMappingCommand(
            executable: "bwa-mem2",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory
        )
    }

    private static func buildBowtie2Command(
        for request: MappingRunRequest,
        rawAlignmentURL: URL,
        indexPrefixURL: URL
    ) -> ManagedMappingCommand {
        var arguments = [
            "-x", indexPrefixURL.path,
            "-p", String(request.threads),
            "--rg-id", request.sampleName,
            "--rg", "SM:\(request.sampleName)",
            "--rg", "PL:ILLUMINA",
            "-S", rawAlignmentURL.path,
        ]
        if request.includeSecondary {
            arguments += ["-k", "10"]
        }
        if request.pairedEnd && request.inputFASTQURLs.count == 2 {
            arguments += ["-1", request.inputFASTQURLs[0].path, "-2", request.inputFASTQURLs[1].path]
        } else {
            arguments += ["-U", request.inputFASTQURLs.map(\.path).joined(separator: ",")]
        }
        arguments += request.advancedArguments

        return ManagedMappingCommand(
            executable: "bowtie2",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory
        )
    }

    private static func buildBBMapCommand(
        for request: MappingRunRequest,
        rawAlignmentURL: URL,
        referenceURL: URL
    ) throws -> ManagedMappingCommand {
        let mode = try mode(for: request)
        let nativeTool: NativeTool = mode == .bbmapPacBio ? .mapPacBio : .bbmap
        let executable = nativeTool.executableName

        var arguments = [
            "ref=\(referenceURL.path)",
            "out=\(rawAlignmentURL.path)",
            "threads=\(request.threads)",
            "nodisk=t",
            "overwrite=t",
            "secondary=\(request.includeSecondary ? "t" : "f")",
        ]
        if request.pairedEnd && request.inputFASTQURLs.count == 2 {
            arguments += [
                "in=\(request.inputFASTQURLs[0].path)",
                "in2=\(request.inputFASTQURLs[1].path)",
            ]
        } else if let inputURL = request.inputFASTQURLs.first {
            arguments.append("in=\(inputURL.path)")
        }
        arguments += request.advancedArguments

        return ManagedMappingCommand(
            executable: executable,
            arguments: arguments,
            environment: nil,
            nativeTool: nativeTool,
            workingDirectory: request.outputDirectory
        )
    }

    private static func mode(for request: MappingRunRequest) throws -> MappingMode {
        guard let mode = MappingMode(rawValue: request.modeID), mode.isValid(for: request.tool) else {
            throw ManagedMappingPipelineError.incompatibleSelection(
                "Invalid mode '\(request.modeID)' for \(request.tool.displayName)."
            )
        }
        return mode
    }

    private static func platformName(for mode: MappingMode) -> String {
        switch mode {
        case .defaultShortRead:
            return "ILLUMINA"
        case .minimap2MapONT:
            return "ONT"
        case .minimap2MapHiFi, .minimap2MapPB, .bbmapPacBio:
            return "PACBIO"
        case .bbmapStandard:
            return "ILLUMINA"
        }
    }

    private static func readGroupHeader(sampleName: String, platform: String) -> String {
        "@RG\\tID:\(sampleName)\\tSM:\(sampleName)\\tPL:\(platform)"
    }
}

public struct ReferenceLocator: Sendable, Equatable {
    public let referenceURL: URL
    public let indexPrefixURL: URL

    public init(referenceURL: URL, indexPrefixURL: URL) {
        self.referenceURL = referenceURL
        self.indexPrefixURL = indexPrefixURL
    }

    public static func live(for request: MappingRunRequest) -> ReferenceLocator {
        let indexWorkspace = request.outputDirectory.appendingPathComponent(".mapping-index", isDirectory: true)
        let indexPrefix = indexWorkspace.appendingPathComponent("reference-index")
        return ReferenceLocator(
            referenceURL: request.referenceFASTAURL,
            indexPrefixURL: indexPrefix
        )
    }
}
