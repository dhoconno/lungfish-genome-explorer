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
//
// A reference bundle written by `fetch genome` keeps its annotation only in
// its annotation database. Without `--gff`, iVar merges no codons and
// viralrecon skips SnpEff and the variants long table. So when the caller
// names no `gff` and `fasta` lies in a `.lungfishref` bundle, the bundle's
// annotation database is exported as GFF3 into the same folder, as the app's
// iVar route exports it (ViralVariantCallingPipeline.exportBundleGFFIfAvailable),
// and recorded the same way. A bundle with no annotation gets a warning for
// the run log instead (Phase 2.10, V1-BIO ruling 3).

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
    /// SHA-256 of the staged copy, which is also the source's digest unless the copy was exported.
    public let sha256: String
    /// Whether the staged file was exported from the source bundle's annotation database, which is then
    /// ``sourceURL``, because the caller named no GFF3.
    public let exportedFromDatabase: Bool

    public init(
        sourceURL: URL,
        stagedURL: URL,
        sourceBundleURL: URL?,
        sourceBundleRelativePath: String?,
        sha256: String,
        exportedFromDatabase: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.stagedURL = stagedURL
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleRelativePath = sourceBundleRelativePath
        self.sha256 = sha256
        self.exportedFromDatabase = exportedFromDatabase
    }

    /// One line for the run log.
    public var summary: String {
        let source: String
        if let sourceBundleURL, let sourceBundleRelativePath {
            source = "\(sourceBundleRelativePath) from \(sourceBundleURL.lastPathComponent)"
        } else {
            source = sourceURL.path
        }
        if exportedFromDatabase {
            return "Exported the annotation database \(source) as \(stagedURL.path), because the reference bundle "
                + "holds no GFF3 file and viralrecon reads --gff for iVar's codon merge and SnpEff."
        }
        return "Staged the GFF3 annotation \(source) as \(stagedURL.path), "
            + "because viralrecon accepts --gff only as .gff or .gff.gz. The bytes are unchanged."
    }

    /// The provenance record, stored under ``ViralReconAnnotationStaging/provenanceKey``.
    public var provenanceValue: ParameterValue {
        let reason = exportedFromDatabase
            ? "The reference bundle holds no GFF3 file, so its annotation database was exported as GFF3 under a .gff name, as the iVar route exports it, for iVar's codon merge and SnpEff"
            : "nf-core/viralrecon accepts --gff only as .gff or .gff.gz, so the GFF3 was copied under that name with its bytes unchanged"
        var fields: [String: ParameterValue] = [
            "parameter": .string(ViralReconAnnotationStaging.parameterName),
            "source": .file(sourceURL),
            "staged": .file(stagedURL),
            "sha256": .string(sha256),
            "reason": .string(reason),
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
    /// With no `gff` parameter, exports the annotation database of the
    /// reference bundle that holds `fasta` instead, when it has one. Returns
    /// nil, and writes nothing, when there is neither, when `gff` is a URL
    /// rather than a local path, when its name already passes, or when the
    /// file already sits at the staged path. The parameters themselves are not
    /// changed. Pass the result to ``launchParams(_:using:)`` for the
    /// parameters the engine is given.
    public static func stage(
        params: [String: String],
        inRunBundle runBundleURL: URL,
        fileManager: FileManager = .default
    ) throws -> ViralReconStagedAnnotation? {
        guard let value = params[parameterName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return try exportBundleAnnotation(params: params, inRunBundle: runBundleURL, fileManager: fileManager)
        }
        guard !value.contains("://") else {
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

    /// A warning for the run log when the caller names no `gff` and the
    /// reference bundle that holds `fasta` has no annotation, so viralrecon
    /// runs without one. Nil otherwise.
    public static func missingAnnotationNotice(params: [String: String]) -> String? {
        guard case .missing(let bundleURL) = bundleAnnotation(for: params) else { return nil }
        return "The reference bundle \(bundleURL.lastPathComponent) has no annotation, so viralrecon runs without --gff. "
            + "iVar merges no codons, and SnpEff and the variants long table are skipped."
    }

    /// What the reference bundle that holds `fasta` offers a run that names no `gff`.
    enum BundleAnnotation: Equatable {
        /// The caller names a `gff`, or `fasta` names no local file in a reference bundle.
        case notApplicable
        /// The bundle's first annotation track has no database.
        case missing(bundle: URL)
        /// The database of the bundle's first annotation track, relative to the bundle.
        case database(bundle: URL, relativePath: String)
    }

    /// The parameter that names the reference FASTA.
    static let fastaParameterName = "fasta"

    /// Reads the bundle's first annotation track, as the iVar route does.
    static func bundleAnnotation(for params: [String: String]) -> BundleAnnotation {
        if let gff = params[parameterName]?.trimmingCharacters(in: .whitespacesAndNewlines), !gff.isEmpty {
            return .notApplicable
        }
        guard let fasta = params[fastaParameterName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fasta.isEmpty,
              !fasta.contains("://"),
              let bundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: URL(fileURLWithPath: fasta))
        else {
            return .notApplicable
        }
        guard let manifest = try? BundleManifest.load(from: bundleURL),
              let databasePath = manifest.annotations.first?.databasePath
        else {
            return .missing(bundle: bundleURL)
        }
        return .database(bundle: bundleURL, relativePath: databasePath)
    }

    /// Exports the annotation database of the reference bundle that holds
    /// `fasta` as GFF3 into the run bundle, under the database's name with
    /// `.gff`, when the caller names no `gff` and the bundle has one.
    private static func exportBundleAnnotation(
        params: [String: String],
        inRunBundle runBundleURL: URL,
        fileManager: FileManager
    ) throws -> ViralReconStagedAnnotation? {
        guard case .database(let bundleURL, let relativePath) = bundleAnnotation(for: params) else { return nil }
        let databaseURL = bundleURL.appendingPathComponent(relativePath).standardizedFileURL
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw StagingError.annotationNotFound(databaseURL)
        }
        let directory = runBundleURL.standardizedFileURL
            .appendingPathComponent(stagingDirectoryPath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagedURL = directory.appendingPathComponent(databaseURL.deletingPathExtension().lastPathComponent + ".gff")
        try AnnotationDatabaseGFFExporter.export(database: try AnnotationDatabase(url: databaseURL), to: stagedURL)
        return ViralReconStagedAnnotation(
            sourceURL: databaseURL,
            stagedURL: stagedURL,
            sourceBundleURL: bundleURL,
            sourceBundleRelativePath: relativePath,
            sha256: try FileDigest.sha256(of: stagedURL),
            exportedFromDatabase: true
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
