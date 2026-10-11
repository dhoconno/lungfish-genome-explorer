// GenotypeAnnotationPairPublication.swift - The CLI genotype commands publish annotations.json and its record as one pair
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Publishes a CLI genotype command's `annotations.json` and its provenance record as one pair
/// (row B8, plan decision S1), through the coordinator the GUI annotation store uses.
///
/// `annotations.json` goes out through `DurableReplace` and the record through `ProvenanceWriter`,
/// inside one transaction under the bundle's publication lock, so the record keeps the writer's
/// bytes and signing and the pair shares one full flush. A failure before the transaction ends
/// puts `annotations.json` back and undoes the record, so a record never cites bytes the file does
/// not hold.
enum GenotypeAnnotationPairPublication {
    /// Restores an `annotations.json` that an interrupted ExFAT swap emptied, so the snapshot a
    /// writer reads under the lock is the file the app would show (docs/contracts/EXTERNAL-VOLUMES.md).
    static func restoreInterruptedSwap(inBundleAt bundleURL: URL) throws {
        try DurableReplace.recover(named: GenotypeAnnotationSidecar.filename, in: bundleURL)
    }

    /// Publishes `annotationData`, then runs `publishRecord`, which writes the record at
    /// `recordURL` beside it, inside the same transaction. `check` sees the snapshot the coordinator
    /// reads under the lock and refuses a stale one. A record that must be new never replaces a
    /// file, and a rollback removes it only once `publishRecord` returned.
    static func publish(
        annotationData: Data,
        recordURL: URL,
        recordMustBeNew: Bool,
        bundleURL: URL,
        assuming publicationLock: ONTGenotypeBundlePublicationLock,
        check: (GenotypeAnnotationPublicationSnapshot) throws -> Void,
        publishRecord: () throws -> Void
    ) throws {
        let coordinator = GenotypeAnnotationPublicationCoordinator(
            bundleURL: bundleURL,
            annotationFilename: GenotypeAnnotationSidecar.filename,
            provenanceFilename: recordURL.lastPathComponent,
            recordPublication: recordMustBeNew ? .alongsideNew : .alongside,
            faultInjector: nil
        )
        do {
            _ = try coordinator.transact(assuming: publicationLock, alongside: publishRecord) { snapshot in
                try check(snapshot)
                return GenotypeAnnotationPublicationPayload(annotationData: annotationData)
            }
        } catch let error as GenotypeAnnotationPublicationTransactionError {
            guard let rollbackError = error.rollbackError else { throw error.primaryError }
            throw ProvenancePublicationRollbackError(
                originalError: error.primaryError,
                rollbackError: rollbackError
            )
        }
    }

    /// The revision check. The snapshot must hold the bytes the command read before it built its
    /// edit, so an edit is never published over a file another writer changed. A file of a newer
    /// schema fails with the schema error first, as the sidecar writer always did.
    static func checkRevision(
        _ snapshot: GenotypeAnnotationPublicationSnapshot,
        expected: GenotypeAnnotationSidecarRevision
    ) throws {
        if let data = snapshot.annotationData {
            var current = try GenotypeAnnotationSidecar.decode(data)
            try current.promoteToCurrentSchema()
        }
        let actual = snapshot.annotationData.map { GenotypeAnnotationSidecarRevision.sha256(sha256Hex($0)) }
            ?? .absent
        guard actual == expected else {
            throw GenotypeAnnotationSidecarPublicationError.staleRevision(expected: expected, actual: actual)
        }
    }

    /// A descriptor of bytes the command holds in memory, so a record never re-reads a path that
    /// changes while the command runs.
    static func descriptor(data: Data, url: URL, role: FileRole) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: sha256Hex(data),
            fileSize: UInt64(data.count),
            format: .json,
            role: role
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
