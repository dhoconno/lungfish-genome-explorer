import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// An immutable description of exactly what the genotype matrix viewport is
/// rendering: the visible sample columns, the visible rows (with their support
/// reads and viewport fill/border colors), the active filter context, and an
/// optional annotation sidecar.
///
/// The Excel export, the one GUI export since 24fe49f05, carries its frozen
/// scientific capture in `excelSnapshotData`, with simultaneous All and
/// Filtered projections, retained replay inputs and canonical provenance. The
/// CLI's CSV and TSV exports never see this type.
struct GenotypeViewportExportSnapshot: Equatable {
    let bundleURL: URL
    let analysisName: String
    let lens: String
    let filters: [String: String]
    let sampleNames: [String]
    let rows: [GenotypeViewportExportRow]
    let provenanceInputURLs: [URL]
    let annotationSidecarURL: URL?
    /// The sidecar the viewer showed at capture, encoded the way the store
    /// saves it. These bytes are not read from the bundle and are not always
    /// the bytes of its file, because the viewer shows the built-in smart
    /// cohorts before any edit saves them. The export reads its frozen Excel
    /// capture, and its record says how the captured annotations stand against
    /// the bundle's file.
    let annotationSidecarData: Data?
    /// Captured annotation context. Workbook presentation uses direct call
    /// values and matrix Notes; the full audit stays in the LGE bundle.
    let sidecar: GenotypeAnnotationSidecarSnapshot?
    let haplotypeCalls: [GenotypeViewProjectionHaplotypeCall]?
    let sourceRevision: GenotypeViewProjectionSourceRevision?
    /// Semantic call scope, distinct from matrix axes (the haplotype
    /// definition matrix uses allele columns rather than sample columns).
    let haplotypeSampleScope: [String]?
    let haplotypeLocusScope: [String]?
    let presentationColors: [GenotypeWorkbookPresentation.Color]
    let matrixColumns: [GenotypeWorkbookPresentation.MatrixColumn]
    /// Canonical immutable scientific capture for the one-way Excel report.
    let excelSnapshotData: Data?

    init(
        bundleURL: URL,
        analysisName: String,
        lens: String,
        filters: [String: String],
        sampleNames: [String],
        rows: [GenotypeViewportExportRow],
        provenanceInputURLs: [URL] = [],
        annotationSidecarURL: URL? = nil,
        annotationSidecarData: Data? = nil,
        sidecar: GenotypeAnnotationSidecarSnapshot? = nil,
        haplotypeCalls: [GenotypeViewProjectionHaplotypeCall]? = nil,
        sourceRevision: GenotypeViewProjectionSourceRevision? = nil,
        haplotypeSampleScope: [String]? = nil,
        haplotypeLocusScope: [String]? = nil,
        presentationColors: [GenotypeWorkbookPresentation.Color] = [],
        matrixColumns: [GenotypeWorkbookPresentation.MatrixColumn] = [],
        excelSnapshotData: Data? = nil
    ) {
        self.bundleURL = bundleURL
        self.analysisName = analysisName
        self.lens = lens
        self.filters = filters
        self.sampleNames = sampleNames
        self.rows = rows
        self.provenanceInputURLs = provenanceInputURLs
        self.annotationSidecarURL = annotationSidecarURL
        self.annotationSidecarData = annotationSidecarData
        self.sidecar = sidecar
        self.haplotypeCalls = haplotypeCalls
        self.sourceRevision = sourceRevision
        self.haplotypeSampleScope = haplotypeSampleScope
        self.haplotypeLocusScope = haplotypeLocusScope
        self.presentationColors = presentationColors
        self.matrixColumns = matrixColumns
        self.excelSnapshotData = excelSnapshotData
    }
}

struct GenotypeAnnotationSidecarSnapshot: Equatable {
    let overrides: [GenotypeAnnotationOverrideEntry]
    let auditEntries: [GenotypeAnnotationAuditEntry]
}

struct GenotypeAnnotationOverrideEntry: Equatable {
    let sample: String
    let locus: String
    let slot: String
    let originalCall: String
    let overrideCall: String
    let reasonTag: String
    let rationale: String
    let author: String
    let timestamp: String
}

struct GenotypeAnnotationAuditEntry: Equatable {
    let action: String
    let sample: String
    let locus: String
    let slot: String
    let before: String
    let after: String
    let author: String
    let timestamp: String
}

struct GenotypeViewportExportRow: Equatable {
    let genotype: String
    let displayName: String
    let locus: String
    let stableClusterID: String?
    let sampleCount: Int
    let totalUniqueReads: Int
    let sampleReads: [String: Int]
    let rowStyle: GenotypeResultHighlightStyle
    let cellStyles: [String: GenotypeResultHighlightStyle]
    let renderedRowStyle: GenotypeMatrixRenderedStyle?
    let renderedCellStyles: [String: GenotypeMatrixRenderedStyle]?
    let matrixColumnValues: [GenotypeWorkbookPresentation.MatrixColumnValue]

    init(
        genotype: String,
        displayName: String? = nil,
        locus: String,
        stableClusterID: String? = nil,
        sampleCount: Int,
        totalUniqueReads: Int,
        sampleReads: [String: Int],
        rowStyle: GenotypeResultHighlightStyle,
        cellStyles: [String: GenotypeResultHighlightStyle],
        renderedRowStyle: GenotypeMatrixRenderedStyle? = nil,
        renderedCellStyles: [String: GenotypeMatrixRenderedStyle]? = nil,
        matrixColumnValues: [GenotypeWorkbookPresentation.MatrixColumnValue] = []
    ) {
        self.genotype = genotype
        self.displayName = displayName ?? genotype
        self.locus = locus
        self.stableClusterID = stableClusterID
        self.sampleCount = sampleCount
        self.totalUniqueReads = totalUniqueReads
        self.sampleReads = sampleReads
        self.rowStyle = rowStyle
        self.cellStyles = cellStyles
        self.renderedRowStyle = renderedRowStyle
        self.renderedCellStyles = renderedCellStyles
        self.matrixColumnValues = matrixColumnValues
    }
}
