// MappingCommandBuilder.swift - Tool-specific command construction for read mapping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

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
            // A sample of pairs and single reads maps in several runs. The
            // first run, its pairs, stands for the mapper invocation.
            if let firstRun = try buildBBMapReadSetRuns(for: request, referenceLocator: resolvedReference).first {
                return firstRun.command
            }
            return try buildBBMapCommand(
                for: request,
                rawAlignmentURL: rawAlignmentURL,
                referenceURL: resolvedReference.referenceURL
            )
        }
    }

    /// One BBMap run of a sample that holds pairs and single reads: the
    /// command, the SAM it writes and the reads it maps.
    public struct BBMapReadSetRun: Sendable, Equatable {
        public let command: ManagedMappingCommand
        public let rawAlignmentURL: URL
        public let inputURLs: [URL]
    }

    /// BBMap takes one kind of read per run, so a sample of pairs and single
    /// reads maps in one run per set of pairs and one per single-read file.
    /// Every run carries the request's read group, so `samtools merge -c -p`
    /// joins them into one BAM. Empty unless the request carries a
    /// ``MappingReadSetLayout``.
    public static func buildBBMapReadSetRuns(
        for request: MappingRunRequest,
        referenceLocator: ReferenceLocator? = nil
    ) throws -> [BBMapReadSetRun] {
        guard request.tool == .bbmap, let readSet = request.readSetLayout else { return [] }
        let referenceURL = (referenceLocator ?? .live(for: request)).referenceURL
        let pairRuns = zip(readSet.r1Files, readSet.r2Files).map { [$0.0, $0.1] }
        let singleRuns = readSet.singleReadFiles.map { [$0] }
        return try (pairRuns + singleRuns).enumerated().map { index, inputURLs in
            let rawAlignmentURL = request.outputDirectory
                .appendingPathComponent("\(request.sampleName).run\(index + 1).raw.sam")
            let inputArguments = inputURLs.count == 2
                ? ["in=\(inputURLs[0].path)", "in2=\(inputURLs[1].path)"]
                : ["in=\(inputURLs[0].path)", "interleaved=f"]
            let command = try buildBBMapCommand(
                for: request,
                rawAlignmentURL: rawAlignmentURL,
                referenceURL: referenceURL,
                inputArguments: inputArguments
            )
            return BBMapReadSetRun(command: command, rawAlignmentURL: rawAlignmentURL, inputURLs: inputURLs)
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
        let readGroup = request.resolvedReadGroup(defaultPlatform: platformName(for: mode))
        var arguments = [
            "-a",
            "-x", mode.commandPresetValue ?? "sr",
            "-t", String(request.threads),
            "-R", readGroupHeader(readGroup),
        ]
        if !request.includeSecondary {
            arguments.append("--secondary=no")
        }
        arguments += request.advancedArguments
        arguments += ["-o", rawAlignmentURL.path]
        arguments.append(referenceURL.path)
        arguments.append(contentsOf: request.inputFASTQURLs.map(\.path))

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
        let readGroup = request.resolvedReadGroup(defaultPlatform: "ILLUMINA")
        var arguments = [
            "mem",
            "-t", String(request.threads),
            "-R", readGroupHeader(readGroup),
        ]
        // Smart pairing: bwa-mem2 pairs adjacent same-name records and maps
        // the rest single, so one interleaved or mixed file gets `-p`
        // (MappingTool+ReadLayout). Two R1/R2 files pair on their own.
        if request.inputFASTQURLs.count == 1, request.readLayoutPlan.handling == .asPairs {
            arguments.append("-p")
        }
        arguments += request.advancedArguments
        arguments.append(indexPrefixURL.path)
        arguments.append(contentsOf: request.inputFASTQURLs.map(\.path))

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
        let readGroup = request.resolvedReadGroup(defaultPlatform: "ILLUMINA")
        var arguments = [
            "-x", indexPrefixURL.path,
            "-p", String(request.threads),
            "--rg-id", readGroup.id,
            "--rg", "SM:\(readGroup.sampleName)",
            "--rg", "LB:\(readGroup.library)",
            "--rg", "PL:\(readGroup.platform)",
            "--rg", "PU:\(readGroup.platformUnit)",
        ]
        if request.includeSecondary {
            arguments += ["-k", "10"]
        }
        arguments += request.advancedArguments
        arguments += ["-S", rawAlignmentURL.path]
        if let readSet = request.readSetLayout {
            // Pairs and single reads of one sample in one run (READ-PAIRING.md).
            if !readSet.r1Files.isEmpty {
                arguments += [
                    "-1", readSet.r1Files.map(\.path).joined(separator: ","),
                    "-2", readSet.r2Files.map(\.path).joined(separator: ","),
                ]
            }
            if !readSet.singleReadFiles.isEmpty {
                arguments += ["-U", readSet.singleReadFiles.map(\.path).joined(separator: ",")]
            }
        } else if request.pairedEnd && request.inputFASTQURLs.count == 2 {
            arguments += ["-1", request.inputFASTQURLs[0].path, "-2", request.inputFASTQURLs[1].path]
        } else if request.inputFASTQURLs.count == 1, request.readLayoutPlan.handling == .asPairs {
            // `--interleaved` pairs records by position, so only a strictly
            // interleaved file gets it; a mixed file runs as single reads
            // through `-U` (MappingTool+ReadLayout).
            arguments += ["--interleaved", request.inputFASTQURLs[0].path]
        } else {
            arguments += ["-U", request.inputFASTQURLs.map(\.path).joined(separator: ",")]
        }

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
        referenceURL: URL,
        inputArguments: [String]? = nil
    ) throws -> ManagedMappingCommand {
        let mode = try mode(for: request)
        let nativeTool: NativeTool = mode == .bbmapPacBio ? .mapPacBio : .bbmap
        let executable = nativeTool.executableName
        let readGroup = request.resolvedReadGroup(defaultPlatform: platformName(for: mode))

        var arguments = request.advancedArguments + [
            "ref=\(referenceURL.path)",
            "out=\(rawAlignmentURL.path)",
            "threads=\(request.threads)",
            "nodisk=t",
            "overwrite=t",
            "secondary=\(request.includeSecondary ? "t" : "f")",
            "rgid=\(readGroup.id)",
            "rgsm=\(readGroup.sampleName)",
            "rglb=\(readGroup.library)",
            "rgpl=\(readGroup.platform)",
            "rgpu=\(readGroup.platformUnit)",
        ]
        if let inputArguments {
            arguments += inputArguments
        } else if request.pairedEnd && request.inputFASTQURLs.count == 2 {
            arguments += [
                "in=\(request.inputFASTQURLs[0].path)",
                "in2=\(request.inputFASTQURLs[1].path)",
            ]
        } else if let inputURL = request.inputFASTQURLs.first {
            arguments.append("in=\(inputURL.path)")
            // `interleaved=auto` never pairs identically named mates, and
            // `interleaved=t` pairs a mixed file blindly by position, so the
            // flag states the resolved layout (MappingTool+ReadLayout).
            let interleaved = request.inputFASTQURLs.count == 1
                && request.readLayoutPlan.handling == .asPairs
            arguments.append("interleaved=\(interleaved ? "t" : "f")")
        }

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
        case .minimap2Asm5:
            return "ASSEMBLY"
        case .minimap2Splice:
            return "CDNA"
        case .minimap2MapONT:
            return "ONT"
        case .minimap2MapHiFi, .minimap2MapPB, .bbmapPacBio:
            return "PACBIO"
        case .bbmapStandard:
            return "ILLUMINA"
        }
    }

    private static func readGroupHeader(_ readGroup: MappingReadGroup) -> String {
        "@RG\\tID:\(readGroup.id)\\tSM:\(readGroup.sampleName)\\tLB:\(readGroup.library)\\tPL:\(readGroup.platform)\\tPU:\(readGroup.platformUnit)"
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
