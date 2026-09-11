import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// An immutable description of exactly what the genotype matrix viewport is
/// rendering: the visible sample columns, the visible rows (with their support
/// reads and viewport fill/border colors), the active filter context, and an
/// optional annotation sidecar.
///
/// ``GenotypeViewportExportService`` serializes this into the
/// ``GenotypeViewProjection`` contract and hands it to `lungfish-cli genotype
/// export --view-projection`, so the headless CLI reproduces the analyst's
/// colored view with canonical provenance.
struct GenotypeViewportExportSnapshot: Equatable {
    let bundleURL: URL
    let analysisName: String
    let lens: String
    let filters: [String: String]
    let sampleNames: [String]
    let rows: [GenotypeViewportExportRow]
    let provenanceInputURLs: [URL]
    let annotationSidecarURL: URL?
    /// Immutable bytes captured with the viewport. When present, export uses
    /// these rather than rereading the live bundle sidecar path.
    let annotationSidecarData: Data?
    /// Optional annotation sidecar to surface in additional worksheets.
    /// When non-nil, the export adds an Overrides sheet and an Audit Log
    /// sheet so consumers reading the workbook see what the analyst has
    /// changed without needing the bundle's annotations.json.
    let sidecar: GenotypeAnnotationSidecarSnapshot?
    let haplotypeCalls: [GenotypeViewProjectionHaplotypeCall]?
    let sourceRevision: GenotypeViewProjectionSourceRevision?
    /// Semantic call scope, distinct from matrix axes (the haplotype
    /// definition matrix uses allele columns rather than sample columns).
    let haplotypeSampleScope: [String]?
    let haplotypeLocusScope: [String]?

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
        haplotypeLocusScope: [String]? = nil
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

    init(
        genotype: String,
        displayName: String? = nil,
        locus: String,
        stableClusterID: String? = nil,
        sampleCount: Int,
        totalUniqueReads: Int,
        sampleReads: [String: Int],
        rowStyle: GenotypeResultHighlightStyle,
        cellStyles: [String: GenotypeResultHighlightStyle]
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
    }
}
