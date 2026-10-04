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
    /// What each of `inputURLs` is, when the sample holds mate pairs and
    /// single reads together (a merge or repair derivative, a file of merged
    /// reads followed by pairs, or a virtual subset of one). `nil` for every
    /// other request. Otherwise it is as long as `inputURLs` and names one R1
    /// file, one R2 file and the single-read files beside them
    /// (``AssemblyReadSetResolution``), so the assembler is handed the pair as
    /// a pair (owner decision 1 of 2026-10-03, docs/contracts/READ-PAIRING.md).
    public let inputRoles: [AssemblyInputRole]?

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
        inputLayout: FASTQInputLayout? = nil,
        inputRoles: [AssemblyInputRole]? = nil
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
        self.inputRoles = inputRoles
    }
}

/// What one file of an assembly request is, when the sample holds mate pairs
/// and single reads together.
public enum AssemblyInputRole: String, Sendable, Codable, Equatable {
    /// The R1 file of the sample's one pair.
    case mateR1 = "mate_r1"
    /// The R2 file of the sample's one pair.
    case mateR2 = "mate_r2"
    /// Overlap-merged reads. SPAdes takes them as `--merged`, MEGAHIT and
    /// SKESA as single reads.
    case merged
    /// Orphans, single-end reads, and reads that may be merged or orphans.
    /// Every assembler takes them as single reads.
    case single
}

/// The files of a request whose sample holds mate pairs and single reads.
public struct AssemblyReadSetFiles: Sendable, Equatable {
    /// One single-read file and whether its reads are overlap-merged.
    public struct SingleReadFile: Sendable, Equatable {
        public let url: URL
        public let isMerged: Bool
    }

    public let forward: URL
    public let reverse: URL
    /// The single-read files in request order.
    public let singleReads: [SingleReadFile]
}

/// How an assembler receives the mates of a run's reads.
public enum AssemblyReadPairing: String, Sendable, Codable, Equatable {
    /// Every record is assembled as an unpaired read.
    case single
    /// Two files bound as R1/R2 (`-1`/`-2`, `--reads r1,r2`).
    case pairedFiles = "paired_files"
    /// One strictly interleaved file (`--12`, `--use_paired_ends`).
    case interleaved
    /// One R1/R2 pair with single-read files beside it (SPAdes `-1 -2
    /// --merged -s`, MEGAHIT `-1 -2 -r`, SKESA `--reads R1,R2 --reads S`).
    case pairedFilesWithSingleReads = "paired_files_with_single_reads"

    /// Whether mates reach the assembler as pairs.
    public var assemblesPairs: Bool { self != .single }

    /// The value shown in the CLI table and the app's operation summary.
    public var displayName: String {
        switch self {
        case .single: return "no"
        case .pairedFiles: return "yes (R1/R2 files)"
        case .interleaved: return "yes (interleaved pairs)"
        case .pairedFilesWithSingleReads: return "yes (R1/R2 files and single reads)"
        }
    }
}

public extension AssemblyRunRequest {
    /// The layout the command builder acts on: the resolved `inputLayout`,
    /// else what the `pairedEnd` flag and file count already say.
    var effectiveInputLayout: FASTQInputLayout {
        if readSetFiles != nil { return .mixedMergedAndPairs }
        if pairedEnd, inputURLs.count == 2 { return .pairedFiles }
        if let inputLayout, inputURLs.count == 1 { return inputLayout }
        return .singleEnd
    }

    /// The R1 file, R2 file and single-read files of a request whose sample
    /// holds pairs and single reads, or `nil` when ``inputRoles`` is absent
    /// or does not name exactly one R1 file and one R2 file among the inputs.
    var readSetFiles: AssemblyReadSetFiles? {
        guard let inputRoles, inputRoles.count == inputURLs.count else { return nil }
        let files = Array(zip(inputURLs, inputRoles))
        let forward = files.filter { $0.1 == .mateR1 }.map(\.0)
        let reverse = files.filter { $0.1 == .mateR2 }.map(\.0)
        guard forward.count == 1, reverse.count == 1 else { return nil }
        let singleReads = files.compactMap { url, role -> AssemblyReadSetFiles.SingleReadFile? in
            switch role {
            case .merged: return .init(url: url, isMerged: true)
            case .single: return .init(url: url, isMerged: false)
            case .mateR1, .mateR2: return nil
            }
        }
        return AssemblyReadSetFiles(forward: forward[0], reverse: reverse[0], singleReads: singleReads)
    }

    /// The handling `tool` declares for ``effectiveInputLayout``
    /// (``FASTQConsumerRegistry``): the short-read assemblers take strictly
    /// interleaved and R1/R2 input as pairs and everything else, including a
    /// mixed file of merged reads and pairs, as single reads; the long-read
    /// assemblers never pair. A sample already split into an R1 file, an R2
    /// file and single-read files (``readSetFiles``) is handed over as pairs.
    var readLayoutHandling: FASTQReadLayoutHandling {
        if readSetFiles != nil { return .asPairs }
        return FASTQConsumerRegistry.declaration(for: "assemble.\(tool.rawValue)")?
            .handling(for: effectiveInputLayout) ?? .asSingle
    }

    /// How the assembler receives mates for this request.
    var readPairing: AssemblyReadPairing {
        if readSetFiles != nil { return .pairedFilesWithSingleReads }
        guard readLayoutHandling == .asPairs else { return .single }
        switch effectiveInputLayout {
        case .pairedFiles: return .pairedFiles
        case .strictlyInterleaved: return .interleaved
        case .singleEnd, .mixedMergedAndPairs: return .single
        }
    }

    /// The layout of a single short-read input once the inputs are resolved,
    /// by the rule `lungfish-cli assemble` applies, or `nil` when there is
    /// nothing to resolve (R1/R2 files, a long-read assembler, several pooled
    /// files). An explicit layout wins, a concatenation of a bundle's files
    /// keeps its `pooled` single-read layout, and otherwise
    /// ``FASTQInputLayoutResolver`` scans the execution file with the
    /// original bundle's metadata as hints, since a materialized scratch
    /// copy carries no sidecar.
    static func resolveInputLayout(
        tool: AssemblyTool,
        readType: AssemblyReadType,
        pairedEnd: Bool,
        explicit: FASTQInputLayout?,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        pooled: FASTQInputLayoutResolution? = nil
    ) -> FASTQInputLayoutResolution? {
        guard [AssemblyTool.spades, .megahit, .skesa].contains(tool),
              readType == .illuminaShortReads,
              !pairedEnd,
              executionInputURLs.count == 1,
              let executionURL = executionInputURLs.first else {
            return nil
        }
        if let explicit {
            return FASTQInputLayoutResolver.resolve(inputURLs: [executionURL], explicit: explicit)
        }
        if let pooled { return pooled }
        let originalURL = originalInputURLs.first?.standardizedFileURL
        let hintURL = originalURL == executionURL.standardizedFileURL ? nil : originalURL
        return FASTQInputLayoutResolver.resolve(fastqURL: executionURL, metadataFrom: hintURL)
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
            inputLayout: inputLayout,
            inputRoles: inputRoles
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
            readType: AssemblyCompatibility.effectiveReadType(tool: tool, readType: readType),
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: effectiveThreadCount(on: host),
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID ?? (tool == .flye
                ? FlyeProfileSelector.profileID(forReadType: AssemblyCompatibility.effectiveReadType(tool: tool, readType: readType))
                : nil),
            extraArguments: extraArguments,
            profileSelectionBasis: profileSelectionBasis,
            inputLayout: inputLayout,
            inputRoles: inputRoles
        )
    }
}
