import Foundation
import LungfishCore
import LungfishIO

/// Shared fixture builders for the MHC genotype test cluster (IO / GenotypeUI /
/// CLI / App / Workflow targets).
///
/// These consolidate the ~duplicated `makeCall`/`makeResult` private helpers that
/// were copy-pasted across the genotype test files. Parameter lists are the
/// superset of what the private copies used, defaulted so most existing call
/// sites migrate by only changing the receiver (`makeCall(...)` ->
/// `GenotypeTestFixtures.makeCall(...)`).
public enum GenotypeTestFixtures {
    /// Builds an `ONTGenotypeCall` for a sample/genotype pair.
    ///
    /// - `reads` is mirrored into both `passedAlignments` and `passedUniqueReads`,
    ///   matching every private copy's behavior.
    /// - `retainedReads` covers `GenotypeMatrixBaseProjectionTests`'s variant,
    ///   which threads a distinct `sampleUniqueRetainedReads` value through.
    public static func makeCall(
        sample: String,
        genotype: String,
        reads: Int,
        retainedReads: Int? = nil,
        sampleTotalReads: Int? = nil,
        sampleUniqueRetainedPercent: Double? = nil,
        overallInputReads: Int? = nil,
        overallUniqueRetainedReads: Int? = nil,
        overallUniqueRetainedPercent: Double? = nil
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: sampleTotalReads,
            sampleUniqueRetainedReads: retainedReads,
            sampleUniqueRetainedPercent: sampleUniqueRetainedPercent,
            overallInputReads: overallInputReads,
            overallUniqueRetainedReads: overallUniqueRetainedReads,
            overallUniqueRetainedPercent: overallUniqueRetainedPercent
        )
    }

    /// Builds an `ONTGenotypeResultBundleData` fixture with a canned bundle URL
    /// and manifest/artifact paths under `/tmp`, matching the shape every
    /// private `makeResult` copy used for unit-level (non-filesystem) tests.
    ///
    /// Pass `manifest` to fully override the manifest (as
    /// `GenotypeManualHaplotypeEligibilityTests` does); otherwise one is built
    /// from `kind`/`haplotypeAnalysis`/`haplotypeDefinitionSetID`/`mhcCandidateArtifacts`.
    public static func makeResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
        samples: [ONTGenotypeSampleResult] = [],
        calls: [ONTGenotypeCall],
        kind: String = "ont-barcode-genotype",
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        haplotypeDefinitionSetID: String? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs = .empty,
        mhcAlignmentArtifactURLs: ONTMHCAlignmentArtifactURLs = .empty,
        stats: ONTGenotypeRunStats = ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact? = nil,
        provisionalExon2SequencesByGenotype:
            [String: ONTGenotypeProvisionalExon2Sequence] = [:],
        provisionalExon2ArtifactURLs:
            ONTGenotypeProvisionalExon2ArtifactURLs = .empty,
        manifest: ONTGenotypeResultBundleManifest? = nil,
        reviewableRowCatalog: GenotypeReviewableRowCatalog? = nil
    ) -> ONTGenotypeResultBundleData {
        let resolvedManifest = manifest ?? ONTGenotypeResultBundleManifest(
            kind: kind,
            workflowKind: GenotypeResultWorkflowKind(rawValue: kind),
            workflowMode: haplotypeAnalysis == nil && haplotypeDefinitionSetID == nil
                ? .genotypeOnly
                : .haplotyped,
            outputName: "example",
            analysisName: "Example",
            primaryWorkbookPath: "example.xlsx",
            longSummaryCSVPath: "example.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "example.retained-demux-samples.csv",
            statsJSONPath: "example.retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json",
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            mhcCandidateArtifacts: mhcCandidateArtifacts
        )
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: resolvedManifest,
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: mhcCandidateGenBankArtifactURLs,
            mhcAlignmentArtifactURLs: mhcAlignmentArtifactURLs,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            integrityWarnings: [],
            referenceMetadata: referenceMetadata,
            provisionalExon2SequencesByGenotype: provisionalExon2SequencesByGenotype,
            provisionalExon2ArtifactURLs: provisionalExon2ArtifactURLs,
            reviewableRowCatalog: reviewableRowCatalog
        )
    }
}
