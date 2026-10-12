import Foundation
import LungfishIO

extension GenotypeAnnotationStore {
    /// The smart cohorts every haplotyped bundle shows from its first open.
    /// The store adds the ones a sidecar lacks to its in-memory copy and writes
    /// them with the first edit that publishes the whole sidecar, so a read
    /// never writes them (walk finding F9). One the analyst deleted is recorded
    /// as dismissed and not shown again until Restore Built-In Cohorts (plan
    /// decision S13). The command line holds no copy of this list, and
    /// `lungfish-cli genotype list-cohorts` reads the file only.
    ///
    /// Each carries a fixed id (plan decisions O2 and G2), the UUID version 5
    /// that `GenotypeCohortSmartFilter.derivedID(scope:name:)` gives its scope
    /// and name. The ids are written out here so they stay as they are whatever
    /// happens to the derivation, and a test pins each to the derivation. A
    /// restored cohort therefore comes back under the id it had, and no other
    /// cohort's id moves when one is deleted, dismissed or restored.
    static let builtInSmartCohorts: [GenotypeCohortSmartFilter] = [
        GenotypeCohortSmartFilter(
            name: "Incomplete haplotypes",
            description: "Samples with unresolved, not-assayed, or error haplotype slots.",
            scope: "bundle",
            isStarred: true,
            predicate: .needsHaplotypeReview,
            id: fixedID("31D2B132-01DD-5F19-BC0A-8878472F012F")
        ),
        GenotypeCohortSmartFilter(
            name: "Needs review",
            description: "Incomplete haplotypes, low support, or analyst-flagged samples.",
            scope: "bundle",
            isStarred: true,
            predicate: .any([
                .needsHaplotypeReview,
                .qcStatus([.review, .lowSupport]),
                .hasAnalystFlag(.needsReview),
            ]),
            id: fixedID("DF4CA8E2-BF22-50FC-8C94-BDB45C58A1F5")
        ),
        GenotypeCohortSmartFilter(
            name: "Homozygous",
            description: "Samples whose H1 equals H2 at every called locus.",
            scope: "bundle",
            isStarred: false,
            predicate: .isHomozygousAcrossAll,
            id: fixedID("5FD26AEC-1025-5049-AE30-F43C219E9A7A")
        ),
        GenotypeCohortSmartFilter(
            name: "Recombinants",
            description: "Samples carrying a rec* haplotype at any locus.",
            scope: "bundle",
            isStarred: false,
            predicate: .hasRegionalRecombinant,
            id: fixedID("048C9D06-A36A-5243-BEEC-7F2F591D780A")
        ),
    ]

    private nonisolated static func fixedID(_ text: String) -> UUID {
        guard let id = UUID(uuidString: text) else {
            preconditionFailure("The built-in smart cohort id \(text) is not a UUID.")
        }
        return id
    }
}
