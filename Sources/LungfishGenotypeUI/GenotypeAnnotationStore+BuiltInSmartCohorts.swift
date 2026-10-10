import LungfishIO

extension GenotypeAnnotationStore {
    /// The smart cohorts every haplotyped bundle shows from its first open.
    /// The store adds the ones a sidecar lacks to its in-memory copy and writes
    /// them with the first edit that publishes the whole sidecar, so a read
    /// never writes them (walk finding F9). The command line holds no copy of
    /// this list, and `lungfish-cli genotype list-cohorts` reads the file only.
    static let builtInSmartCohorts: [GenotypeCohortSmartFilter] = [
        GenotypeCohortSmartFilter(
            name: "Incomplete haplotypes",
            description: "Samples with unresolved, not-assayed, or error haplotype slots.",
            scope: "bundle",
            isStarred: true,
            predicate: .needsHaplotypeReview
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
            ])
        ),
        GenotypeCohortSmartFilter(
            name: "Homozygous",
            description: "Samples whose H1 equals H2 at every called locus.",
            scope: "bundle",
            isStarred: false,
            predicate: .isHomozygousAcrossAll
        ),
        GenotypeCohortSmartFilter(
            name: "Recombinants",
            description: "Samples carrying a rec* haplotype at any locus.",
            scope: "bundle",
            isStarred: false,
            predicate: .hasRegionalRecombinant
        ),
    ]
}
