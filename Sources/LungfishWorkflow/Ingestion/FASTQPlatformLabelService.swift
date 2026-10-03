// FASTQPlatformLabelService.swift - Shows, checks and changes the platform label of FASTQ bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The logic behind `lungfish-cli fastq platform`. The app runs that command
/// and never writes the label itself, so every change has a provenance record.
///
/// A change rewrites only the FASTQ sidecar (`<fastq>.lungfish-meta.json`).
/// The reads are never touched.
public enum FASTQPlatformLabelService {

    public enum LabelError: Error, LocalizedError, Equatable {
        case notAFASTQBundle(String)
        case noPrimaryFASTQ(String)

        public var errorDescription: String? {
            switch self {
            case .notAFASTQBundle(let path):
                return "Not a .lungfishfastq bundle: \(path)"
            case .noPrimaryFASTQ(let path):
                return "The bundle holds no FASTQ file whose label can be read: \(path)"
            }
        }
    }

    /// The label of one bundle and what the reads show.
    public struct Report: Sendable, Equatable {
        public let bundleURL: URL
        public let fastqURL: URL
        public let check: PlatformLabelCheck
    }

    /// One label change.
    public struct Change: Sendable, Equatable {
        public let bundleURL: URL
        public let sidecarURL: URL
        public let previousPlatform: SequencingPlatform?
        public let previousReadType: FASTQAssemblyReadType?
        public let platform: SequencingPlatform?
        public let readType: FASTQAssemblyReadType?
        public let source: PlatformAssignment.Source
    }

    /// The FASTQ file whose sidecar holds the bundle's label.
    public static func labelledFASTQURL(forBundle bundleURL: URL) throws -> URL {
        guard FASTQBundle.isBundleURL(bundleURL) else {
            throw LabelError.notAFASTQBundle(bundleURL.path)
        }
        guard let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) else {
            throw LabelError.noPrimaryFASTQ(bundleURL.path)
        }
        return fastqURL
    }

    /// Reads the label of a bundle and checks it against its reads.
    public static func report(forBundle bundleURL: URL) throws -> Report {
        let fastqURL = try labelledFASTQURL(forBundle: bundleURL)
        let check = PlatformLabelCheck.check(fastqURL: fastqURL, metadata: FASTQMetadataStore.load(for: fastqURL))
        return Report(bundleURL: bundleURL, fastqURL: fastqURL, check: check)
    }

    /// Every FASTQ bundle under a folder (such as a project), sorted by path.
    public static func bundles(under folderURL: URL) -> [URL] {
        if FASTQBundle.isBundleURL(folderURL) { return [folderURL] }
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var bundles: [URL] = []
        for case let url as URL in enumerator where FASTQBundle.isBundleURL(url) {
            bundles.append(url.standardizedFileURL)
            enumerator.skipDescendants()
        }
        return bundles.sorted { $0.path < $1.path }
    }

    /// Derived bundles (subsets, trims, demultiplexed reads) in the same
    /// project whose root is `rootBundleURL`.
    public static func derivedBundles(ofRoot rootBundleURL: URL, searchingFrom folderURL: URL) -> [URL] {
        let root = rootBundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        return bundles(under: folderURL).filter { candidate in
            guard let manifest = FASTQBundle.loadDerivedManifest(in: candidate) else { return false }
            let resolved = FASTQBundle.resolveBundle(relativePath: manifest.rootBundleRelativePath, from: candidate)
            return resolved.standardizedFileURL.resolvingSymlinksInPath().path == root
        }
    }

    /// The read type a platform implies, or the one the reads show when they agree.
    public static func readType(
        for platform: SequencingPlatform,
        inference: PlatformInference?
    ) -> FASTQAssemblyReadType? {
        if let inference, inference.isActionable, inference.platform == platform, let readClass = inference.readClass {
            return readClass
        }
        return FASTQAssemblyReadType(sequencingPlatform: platform)
    }

    /// Writes a new label. `platform` nil keeps the recorded platform, and
    /// `readType` nil takes the read type the platform implies (or keeps the
    /// recorded one when no platform is given). `clearReadType` removes the
    /// recorded read type, so detection decides.
    @discardableResult
    public static func apply(
        toBundle bundleURL: URL,
        platform: SequencingPlatform?,
        readType: FASTQAssemblyReadType?,
        clearReadType: Bool = false,
        source: PlatformAssignment.Source,
        now: Date = Date()
    ) throws -> Change {
        let fastqURL = try labelledFASTQURL(forBundle: bundleURL)
        var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
        let previousPlatform = metadata.sequencingPlatform
        let previousReadType = metadata.assemblyReadType
        let newPlatform = platform ?? previousPlatform
        let inference = PlatformInference.infer(fromFASTQ: fastqURL)

        let newReadType: FASTQAssemblyReadType?
        if clearReadType {
            newReadType = nil
        } else if let readType {
            newReadType = readType
        } else if let platform {
            newReadType = Self.readType(for: platform, inference: inference)
        } else {
            newReadType = previousReadType
        }

        metadata.sequencingPlatform = newPlatform
        metadata.assemblyReadType = newReadType
        metadata.platformAssignment = PlatformAssignment(
            source: source,
            platform: newPlatform ?? .unknown,
            readClass: newReadType,
            vendorDetail: inference.vendorDetail,
            confidence: inference.confidence,
            evidence: inference.evidence,
            sampledRecords: inference.sampledRecords,
            detectorVersion: PlatformInference.detectorVersion,
            recordedAt: now
        )
        FASTQMetadataStore.save(metadata, for: fastqURL)
        return Change(
            bundleURL: bundleURL,
            sidecarURL: FASTQMetadataStore.metadataURL(for: fastqURL),
            previousPlatform: previousPlatform,
            previousReadType: previousReadType,
            platform: newPlatform,
            readType: newReadType,
            source: source
        )
    }
}
