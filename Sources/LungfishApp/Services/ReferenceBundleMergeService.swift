import Foundation
import LungfishIO
import LungfishWorkflow

enum ReferenceBundleMergeServiceError: LocalizedError {
    case requiresAtLeastTwoBundles
    case noFASTAFound(bundleName: String)

    var errorDescription: String? {
        switch self {
        case .requiresAtLeastTwoBundles:
            return "Select at least two reference bundles to merge."
        case .noFASTAFound(let bundleName):
            return "No FASTA file was found in \(bundleName)."
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
        guard sourceBundleURLs.count >= 2 else {
            throw ReferenceBundleMergeServiceError.requiresAtLeastTwoBundles
        }

        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "reference-merge-",
            contextURL: outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let mergedFASTA = tempDirectory.appendingPathComponent("merged.fa")
        FileManager.default.createFile(atPath: mergedFASTA.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: mergedFASTA)
        defer { try? outputHandle.close() }

        for bundleURL in sourceBundleURLs {
            let fastaURL = try resolveFASTAURL(in: bundleURL)
            try await appendFASTAContents(from: fastaURL, to: outputHandle)
        }

        // TODO: Merge annotations, variants, and tracks when merging .lungfishref bundles.
        let result = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: mergedFASTA,
            outputDirectory: outputDirectory,
            preferredBundleName: bundleName
        )
        return result.bundleURL
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
