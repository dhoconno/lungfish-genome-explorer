import Foundation
import LungfishIO
import LungfishWorkflow

enum ReferenceBundleMergeServiceError: LocalizedError {
    case requiresAtLeastTwoBundles
    case noFASTAFound(bundleName: String)
    case unsupportedNonSequenceOnlyBundle(bundleName: String)

    var errorDescription: String? {
        switch self {
        case .requiresAtLeastTwoBundles:
            return "Select at least two reference bundles to merge."
        case .noFASTAFound(let bundleName):
            return "No FASTA file was found in \(bundleName)."
        case .unsupportedNonSequenceOnlyBundle(let bundleName):
            return "\(bundleName) contains annotations, variants, tracks, or alignments; reference bundle merge currently supports sequence-only source bundles."
        }
    }
}

enum ReferenceBundleMergeService {
    @MainActor
    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String
    ) async throws -> URL {
        try await merge(
            sourceBundleURLs: sourceBundleURLs,
            outputDirectory: outputDirectory,
            bundleName: bundleName,
            provenanceWriter: .live
        )
    }

    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        provenanceWriter: BundleMergeProvenanceSidecarWriter
    ) async throws -> URL {
        guard sourceBundleURLs.count >= 2 else {
            throw ReferenceBundleMergeServiceError.requiresAtLeastTwoBundles
        }

        for bundleURL in sourceBundleURLs {
            try validateSequenceOnlySourceBundle(bundleURL)
        }

        let startedAt = Date()
        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "reference-merge-",
            contextURL: outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var createdBundleURL: URL?
        do {
            let mergedFASTA = tempDirectory.appendingPathComponent("merged.fa")
            FileManager.default.createFile(atPath: mergedFASTA.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: mergedFASTA)
            defer { try? outputHandle.close() }

            var sourceFASTAURLs: [URL] = []
            for bundleURL in sourceBundleURLs {
                let fastaURL = try resolveFASTAURL(in: bundleURL)
                sourceFASTAURLs.append(fastaURL)
                try await appendFASTAContents(from: fastaURL, to: outputHandle)
            }

            // TODO: Merge annotations, variants, and tracks when merging .lungfishref bundles.
            let result = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
                sourceURL: mergedFASTA,
                outputDirectory: outputDirectory,
                preferredBundleName: bundleName
            )
            createdBundleURL = result.bundleURL
            let builderProvenance = try ProvenanceEnvelopeReader.load(from: result.bundleURL)
            try writeMergeProvenance(
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: sourceFASTAURLs,
                bundleURL: result.bundleURL,
                requestedBundleName: bundleName,
                resolvedBundleName: result.bundleName,
                nestedProvenance: builderProvenance,
                startedAt: startedAt,
                completedAt: Date(),
                provenanceWriter: provenanceWriter
            )
            return result.bundleURL
        } catch {
            if let createdBundleURL {
                try? FileManager.default.removeItem(at: createdBundleURL)
            }
            throw error
        }
    }

    private static func resolveFASTAURL(in bundleURL: URL) throws -> URL {
        if let simpleFASTA = ReferenceSequenceFolder.fastaURL(in: bundleURL) {
            return simpleFASTA
        }

        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: genomeDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ),
           let fastaURL = contents.first(where: isFASTAFileURL(_:)) {
            return fastaURL
        }

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ),
           let fastaURL = contents.first(where: isFASTAFileURL(_:)) {
            return fastaURL
        }

        throw ReferenceBundleMergeServiceError.noFASTAFound(
            bundleName: bundleURL.deletingPathExtension().lastPathComponent
        )
    }

    private static func appendFASTAContents(
        from fastaURL: URL,
        to outputHandle: FileHandle
    ) async throws {
        for try await line in fastaURL.linesAutoDecompressing() {
            outputHandle.write(Data(line.utf8))
            outputHandle.write(Data("\n".utf8))
        }
    }

    private static func validateSequenceOnlySourceBundle(_ bundleURL: URL) throws {
        guard let manifest = try? BundleManifest.load(from: bundleURL) else {
            return
        }
        guard manifest.genome != nil,
              manifest.annotations.isEmpty,
              manifest.variants.isEmpty,
              manifest.tracks.isEmpty,
              manifest.alignments.isEmpty else {
            throw ReferenceBundleMergeServiceError.unsupportedNonSequenceOnlyBundle(
                bundleName: bundleURL.deletingPathExtension().lastPathComponent
            )
        }
    }

    private static func writeMergeProvenance(
        sourceBundleURLs: [URL],
        inputPayloadURLs: [URL],
        bundleURL: URL,
        requestedBundleName: String,
        resolvedBundleName: String,
        nestedProvenance: ProvenanceEnvelope?,
        startedAt: Date,
        completedAt: Date,
        provenanceWriter: BundleMergeProvenanceSidecarWriter
    ) throws {
        let outputPayloadURLs = try BundleMergeProvenance.regularPayloadFileURLs(in: bundleURL)
        let nestedSteps = try normalizedNestedSteps(
            from: nestedProvenance,
            inputPayloadURLs: inputPayloadURLs,
            outputPayloadURLs: outputPayloadURLs,
            bundleURL: bundleURL,
            resolvedBundleName: resolvedBundleName
        )
        try BundleMergeProvenance.write(
            request: BundleMergeProvenance.Request(
                workflowName: "lungfish reference merge",
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: inputPayloadURLs,
                outputBundleURL: bundleURL,
                outputPayloadURLs: outputPayloadURLs,
                bundleName: resolvedBundleName,
                requestedBundleName: requestedBundleName,
                mergeMode: "sequence-only",
                defaults: [
                    "compressFASTA": .boolean(true),
                    "annotationMerge": .string("unsupported"),
                    "variantMerge": .string("unsupported"),
                    "trackMerge": .string("unsupported"),
                ],
                resolvedDefaults: [
                    "compressFASTA": .boolean(true),
                    "annotationMerge": .string("unsupported"),
                    "variantMerge": .string("unsupported"),
                    "trackMerge": .string("unsupported"),
                ],
                nestedSteps: nestedSteps,
                startedAt: startedAt,
                completedAt: completedAt
            ),
            sidecarWriter: provenanceWriter
        )
    }

    private static func normalizedNestedSteps(
        from envelope: ProvenanceEnvelope?,
        inputPayloadURLs: [URL],
        outputPayloadURLs: [URL],
        bundleURL: URL,
        resolvedBundleName: String
    ) throws -> [ProvenanceStep] {
        guard let envelope else { return [] }
        let sourceInputs = try inputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, format: .fasta, role: .input)
        }
        let outputs = try outputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, format: fileFormat(for: $0), role: .output)
        }
        let durableFASTAURL = finalGenomePayloadURL(in: bundleURL, outputPayloadURLs: outputPayloadURLs)
        let durableFASTAInput = try durableFASTAURL.map {
            try ProvenanceFileDescriptor.file(url: $0, format: .fasta, role: .input)
        }
        let inputs = uniqueDescriptors(sourceInputs + Array(durableFASTAInput.map { [$0] } ?? []))

        return envelope.steps.map { step in
            guard step.toolName == "NativeBundleBuilder.build" else {
                return step
            }
            let originalArgv = step.durableReplayArgv ?? step.argv
            let argv = rewriteBuilderReplayArgv(
                originalArgv,
                tempInputPaths: step.inputs.map(\.path),
                durableFASTAURL: durableFASTAURL,
                bundleURL: bundleURL,
                resolvedBundleName: resolvedBundleName
            )
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                durableReplayArgv: argv,
                reproducibleCommand: BundleMergeProvenance.commandLine(from: argv),
                inputs: inputs,
                outputs: outputs,
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
    }

    private static func finalGenomePayloadURL(in bundleURL: URL, outputPayloadURLs: [URL]) -> URL? {
        if let manifest = try? BundleManifest.load(from: bundleURL),
           let genome = manifest.genome {
            return bundleURL.appendingPathComponent(genome.path).standardizedFileURL
        }
        return outputPayloadURLs.first(where: isFASTAFileURL(_:))?.standardizedFileURL
    }

    private static func rewriteBuilderReplayArgv(
        _ argv: [String],
        tempInputPaths: [String],
        durableFASTAURL: URL?,
        bundleURL: URL,
        resolvedBundleName: String
    ) -> [String] {
        let durableFASTAPath = durableFASTAURL?.standardizedFileURL.path
        let tempInputPaths = Set(tempInputPaths)
        var rewritten = argv.map { argument in
            rewriteBuilderArgument(
                argument,
                tempInputPaths: tempInputPaths,
                durableFASTAPath: durableFASTAPath
            )
        }

        if rewritten.isEmpty, let durableFASTAPath {
            rewritten = [
                "NativeBundleBuilder.build",
                "--name",
                resolvedBundleName,
                "--identifier",
                resolvedBundleIdentifier(in: bundleURL, fallbackName: resolvedBundleName),
                "--fasta",
                durableFASTAPath,
                "--output-directory",
                bundleURL.deletingLastPathComponent().standardizedFileURL.path,
                "--bundle",
                bundleURL.standardizedFileURL.path,
                "--compress-fasta",
                "true",
            ]
        }

        return rewritten
    }

    private static func resolvedBundleIdentifier(in bundleURL: URL, fallbackName: String) -> String {
        if let manifest = try? BundleManifest.load(from: bundleURL) {
            return manifest.identifier
        }
        let sanitized = fallbackName
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "." || character == "-" {
                    return character
                }
                return "-"
            }
        return "org.lungfish.\(String(sanitized))"
    }

    private static func rewriteBuilderArgument(
        _ argument: String,
        tempInputPaths: Set<String>,
        durableFASTAPath: String?
    ) -> String {
        guard let durableFASTAPath else { return argument }
        if tempInputPaths.contains(argument) {
            return durableFASTAPath
        }
        for tempInputPath in tempInputPaths where argument.contains(tempInputPath) {
            return argument.replacingOccurrences(of: tempInputPath, with: durableFASTAPath)
        }
        return argument
    }

    private static func uniqueDescriptors(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen: Set<String> = []
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue):\(descriptor.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(descriptor)
        }
        return result
    }

    private static func fileFormat(for url: URL) -> FileFormat? {
        var candidate = url
        if candidate.pathExtension.lowercased() == "gz" {
            candidate = candidate.deletingPathExtension()
        }
        switch candidate.pathExtension.lowercased() {
        case "fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn":
            return .fasta
        case "json":
            return .json
        case "csv", "tsv", "txt", "fai", "gzi":
            return .text
        default:
            return .unknown
        }
    }

    private static func isFASTAFileURL(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".fa")
            || lowercasedName.hasSuffix(".fasta")
            || lowercasedName.hasSuffix(".fna")
            || lowercasedName.hasSuffix(".fa.gz")
            || lowercasedName.hasSuffix(".fasta.gz")
            || lowercasedName.hasSuffix(".fna.gz")
    }
}
