import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// A deleted built-in smart cohort stays deleted (plan decision S13). The
/// deletion is recorded in the sidecar settings as a dismissal, which opening
/// reads, so the cohort is not shown from memory again. A sidecar without the
/// field decodes as no dismissals. Restore Built-In Cohorts empties the
/// dismissals and brings the cohorts back with its own recorded edit, and the
/// record of the edit that first writes the built-ins names the cohorts it
/// seeds. An analyst's own cohort with a built-in's name is never replaced.
/// `genotype list-cohorts` and `genotype export-labkey` read the file, which
/// no longer holds a dismissed cohort, so they need no change.
extension GenotypeAnnotationStore {
    /// The built-in cohorts a sidecar shows from memory, the ones it neither
    /// holds nor dismissed.
    static func builtInSmartCohortsToSeed(into sidecar: GenotypeAnnotationSidecar) -> [GenotypeCohortSmartFilter] {
        let dismissed = Set(sidecar.settings.dismissedBuiltInSmartCohorts ?? [])
        return builtInSmartCohorts.filter { !dismissed.contains($0.name) && !holds($0, in: sidecar) }
    }

    /// Whether `sidecar` holds `builtIn`, under its name or, renamed, under its
    /// fixed id (plan decision G2), so no id is stored twice in one sidecar.
    private static func holds(_ builtIn: GenotypeCohortSmartFilter, in sidecar: GenotypeAnnotationSidecar) -> Bool {
        sidecar.smartCohorts.contains { $0.name == builtIn.name || ($0.id != nil && $0.id == builtIn.id) }
    }

    /// Whether a cohort has the name and scope of a built-in cohort.
    static func isBuiltInSmartCohort(_ cohort: GenotypeCohortSmartFilter) -> Bool {
        builtInSmartCohorts.contains { $0.name == cohort.name && $0.scope == cohort.scope }
    }

    /// Records the deletion of a cohort with a built-in's name and scope, so
    /// opening never shows that built-in again. An analyst's own cohort under
    /// that name counts too, because a deletion should stick either way.
    static func recordDismissal(of cohort: GenotypeCohortSmartFilter, in settings: inout GenotypeAnnotationSidecar.Settings) {
        guard isBuiltInSmartCohort(cohort) else { return }
        var names = settings.dismissedBuiltInSmartCohorts ?? []
        guard !names.contains(cohort.name) else { return }
        names.append(cohort.name)
        settings.dismissedBuiltInSmartCohorts = names
    }

    /// The record option naming the built-in cohorts that `sidecar`, as it is
    /// published, writes to the bundle for the first time. Empty for an edit
    /// that writes none, such as a replayed edit, which starts from the file.
    nonisolated static func seededBuiltInSmartCohortOptions(
        _ unsavedBuiltInSmartCohorts: [GenotypeCohortSmartFilter],
        publishing sidecar: GenotypeAnnotationSidecar
    ) -> [String: ParameterValue] {
        let seeded = unsavedBuiltInSmartCohorts.filter { sidecar.smartCohorts.contains($0) }
        guard !seeded.isEmpty else { return [:] }
        return ["seededBuiltInSmartCohorts": .array(seeded.map { .string($0.name) })]
    }

    /// Whether Restore Built-In Cohorts would change anything.
    var canRestoreBuiltInSmartCohorts: Bool {
        sidecar.settings.dismissedBuiltInSmartCohorts?.isEmpty == false
            || !Self.builtInSmartCohortsMissing(from: sidecar).isEmpty
    }

    /// Brings back every built-in cohort the sidecar lacks and empties the
    /// dismissals, as its own recorded edit. The restored cohorts follow the
    /// analyst's own, and a cohort the sidecar holds under a built-in's name or id
    /// stays as it is.
    ///
    /// - Returns: The names it brought back. When there is nothing to restore
    ///   it writes nothing.
    @discardableResult
    func restoreBuiltInSmartCohorts(author editAuthor: String? = nil) async throws -> [String] {
        return try await publicationChain.run {
            let dismissed = sidecar.settings.dismissedBuiltInSmartCohorts ?? []
            let restored = Self.builtInSmartCohortsMissing(from: sidecar)
            guard !restored.isEmpty || !dismissed.isEmpty else { return [] }
            let author = editAuthor ?? self.author
            let names = restored.map(\.name)
            try await publishWholeSidecar(action: "restoreBuiltInSmartCohorts", options: [
                "restoredBuiltInSmartCohorts": .array(names.map(ParameterValue.string)),
                "clearedDismissals": .array(dismissed.map(ParameterValue.string)),
            ]) { sidecar in
                sidecar.smartCohorts.append(contentsOf: restored)
                sidecar.settings.dismissedBuiltInSmartCohorts = nil
                sidecar.append(audit: .init(
                    action: "restoreBuiltInSmartCohorts", sample: "bundle", locus: nil, slot: nil,
                    before: dismissed.isEmpty ? nil : dismissed.joined(separator: ", "),
                    after: names.joined(separator: ", "),
                    color: nil, reason: "smartCohort", rationale: nil,
                    author: author, timestamp: now()
                ))
            }
            return names
        }
    }

    private static func builtInSmartCohortsMissing(from sidecar: GenotypeAnnotationSidecar) -> [GenotypeCohortSmartFilter] {
        builtInSmartCohorts.filter { !holds($0, in: sidecar) }
    }
}
