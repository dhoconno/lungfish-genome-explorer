// AssemblyRunRequest.swift - Shared assembly run request for app and CLI entry points
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct AssemblyExecutionHost: Sendable, Equatable {
    public enum OperatingSystem: Sendable, Equatable {
        case macOS
        case other
    }

    public let operatingSystem: OperatingSystem
    public let architecture: String

    public init(operatingSystem: OperatingSystem, architecture: String) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static let current = AssemblyExecutionHost(
        operatingSystem: {
            #if os(macOS)
            .macOS
            #else
            .other
            #endif
        }(),
        architecture: {
            #if arch(arm64)
            "arm64"
            #elseif arch(x86_64)
            "x86_64"
            #else
            "unknown"
            #endif
        }()
    )

    public var capsMegahitThreads: Bool {
        operatingSystem == .macOS && architecture == "arm64"
    }
}

/// Assembler-neutral request passed into the managed assembly pipeline.
public struct AssemblyRunRequest: Sendable, Codable, Equatable {
    public let tool: AssemblyTool
    public let readType: AssemblyReadType
    public let inputURLs: [URL]
    public let projectName: String
    public let outputDirectory: URL
    public let pairedEnd: Bool
    public let threads: Int
    public let memoryGB: Int?
    public let minContigLength: Int?
    public let selectedProfileID: String?
    public let extraArguments: [String]
    /// Why `selectedProfileID` holds what it holds when the app or CLI chose
    /// it from the reads (Flye's Nano Raw / Nano HQ), recorded in provenance.
    public let profileSelectionBasis: String?
    /// The resolved layout of a SINGLE input file (``FASTQInputLayoutResolver``),
    /// or `nil` until the CLI resolves it after input materialization.
    ///
    /// `pairedEnd` only ever describes two R1/R2 files. A paired import is
    /// stored as ONE interleaved FASTQ inside its bundle, so without this
    /// field every such bundle assembled as single reads (SPAdes `-s`,
    /// MEGAHIT `-r`, SKESA `--reads` without `--use_paired_ends`).
    public let inputLayout: FASTQInputLayout?

    public init(
        tool: AssemblyTool,
        readType: AssemblyReadType,
        inputURLs: [URL],
        projectName: String,
        outputDirectory: URL,
        pairedEnd: Bool = false,
        threads: Int,
        memoryGB: Int? = nil,
        minContigLength: Int? = nil,
        selectedProfileID: String? = nil,
        extraArguments: [String] = [],
        profileSelectionBasis: String? = nil,
        inputLayout: FASTQInputLayout? = nil
    ) {
        self.tool = tool
        self.readType = readType
        self.inputURLs = inputURLs
        self.projectName = projectName
        self.outputDirectory = outputDirectory
        self.pairedEnd = pairedEnd
        self.threads = threads
        self.memoryGB = memoryGB
        self.minContigLength = minContigLength
        self.selectedProfileID = selectedProfileID
        self.extraArguments = extraArguments
        self.profileSelectionBasis = profileSelectionBasis
        self.inputLayout = inputLayout
    }
}

/// How an assembler receives the mates of a run's reads.
public enum AssemblyReadPairing: String, Sendable, Codable, Equatable {
    /// Every record is assembled as an unpaired read.
    case single
    /// Two files bound as R1/R2 (`-1`/`-2`, `--reads r1,r2`).
    case pairedFiles = "paired_files"
    /// One strictly interleaved file (`--12`, `--use_paired_ends`).
    case interleaved

    /// Whether mates reach the assembler as pairs.
    public var assemblesPairs: Bool { self != .single }

    /// The value shown in the CLI table and the app's operation summary.
    public var displayName: String {
        switch self {
        case .single: return "no"
        case .pairedFiles: return "yes (R1/R2 files)"
        case .interleaved: return "yes (interleaved pairs)"
        }
    }
}

public extension AssemblyRunRequest {
    /// The layout the command builder acts on: the resolved `inputLayout`,
    /// else what the `pairedEnd` flag and file count already say.
    var effectiveInputLayout: FASTQInputLayout {
        if pairedEnd, inputURLs.count == 2 { return .pairedFiles }
        if let inputLayout, inputURLs.count == 1 { return inputLayout }
        return .singleEnd
    }

    /// The handling `tool` declares for ``effectiveInputLayout``
    /// (``FASTQConsumerRegistry``): the short-read assemblers take strictly
    /// interleaved and R1/R2 input as pairs and everything else, including a
    /// mixed file of merged reads and pairs, as single reads; the long-read
    /// assemblers never pair.
    var readLayoutHandling: FASTQReadLayoutHandling {
        FASTQConsumerRegistry.declaration(for: "assemble.\(tool.rawValue)")?
            .handling(for: effectiveInputLayout) ?? .asSingle
    }

    /// How the assembler receives mates for this request.
    var readPairing: AssemblyReadPairing {
        guard readLayoutHandling == .asPairs else { return .single }
        switch effectiveInputLayout {
        case .pairedFiles: return .pairedFiles
        case .strictlyInterleaved: return .interleaved
        case .singleEnd, .mixedMergedAndPairs: return .single
        }
    }

    /// Returns a copy with `inputLayout` set explicitly.
    func withInputLayout(_ inputLayout: FASTQInputLayout?) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: threads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments,
            profileSelectionBasis: profileSelectionBasis,
            inputLayout: inputLayout
        )
    }

    /// Assemblers that expose a minimum-contig flag require a positive value.
    /// Treat zero-or-negative requests as the smallest usable threshold.
    var effectiveMinContigLength: Int? {
        guard let minContigLength else { return nil }
        return max(minContigLength, 1)
    }

    var effectiveMegahitMemoryBytes: Int64? {
        guard tool == .megahit, let memoryGB else { return nil }
        return Int64(max(memoryGB, 1)) * 1024 * 1024 * 1024
    }

    func effectiveThreadCount(on host: AssemblyExecutionHost = .current) -> Int {
        let requestedThreads = max(threads, 1)
        if tool == .megahit && host.capsMegahitThreads {
            // MEGAHIT 1.2.9 arm64 crashes reliably above two threads on Apple Silicon.
            return min(requestedThreads, 2)
        }
        return requestedThreads
    }

    func normalizedForExecution(on host: AssemblyExecutionHost = .current) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: effectiveThreadCount(on: host),
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments,
            profileSelectionBasis: profileSelectionBasis,
            inputLayout: inputLayout
        )
    }
}
