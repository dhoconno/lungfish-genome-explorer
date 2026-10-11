// AIHaplotypingRevisionPublisher+Record.swift - The reviewed annotations.json and the revision's record publish as one pair
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishIO

extension AIHaplotypingRevisionPublisher {
    /// Publishes the revision's record. With a reviewed sidecar, `annotations.json` and the record
    /// go out as one pair through the coordinator the GUI annotation store uses (row B8).
    ///
    /// The record is a new file in the new revision folder, so `provenanceWriter` writes it inside
    /// the coordinator's transaction once `annotations.json` holds the review, and both share one
    /// full flush. A failure there puts `annotations.json` back, and the caller's rollback removes
    /// the revision folder with whatever the writer left in it. The revision check runs again on
    /// the snapshot the coordinator reads under the lock.
    func publishRecord(
        _ envelope: ProvenanceEnvelope,
        at provenanceURL: URL,
        sidecarData: Data?,
        bundleURL: URL,
        expectedSidecarRevision: GenotypeAnnotationSidecarRevision,
        publicationLock: ONTGenotypeBundlePublicationLock
    ) throws {
        guard let sidecarData else {
            try provenanceWriter(envelope, provenanceURL)
            return
        }
        let coordinator = GenotypeAnnotationPublicationCoordinator(
            bundleURL: bundleURL,
            annotationFilename: GenotypeAnnotationSidecar.filename,
            provenanceFilename: nil,
            faultInjector: nil
        )
        do {
            _ = try coordinator.transact(
                assuming: publicationLock,
                alongside: { try provenanceWriter(envelope, provenanceURL) }
            ) { snapshot in
                let actual = snapshot.annotationData.map { data in
                    GenotypeAnnotationSidecarRevision.sha256(
                        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    )
                } ?? .absent
                guard actual == expectedSidecarRevision else {
                    throw GenotypeAnnotationSidecarPublicationError.staleRevision(
                        expected: expectedSidecarRevision,
                        actual: actual
                    )
                }
                return GenotypeAnnotationPublicationPayload(annotationData: sidecarData)
            }
        } catch let error as GenotypeAnnotationPublicationTransactionError {
            guard let rollbackError = error.rollbackError else { throw error.primaryError }
            throw ProvenancePublicationRollbackError(
                originalError: error.primaryError,
                rollbackError: rollbackError
            )
        }
    }
}
