import Foundation

/// The one mapping from a reviewable row catalog row to the matrix identity
/// its cells carry. The matrix UI reads it through
/// `GenotypeMatrixReviewEligibility.rawSupport(in:)` and the Excel builder
/// through `GenotypeExcelSnapshotBuilder.capture`, so a catalog-attested zero
/// is reviewable in the matrix exactly when the workbook treats it as
/// reviewable (Phase 2.3 finding S1).
///
/// A catalog call ID is a transport identity, `reference:<locus>:<allele>` or
/// `<kind>:<locus>:<stableID>`. Annotations and the native matrix use the
/// displayed identity, a call's locus group and genotype plus a candidate's
/// stable cluster ID. A catalog row names the native row whose canonical locus
/// and stable ID equal its own and whose genotype equals its call ID or its
/// display name, or whose allele name equals its display name. A row that
/// names no native row stands alone under its own locus and display name, and
/// later rows can name it. A row that names two native rows is ambiguous, and
/// a catalog value that differs from an observed value of the same cell is a
/// disagreement. Both refuse the whole catalog.
public enum GenotypeCatalogMatrixIdentity {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    public typealias Row = GenotypeReviewableRowCatalog.Row

    /// A row of the native matrix, as the unfiltered matrix lists it.
    public struct NativeRow: Hashable, Sendable {
        public let locus: String
        public let genotype: String
        public let stableClusterID: String?

        public init(locus: String, genotype: String, stableClusterID: String?) {
            self.locus = locus
            self.genotype = genotype
            self.stableClusterID = stableClusterID
        }
    }

    /// Where one catalog row lands.
    public struct Resolution: Equatable, Sendable {
        public let row: Row
        /// The native row the catalog row names, nil when the catalog alone
        /// carries the row.
        public let native: NativeRow?

        /// The identity the row's cells carry in the matrix and the workbook.
        public var matrixRow: NativeRow {
            native ?? NativeRow(locus: row.locus, genotype: row.displayName, stableClusterID: row.stableID)
        }

        public func target(sample: String) -> Target {
            let identity = matrixRow
            return .cell(locus: identity.locus, genotype: identity.genotype, sample: sample,
                         stableClusterID: identity.stableClusterID)
        }
    }

    /// Every catalog row resolved in catalog order, and `support` extended by
    /// their cells.
    public struct Mapping: Equatable, Sendable {
        public let support: [Target: Int]
        public let resolutions: [Resolution]
    }

    public enum Refusal: Error, Equatable {
        /// The row names more than one native row.
        case ambiguousIdentity(callID: String)
        /// The catalog records a value for a cell that an observation attests
        /// differently.
        case supportDisagreement(target: Target, observed: Int, catalog: Int)

        /// The reason the Excel capture reports. The wording predates the
        /// shared mapping and is pinned by the export tests.
        public var message: String {
            switch self {
            case .ambiguousIdentity:
                return "ambiguous catalog to native row identity"
            case .supportDisagreement:
                return "catalog support disagrees with captured observations"
            }
        }
    }

    /// The native rows of a result as the unfiltered matrix lists them, one
    /// per locus group and genotype of the calls, one per candidate and one
    /// per interpreted incomplete-span cluster, in first-seen order. This is
    /// the identity set of `GenotypeMatrixBaseProjection.derive(.unfiltered)`
    /// under the default candidate settings, which the Excel builder maps
    /// against, and `GenotypeCatalogMatrixIdentityTests` pins the two equal.
    public static func nativeRows(in result: ONTGenotypeResultBundleData) -> [NativeRow] {
        var rows: [NativeRow] = []
        var seen = Set<NativeRow>()
        func append(_ row: NativeRow) {
            if seen.insert(row).inserted { rows.append(row) }
        }
        // A call's locus group is a function of its genotype, so one lookup
        // per genotype names the same row as one per call.
        var seenGenotypes = Set<String>()
        for call in result.calls where seenGenotypes.insert(call.genotype).inserted {
            append(NativeRow(locus: call.locusGroup, genotype: call.genotype, stableClusterID: nil))
        }
        for candidate in result.mhcCandidates?.candidates ?? [] {
            append(NativeRow(locus: candidate.locus, genotype: candidate.provisionalName,
                             stableClusterID: candidate.stableClusterID))
        }
        for record in result.mhcUnnameableClusters?.clusters ?? [] {
            guard record.reason == .incompleteReferenceSpan,
                  let interpretation = record.candidateInterpretation else { continue }
            append(NativeRow(locus: interpretation.locus, genotype: interpretation.provisionalName,
                             stableClusterID: record.stableClusterID))
        }
        return rows
    }

    /// Maps the whole catalog. Each row is resolved against the native rows
    /// plus the rows earlier catalog rows added, then its complete-roster
    /// support is written into `support`. The native rows are indexed once,
    /// so a reference panel of thousands of rows maps in a few milliseconds.
    public static func map(
        _ catalog: GenotypeReviewableRowCatalog,
        nativeRows: [NativeRow],
        into support: [Target: Int]
    ) throws(Refusal) -> Mapping {
        var index = NativeRowIndex(nativeRows)
        var support = support
        support.reserveCapacity(support.count + catalog.rows.count * catalog.samples.count)
        var resolutions: [Resolution] = []
        resolutions.reserveCapacity(catalog.rows.count)
        for row in catalog.rows {
            let resolution = try resolve(row, in: index)
            try merge(resolution, into: &support)
            if resolution.native == nil {
                index.append(resolution.matrixRow)
            }
            resolutions.append(resolution)
        }
        return Mapping(support: support, resolutions: resolutions)
    }

    /// Names the native row a catalog row maps onto, or none. A catalog row
    /// names the native row whose canonical locus and stable ID equal its own
    /// and whose genotype equals its call ID or display name, or whose allele
    /// name equals its display name.
    public static func resolve(_ row: Row, among nativeRows: [NativeRow]) throws(Refusal) -> Resolution {
        try resolve(row, in: NativeRowIndex(nativeRows))
    }

    private static func resolve(_ row: Row, in index: NativeRowIndex) throws(Refusal) -> Resolution {
        let matches = index.matches(for: row)
        guard matches.count <= 1 else {
            throw Refusal.ambiguousIdentity(callID: row.callID)
        }
        return Resolution(row: row, native: matches.first)
    }

    /// The native rows keyed the way the match predicate reads them, so one
    /// catalog row resolves through three lookups instead of a scan that
    /// canonicalises every native locus again.
    private struct NativeRowIndex {
        private struct Key: Hashable {
            let canonicalLocus: String
            let stableClusterID: String?
            let name: String
        }

        private var rows: [NativeRow] = []
        /// Row positions by canonical locus, stable ID and genotype.
        private var byGenotype: [Key: [Int]] = [:]
        /// Row positions by canonical locus, stable ID and allele name.
        private var byAlleleName: [Key: [Int]] = [:]

        init(_ rows: [NativeRow]) {
            self.rows.reserveCapacity(rows.count)
            for row in rows { append(row) }
        }

        mutating func append(_ row: NativeRow) {
            let position = rows.count
            rows.append(row)
            let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(row.locus)
            byGenotype[Key(canonicalLocus: locus, stableClusterID: row.stableClusterID, name: row.genotype), default: []]
                .append(position)
            byAlleleName[Key(canonicalLocus: locus, stableClusterID: row.stableClusterID,
                             name: MHCReferenceGenotypeDisplay.alleleName(for: row.genotype)), default: []]
                .append(position)
        }

        /// Every native row the catalog row names, in native order.
        func matches(for row: Row) -> [NativeRow] {
            var positions = Set<Int>()
            positions.formUnion(byGenotype[Key(canonicalLocus: row.locus, stableClusterID: row.stableID, name: row.callID)] ?? [])
            positions.formUnion(byGenotype[Key(canonicalLocus: row.locus, stableClusterID: row.stableID, name: row.displayName)] ?? [])
            positions.formUnion(byAlleleName[Key(canonicalLocus: row.locus, stableClusterID: row.stableID, name: row.displayName)] ?? [])
            return positions.sorted().map { rows[$0] }
        }
    }

    /// Writes a resolved row's complete-roster support into `support`. An
    /// observed value of the same cell must agree with the catalog, and a
    /// disagreement leaves that cell as it was.
    public static func merge(_ resolution: Resolution, into support: inout [Target: Int]) throws(Refusal) {
        let identity = resolution.matrixRow
        for (sample, reads) in resolution.row.supportBySample {
            let target = Target.cell(locus: identity.locus, genotype: identity.genotype, sample: sample,
                                     stableClusterID: identity.stableClusterID)
            if let observed = support.updateValue(reads, forKey: target), observed != reads {
                support[target] = observed
                throw Refusal.supportDisagreement(target: target, observed: observed, catalog: reads)
            }
        }
    }
}
