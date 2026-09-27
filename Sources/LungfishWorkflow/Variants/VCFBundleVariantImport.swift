// VCFBundleVariantImport.swift - Shared core for attaching a VCF to a .lungfishref bundle's variant database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The bundle-facing contract of a VCF import into an existing `.lungfishref`
/// bundle: how the track is named, which `createFromVCF` parameters build
/// `variants/<track>.db`, how chromosome names are reconciled with the bundle,
/// which metadata the database carries, and how the database, provenance
/// sidecar and manifest are published together.
///
/// FEA-12: the GUI Import Center (`performVCFImport`, which builds the database
/// out of process through `--vcf-import-helper`) and `lungfish-cli import vcf
/// <path> --output-dir <bundle.lungfishref>` (which builds it in process through
/// `attachInProcess`) both call these functions, so the two entry points cannot
/// drift apart on anything that lands in the bundle.
public enum VCFBundleVariantImport {

    // MARK: - Naming

    /// Base track identifier: the file name with a trailing `.gz` and then
    /// `.vcf` removed (`calls.vcf.gz` becomes `calls`). Two VCFs with the
    /// same file name share this base, so an import into a bundle must use
    /// ``resolveTrackID(forVCFURL:in:bundleURL:replacing:)``, which keeps
    /// the id unique; this base alone is only the first candidate.
    public static func trackID(forVCFURL vcfURL: URL) -> String {
        var base = vcfURL
        if base.pathExtension.lowercased() == "gz" {
            base = base.deletingPathExtension()
        }
        if base.pathExtension.lowercased() == "vcf" {
            base = base.deletingPathExtension()
        }
        return base.lastPathComponent
    }

    /// The track id an import into `manifest` will publish under.
    ///
    /// Without `replacing`, the id is ``trackID(forVCFURL:)`` when nothing
    /// in the bundle uses it, else the first free `<base>-2`, `<base>-3`, ...
    /// so importing a second `calls.vcf.gz` adds a second track instead of
    /// silently replacing the first one's database, provenance sidecar and
    /// manifest entry. "Used" means a manifest variant track with that id,
    /// or a `variants/<id>.db` or `variants/<id>.lungfish-provenance.json`
    /// already on disk (a track removed from the manifest whose files were
    /// kept must not be overwritten either).
    ///
    /// With `replacing`, the caller asked for that exact track to be
    /// replaced (`lungfish-cli import vcf --replace <track-id>`, or the
    /// Import Center confirmation naming the track); the id must belong to
    /// an existing variant track or ``Error/replaceTargetNotFound(trackID:available:)``
    /// is thrown.
    public static func resolveTrackID(
        forVCFURL vcfURL: URL,
        in manifest: BundleManifest,
        bundleURL: URL,
        replacing replaceTrackID: String? = nil
    ) throws -> String {
        let existingIDs = manifest.variants.map(\.id)
        if let replaceTrackID {
            let trimmed = replaceTrackID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard existingIDs.contains(trimmed) else {
                throw Error.replaceTargetNotFound(trackID: trimmed, available: existingIDs)
            }
            return trimmed
        }
        let base = trackID(forVCFURL: vcfURL)
        let fileManager = FileManager.default
        func isTaken(_ candidate: String) -> Bool {
            if existingIDs.contains(candidate) { return true }
            let databaseURL = bundleURL.appendingPathComponent(databaseRelativePath(trackID: candidate))
            let provenanceURL = bundleURL.appendingPathComponent(provenanceRelativePath(trackID: candidate))
            return fileManager.fileExists(atPath: databaseURL.path)
                || fileManager.fileExists(atPath: provenanceURL.path)
        }
        if !isTaken(base) { return base }
        var suffix = 2
        while isTaken("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// The manifest track a same-named import would collide with, so a front
    /// end can offer "replace `<name>`" by id instead of guessing.
    public static func existingTrack(forVCFURL vcfURL: URL, in manifest: BundleManifest) -> VariantTrackInfo? {
        let base = trackID(forVCFURL: vcfURL)
        return manifest.variants.first { $0.id == base }
    }

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        /// `--replace <track-id>` named a track the bundle does not have.
        case replaceTargetNotFound(trackID: String, available: [String])

        public var errorDescription: String? {
            switch self {
            case .replaceTargetNotFound(let trackID, let available):
                let list = available.isEmpty
                    ? "the bundle has no variant tracks"
                    : "existing track ids: \(available.joined(separator: ", "))"
                return "No variant track with id '\(trackID)' to replace (\(list))."
            }
        }
    }

    /// Default display name: the file name with only its last extension removed.
    /// This keeps the historical GUI behaviour (`calls.vcf.gz` is shown as `calls.vcf`).
    public static func defaultTrackName(forVCFURL vcfURL: URL) -> String {
        vcfURL.deletingPathExtension().lastPathComponent
    }

    public static func databaseFilename(trackID: String) -> String { "\(trackID).db" }
    public static func databaseRelativePath(trackID: String) -> String { "variants/\(databaseFilename(trackID: trackID))" }
    public static func provenanceRelativePath(trackID: String) -> String { "variants/\(trackID).lungfish-provenance.json" }

    // MARK: - Database construction

    /// Builds (or rebuilds) the variant database for one VCF, or one chromosome
    /// of it, with the exact parameters the import helper has always used.
    /// Indexes are deferred, so the database may be left with
    /// `import_state == "indexing"`; callers finish it with
    /// `VariantDatabase.resumeImport(existingDBURL:)`.
    public static func createDatabase(
        vcfURL: URL,
        outputDBURL: URL,
        sourceFile: String,
        importProfile: VCFImportProfile,
        onlyChromosome: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> Int {
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: outputDBURL,
            parseGenotypes: true,
            sourceFile: sourceFile,
            progressHandler: progressHandler,
            shouldCancel: shouldCancel,
            importProfile: importProfile,
            deferIndexBuild: true,
            partitionByChromosome: false,
            onlyChromosome: onlyChromosome
        )
    }

    /// Renames VCF chromosomes to the bundle's names (aliases, `chr` prefix,
    /// version suffix). Length-based matching stays with the runtime alias map.
    @discardableResult
    public static func normalizeChromosomes(
        in database: VariantDatabase,
        toBundle manifest: BundleManifest
    ) throws -> [String: String] {
        let mapping = mapVCFChromosomes(
            database.allChromosomes(),
            toBundleChromosomes: manifest.genome?.chromosomes ?? []
        )
        if !mapping.isEmpty {
            try database.renameChromosomes(mapping)
        }
        return mapping
    }

    // MARK: - Manifest and metadata

    /// The imported variants live only in `variants/<track>.db`, so the
    /// track's `path` names that database and it carries no index file.
    /// Bundles written before this recorded a `variants/<track>.bcf` and
    /// `.bcf.csi` placeholder pair that never existed on disk, which made
    /// `bundle validate --check-integrity` fail on every imported VCF; those
    /// manifests still load, and ``isDatabaseBackedTrack(_:)`` recognises
    /// both spellings.
    public static func makeTrackInfo(
        trackID: String,
        vcfURL: URL,
        trackName: String? = nil,
        variantCount: Int
    ) -> VariantTrackInfo {
        VariantTrackInfo(
            id: trackID,
            name: trackName ?? defaultTrackName(forVCFURL: vcfURL),
            description: "Imported from \(vcfURL.lastPathComponent)",
            path: databaseRelativePath(trackID: trackID),
            indexPath: "",
            databasePath: databaseRelativePath(trackID: trackID),
            variantType: .mixed,
            variantCount: variantCount,
            source: "VCF Import"
        )
    }

    /// True when the track's variants are served from its SQLite database:
    /// every VCF import (CLI, Import Center, auto-ingest). For such a track
    /// `path` is either the database itself or a legacy `.bcf` placeholder
    /// that was never written, so readers must not require a variant file
    /// beside the database.
    public static func isDatabaseBackedTrack(_ track: VariantTrackInfo) -> Bool {
        guard let databasePath = track.databasePath else { return false }
        return !databasePath.isEmpty
    }

    /// The manifest fields that name a real file for `track`: the database
    /// for a database-backed track (plus `path`/`indexPath` when they are
    /// distinct files that exist), otherwise `path` and `indexPath`.
    public static func requiredFiles(for track: VariantTrackInfo) -> [(field: String, relativePath: String)] {
        var files: [(field: String, relativePath: String)] = []
        if isDatabaseBackedTrack(track), let databasePath = track.databasePath {
            files.append(("database_path", databasePath))
            return files
        }
        if !track.path.isEmpty { files.append(("path", track.path)) }
        if !track.indexPath.isEmpty { files.append(("index_path", track.indexPath)) }
        return files
    }

    public static func finalizationMetadata(
        trackID: String,
        vcfURL: URL,
        importProfile: VCFImportProfile,
        createdAt: Date = Date()
    ) -> [String: String] {
        [
            "workflow_provenance_path": provenanceRelativePath(trackID: trackID),
            "artifact_database_path": databaseRelativePath(trackID: trackID),
            "source_vcf_path": vcfURL.path,
            "source_vcf_name": vcfURL.lastPathComponent,
            "import_profile": importProfile.rawValue,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
        ]
    }

    /// Protects the manifest and the provenance sidecar artifacts for one track.
    public static func makeFilePublication(bundleURL: URL, trackID: String) throws -> ScientificFilePublicationTransaction {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let provenanceURL = bundleURL.appendingPathComponent(provenanceRelativePath(trackID: trackID))
        let protected = [manifestURL] + ProvenancePublicationArtifacts.sidecarArtifacts(for: provenanceURL)
        return try ScientificFilePublicationTransaction(protectedURLs: protected, fileDestinations: protected)
    }

    // MARK: - Publication

    /// Final publication boundary: the staged database replaces the bundle's
    /// database, then the provenance sidecar and the manifest are published.
    /// Any failure restores the previous database and files, or throws
    /// `OperationImportStaging.RecoveryRequired` naming what was retained.
    public static func publish(
        databasePublication: OperationImportStaging.SQLitePublication,
        bundleURL: URL,
        provenanceURL: URL,
        updatedManifest: BundleManifest,
        filePublication: ScientificFilePublicationTransaction? = nil,
        shouldCancel: () -> Bool = { false },
        provenanceWriter: ProvenanceWriter = ProvenanceWriter(signingProvider: nil),
        writeProvenance: (ProvenanceWriter) throws -> Void
    ) throws {
        let stagingDirectory = databasePublication.staging.directory
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let files = try filePublication ?? ScientificFilePublicationTransaction(
            protectedURLs: [manifestURL] + ProvenancePublicationArtifacts.sidecarArtifacts(for: provenanceURL),
            fileDestinations: [manifestURL] + ProvenancePublicationArtifacts.sidecarArtifacts(for: provenanceURL)
        )
        let observedWriter = provenanceWriter.observingPublications { try files.observe($0) }
        do {
            // Validate the captured manifest generation before changing the DB,
            // not only when rollback becomes necessary.
            try files.validateCurrentOwnership()
            let manifestDirectory = stagingDirectory.appendingPathComponent("manifest-publication", isDirectory: true)
            try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
            try updatedManifest.save(to: manifestDirectory)
            try databasePublication.publish(beforeRollback: { try files.validateCurrentOwnership() }) {
                if shouldCancel() { throw VariantDatabaseError.cancelled }
                try writeProvenance(observedWriter)
                if shouldCancel() { throw VariantDatabaseError.cancelled }
                try files.publish(stagedURL: manifestDirectory.appendingPathComponent(BundleManifest.filename), to: manifestURL)
                if shouldCancel() { throw VariantDatabaseError.cancelled }
            }
            files.commit()
        } catch let recovery as OperationImportStaging.RecoveryRequired {
            // The database is still current or its restoration is uncertain.
            // Preserve its matching files and both recovery owners together.
            throw recovery.retainingRecoveryURLs([files.recoveryDirectoryURL] + files.displacedArtifactURLs)
        } catch {
            let original = error
            do { try files.rollback(after: original) }
            catch let recovery as ScientificPublicationRecoveryRequired {
                throw OperationImportStaging.RecoveryRequired(directory: stagingDirectory,
                    originalError: original, restorationError: recovery, additionalRecoveryURLs: recovery.recoveryURLs)
            }
        }
    }

    // MARK: - In-process attach (CLI)

    public struct Request: Sendable {
        public let vcfURL: URL
        public let bundleURL: URL
        public let trackName: String?
        public let importProfile: VCFImportProfile
        public let operationID: UUID
        /// The id of an existing variant track this import replaces. `nil`
        /// (the default) adds a new track under a unique id; see
        /// ``resolveTrackID(forVCFURL:in:bundleURL:replacing:)``.
        public let replaceTrackID: String?

        public init(vcfURL: URL, bundleURL: URL, trackName: String? = nil,
                    importProfile: VCFImportProfile = .auto, operationID: UUID = UUID(),
                    replaceTrackID: String? = nil) {
            self.vcfURL = vcfURL
            self.bundleURL = bundleURL
            self.trackName = trackName
            self.importProfile = importProfile
            self.operationID = operationID
            self.replaceTrackID = replaceTrackID
        }
    }

    /// What a caller needs to describe the run in its provenance envelope.
    public struct ProvenanceContext: Sendable {
        public let request: Request
        public let trackInfo: VariantTrackInfo
        public let variantCount: Int
        /// The published database path (`variants/<track>.db` inside the bundle).
        public let databaseURL: URL
        public let provenanceURL: URL
        /// The manifest as it was before this track was added.
        public let originalManifest: BundleManifest
    }

    public struct Result: Sendable {
        public let trackInfo: VariantTrackInfo
        public let variantCount: Int
        public let databaseURL: URL
        public let provenanceURL: URL
        public let chromosomeMapping: [String: String]
        public let cleanupWarning: String?
    }

    /// Attaches a VCF to an existing bundle in this process. This is the same
    /// sequence the GUI runs through its helper processes (fresh import,
    /// phase-2 index build, chromosome reconciliation, INFO materialization,
    /// metadata, publication), without the GUI's crash-resume branches: every
    /// call stages a private copy under `variants/.import-<operationID>/`.
    public static func attachInProcess(
        _ request: Request,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        makeProvenance: (ProvenanceContext) throws -> ProvenanceEnvelope
    ) throws -> Result {
        let vcfURL = request.vcfURL
        let bundleURL = request.bundleURL
        // Decide the id against the manifest before any staging: a second
        // `calls.vcf.gz` must land as `calls-2`, and `--replace` must name a
        // track that exists, before a database is built.
        let initialManifest = try BundleManifest.load(from: bundleURL)
        let trackID = try resolveTrackID(
            forVCFURL: vcfURL, in: initialManifest, bundleURL: bundleURL, replacing: request.replaceTrackID)
        let replacedTrack = request.replaceTrackID == nil
            ? nil
            : initialManifest.variants.first { $0.id == trackID }
        let dbFilename = databaseFilename(trackID: trackID)
        let variantsDir = bundleURL.appendingPathComponent("variants")
        let finalDBURL = variantsDir.appendingPathComponent(dbFilename)
        let provenanceURL = bundleURL.appendingPathComponent(provenanceRelativePath(trackID: trackID))

        let staging = try OperationImportStaging(parentDirectory: variantsDir, operationID: request.operationID)
        do {
            let databasePublication = try staging.prepareSQLiteCopy(filename: dbFilename, from: finalDBURL)
            let dbURL = databasePublication.stagedURL
            if shouldCancel() { throw VariantDatabaseError.cancelled }
            if FileManager.default.fileExists(atPath: dbURL.path) {
                try FileManager.default.removeItem(at: dbURL)
            }

            var variantCount = try createDatabase(
                vcfURL: vcfURL,
                outputDBURL: dbURL,
                sourceFile: vcfURL.lastPathComponent,
                importProfile: request.importProfile,
                progressHandler: progressHandler,
                shouldCancel: shouldCancel
            )
            if VariantDatabase.importState(at: dbURL) == "indexing" {
                variantCount = try VariantDatabase.resumeImport(
                    existingDBURL: dbURL, progressHandler: progressHandler, shouldCancel: shouldCancel)
            }
            if shouldCancel() { throw VariantDatabaseError.cancelled }

            let manifestForChromosomes = try BundleManifest.load(from: bundleURL)
            var rwDB: VariantDatabase? = try VariantDatabase(url: dbURL, readWrite: true)
            let mapping = try normalizeChromosomes(in: rwDB!, toBundle: manifestForChromosomes)
            if shouldCancel() { throw VariantDatabaseError.cancelled }
            if rwDB!.variantInfoSkipped {
                _ = try VariantDatabase.materializeVariantInfo(
                    existingDBURL: dbURL, progressHandler: progressHandler, shouldCancel: shouldCancel)
            }

            // A replacement keeps the replaced track's display name unless
            // the caller renamed it; a new track takes the file-derived name.
            let trackInfo = makeTrackInfo(
                trackID: trackID, vcfURL: vcfURL,
                trackName: request.trackName ?? replacedTrack?.name,
                variantCount: variantCount)
            // Capture file ownership before reading the manifest the
            // replacement is built from.
            let filePublication = try makeFilePublication(bundleURL: bundleURL, trackID: trackID)
            var filePublicationTransferred = false
            defer { if !filePublicationTransferred { filePublication.commit() } }
            let currentManifest = try BundleManifest.load(from: bundleURL)
            let updatedManifest = currentManifest.replacingVariantTrack(trackInfo)

            try rwDB!.setMetadataValues(finalizationMetadata(
                trackID: trackID, vcfURL: vcfURL, importProfile: request.importProfile))
            // Release the private writer before the coherent final snapshot.
            rwDB = nil
            if shouldCancel() { throw VariantDatabaseError.cancelled }

            let context = ProvenanceContext(
                request: request, trackInfo: trackInfo, variantCount: variantCount,
                databaseURL: finalDBURL, provenanceURL: provenanceURL, originalManifest: currentManifest)
            filePublicationTransferred = true
            try publish(
                databasePublication: databasePublication,
                bundleURL: bundleURL,
                provenanceURL: provenanceURL,
                updatedManifest: updatedManifest,
                filePublication: filePublication,
                shouldCancel: shouldCancel
            ) { writer in
                _ = try writer.write(try makeProvenance(context), toSidecar: provenanceURL)
            }
            return Result(
                trackInfo: trackInfo, variantCount: variantCount, databaseURL: finalDBURL,
                provenanceURL: provenanceURL, chromosomeMapping: mapping,
                cleanupWarning: staging.finishCommittedImport())
        } catch {
            if !(error is OperationImportStaging.RecoveryRequired) && !(error is ScientificPublicationRecoveryRequired) {
                try? staging.cleanup()
            }
            throw error
        }
    }
}
