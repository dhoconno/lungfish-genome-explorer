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
                if case .fullFASTA(let fastaFilename) = manifest.payload {
                    let resolvedURL = bundleURL.appendingPathComponent(fastaFilename).standardizedFileURL
                    return FileManager.default.fileExists(atPath: resolvedURL.path) ? resolvedURL : nil
                }

                let descriptor = VirtualFASTQDescriptor(bundleURL: bundleURL, manifest: manifest)
                let resolvedURL = descriptor.resolvedRootFASTQURL
                return FileManager.default.fileExists(atPath: resolvedURL.path) ? resolvedURL : nil
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
                default:
                    return SequenceFormat.from(
                        url: VirtualFASTQDescriptor(bundleURL: bundleURL, manifest: manifest).resolvedRootFASTQURL
                    )
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

    /// Returns the enclosing `.lungfishfastq` bundle for a candidate URL.
    public static func enclosingFASTQBundleURL(for candidateURL: URL) -> URL? {
        let standardizedURL = candidateURL.standardizedFileURL
        if FASTQBundle.isBundleURL(standardizedURL) {
            return standardizedURL
        }

        let parentURL = standardizedURL.deletingLastPathComponent().standardizedFileURL
        return FASTQBundle.isBundleURL(parentURL) ? parentURL : nil
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
