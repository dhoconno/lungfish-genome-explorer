// ReferenceBundleMergeService+Provenance.swift - Naming the merged bundle and writing the record of a reference merge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension ReferenceBundleMergeService {

    static func mergedSourceInfo(from sources: [SourceBundle], bundleName: String) -> SourceInfo {
        let organisms = orderedUnique(
            sources.compactMap { $0.manifest?.source.organism }.filter { !$0.isEmpty }
        )
        let databases = orderedUnique(sources.compactMap { $0.manifest?.source.database })
        return SourceInfo(
            organism: organisms.isEmpty ? bundleName : organisms.joined(separator: "; "),
            assembly: bundleName,
            database: databases.isEmpty ? nil : databases.joined(separator: "; "),
            downloadDate: Date(),
            notes: "Merged from \(sources.map(\.displayName).joined(separator: ", "))."
        )
    }

    static func mergedWarnings(from sources: [SourceBundle]) -> [BundleWarning] {
        var merged: [BundleWarning] = []
        for source in sources {
            for warning in source.manifest?.warnings ?? [] where !merged.contains(warning) {
                merged.append(warning)
            }
        }
        return merged
    }

    static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func slugify(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "_"
        }
        let collapsed = String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "source" : collapsed
    }

    /// Mirrors `ReferenceBundleImportService`'s uniquing so a merge into a directory that
    /// already holds a bundle of the requested name gets "<name> 2" rather than colliding.
    static func makeUniqueBundleName(base: String, in directory: URL) -> String {
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(
            atPath: bundleURL(forBundleName: candidate, in: directory).path
        ) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    static func bundleURL(forBundleName bundleName: String, in directory: URL) -> URL {
        let safeName = bundleName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safeName).lungfishref", isDirectory: true)
    }

    static func resolveFASTAURL(in bundleURL: URL) throws -> URL {
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

    static func appendFASTAContents(
        from fastaURL: URL,
        to outputHandle: FileHandle
    ) async throws {
        for try await line in fastaURL.linesAutoDecompressing() {
            outputHandle.write(Data(line.utf8))
            outputHandle.write(Data("\n".utf8))
        }
    }

    static func writeMergeProvenance(
        sourceBundleURLs: [URL],
        inputPayloadURLs: [URL],
        bundleURL: URL,
        requestedBundleName: String,
        resolvedBundleName: String,
        nestedProvenance: ProvenanceEnvelope?,
        mergedAnnotationTrackCount: Int,
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
                mergeMode: mergedAnnotationTrackCount > 0 ? "sequence-and-annotations" : "sequence-only",
                defaults: [
                    "compressFASTA": .boolean(true),
                    "annotationMerge": .string("preserved"),
                    "variantMerge": .string("unsupported"),
                    "trackMerge": .string("unsupported"),
                ],
                resolvedDefaults: [
                    "compressFASTA": .boolean(true),
                    "annotationMerge": .string(
                        mergedAnnotationTrackCount > 0 ? "preserved" : "no-annotations-in-sources"
                    ),
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

    static func normalizedNestedSteps(
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

        return envelope.steps.compactMap { step -> ProvenanceStep? in
            guard step.toolName == "NativeBundleBuilder.build" else {
                return nil
            }
            let originalArgv = step.durableReplayArgv ?? step.argv
            let argv = rewriteBuilderReplayArgv(
                originalArgv,
                tempInputPaths: step.inputs.map(\.path),
                durableFASTAURL: durableFASTAURL,
                bundleURL: bundleURL,
                resolvedBundleName: resolvedBundleName
            )
            return step.with { copy in
                copy.durableReplayArgv = argv
                copy.reproducibleCommand = BundleMergeProvenance.commandLine(from: argv)
                copy.inputs = inputs
                copy.outputs = outputs
                // The options named the staged input as the replay command did, and both now name the durable FASTA.
                let fastaPath = durableFASTAURL?.standardizedFileURL.path, staged = Set(step.inputs.map(\.path))
                copy.resolvedOptions = step.resolvedOptions.mapValues { option in
                    option.rewritingPaths { rewriteBuilderArgument($0, tempInputPaths: staged, durableFASTAPath: fastaPath) }
                }
            }
        }
    }

    static func finalGenomePayloadURL(in bundleURL: URL, outputPayloadURLs: [URL]) -> URL? {
        if let manifest = try? BundleManifest.load(from: bundleURL),
           let genome = manifest.genome,
           let genomeURL = try? BundleManifest.validatedBundleMemberURL(
               for: genome.path,
               in: bundleURL,
               field: "genome.path"
           ) {
            return genomeURL.standardizedFileURL
        }
        return outputPayloadURLs.first(where: isFASTAFileURL(_:))?.standardizedFileURL
    }

    static func rewriteBuilderReplayArgv(
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

    static func resolvedBundleIdentifier(in bundleURL: URL, fallbackName: String) -> String {
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

    static func rewriteBuilderArgument(
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

    static func uniqueDescriptors(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen: Set<String> = []
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue):\(descriptor.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(descriptor)
        }
        return result
    }

    static func fileFormat(for url: URL) -> FileFormat? {
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

    static func isFASTAFileURL(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".fa")
            || lowercasedName.hasSuffix(".fasta")
            || lowercasedName.hasSuffix(".fna")
            || lowercasedName.hasSuffix(".fa.gz")
            || lowercasedName.hasSuffix(".fasta.gz")
            || lowercasedName.hasSuffix(".fna.gz")
    }
}
