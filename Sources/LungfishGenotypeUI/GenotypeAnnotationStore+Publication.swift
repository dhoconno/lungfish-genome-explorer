import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension GenotypeAnnotationStore {
    func transactAnnotationPublication(
        _ prepare: (GenotypeAnnotationPublicationSnapshot) throws -> GenotypeAnnotationPublicationPayload?
    ) throws -> GenotypeAnnotationPublicationPayload? {
        return try annotationPublicationCoordinator().transact(prepare: prepare)
    }

    /// Publishes the whole sidecar the analyst sees in one write, with the derived id of each smart cohort
    /// that stores none (plan decision G2). The built-in smart cohorts that are only in memory go out with
    /// the edit, because the file is checked against `lastPersistedSidecar` and not against `sidecar`.
    func persist(action: String, editContext: ProvenanceEditContext? = nil) throws {
        guard !isReadOnly else { return }
        let runClock = ProvenanceRunClock()
        var desiredSidecar = sidecar.storingSmartCohortIDs()
        do {
            try desiredSidecar.promoteToCurrentSchema()
        } catch {
            adoptPersisted(lastPersistedSidecar)
            throw error
        }
        var latestForRollback = lastPersistedSidecar
        do {
            _ = try transactAnnotationPublication { snapshot in
                var latest = try decodedLatestSidecar(from: snapshot.annotationData)
                latestForRollback = latest
                guard latest == lastPersistedSidecar else {
                    throw GenotypeAnnotationStorePersistenceError.staleRevision
                }
                try latest.promoteToCurrentSchema()
                return try annotationPublicationPayload(
                    sidecar: desiredSidecar,
                    action: action,
                    editContext: editContext,
                    snapshot: snapshot,
                    startedAt: runClock.startedAt,
                    endedAt: runClock.now
                )
            }
            sidecar = desiredSidecar
            lastPersistedSidecar = desiredSidecar
            unsavedBuiltInSmartCohorts = []
        } catch {
            adoptPersisted(latestForRollback)
            throw error
        }
    }

    private func annotationPublicationCoordinator() -> GenotypeAnnotationPublicationCoordinator {
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        return GenotypeAnnotationPublicationCoordinator(
            bundleURL: bundleURL,
            annotationFilename: annotationURL.lastPathComponent,
            provenanceFilename: ProvenanceRecorder.fileSidecarURL(for: annotationURL).lastPathComponent,
            faultInjector: publicationFaultInjector
        )
    }
}
