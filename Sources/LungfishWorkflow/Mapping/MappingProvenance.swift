// MappingProvenance.swift - Rich optional provenance for managed mapping analyses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct MappingCommandInvocation: Sendable, Codable, Equatable {
    public let label: String
    public let argv: [String]

    public init(label: String, argv: [String]) {
        self.label = label
        self.argv = argv
    }

    public var commandLine: String {
        argv.map(shellEscape).joined(separator: " ")
    }
}

public struct MappingProvenance: Sendable, Codable, Equatable {
    public static let filename = "mapping-provenance.json"

    public let schemaVersion: Int
    public let workflowName: String
    public let mapper: MappingTool
    public let mapperDisplayName: String
    public let modeID: String
    public let modeDisplayName: String
    public let sampleName: String
    public let pairedEnd: Bool
    public let threads: Int
    public let minimumMappingQuality: Int
    public let includeSecondary: Bool
    public let includeSupplementary: Bool
    public let advancedArguments: [String]
    public let readClassHints: [String]
    public let inputFASTQPaths: [String]
    public let referenceFASTAPath: String
    public let sourceReferenceBundlePath: String?
    public let viewerBundlePath: String?
    public let mapperVersion: String
    public let samtoolsVersion: String
    public let wallClockSeconds: Double
    public let recordedAt: Date
    public let mapperInvocation: MappingCommandInvocation
    public let normalizationInvocations: [MappingCommandInvocation]
    public let inputFiles: [FileRecord]
    public let outputFiles: [FileRecord]
    public let runtimeIdentity: [String: String]
    public let steps: [StepExecution]
    public let exitStatus: Int32?
    public let stderr: String?

    public init(
        schemaVersion: Int = 2,
        workflowName: String = "lungfish map",
        mapper: MappingTool,
        modeID: String,
        sampleName: String,
        pairedEnd: Bool,
        threads: Int,
        minimumMappingQuality: Int,
        includeSecondary: Bool,
        includeSupplementary: Bool,
        advancedArguments: [String],
        inputFASTQURLs: [URL],
        referenceFASTAURL: URL,
        sourceReferenceBundleURL: URL? = nil,
        viewerBundleURL: URL? = nil,
        mapperInvocation: MappingCommandInvocation,
        normalizationInvocations: [MappingCommandInvocation],
        mapperVersion: String,
        samtoolsVersion: String,
        wallClockSeconds: Double,
        recordedAt: Date = Date(),
        readClassHints: [String] = [],
        inputFiles: [FileRecord] = [],
        outputFiles: [FileRecord] = [],
        runtimeIdentity: [String: String] = [:],
        steps: [StepExecution] = [],
        exitStatus: Int32? = nil,
        stderr: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.workflowName = workflowName
        self.mapper = mapper
        self.mapperDisplayName = mapper.displayName
        self.modeID = modeID
        self.modeDisplayName = MappingMode(rawValue: modeID)?.displayName ?? modeID
        self.sampleName = sampleName
        self.pairedEnd = pairedEnd
        self.threads = threads
        self.minimumMappingQuality = minimumMappingQuality
        self.includeSecondary = includeSecondary
        self.includeSupplementary = includeSupplementary
        self.advancedArguments = advancedArguments
        self.readClassHints = readClassHints.isEmpty
            ? Self.readClassHints(from: inputFASTQURLs)
            : readClassHints
        self.inputFASTQPaths = inputFASTQURLs.map { $0.standardizedFileURL.path }
        self.referenceFASTAPath = referenceFASTAURL.standardizedFileURL.path
        self.sourceReferenceBundlePath = sourceReferenceBundleURL?.standardizedFileURL.path
        self.viewerBundlePath = viewerBundleURL?.standardizedFileURL.path
        self.mapperVersion = mapperVersion
        self.samtoolsVersion = samtoolsVersion
        self.wallClockSeconds = wallClockSeconds
        self.recordedAt = recordedAt
        self.mapperInvocation = mapperInvocation
        self.normalizationInvocations = normalizationInvocations
        self.inputFiles = inputFiles
        self.outputFiles = outputFiles
        self.runtimeIdentity = runtimeIdentity
        self.steps = steps
        self.exitStatus = exitStatus
        self.stderr = stderr
    }

    public var commandInvocations: [MappingCommandInvocation] {
        [mapperInvocation] + normalizationInvocations
    }

    public func withViewerBundleURL(_ viewerBundleURL: URL?) -> MappingProvenance {
        MappingProvenance(
            schemaVersion: schemaVersion,
            workflowName: workflowName,
            mapper: mapper,
            modeID: modeID,
            sampleName: sampleName,
            pairedEnd: pairedEnd,
            threads: threads,
            minimumMappingQuality: minimumMappingQuality,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            advancedArguments: advancedArguments,
            inputFASTQURLs: self.inputFASTQURLs,
            referenceFASTAURL: self.referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundlePath.map { URL(fileURLWithPath: $0) },
            viewerBundleURL: viewerBundleURL,
            mapperInvocation: mapperInvocation,
            normalizationInvocations: normalizationInvocations,
            mapperVersion: mapperVersion,
            samtoolsVersion: samtoolsVersion,
            wallClockSeconds: wallClockSeconds,
            recordedAt: recordedAt,
            readClassHints: readClassHints,
            inputFiles: inputFiles,
            outputFiles: outputFiles,
            runtimeIdentity: runtimeIdentity,
            steps: steps,
            exitStatus: exitStatus,
            stderr: stderr
        )
    }

    public func withSourceReferenceBundleURL(_ sourceReferenceBundleURL: URL?) -> MappingProvenance {
        MappingProvenance(
            schemaVersion: schemaVersion,
            workflowName: workflowName,
            mapper: mapper,
            modeID: modeID,
            sampleName: sampleName,
            pairedEnd: pairedEnd,
            threads: threads,
            minimumMappingQuality: minimumMappingQuality,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            advancedArguments: advancedArguments,
            inputFASTQURLs: self.inputFASTQURLs,
            referenceFASTAURL: self.referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            viewerBundleURL: viewerBundlePath.map { URL(fileURLWithPath: $0) },
            mapperInvocation: mapperInvocation,
            normalizationInvocations: normalizationInvocations,
            mapperVersion: mapperVersion,
            samtoolsVersion: samtoolsVersion,
            wallClockSeconds: wallClockSeconds,
            recordedAt: recordedAt,
            readClassHints: readClassHints,
            inputFiles: inputFiles,
            outputFiles: outputFiles,
            runtimeIdentity: runtimeIdentity,
            steps: steps,
            exitStatus: exitStatus,
            stderr: stderr
        )
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(
            PersistedMappingProvenance(
                schemaVersion: schemaVersion,
                workflowName: workflowName,
                mapper: mapper,
                mapperDisplayName: mapperDisplayName,
                modeID: modeID,
                modeDisplayName: modeDisplayName,
                sampleName: sampleName,
                pairedEnd: pairedEnd,
                threads: threads,
                minimumMappingQuality: minimumMappingQuality,
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary,
                advancedArguments: advancedArguments,
                readClassHints: readClassHints,
                inputFASTQPaths: inputFASTQPaths.map { Self.storedPath(for: URL(fileURLWithPath: $0), relativeTo: directory) },
                referenceFASTAPath: Self.storedPath(for: URL(fileURLWithPath: referenceFASTAPath), relativeTo: directory),
                sourceReferenceBundlePath: sourceReferenceBundlePath.map {
                    Self.storedPath(for: URL(fileURLWithPath: $0), relativeTo: directory)
                },
                viewerBundlePath: viewerBundlePath.map {
                    Self.storedPath(for: URL(fileURLWithPath: $0), relativeTo: directory)
                },
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                wallClockSeconds: wallClockSeconds,
                recordedAt: recordedAt.timeIntervalSince1970,
                mapperInvocation: mapperInvocation,
                normalizationInvocations: normalizationInvocations,
                inputFiles: inputFiles,
                outputFiles: outputFiles,
                runtimeIdentity: runtimeIdentity,
                steps: steps,
                exitStatus: exitStatus,
                stderr: stderr
            )
        )

        try data.write(
            to: directory.appendingPathComponent(Self.filename),
            options: .atomic
        )
    }

    public static func load(from directory: URL) -> MappingProvenance? {
        let url = directory.appendingPathComponent(Self.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()

        guard let persisted = try? decoder.decode(PersistedMappingProvenance.self, from: data) else {
            return nil
        }

        return MappingProvenance(
            schemaVersion: persisted.schemaVersion,
            workflowName: persisted.workflowName ?? "lungfish map",
            mapper: persisted.mapper,
            modeID: persisted.modeID,
            sampleName: persisted.sampleName,
            pairedEnd: persisted.pairedEnd,
            threads: persisted.threads,
            minimumMappingQuality: persisted.minimumMappingQuality,
            includeSecondary: persisted.includeSecondary,
            includeSupplementary: persisted.includeSupplementary,
            advancedArguments: persisted.advancedArguments,
            inputFASTQURLs: persisted.inputFASTQPaths.map { URL(fileURLWithPath: Self.resolvedPath(for: $0, relativeTo: directory)) },
            referenceFASTAURL: URL(fileURLWithPath: Self.resolvedPath(for: persisted.referenceFASTAPath, relativeTo: directory)),
            sourceReferenceBundleURL: persisted.sourceReferenceBundlePath.map {
                URL(fileURLWithPath: Self.resolvedPath(for: $0, relativeTo: directory))
            },
            viewerBundleURL: persisted.viewerBundlePath.map {
                URL(fileURLWithPath: Self.resolvedPath(for: $0, relativeTo: directory))
            },
            mapperInvocation: persisted.mapperInvocation,
            normalizationInvocations: persisted.normalizationInvocations,
            mapperVersion: persisted.mapperVersion,
            samtoolsVersion: persisted.samtoolsVersion,
            wallClockSeconds: persisted.wallClockSeconds,
            recordedAt: Date(timeIntervalSince1970: persisted.recordedAt),
            readClassHints: persisted.readClassHints,
            inputFiles: persisted.inputFiles ?? [],
            outputFiles: persisted.outputFiles ?? [],
            runtimeIdentity: persisted.runtimeIdentity ?? [:],
            steps: persisted.steps ?? [],
            exitStatus: persisted.exitStatus,
            stderr: persisted.stderr
        )
    }

    public static func build(
        request: MappingRunRequest,
        result: MappingResult,
        mapperInvocation: MappingCommandInvocation,
        normalizationInvocations: [MappingCommandInvocation],
        mapperVersion: String,
        samtoolsVersion: String,
        recordedAt: Date = Date(),
        inputFiles: [FileRecord] = [],
        outputFiles: [FileRecord] = [],
        runtimeIdentity: [String: String] = [:],
        steps: [StepExecution] = [],
        exitStatus: Int32? = nil,
        stderr: String? = nil
    ) -> MappingProvenance {
        MappingProvenance(
            schemaVersion: 2,
            workflowName: "lungfish map",
            mapper: request.tool,
            modeID: request.modeID,
            sampleName: request.sampleName,
            pairedEnd: request.pairedEnd,
            threads: request.threads,
            minimumMappingQuality: request.minimumMappingQuality,
            includeSecondary: request.includeSecondary,
            includeSupplementary: request.includeSupplementary,
            advancedArguments: request.advancedArguments,
            inputFASTQURLs: request.inputFASTQURLs,
            referenceFASTAURL: request.referenceFASTAURL,
            sourceReferenceBundleURL: result.sourceReferenceBundleURL ?? request.sourceReferenceBundleURL,
            viewerBundleURL: result.viewerBundleURL,
            mapperInvocation: mapperInvocation,
            normalizationInvocations: normalizationInvocations,
            mapperVersion: mapperVersion,
            samtoolsVersion: samtoolsVersion,
            wallClockSeconds: result.wallClockSeconds,
            recordedAt: recordedAt,
            inputFiles: inputFiles,
            outputFiles: outputFiles,
            runtimeIdentity: runtimeIdentity,
            steps: steps,
            exitStatus: exitStatus,
            stderr: stderr
        )
    }

    public static func readClassHints(from inputFASTQURLs: [URL]) -> [String] {
        Array(
            Set(
                inputFASTQURLs.compactMap { MappingReadClass.detect(fromInputURL: $0)?.displayName }
            )
        )
        .sorted()
    }

    public static func mapperInvocation(
        for request: MappingRunRequest,
        referenceLocator: ReferenceLocator? = nil
    ) throws -> MappingCommandInvocation {
        let command = try MappingCommandBuilder.buildCommand(
            for: request,
            referenceLocator: referenceLocator
        )
        return MappingCommandInvocation(
            label: request.tool.displayName,
            argv: [command.executable] + command.arguments
        )
    }

    public static func normalizationInvocations(
        rawAlignmentURL: URL,
        outputDirectory: URL,
        sampleName: String,
        threads: Int,
        minimumMappingQuality: Int,
        includeSecondary: Bool,
        includeSupplementary: Bool
    ) -> [MappingCommandInvocation] {
        let derivedSampleName = Self.derivedSampleName(from: rawAlignmentURL, fallback: sampleName)
        let sortedBAM = outputDirectory.appendingPathComponent("\(derivedSampleName).sorted.bam")
        let tempFilteredBAM = outputDirectory.appendingPathComponent("\(derivedSampleName).filtered.bam")
        let extensionLower = rawAlignmentURL.pathExtension.lowercased()
        let isAlreadySorted = rawAlignmentURL.lastPathComponent.hasSuffix(".sorted.bam")
        let needsFiltering = minimumMappingQuality > 0 || !includeSecondary || !includeSupplementary

        var invocations: [MappingCommandInvocation] = []

        if extensionLower == "sam" {
            invocations.append(
                MappingCommandInvocation(
                    label: "samtools view",
                    argv: ["samtools", "view", "-b", "-o", tempFilteredBAM.path]
                        + filterArguments(
                            minimumMappingQuality: minimumMappingQuality,
                            includeSecondary: includeSecondary,
                            includeSupplementary: includeSupplementary
                        )
                        + [rawAlignmentURL.path]
                )
            )
            invocations.append(
                MappingCommandInvocation(
                    label: "samtools sort",
                    argv: [
                        "samtools", "sort",
                        "-@", String(max(1, threads / 2)),
                        "-o", sortedBAM.path,
                        tempFilteredBAM.path
                    ]
                )
            )
        } else if extensionLower == "bam", isAlreadySorted, !needsFiltering {
            // No sort required when the input is already sorted and no filter changes are applied.
        } else if extensionLower == "bam", !needsFiltering {
            invocations.append(
                MappingCommandInvocation(
                    label: "samtools sort",
                    argv: [
                        "samtools", "sort",
                        "-@", String(max(1, threads / 2)),
                        "-o", sortedBAM.path,
                        rawAlignmentURL.path
                    ]
                )
            )
        } else {
            invocations.append(
                MappingCommandInvocation(
                    label: "samtools view",
                    argv: ["samtools", "view", "-b", "-o", tempFilteredBAM.path]
                        + filterArguments(
                            minimumMappingQuality: minimumMappingQuality,
                            includeSecondary: includeSecondary,
                            includeSupplementary: includeSupplementary
                        )
                        + [rawAlignmentURL.path]
                )
            )
            invocations.append(
                MappingCommandInvocation(
                    label: "samtools sort",
                    argv: [
                        "samtools", "sort",
                        "-@", String(max(1, threads / 2)),
                        "-o", sortedBAM.path,
                        tempFilteredBAM.path
                    ]
                )
            )
        }

        invocations.append(
            MappingCommandInvocation(
                label: "samtools index",
                argv: ["samtools", "index", sortedBAM.path]
            )
        )
        invocations.append(
            MappingCommandInvocation(
                label: "samtools flagstat",
                argv: ["samtools", "flagstat", sortedBAM.path]
            )
        )

        return invocations
    }

    public func commandLineSummary() -> [String] {
        commandInvocations.map(\.commandLine)
    }

    private var inputFASTQURLs: [URL] {
        inputFASTQPaths.map { URL(fileURLWithPath: $0) }
    }

    private var referenceFASTAURL: URL {
        URL(fileURLWithPath: referenceFASTAPath)
    }

    private static func filterArguments(
        minimumMappingQuality: Int,
        includeSecondary: Bool,
        includeSupplementary: Bool
    ) -> [String] {
        var arguments: [String] = []
        if minimumMappingQuality > 0 {
            arguments += ["-q", String(minimumMappingQuality)]
        }
        let excludedFlags = excludedFlags(
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary
        )
        if excludedFlags > 0 {
            arguments += ["-F", String(excludedFlags)]
        }
        return arguments
    }

    private static func excludedFlags(
        includeSecondary: Bool,
        includeSupplementary: Bool
    ) -> Int {
        var flags = 0
        if !includeSecondary {
            flags |= 0x100
        }
        if !includeSupplementary {
            flags |= 0x800
        }
        return flags
    }

    private static func derivedSampleName(from rawAlignmentURL: URL, fallback: String) -> String {
        var name = rawAlignmentURL.deletingPathExtension().lastPathComponent
        let suffixes = [".raw", ".unsorted", ".sorted"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.isEmpty ? fallback : name
    }

    private static func storedPath(for url: URL, relativeTo directory: URL) -> String {
        let standardizedDirectory = directory.standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL.path
        let relativePrefix = standardizedDirectory.hasSuffix("/") ? standardizedDirectory : standardizedDirectory + "/"
        guard standardizedURL.hasPrefix(relativePrefix) else {
            return standardizedURL
        }
        return String(standardizedURL.dropFirst(relativePrefix.count))
    }

    private static func resolvedPath(for path: String, relativeTo directory: URL) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return directory.appendingPathComponent(path).standardizedFileURL.path
    }

}

private struct PersistedMappingProvenance: Sendable, Codable, Equatable {
    let schemaVersion: Int
    let workflowName: String?
    let mapper: MappingTool
    let mapperDisplayName: String
    let modeID: String
    let modeDisplayName: String
    let sampleName: String
    let pairedEnd: Bool
    let threads: Int
    let minimumMappingQuality: Int
    let includeSecondary: Bool
    let includeSupplementary: Bool
    let advancedArguments: [String]
    let readClassHints: [String]
    let inputFASTQPaths: [String]
    let referenceFASTAPath: String
    let sourceReferenceBundlePath: String?
    let viewerBundlePath: String?
    let mapperVersion: String
    let samtoolsVersion: String
    let wallClockSeconds: Double
    let recordedAt: Double
    let mapperInvocation: MappingCommandInvocation
    let normalizationInvocations: [MappingCommandInvocation]
    let inputFiles: [FileRecord]?
    let outputFiles: [FileRecord]?
    let runtimeIdentity: [String: String]?
    let steps: [StepExecution]?
    let exitStatus: Int32?
    let stderr: String?
}
