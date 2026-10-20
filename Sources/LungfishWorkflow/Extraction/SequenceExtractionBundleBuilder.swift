// SequenceExtractionBundleBuilder.swift - Shared .lungfishref bundle output for extracted sequences
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

package struct SequenceExtractionBundleCommandContext: Sendable {
    package let workflowName: String
    package let toolName: String
    package let toolVersion: String
    package let argv: [String]
    package let explicitOptions: [String: ParameterValue]
    package let defaultOptions: [String: ParameterValue]
    package let resolvedOptions: [String: ParameterValue]
    package let inputURLs: [URL]
    /// The caller's clock, when the caller timed the run. The bundle's
    /// provenance takes both its start and its end from it.
    package let runClock: ProvenanceRunClock?

    package init(
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

package struct SequenceExtractionBundleBuildRequest: Sendable {
    package let result: LungfishCore.ExtractionResult
    package let outputDirectory: URL
    package let outputBundleURL: URL?
    package let sourceBundleURL: URL?
    package let sourceBundleName: String?
    package let desiredBundleName: String?
    /// The source bundle's chromosomes, which map a track's chromosome names to the region's.
    package let sourceBundleChromosomes: [ChromosomeInfo]
    package let sourceAnnotationTracks: [SequenceExtractionSourceAnnotationTrack]
    package let sourceVariantTracks: [SequenceExtractionSourceVariantTrack]
    /// The samples whose calls the variant tracks keep, or nil for every sample.
    package let sampleFilter: Set<String>?
    package let isConcatenated: Bool
    /// When a bundle already holds `outputBundleURL`'s name at the publish, the new bundle takes the
    /// next free name (`_1`, `_2`) and replaces nothing, and its identifier, the plain path's manifest
    /// name and its record follow the name it took (2.11 A48 M1 review Fix 6, SC5). When false the
    /// bundle replaces the one there, as a typed `-o` asks.
    package let publishesUnderNextFreeName: Bool
    package let commandContext: SequenceExtractionBundleCommandContext

    package init(
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
        publishesUnderNextFreeName: Bool = false,
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
        self.publishesUnderNextFreeName = publishesUnderNextFreeName
        self.commandContext = commandContext
    }

    /// A run that keeps a track, filters samples or joins exons builds its bundle on the track path.
    var usesTrackPath: Bool {
        !sourceAnnotationTracks.isEmpty || !sourceVariantTracks.isEmpty || sampleFilter != nil || isConcatenated
    }
}

package final class SequenceExtractionBundleBuilder: Sendable {
    let toolRunner: NativeToolRunner

    package init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    /// The folder a bundle of `result` takes in `directory`. The desired name, or the result's
    /// source name when no name is desired, goes through the one sanitizer and the one uniquer of
    /// `BundleBuildHelpers`, and an empty name becomes `extracted_sequence`.
    package static func uniqueBundleURL(
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

    package func buildBundle(
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
                identifier: Self.extractedIdentifier(forBundleNamed: bundleName),
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
        // A cancel that came while the bundle was built publishes nothing, and the stage goes.
        try Task.checkCancellation()
        let bundleURL = try moveToRequestedOutputIfNeeded(
            builtBundleURL,
            request: request
        )

        do {
            progressHandler?(0.92, "Writing provenance...")
            let completedAt = runClock.now
            try writeProvenance(
                request: request,
                bundleURL: bundleURL,
                toolSteps: try await genomeToolSteps(bundleURL: bundleURL, startedAt: startedAt, completedAt: completedAt),
                startedAt: startedAt,
                completedAt: completedAt
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
        if request.publishesUnderNextFreeName {
            return try publishUnderNextFreeName(builtURL, planned: outputBundleURL, keepsManifestName: request.usesTrackPath)
        }
        // The bundle is staged in the project's `.tmp/` and published under its name with one
        // rename, so no reader sees a part of it there (2.11 A48 M2, SC5). A folder on another volume
        // than the stage, which no rename can reach, is copied as before.
        guard Self.onSameVolume(builtURL, outputBundleURL.deletingLastPathComponent()) else {
            if fileManager.fileExists(atPath: outputBundleURL.path) {
                try fileManager.removeItem(at: outputBundleURL)
            }
            try fileManager.moveItem(at: builtURL, to: outputBundleURL)
            return outputBundleURL
        }
        if fileManager.fileExists(atPath: outputBundleURL.path) {
            _ = try PortableRename.swap(builtURL, outputBundleURL)
            try? fileManager.removeItem(at: builtURL) // the bundle it replaced
        } else {
            _ = try PortableRename.exclusive(builtURL, to: outputBundleURL)
        }
        return outputBundleURL
    }

    /// Moves the staged bundle to `planned`, or to the next free name when a bundle holds it, and never
    /// replaces one. Another run may publish a name between the check and the rename, so a refused
    /// rename tries the next name, as `fetch genome` publishes. A bundle that takes another name gets
    /// that name's identifier, and on the plain path its manifest name, before it appears there, as a
    /// run that started later would have named it (2.11 A48 M1 review Fix 6, SC5).
    private func publishUnderNextFreeName(_ builtURL: URL, planned: URL, keepsManifestName: Bool) throws -> URL {
        let directory = planned.deletingLastPathComponent()
        let baseName = planned.deletingPathExtension().lastPathComponent
        let sameVolume = Self.onSameVolume(builtURL, directory)
        for _ in 0..<32 {
            let destination = BundleBuildHelpers.makeUniqueBundleURL(
                baseName: baseName,
                in: directory,
                emptyNameFallback: BundleBuildHelpers.extractedSequenceBundleName
            )
            if destination.path != planned.path {
                try Self.renameManifest(in: builtURL, to: destination, keepingName: keepsManifestName)
            }
            do {
                if sameVolume {
                    _ = try PortableRename.exclusive(builtURL, to: destination)
                } else {
                    // A folder on another volume than the stage, which no rename reaches. The move
                    // refuses a name that is taken too.
                    try FileManager.default.moveItem(at: builtURL, to: destination)
                }
                return destination
            } catch where FileManager.default.fileExists(atPath: destination.path) {
                continue // Another run published this name after the check.
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: planned.path])
    }

    /// The identifier of an extracted bundle in the folder `<bundleName>.lungfishref`, on both paths.
    static func extractedIdentifier(forBundleNamed bundleName: String) -> String {
        "org.lungfish.extracted.\(bundleName.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }

    /// Gives the staged bundle at `bundleURL` the identifier of `destination`'s name, and that name as
    /// its manifest name unless `keepingName`, since the track path's manifest keeps the name the
    /// person typed. The manifest goes through its own coding, so every other field stays as written.
    private static func renameManifest(in bundleURL: URL, to destination: URL, keepingName: Bool) throws {
        let name = destination.deletingPathExtension().lastPathComponent
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(BundleManifest.load(from: bundleURL))
        guard var fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: bundleURL.path])
        }
        fields["identifier"] = extractedIdentifier(forBundleNamed: name)
        if !keepingName {
            fields["name"] = name
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try decoder.decode(BundleManifest.self, from: JSONSerialization.data(withJSONObject: fields)).save(to: bundleURL)
    }

    private static func onSameVolume(_ first: URL, _ second: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let one = try? first.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let other = try? second.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else {
            return false
        }
        return one.isEqual(other)
    }

    /// The bgzip and samtools faidx steps that made the bundle's genome, each with the version of the
    /// tool that ran and the argv the runner gave it, so the record names every tool of the run
    /// (2.11 A48 M2, BIO 4). A bundle with no compressed genome names neither. Each version is typed
    /// evidence, as the FASTQ ingestion steps record it. A probe that answers is observed, and one that
    /// does not leaves the lock's pin for the tool's id, recorded as a pin and never as the word unknown
    /// (2.11 landing 4 Handoff 1). The method is internal so a test can drive it with a runner whose
    /// probes fail.
    func genomeToolSteps(bundleURL: URL, startedAt: Date, completedAt: Date) async throws -> [ProvenanceStep] {
        let genome = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let compressed = genome.appendingPathComponent("sequence.fa.gz")
        guard FileManager.default.fileExists(atPath: compressed.path) else { return [] }
        let indexes = ["sequence.fa.gz.fai", "sequence.fa.gz.gzi"]
            .map { genome.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let bgzipArgv = ["bgzip", "-f"] + (threads > 1 ? ["-@", String(threads)] : []) + ["sequence.fa"]
        let faidxArgv = ["samtools", "faidx", "sequence.fa.gz"]
        let compressedDescriptor = try ProvenanceFileDescriptor.file(url: compressed, format: .fasta, role: .output)
        let indexDescriptors = try indexes.map { try ProvenanceFileDescriptor.file(url: $0, format: .text, role: .index) }
        let bgzipEvidence = FASTQIngestionPipeline.versionEvidence(
            observed: await toolRunner.getToolVersion(.bgzip), for: .bgzip
        )
        let samtoolsEvidence = FASTQIngestionPipeline.versionEvidence(
            observed: await toolRunner.getToolVersion(.samtools), for: .samtools
        )
        let wallTime = completedAt.timeIntervalSince(startedAt)
        return [
            ProvenanceStep(
                toolName: "bgzip", toolVersion: bgzipEvidence.recordedString, argv: bgzipArgv,
                reproducibleCommand: bgzipArgv.joined(separator: " "), inputs: [], outputs: [compressedDescriptor],
                exitStatus: 0, wallTimeSeconds: wallTime, stderr: nil, startedAt: startedAt, completedAt: completedAt,
                managedToolID: NativeTool.bgzip.managedToolID, toolVersionEvidence: bgzipEvidence
            ),
            ProvenanceStep(
                toolName: "samtools faidx", toolVersion: samtoolsEvidence.recordedString, argv: faidxArgv,
                reproducibleCommand: faidxArgv.joined(separator: " "), inputs: [compressedDescriptor], outputs: indexDescriptors,
                exitStatus: 0, wallTimeSeconds: wallTime, stderr: nil, startedAt: startedAt, completedAt: completedAt,
                managedToolID: NativeTool.samtools.managedToolID, toolVersionEvidence: samtoolsEvidence
            ),
        ]
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
        toolSteps: [ProvenanceStep],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let inputDescriptors = try inputDescriptors(for: request)
        let outputDescriptors = try outputDescriptors(in: bundleURL)
        // A bundle published under the next free name records the folder it took.
        let tookAnotherName = request.outputBundleURL.map { $0.standardizedFileURL.path != bundleURL.path } ?? false
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

        let runBuilder = try ProvenanceRunBuilder(
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
                .merging(["output_bundle": .file(bundleURL)]) { current, published in tookAnotherName ? published : current }
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        let envelope = try toolSteps.reduce(runBuilder) { $0.step($1) }
            .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        try ProvenanceWriter().write(envelope, to: bundleURL)
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
