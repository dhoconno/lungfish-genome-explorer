import Foundation
import LungfishCore

/// Resolves FASTQ/FASTA-like sequence inputs across plain files, FASTQ bundles,
/// and reference bundles.
public enum SequenceInputResolver {
    /// Returns the primary sequence file for a candidate input.
    ///
    /// Supports:
    /// - raw FASTQ / FASTA files
    /// - `.lungfishfastq` bundles (including derived FASTA bundles)
    /// - `.lungfishref` bundles and files nested inside them
    public static func resolvePrimarySequenceURL(for candidateURL: URL) -> URL? {
        let standardizedURL = candidateURL.standardizedFileURL

        if let bundleURL = enclosingFASTQBundleURL(for: standardizedURL) {
            if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
                if let materializedURL = materializedSequenceURL(for: manifest, in: bundleURL) {
                    return materializedURL
                }

                switch manifest.payload {
                case .full, .fullFASTA, .fullPaired, .fullMixed:
                    return nil
                default:
                    break
                }

                let rootBundleURL = FASTQBundle.resolveBundle(
                    relativePath: manifest.rootBundleRelativePath,
                    from: bundleURL
                )
                let resolvedURL = rootBundleURL
                    .appendingPathComponent(manifest.rootFASTQFilename)
                    .standardizedFileURL
                if FileManager.default.fileExists(atPath: resolvedURL.path) {
                    return resolvedURL
                }

                return nil
            }

            if let primaryFASTQURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
                return primaryFASTQURL
            }
        }

        if let bundleURL = enclosingReferenceBundleURL(for: standardizedURL),
           let manifest = try? BundleManifest.load(from: bundleURL),
           let genomePath = manifest.genome?.path {
            let sequenceURL = bundleURL.appendingPathComponent(genomePath).standardizedFileURL
            return FileManager.default.fileExists(atPath: sequenceURL.path) ? sequenceURL : nil
        }

        guard SequenceFormat.from(url: standardizedURL) != nil else {
            return nil
        }
        return standardizedURL
    }

    /// Returns the effective FASTQ/FASTA format for a candidate input.
    public static func inputSequenceFormat(for candidateURL: URL) -> SequenceFormat? {
        let standardizedURL = candidateURL.standardizedFileURL

        if let bundleURL = enclosingFASTQBundleURL(for: standardizedURL) {
            if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
                if let sequenceFormat = manifest.sequenceFormat {
                    return sequenceFormat
                }
                switch manifest.payload {
                case .fullFASTA:
                    return .fasta
                case .full, .fullPaired, .fullMixed:
                    return .fastq
                default:
                    let rootBundleURL = FASTQBundle.resolveBundle(
                        relativePath: manifest.rootBundleRelativePath,
                        from: bundleURL
                    )
                    let rootURL = rootBundleURL.appendingPathComponent(manifest.rootFASTQFilename)
                    return SequenceFormat.from(url: rootURL)
                }
            }

            if FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) != nil {
                return .fastq
            }
            if let sequenceURL = FASTQBundle.resolvePrimarySequenceURL(for: bundleURL) {
                return SequenceFormat.from(url: sequenceURL)
            }
        }

        if let resolvedReferenceURL = resolveReferenceBundleSequenceURL(for: standardizedURL) {
            return SequenceFormat.from(url: resolvedReferenceURL) ?? .fasta
        }

        return SequenceFormat.from(url: standardizedURL)
    }

    private static func materializedSequenceURL(
        for manifest: FASTQDerivedBundleManifest,
        in bundleURL: URL
    ) -> URL? {
        let candidateURL: URL?
        switch manifest.payload {
        case .full(let fastqFilename):
            candidateURL = bundleURL.appendingPathComponent(fastqFilename).standardizedFileURL
        case .fullFASTA(let fastaFilename):
            candidateURL = bundleURL.appendingPathComponent(fastaFilename).standardizedFileURL
        case .fullPaired(let r1Filename, _):
            candidateURL = bundleURL.appendingPathComponent(r1Filename).standardizedFileURL
        case .fullMixed(let classification):
            candidateURL = classification.files
                .map { bundleURL.appendingPathComponent($0.filename).standardizedFileURL }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        default:
            candidateURL = nil
        }

        guard let candidateURL,
              FileManager.default.fileExists(atPath: candidateURL.path) else {
            return nil
        }
        return candidateURL
    }

    /// Returns the enclosing `.lungfishfastq` bundle for a candidate URL.
    public static func enclosingFASTQBundleURL(for candidateURL: URL) -> URL? {
        let standardizedURL = candidateURL.standardizedFileURL
        var currentURL = standardizedURL
        while currentURL.pathComponents.count > 1 {
            if currentURL.pathExtension.lowercased() == FASTQBundle.directoryExtension {
                return currentURL
            }
            currentURL = currentURL.deletingLastPathComponent().standardizedFileURL
        }

        return nil
    }

    /// Returns the enclosing `.lungfishref` bundle for a candidate URL.
    public static func enclosingReferenceBundleURL(for candidateURL: URL) -> URL? {
        let standardizedURL = candidateURL.standardizedFileURL
        if isReferenceBundleURL(standardizedURL) {
            return standardizedURL
        }

        var currentURL = standardizedURL
        while currentURL.pathComponents.count > 1 {
            currentURL = currentURL.deletingLastPathComponent().standardizedFileURL
            if isReferenceBundleURL(currentURL) {
                return currentURL
            }
        }

        return nil
    }

    private static func resolveReferenceBundleSequenceURL(for candidateURL: URL) -> URL? {
        guard let bundleURL = enclosingReferenceBundleURL(for: candidateURL),
              let manifest = try? BundleManifest.load(from: bundleURL),
              let genomePath = manifest.genome?.path else {
            return nil
        }

        let sequenceURL = bundleURL.appendingPathComponent(genomePath).standardizedFileURL
        return FileManager.default.fileExists(atPath: sequenceURL.path) ? sequenceURL : nil
    }

    private static func isReferenceBundleURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "lungfishref" else {
            return false
        }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
