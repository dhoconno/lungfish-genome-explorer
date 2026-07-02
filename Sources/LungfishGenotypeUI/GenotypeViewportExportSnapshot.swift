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
    /// Optional annotation sidecar to surface in additional worksheets.
    /// When non-nil, the export adds an Overrides sheet and an Audit Log
    /// sheet so consumers reading the workbook see what the analyst has
    /// changed without needing the bundle's annotations.json.
    let sidecar: GenotypeAnnotationSidecarSnapshot?

    init(
        bundleURL: URL,
        analysisName: String,
        lens: String,
        filters: [String: String],
        sampleNames: [String],
        rows: [GenotypeViewportExportRow],
        provenanceInputURLs: [URL] = [],
        annotationSidecarURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecarSnapshot? = nil
    ) {
        self.bundleURL = bundleURL
        self.analysisName = analysisName
        self.lens = lens
        self.filters = filters
        self.sampleNames = sampleNames
        self.rows = rows
        self.provenanceInputURLs = provenanceInputURLs
        self.annotationSidecarURL = annotationSidecarURL
        self.sidecar = sidecar
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
    let locus: String
    let sampleCount: Int
    let totalUniqueReads: Int
    let sampleReads: [String: Int]
    let rowStyle: GenotypeResultHighlightStyle
    let cellStyles: [String: GenotypeResultHighlightStyle]
}
