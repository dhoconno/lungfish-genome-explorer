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

/// User-visible description of the immutable snapshot captured before the
/// Excel role dialog is presented.
struct GenotypeExcelCapturedScope: Equatable {
    let summary: String
    let capability: String

    init(snapshot: GenotypeViewportExportSnapshot, callEditingSupported: Bool) {
        let filters = snapshot.filters
        let samples = snapshot.haplotypeSampleScope ?? snapshot.sampleNames
        let loci = snapshot.haplotypeLocusScope
            ?? Array(Set(snapshot.rows.map(\.locus))).sorted()
        func boundedList(_ values: [String]) -> String {
            let shown = values.prefix(8).joined(separator: ", ")
            let remainder = values.count - min(values.count, 8)
            return remainder == 0 ? shown : "\(shown), +\(remainder) more"
        }
        let visibility = filters["hideLowSupport"] == "true" ? "hidden" : "shown"
        summary = [
            "Captured scope (will not change while this dialog is open):",
            "Samples (\(samples.count)): \(boundedList(samples))",
            "Loci (\(loci.count)): \(boundedList(loci))",
            "Min reads: \(filters["matrixMinimumReads"] ?? "0")",
            "Min percent: \(filters["matrixMinimumPercent"] ?? "0")",
            "Percent basis: \(filters["matrixPercentDenominator"] ?? "Not applicable")",
            "Search: \(filters["searchText"].flatMap { $0.isEmpty ? nil : $0 } ?? "None")",
            "Low-support rows: \(visibility)",
            "Locus filter: \(filters["locus"] ?? "All Loci")",
        ].joined(separator: "\n")

        capability = !callEditingSupported
            ? "H1/H2 calls are read-only for this legacy workbook; matrix reviews and comments remain supported."
            : "H1/H2 call edits are supported where a raw baseline is available; matrix reviews and comments remain supported."
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
