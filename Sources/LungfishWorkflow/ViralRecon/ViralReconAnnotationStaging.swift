// ViralReconAnnotationStaging.swift - Hand viralrecon a GFF3 annotation under the .gff name its schema accepts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// nf-core/viralrecon 3.0.0 validates `--gff` against `^\S+\.gff(\.gz)?$`, so a
// path ending in `.gff3` fails parameter validation about 20 seconds into the
// run. Reference bundles carry their annotation as `genome/genes.gff3`, and
// the file a user picks is usually `.gff3` too. The content is GFF3 either
// way, which is what viralrecon reads, so only the name has to change.
//
// The annotation is copied into the run bundle under `inputs/reference/`
// with a `.gff` name, its bytes unchanged, and only the engine is pointed at
// the copy. The GUI launches viralrecon through `lungfish-cli workflow run
// nf-core/viralrecon`, whose launch staging (NFCoreLaunchStaging.stageAnnotation)
// calls `stage` before the run bundle is written, so the app and a direct CLI
// call get the same staging. The copy, its digest, the original path and the
// original's path inside its `.lungfishref` bundle are recorded in the run's
// provenance under `stagedAnnotation`.

import Foundation
import LungfishCore
import LungfishIO

/// A GFF3 annotation copied into a run bundle under a name viralrecon accepts.
public struct ViralReconStagedAnnotation: Sendable, Equatable {
    /// The file the caller named, such as `genome/genes.gff3` in a reference bundle.
    public let sourceURL: URL
    /// The copy the pipeline reads, under `inputs/reference/` in the run bundle.
    public let stagedURL: URL
    /// The `.lungfishref` bundle that holds the source, when there is one.
    public let sourceBundleURL: URL?
    /// The source's path inside `sourceBundleURL`, such as `genome/genes.gff3`.
    public let sourceBundleRelativePath: String?
    /// SHA-256 of the staged copy, which is also the source's digest.
    public let sha256: String

    public init(
        sourceURL: URL,
        stagedURL: URL,
        sourceBundleURL: URL?,
        sourceBundleRelativePath: String?,
        sha256: String
    ) {
        self.sourceURL = sourceURL
        self.stagedURL = stagedURL
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleRelativePath = sourceBundleRelativePath
        self.sha256 = sha256
    }

    /// One line for the run log.
    public var summary: String {
        let source: String
        if let sourceBundleURL, let sourceBundleRelativePath {
            source = "\(sourceBundleRelativePath) from \(sourceBundleURL.lastPathComponent)"
        } else {
            source = sourceURL.path
        }
        return "Staged the GFF3 annotation \(source) as \(stagedURL.path), "
            + "because viralrecon accepts --gff only as .gff or .gff.gz. The bytes are unchanged."
    }

    /// The provenance record, stored under ``ViralReconAnnotationStaging/provenanceKey``.
    public var provenanceValue: ParameterValue {
        var fields: [String: ParameterValue] = [
            "parameter": .string(ViralReconAnnotationStaging.parameterName),
            "source": .file(sourceURL),
            "staged": .file(stagedURL),
            "sha256": .string(sha256),
            "reason": .string("nf-core/viralrecon accepts --gff only as .gff or .gff.gz, so the GFF3 was copied under that name with its bytes unchanged"),
        ]
        if let sourceBundleURL {
            fields["sourceBundle"] = .file(sourceBundleURL)
        }
        if let sourceBundleRelativePath {
            fields["sourceBundleRelativePath"] = .string(sourceBundleRelativePath)
        }
        return .dictionary(fields)
    }
}

/// Gives viralrecon its GFF3 annotation under a `.gff` or `.gff.gz` name.
public enum ViralReconAnnotationStaging {
    /// The pipeline parameter that names the annotation.
    public static let parameterName = "gff"

    /// The provenance parameter that records a staging.
    public static let provenanceKey = "stagedAnnotation"

    /// Where staged annotations go, relative to the run bundle.
    public static let stagingDirectoryPath = "inputs/reference"

    public enum StagingError: Error, LocalizedError, Equatable {
        /// The annotation named by `--param gff` does not exist.
        case annotationNotFound(URL)
        /// The staged copy does not hash to the source's digest.
        case stagedCopyDiffers(source: URL, staged: URL)

        public var errorDescription: String? {
            switch self {
            case .annotationNotFound(let url):
                return "The GFF3 annotation \(url.path) does not exist."
            case .stagedCopyDiffers(let source, let staged):
                return "The staged annotation \(staged.path) is not a byte-for-byte copy of \(source.path)."
            }
        }
    }

    /// The name an annotation is staged under, or nil when none is needed.
    ///
    /// `genes.gff3` becomes `genes.gff` and `genes.gff3.gz` becomes
    /// `genes.gff.gz`, whatever the case of the extension. A name that already
    /// ends in `.gff` or `.gff.gz` needs nothing, and a name that is not a GFF
    /// name at all (`.gtf`, `.txt`) is left for the pipeline's own validation.
    public static func stagedFileName(for fileName: String) -> String? {
        if fileName.hasSuffix(".gff") || fileName.hasSuffix(".gff.gz") {
            return nil
        }
        let lowercased = fileName.lowercased()
        let renames: [(suffix: String, replacement: String)] = [
            (".gff3.gz", ".gff.gz"),
            (".gff3", ".gff"),
            (".gff.gz", ".gff.gz"),
            (".gff", ".gff"),
        ]
        for rename in renames where lowercased.hasSuffix(rename.suffix) {
            let base = String(fileName.dropLast(rename.suffix.count))
            return (base.isEmpty ? "annotation" : base) + rename.replacement
        }
        return nil
    }

    /// Copies the annotation `params` names into the run bundle when its name
    /// would fail viralrecon's `--gff` check.
    ///
    /// Returns nil, and writes nothing, when there is no `gff` parameter, when
    /// it is a URL rather than a local path, when its name already passes, or
    /// when the file already sits at the staged path. The parameters themselves
    /// are not changed. Pass the result to ``launchParams(_:using:)`` for the
    /// parameters the engine is given.
    public static func stage(
        params: [String: String],
        inRunBundle runBundleURL: URL,
        fileManager: FileManager = .default
    ) throws -> ViralReconStagedAnnotation? {
        guard let value = params[parameterName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("://") else {
            return nil
        }
        let sourceURL = URL(fileURLWithPath: value).standardizedFileURL
        guard let stagedName = stagedFileName(for: sourceURL.lastPathComponent) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StagingError.annotationNotFound(sourceURL)
        }

        let directory = runBundleURL.standardizedFileURL
            .appendingPathComponent(stagingDirectoryPath, isDirectory: true)
        let stagedURL = directory.appendingPathComponent(stagedName)
        // `genes.GFF` already sitting where `genes.gff` would go is the same
        // file on a case-insensitive volume, and replacing it would delete it.
        guard stagedURL.path.lowercased() != sourceURL.path.lowercased() else {
            return nil
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        try fileManager.copyItem(at: sourceURL, to: stagedURL)

        let stagedDigest = try FileDigest.sha256(of: stagedURL)
        guard try FileDigest.sha256(of: sourceURL) == stagedDigest else {
            throw StagingError.stagedCopyDiffers(source: sourceURL, staged: stagedURL)
        }

        let bundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: sourceURL)
        return ViralReconStagedAnnotation(
            sourceURL: sourceURL,
            stagedURL: stagedURL,
            sourceBundleURL: bundleURL,
            sourceBundleRelativePath: bundleURL.flatMap { relativePath(of: sourceURL, inside: $0) },
            sha256: stagedDigest
        )
    }

    /// The parameters the engine is launched with, with `gff` naming the
    /// staged copy. Unchanged when nothing was staged.
    public static func launchParams(
        _ params: [String: String],
        using staged: ViralReconStagedAnnotation?
    ) -> [String: String] {
        guard let staged else { return params }
        var launch = params
        launch[parameterName] = staged.stagedURL.path
        return launch
    }

    private static func relativePath(of fileURL: URL, inside bundleURL: URL) -> String? {
        let bundlePath = bundleURL.standardizedFileURL.path
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
