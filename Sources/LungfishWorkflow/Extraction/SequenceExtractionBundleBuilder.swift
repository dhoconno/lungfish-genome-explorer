// SequenceExtractionBundleBuilder.swift - Shared .lungfishref bundle output for extracted sequences
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public struct SequenceExtractionBundleCommandContext: Sendable {
    public let workflowName: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let explicitOptions: [String: ParameterValue]
    public let defaultOptions: [String: ParameterValue]
    public let resolvedOptions: [String: ParameterValue]
    public let inputURLs: [URL]
    /// The caller's clock, when the caller timed the run. The bundle's
    /// provenance takes both its start and its end from it.
    public let runClock: ProvenanceRunClock?

    public init(
        workflowName: String,
        toolName: String,
        toolVersion: String = WorkflowRun.currentAppVersion,
        argv: [String],
        explicitOptions: [String: ParameterValue],
        defaultOptions: [String: ParameterValue],
        resolvedOptions: [String: ParameterValue],
        inputURLs: [URL],
        runClock: ProvenanceRunClock? = nil
    ) {
        self.workflowName = workflowName
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.explicitOptions = explicitOptions
        self.defaultOptions = defaultOptions
        self.resolvedOptions = resolvedOptions
        self.inputURLs = inputURLs
        self.runClock = runClock
    }
}

public struct SequenceExtractionBundleBuildRequest: Sendable {
    public let result: LungfishCore.ExtractionResult
    public let outputDirectory: URL
    public let outputBundleURL: URL?
    public let sourceBundleURL: URL?
    public let sourceBundleName: String?
    public let desiredBundleName: String?
    /// The source bundle's chromosomes, which map a track's chromosome names to the region's.
    public let sourceBundleChromosomes: [ChromosomeInfo]
    public let sourceAnnotationTracks: [SequenceExtractionSourceAnnotationTrack]
    public let sourceVariantTracks: [SequenceExtractionSourceVariantTrack]
    /// The samples whose calls the variant tracks keep, or nil for every sample.
    public let sampleFilter: Set<String>?
    public let isConcatenated: Bool
    public let commandContext: SequenceExtractionBundleCommandContext

    public init(
        result: LungfishCore.ExtractionResult,
        outputDirectory: URL,
        outputBundleURL: URL? = nil,
        sourceBundleURL: URL? = nil,
        sourceBundleName: String? = nil,
        desiredBundleName: String? = nil,
        sourceBundleChromosomes: [ChromosomeInfo] = [],
        sourceAnnotationTracks: [SequenceExtractionSourceAnnotationTrack] = [],
        sourceVariantTracks: [SequenceExtractionSourceVariantTrack] = [],
        sampleFilter: Set<String>? = nil,
        isConcatenated: Bool = false,
        commandContext: SequenceExtractionBundleCommandContext
    ) {
        self.result = result
        self.outputDirectory = outputDirectory
        self.outputBundleURL = outputBundleURL
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleName = sourceBundleName
        self.desiredBundleName = desiredBundleName
        self.sourceBundleChromosomes = sourceBundleChromosomes
        self.sourceAnnotationTracks = sourceAnnotationTracks
        self.sourceVariantTracks = sourceVariantTracks
        self.sampleFilter = sampleFilter
        self.isConcatenated = isConcatenated
        self.commandContext = commandContext
    }

    /// A run that keeps a track, filters samples or joins exons builds its bundle on the track path.
    var usesTrackPath: Bool {
        !sourceAnnotationTracks.isEmpty || !sourceVariantTracks.isEmpty || sampleFilter != nil || isConcatenated
    }
}

public final class SequenceExtractionBundleBuilder: @unchecked Sendable {
    let toolRunner: NativeToolRunner

    public init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    /// The folder a bundle of `result` takes in `directory`. The desired name, or the result's
    /// source name when no name is desired, goes through the one sanitizer and the one uniquer of
    /// `BundleBuildHelpers`, and an empty name becomes `extracted_sequence`.
    public static func uniqueBundleURL(
        for result: LungfishCore.ExtractionResult,
        desiredBundleName: String?,
        in directory: URL
    ) -> URL {
        let rawName = desiredBundleName?.isEmpty == false ? desiredBundleName! : result.sourceName
        return BundleBuildHelpers.makeUniqueBundleURL(
            baseName: BundleBuildHelpers.sanitizedFilename(rawName),
            in: directory,
            emptyNameFallback: BundleBuildHelpers.extractedSequenceBundleName
        )
    }

    public func buildBundle(
        request: SequenceExtractionBundleBuildRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let runClock = request.commandContext.runClock ?? ProvenanceRunClock()
        let startedAt = runClock.startedAt
        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "extract-bundle-",
            contextURL: request.outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        progressHandler?(0.10, "Writing FASTA...")
        let fastaURL = tempDirectory.appendingPathComponent("sequence.fa")
        try SequenceExtractor.formatFASTA(request.result)
            .write(to: fastaURL, atomically: true, encoding: .utf8)

        let bundleName = try resolvedBundleName(for: request)
        let buildOutputDirectory = request.outputBundleURL == nil
            ? request.outputDirectory
            : tempDirectory.appendingPathComponent("bundle-output", isDirectory: true)
        let builtBundleURL: URL
        if request.usesTrackPath {
            builtBundleURL = try await buildTrackBundle(
                request: request,
                fastaURL: fastaURL,
                bundleName: bundleName,
                outputDirectory: buildOutputDirectory,
                tempDirectory: tempDirectory,
                progressHandler: progressHandler
            )
        } else {
            let configuration = BuildConfiguration(
                name: bundleName,
                identifier: "org.lungfish.extracted.\(bundleName.lowercased().replacingOccurrences(of: " ", with: "-"))",
                fastaURL: fastaURL,
                outputDirectory: buildOutputDirectory,
                source: sourceInfo(for: request),
                compressFASTA: true,
                provenanceWorkflowName: request.commandContext.workflowName,
                provenanceCommand: request.commandContext.argv,
                provenanceInputFiles: request.commandContext.inputURLs
            )

            progressHandler?(0.20, "Building reference bundle...")
            builtBundleURL = try await NativeBundleBuilder(toolRunner: toolRunner).build(configuration: configuration) {
                _, progress, message in
                progressHandler?(0.20 + (progress * 0.65), message)
            }
        }
        let bundleURL = try moveToRequestedOutputIfNeeded(
            builtBundleURL,
            request: request
        )

        do {
            progressHandler?(0.92, "Writing provenance...")
            try writeProvenance(
                request: request,
                bundleURL: bundleURL,
                startedAt: startedAt,
                completedAt: runClock.now
            )
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        return bundleURL
    }

    private func resolvedBundleName(for request: SequenceExtractionBundleBuildRequest) throws -> String {
        if let outputBundleURL = request.outputBundleURL {
            try FileManager.default.createDirectory(
                at: outputBundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return outputBundleURL.deletingPathExtension().lastPathComponent
        }

        return Self.uniqueBundleURL(
            for: request.result,
            desiredBundleName: request.desiredBundleName,
            in: request.outputDirectory
        ).deletingPathExtension().lastPathComponent
    }

    private func moveToRequestedOutputIfNeeded(
        _ builtBundleURL: URL,
        request: SequenceExtractionBundleBuildRequest
    ) throws -> URL {
        guard let outputBundleURL = request.outputBundleURL?.standardizedFileURL else {
            return builtBundleURL
        }

        let builtURL = builtBundleURL.standardizedFileURL
        if builtURL.path == outputBundleURL.path {
            return builtURL
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputBundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputBundleURL.path) {
            try fileManager.removeItem(at: outputBundleURL)
        }
        try fileManager.moveItem(at: builtURL, to: outputBundleURL)
        return outputBundleURL
    }

    private func sourceInfo(for request: SequenceExtractionBundleBuildRequest) -> SourceInfo {
        let coordinateLabel = "\(request.result.headerRegion) (\(LungfishCore.ExtractionResult.headerCoordinateSystem))"
        let description: String
        if let sourceBundleName = request.sourceBundleName {
            description = "Extracted from \(sourceBundleName) at \(coordinateLabel)"
        } else {
            description = "Extracted sequence at \(coordinateLabel)"
        }
        return SourceInfo(
            organism: request.sourceBundleName ?? "Unknown",
            assembly: "Extracted",
            sourceURL: request.sourceBundleURL,
            downloadDate: Date(),
            notes: description
        )
    }

    private func writeProvenance(
        request: SequenceExtractionBundleBuildRequest,
        bundleURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let inputDescriptors = try inputDescriptors(for: request)
        let outputDescriptors = try outputDescriptors(in: bundleURL)
        let reproducibleCommand = request.commandContext.argv.map { shellEscape($0) }.joined(separator: " ")
        let step = ProvenanceStep(
            toolName: request.commandContext.toolName,
            toolVersion: request.commandContext.toolVersion,
            argv: request.commandContext.argv,
            reproducibleCommand: reproducibleCommand,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )

        let envelope = try ProvenanceRunBuilder(
            workflowName: request.commandContext.workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: request.commandContext.toolName,
            toolVersion: request.commandContext.toolVersion
        )
        .argv(request.commandContext.argv)
        .reproducibleCommand(reproducibleCommand)
        .options(
            explicit: request.commandContext.explicitOptions,
            defaults: request.commandContext.defaultOptions,
            resolved: request.commandContext.resolvedOptions
                .merging(["output_bundle": .file(bundleURL)]) { current, _ in current }
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private func inputDescriptors(
        for request: SequenceExtractionBundleBuildRequest
    ) throws -> [ProvenanceFileDescriptor] {
        var inputURLs = request.commandContext.inputURLs
        if let sourceBundleURL = request.sourceBundleURL {
            inputURLs.append(contentsOf: sourceBundleInputURLs(sourceBundleURL))
        }
        inputURLs.append(contentsOf: request.sourceAnnotationTracks.map(\.databaseURL))
        inputURLs.append(contentsOf: request.sourceVariantTracks.map(\.databaseURL))
        return try deduplicatedExistingURLs(inputURLs).map {
            try ProvenanceFileDescriptor.file(url: $0, format: provenanceFormat(for: $0), role: provenanceInputRole(for: $0))
        }
    }

    /// Every regular file of the bundle but its records. The bundle and each file are compared
    /// with their links resolved, since the folder may be reached through one, as the temporary
    /// folder is, and a record that the bundle builder wrote first must not be listed.
    private func outputDescriptors(in bundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        let bundlePrefix = bundleURL.resolvingSymlinksInPath().path + "/"
        var outputURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let resolvedPath = fileURL.resolvingSymlinksInPath().path
            let relativePath = resolvedPath.hasPrefix(bundlePrefix)
                ? String(resolvedPath.dropFirst(bundlePrefix.count))
                : resolvedPath
            guard relativePath != ProvenanceWriter.provenanceFilename,
                  relativePath != ProvenanceWriter.bundleProvenanceDirectoryName,
                  !relativePath.hasPrefix("\(ProvenanceWriter.bundleProvenanceDirectoryName)/") else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                outputURLs.append(fileURL.standardizedFileURL)
            }
        }

        return try outputURLs.sorted { $0.path < $1.path }.map {
            try ProvenanceFileDescriptor.file(
                url: $0,
                format: provenanceFormat(for: $0),
                role: provenanceOutputRole(for: $0)
            )
        }
    }

    private func sourceBundleInputURLs(_ sourceBundleURL: URL) -> [URL] {
        var urls = [sourceBundleURL.appendingPathComponent("manifest.json")]
        guard let manifest = try? BundleManifest.load(from: sourceBundleURL),
              let genome = manifest.genome else {
            return urls
        }
        // Route through the escape-root-aware policy so consensus export from a
        // symlinked mapping viewer bundle resolves its genome members too.
        let allowedEscapeRoots = ReferenceBundleEscapeRoots.allowedRoots(
            forBundleAt: sourceBundleURL,
            manifest: manifest
        )
        if let genomeURL = try? BundleManifest.validatedBundleMemberURL(
            for: genome.path,
            in: sourceBundleURL,
            field: "genome.path",
            allowedEscapeRoots: allowedEscapeRoots
        ) {
            urls.append(genomeURL)
        }
        if let indexURL = try? BundleManifest.validatedBundleMemberURL(
            for: genome.indexPath,
            in: sourceBundleURL,
            field: "genome.indexPath",
            allowedEscapeRoots: allowedEscapeRoots
        ) {
            urls.append(indexURL)
        }
        if let gzipIndexPath = genome.gzipIndexPath {
            if let gzipIndexURL = try? BundleManifest.validatedBundleMemberURL(
                for: gzipIndexPath,
                in: sourceBundleURL,
                field: "genome.gzipIndexPath",
                allowedEscapeRoots: allowedEscapeRoots
            ) {
                urls.append(gzipIndexURL)
            }
        }
        return urls
    }

    private func deduplicatedExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else {
                continue
            }
            result.append(standardized)
        }
        return result
    }

    private func provenanceInputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "gzi":
            return .index
        default:
            return .input
        }
    }

    private func provenanceOutputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "gzi":
            return .index
        default:
            return .output
        }
    }

    private func provenanceFormat(for url: URL) -> FileFormat {
        let filename = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "bed":
            return .bed
        case "json":
            return .json
        case "fai", "gzi", "txt":
            return .text
        case "fa", "fasta", "fna", "ffn", "faa", "fas":
            return .fasta
        case "gz" where filename.hasSuffix(".fa.gz")
            || filename.hasSuffix(".fasta.gz")
            || filename.hasSuffix(".fna.gz")
            || filename.hasSuffix(".ffn.gz")
            || filename.hasSuffix(".faa.gz")
            || filename.hasSuffix(".fas.gz"):
            return .fasta
        case "db":
            return .unknown
        default:
            return .unknown
        }
    }
}
