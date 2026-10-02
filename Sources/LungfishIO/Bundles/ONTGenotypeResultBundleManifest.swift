import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeResultBundleManifest: Codable, Equatable, Sendable {
    public static let filename = "genotype-result.json"

    public let schemaVersion: Int
    public let kind: String
    @GenotypeResultWorkflowKindField public private(set) var workflowKind:
        GenotypeResultWorkflowKind?
    @GenotypeResultWorkflowModeField public private(set) var workflowMode:
        GenotypeResultWorkflowMode?
    public var workflowKindDeclaration: GenotypeResultWorkflowDeclaration { $workflowKind }
    public var workflowModeDeclaration: GenotypeResultWorkflowDeclaration { $workflowMode }
    public let outputName: String
    public let analysisName: String
    public let primaryWorkbookPath: String
    public private(set) var currentWorkbookPath: String?
    public private(set) var workbookRevisions: [ONTGenotypeWorkbookRevision]?
    public let longSummaryCSVPath: String
    public let sampleSummaryCSVPath: String
    public let statsJSONPath: String
    public let provenancePath: String
    public let deduplicatedUnmatchedClustersFASTAPath: String?
    public private(set) var haplotypeAnalysisPath: String?
    public private(set) var activeHaplotypeAnalysisRevisionID: String?
    public private(set) var haplotypeAnalysisRevisions:
        [ONTGenotypeHaplotypeAnalysisRevision]?
    public let haplotypeDefinitionSetID: String?
    public let haplotypeAssayID: String?
    public let presetID: String?
    public let presetVersion: String?
    public let createdAt: String?
    public let mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest?
    public let mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifacts?
    public let referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo?
    public let alignmentArtifacts: ONTGenotypeAlignmentArtifactManifest?
    public let provisionalExon2Artifacts: ONTGenotypeProvisionalExon2ArtifactManifest?
    public let reviewableRowCatalog: ONTMHCArtifactReference?
    public let genotypeLocusDisplayOrder: [String]?

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        currentWorkbookPath: String? = nil,
        workbookRevisions: [ONTGenotypeWorkbookRevision]? = nil,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifacts? = nil,
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo? = nil,
        reviewableRowCatalog: ONTMHCArtifactReference? = nil,
        genotypeLocusDisplayOrder: [String]? = nil
    ) {
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            primaryWorkbookPath: primaryWorkbookPath,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: workbookRevisions,
            longSummaryCSVPath: longSummaryCSVPath,
            sampleSummaryCSVPath: sampleSummaryCSVPath,
            statsJSONPath: statsJSONPath,
            provenancePath: provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: mhcCandidateArtifacts,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            referenceRecordStore: referenceRecordStore,
            alignmentArtifacts: nil,
            provisionalExon2Artifacts: nil,
            reviewableRowCatalog: reviewableRowCatalog,
            genotypeLocusDisplayOrder: genotypeLocusDisplayOrder
        )
    }

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        currentWorkbookPath: String? = nil,
        workbookRevisions: [ONTGenotypeWorkbookRevision]? = nil,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifacts? = nil,
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo? = nil,
        alignmentArtifacts: ONTGenotypeAlignmentArtifactManifest?,
        provisionalExon2Artifacts: ONTGenotypeProvisionalExon2ArtifactManifest?,
        reviewableRowCatalog: ONTMHCArtifactReference? = nil,
        genotypeLocusDisplayOrder: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.workflowKind = nil
        self.workflowMode = nil
        self.outputName = outputName
        self.analysisName = analysisName
        self.primaryWorkbookPath = primaryWorkbookPath
        self.currentWorkbookPath = currentWorkbookPath
        self.workbookRevisions = workbookRevisions
        self.longSummaryCSVPath = longSummaryCSVPath
        self.sampleSummaryCSVPath = sampleSummaryCSVPath
        self.statsJSONPath = statsJSONPath
        self.provenancePath = provenancePath
        self.deduplicatedUnmatchedClustersFASTAPath = deduplicatedUnmatchedClustersFASTAPath
        self.haplotypeAnalysisPath = haplotypeAnalysisPath
        self.activeHaplotypeAnalysisRevisionID = activeHaplotypeAnalysisRevisionID
        self.haplotypeAnalysisRevisions = haplotypeAnalysisRevisions
        self.haplotypeDefinitionSetID = haplotypeDefinitionSetID
        self.haplotypeAssayID = haplotypeAssayID
        self.presetID = presetID
        self.presetVersion = presetVersion
        self.createdAt = createdAt
        self.mhcCandidateArtifacts = mhcCandidateArtifacts
        self.mhcReferenceVisualizations = mhcReferenceVisualizations
        self.referenceRecordStore = referenceRecordStore
        self.alignmentArtifacts = alignmentArtifacts
        self.provisionalExon2Artifacts = provisionalExon2Artifacts
        self.reviewableRowCatalog = reviewableRowCatalog
        self.genotypeLocusDisplayOrder = genotypeLocusDisplayOrder
    }

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        currentWorkbookPath: String? = nil,
        workbookRevisions: [ONTGenotypeWorkbookRevision]? = nil,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo? = nil,
        reviewableRowCatalog: ONTMHCArtifactReference? = nil,
        genotypeLocusDisplayOrder: [String]? = nil
    ) {
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            primaryWorkbookPath: primaryWorkbookPath,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: workbookRevisions,
            longSummaryCSVPath: longSummaryCSVPath,
            sampleSummaryCSVPath: sampleSummaryCSVPath,
            statsJSONPath: statsJSONPath,
            provenancePath: provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: mhcCandidateArtifacts,
            mhcReferenceVisualizations: nil,
            referenceRecordStore: referenceRecordStore,
            alignmentArtifacts: nil,
            provisionalExon2Artifacts: nil,
            reviewableRowCatalog: reviewableRowCatalog,
            genotypeLocusDisplayOrder: genotypeLocusDisplayOrder
        )
    }

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        currentWorkbookPath: String? = nil,
        workbookRevisions: [ONTGenotypeWorkbookRevision]? = nil,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo? = nil,
        alignmentArtifacts: ONTGenotypeAlignmentArtifactManifest?,
        provisionalExon2Artifacts: ONTGenotypeProvisionalExon2ArtifactManifest?,
        reviewableRowCatalog: ONTMHCArtifactReference? = nil,
        genotypeLocusDisplayOrder: [String]? = nil
    ) {
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            primaryWorkbookPath: primaryWorkbookPath,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: workbookRevisions,
            longSummaryCSVPath: longSummaryCSVPath,
            sampleSummaryCSVPath: sampleSummaryCSVPath,
            statsJSONPath: statsJSONPath,
            provenancePath: provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: mhcCandidateArtifacts,
            mhcReferenceVisualizations: nil,
            referenceRecordStore: referenceRecordStore,
            alignmentArtifacts: alignmentArtifacts,
            provisionalExon2Artifacts: provisionalExon2Artifacts,
            reviewableRowCatalog: reviewableRowCatalog,
            genotypeLocusDisplayOrder: genotypeLocusDisplayOrder
        )
    }

    public init(
        schemaVersion: Int = 1,
        kind: String,
        workflowKind: GenotypeResultWorkflowKind?,
        workflowMode: GenotypeResultWorkflowMode?,
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        currentWorkbookPath: String? = nil,
        workbookRevisions: [ONTGenotypeWorkbookRevision]? = nil,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifacts? = nil,
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo? = nil,
        alignmentArtifacts: ONTGenotypeAlignmentArtifactManifest? = nil,
        provisionalExon2Artifacts: ONTGenotypeProvisionalExon2ArtifactManifest? = nil,
        reviewableRowCatalog: ONTMHCArtifactReference? = nil,
        genotypeLocusDisplayOrder: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.workflowKind = workflowKind
        self.workflowMode = workflowMode
        self.outputName = outputName
        self.analysisName = analysisName
        self.primaryWorkbookPath = primaryWorkbookPath
        self.currentWorkbookPath = currentWorkbookPath
        self.workbookRevisions = workbookRevisions
        self.longSummaryCSVPath = longSummaryCSVPath
        self.sampleSummaryCSVPath = sampleSummaryCSVPath
        self.statsJSONPath = statsJSONPath
        self.provenancePath = provenancePath
        self.deduplicatedUnmatchedClustersFASTAPath = deduplicatedUnmatchedClustersFASTAPath
        self.haplotypeAnalysisPath = haplotypeAnalysisPath
        self.activeHaplotypeAnalysisRevisionID = activeHaplotypeAnalysisRevisionID
        self.haplotypeAnalysisRevisions = haplotypeAnalysisRevisions
        self.haplotypeDefinitionSetID = haplotypeDefinitionSetID
        self.haplotypeAssayID = haplotypeAssayID
        self.presetID = presetID
        self.presetVersion = presetVersion
        self.createdAt = createdAt
        self.mhcCandidateArtifacts = mhcCandidateArtifacts
        self.mhcReferenceVisualizations = mhcReferenceVisualizations
        self.referenceRecordStore = referenceRecordStore
        self.alignmentArtifacts = alignmentArtifacts
        self.provisionalExon2Artifacts = provisionalExon2Artifacts
        self.reviewableRowCatalog = reviewableRowCatalog
        self.genotypeLocusDisplayOrder = genotypeLocusDisplayOrder
    }

    public func replacingWorkbookFields(
        currentWorkbookPath: String,
        workbookRevisions: [ONTGenotypeWorkbookRevision]
    ) -> Self {
        var copy = self
        copy.currentWorkbookPath = currentWorkbookPath
        copy.workbookRevisions = workbookRevisions
        return copy
    }

    public func appendingHaplotypeAnalysisRevision(
        _ revision: ONTGenotypeHaplotypeAnalysisRevision
    ) -> Self {
        var copy = self
        copy.workflowMode = .haplotyped
        copy.haplotypeAnalysisPath = revision.path
        copy.activeHaplotypeAnalysisRevisionID = revision.id
        copy.haplotypeAnalysisRevisions =
            (haplotypeAnalysisRevisions ?? []) + [revision]
        return copy
    }
}
