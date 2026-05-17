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
            try writeMergeProvenance(
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: sourceFASTAURLs,
                bundleURL: result.bundleURL,
                bundleName: bundleName,
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
        bundleName: String,
        startedAt: Date,
        completedAt: Date,
        provenanceWriter: BundleMergeProvenanceSidecarWriter
    ) throws {
        let outputPayloadURLs = try BundleMergeProvenance.regularPayloadFileURLs(in: bundleURL)
        try BundleMergeProvenance.write(
            request: BundleMergeProvenance.Request(
                workflowName: "lungfish reference merge",
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: inputPayloadURLs,
                outputBundleURL: bundleURL,
                outputPayloadURLs: outputPayloadURLs,
                bundleName: bundleName,
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
                startedAt: startedAt,
                completedAt: completedAt
            ),
            sidecarWriter: provenanceWriter
        )
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
