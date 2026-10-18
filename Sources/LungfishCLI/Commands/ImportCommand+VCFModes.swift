// ImportCommand+VCFModes.swift - The fresh, resume and materialize attaches of import vcf and their record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// What the record of one `import vcf` attach describes.
struct VCFAttachFacts: Sendable {
    let request: VCFBundleVariantImport.Request
    let trackInfo: VariantTrackInfo
    let variantCount: Int
    /// The published database path (`variants/<track>.db` inside the bundle).
    let databaseURL: URL
    /// The manifest as it was before this track was added.
    let originalManifest: BundleManifest
    /// The track's database as it was before `--resume` or `--materialize` finished it, an input of that run.
    let priorDatabase: ProvenanceFileDescriptor?
}

/// What the command prints once the attach published the track.
struct VCFAttachSummary: Sendable {
    let trackInfo: VariantTrackInfo
    let variantCount: Int
    let renamedChromosomes: Int
    let cleanupWarning: String?
}

extension ImportCommand.VCFSubcommand {
    typealias AttachSummary = VCFAttachSummary

    /// Builds the track in `mode`. A fresh attach is `VCFBundleVariantImport.attachInProcess`. `--resume` and
    /// `--materialize` finish the `--replace` track's own database, as the app's `--vcf-resume-helper` and
    /// `--vcf-materialize-helper` modes did, then run the same reconciliation, finalization and publication.
    static func attach(
        _ request: VCFBundleVariantImport.Request,
        mode: AttachMode,
        progressHandler: @escaping @Sendable (Double, String) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool,
        makeProvenance: (VCFAttachFacts) throws -> ProvenanceEnvelope
    ) throws -> VCFAttachSummary {
        guard mode != .fresh else {
            let result = try VCFBundleVariantImport.attachInProcess(
                request, progressHandler: progressHandler, shouldCancel: shouldCancel
            ) { context in
                try makeProvenance(VCFAttachFacts(
                    request: context.request, trackInfo: context.trackInfo, variantCount: context.variantCount,
                    databaseURL: context.databaseURL, originalManifest: context.originalManifest, priorDatabase: nil
                ))
            }
            return VCFAttachSummary(
                trackInfo: result.trackInfo, variantCount: result.variantCount,
                renamedChromosomes: result.chromosomeMapping.count, cleanupWarning: result.cleanupWarning
            )
        }
        guard let replaceTrackID = request.replaceTrackID else {
            throw AttachRefusal(errorDescription: "--\(mode.rawValue) finishes the import of an existing track. Name the track with --replace <track-id>.")
        }
        let vcfURL = request.vcfURL
        let bundleURL = request.bundleURL
        let initialManifest = try BundleManifest.load(from: bundleURL)
        let trackID = try VCFBundleVariantImport.resolveTrackID(
            forVCFURL: vcfURL, in: initialManifest, bundleURL: bundleURL, replacing: replaceTrackID)
        let replacedTrack = initialManifest.variants.first { $0.id == trackID }
        let dbFilename = VCFBundleVariantImport.databaseFilename(trackID: trackID)
        let variantsDir = bundleURL.appendingPathComponent("variants")
        let finalDBURL = variantsDir.appendingPathComponent(dbFilename)
        let provenanceURL = bundleURL.appendingPathComponent(VCFBundleVariantImport.provenanceRelativePath(trackID: trackID))

        let staging = try OperationImportStaging(parentDirectory: variantsDir, operationID: request.operationID)
        do {
            let databasePublication = try staging.prepareSQLiteCopy(filename: dbFilename, from: finalDBURL)
            let dbURL = databasePublication.stagedURL
            try requireFinishable(mode, databaseURL: dbURL, trackID: trackID)
            let priorDatabase = try ProvenanceFileDescriptor.file(url: finalDBURL, format: .unknown, role: .input)
            if shouldCancel() { throw VariantDatabaseError.cancelled }

            let variantCount: Int
            if mode == .resume {
                variantCount = try VariantDatabase.resumeImport(
                    existingDBURL: dbURL, progressHandler: progressHandler, shouldCancel: shouldCancel)
            } else {
                variantCount = try VariantDatabase(url: dbURL).totalCount()
                _ = try VariantDatabase.materializeVariantInfo(
                    existingDBURL: dbURL, progressHandler: progressHandler, shouldCancel: shouldCancel)
            }
            if shouldCancel() { throw VariantDatabaseError.cancelled }

            let manifestForChromosomes = try BundleManifest.load(from: bundleURL)
            var rwDB: VariantDatabase? = try VariantDatabase(url: dbURL, readWrite: true)
            let mapping = try VCFBundleVariantImport.normalizeChromosomes(in: rwDB!, toBundle: manifestForChromosomes)
            if shouldCancel() { throw VariantDatabaseError.cancelled }
            if rwDB!.variantInfoSkipped {
                _ = try VariantDatabase.materializeVariantInfo(
                    existingDBURL: dbURL, progressHandler: progressHandler, shouldCancel: shouldCancel)
            }

            let trackInfo = VCFBundleVariantImport.makeTrackInfo(
                trackID: trackID, vcfURL: vcfURL,
                trackName: request.trackName ?? replacedTrack?.name,
                variantCount: variantCount)
            // Capture file ownership before reading the manifest the replacement is built from.
            let filePublication = try VCFBundleVariantImport.makeFilePublication(bundleURL: bundleURL, trackID: trackID)
            var filePublicationTransferred = false
            defer { if !filePublicationTransferred { filePublication.commit() } }
            let currentManifest = try BundleManifest.load(from: bundleURL)
            let updatedManifest = currentManifest.replacingVariantTrack(trackInfo)
            try rwDB!.setMetadataValues(VCFBundleVariantImport.finalizationMetadata(
                trackID: trackID, vcfURL: vcfURL, importProfile: request.importProfile))
            // Release the private writer before the coherent final snapshot.
            rwDB = nil
            if shouldCancel() { throw VariantDatabaseError.cancelled }

            let facts = VCFAttachFacts(
                request: request, trackInfo: trackInfo, variantCount: variantCount, databaseURL: finalDBURL,
                originalManifest: currentManifest, priorDatabase: priorDatabase)
            filePublicationTransferred = true
            try VCFBundleVariantImport.publish(
                databasePublication: databasePublication,
                bundleURL: bundleURL,
                provenanceURL: provenanceURL,
                updatedManifest: updatedManifest,
                filePublication: filePublication,
                shouldCancel: shouldCancel
            ) { writer in
                _ = try writer.write(try makeProvenance(facts), toSidecar: provenanceURL)
            }
            return VCFAttachSummary(
                trackInfo: trackInfo, variantCount: variantCount, renamedChromosomes: mapping.count,
                cleanupWarning: staging.finishCommittedImport())
        } catch {
            if !(error is OperationImportStaging.RecoveryRequired) && !(error is ScientificPublicationRecoveryRequired) {
                try? staging.cleanup()
            }
            throw error
        }
    }

    /// Refuses a database that `mode` cannot finish, before anything is changed.
    static func requireFinishable(_ mode: AttachMode, databaseURL: URL, trackID: String) throws {
        let state = VariantDatabase.importState(at: databaseURL) ?? "none"
        switch mode {
        case .fresh:
            return
        case .resume:
            guard state == "indexing" else {
                throw AttachRefusal(errorDescription: "--resume finishes an import that stopped before its index build, "
                    + "and the database of track '\(trackID)' is at import state '\(state)'. Import the VCF without --resume.")
            }
        case .materialize:
            let unfinished = VariantDatabase.metadataValue(at: databaseURL, key: "materialize_state") == "materializing"
                || VariantDatabase.metadataValue(at: databaseURL, key: "skip_variant_info") == "true"
            guard state == "complete", unfinished else {
                throw AttachRefusal(errorDescription: "--materialize fills the INFO table of a finished import whose INFO was "
                    + "skipped or stopped, and the database of track '\(trackID)' is at import state '\(state)' with "
                    + "\(unfinished ? "its INFO unfinished" : "its INFO complete"). Import the VCF without --materialize.")
            }
        }
    }
}
