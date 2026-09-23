import Foundation
import LungfishCore

/// Display evidence derived from the active definition set and effective calls.
/// This index never changes scientific calls or support denominators.
public struct GenotypeAlleleHaplotypeEvidenceIndex: Equatable, Sendable {
    public struct EffectiveCall: Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let haplotypeNames: [String]

        public init(sample: String, locus: String, haplotypeNames: [String]) {
            self.sample = sample
            self.locus = locus
            self.haplotypeNames = haplotypeNames
        }
    }

    public struct Support: Equatable, Sendable {
        public let locus: String
        public let name: String
        public let fillColor: AnnotationColor

        public init(locus: String, name: String, fillColor: AnnotationColor) {
            self.locus = locus
            self.name = name
            self.fillColor = fillColor
        }
    }

    private struct RowKey: Hashable, Sendable {
        let locus: String
        let genotype: String
    }

    private struct CellKey: Hashable, Sendable {
        let row: RowKey
        let sample: String
    }

    public static let empty = Self()
    public let legend: [Support]
    private let diagnosticRows: Set<RowKey>
    private let supportByCell: [CellKey: [Support]]

    private init() {
        legend = []
        diagnosticRows = []
        supportByCell = [:]
    }

    public init(
        calls: [ONTGenotypeCall],
        definitionSet: GenotypeHaplotypeDefinitionSet,
        effectiveCalls: [EffectiveCall]
    ) {
        let effectiveBySample = Dictionary(grouping: effectiveCalls, by: \.sample)
        var diagnosticRows = Set<RowKey>()
        var supportByCell: [CellKey: [Support]] = [:]
        var legend: [Support] = []
        for locus in definitionSet.locusDefinitions {
            for haplotype in locus.haplotypes {
                let support = Support(locus: locus.locus, name: haplotype.name, fillColor: haplotype.effectiveFillColor)
                if !legend.contains(support) { legend.append(support) }
            }
        }
        // Classify every observed reference row, including rows in no-call
        // samples. Restrict colors to positive observations and displayed calls.
        for call in calls {
            let row = RowKey(locus: call.locusGroup, genotype: call.genotype)
            let cell = CellKey(row: row, sample: call.sample)
            var supports = supportByCell[cell] ?? []
            let associatedNames = Self.associatedNames(in: call.genotype)
            for locus in definitionSet.locusDefinitions {
                let belongsToLocus = GenotypeHaplotypeLocusResolver.rawCall(call, belongsTo: locus)
                guard belongsToLocus || GenotypeHaplotypeLocusResolver.allowsCrossFamilyDiagnostics(for: locus) else { continue }
                let diagnosticMatches = locus.haplotypes.filter { definition in
                    definition.diagnosticAlleles.contains {
                        GenotypeHaplotypeDiagnosticMatcher.matches(genotype: call.genotype, diagnosticAllele: $0)
                    }
                }
                if !diagnosticMatches.isEmpty { diagnosticRows.insert(row) }
                guard call.passedUniqueReads > 0 else { continue }
                let calledNames = Set((effectiveBySample[call.sample] ?? [])
                    .filter { $0.locus == locus.locus }
                    .flatMap(\.haplotypeNames))
                for definition in locus.haplotypes where calledNames.contains(definition.name) {
                    // Explicit membership governs colors independently of which
                    // haplotype uses this row diagnostically. Keep header fallback
                    // only for legacy definitions, with its stale-header guard.
                    let member = definition.effectiveAssociatedAlleles.contains {
                        GenotypeHaplotypeDiagnosticMatcher.matches(genotype: call.genotype, diagnosticAllele: $0)
                    }
                    let legacyHeaderAssociation = definition.associatedAlleles == nil
                        && diagnosticMatches.isEmpty
                        && belongsToLocus
                        && Self.associationMatches(associatedNames, definitionName: definition.name, locus: locus.locus)
                    guard member || legacyHeaderAssociation else { continue }
                    let support = Support(locus: locus.locus, name: definition.name, fillColor: definition.effectiveFillColor)
                    if !supports.contains(support) { supports.append(support) }
                }
            }
            if !supports.isEmpty { supportByCell[cell] = supports }
        }
        self.legend = legend
        self.diagnosticRows = diagnosticRows
        self.supportByCell = supportByCell
    }

    public func isDiagnostic(locus: String, genotype: String) -> Bool {
        diagnosticRows.contains(RowKey(locus: locus, genotype: genotype))
    }

    /// Multiple values mean shared support; they must not be assigned to one
    /// chromosome or one haplotype arbitrarily.
    public func support(locus: String, genotype: String, sample: String) -> [Support] {
        supportByCell[CellKey(row: RowKey(locus: locus, genotype: genotype), sample: sample)] ?? []
    }

    private static func associationMatches(_ names: Set<String>, definitionName: String, locus: String) -> Bool {
        if names.contains(definitionName) { return true }
        // Portable MHC references may store a repertoire token (M1) while
        // definitions qualify it by their locus (M1A, M1DQ). Resolve that
        // spelling only against the active locus and exact definition name;
        // never use unrestricted prefix matching (M1 must not match M10).
        guard locus.hasPrefix("MHC-") else { return false }
        let suffix = String(locus.dropFirst("MHC-".count))
        guard !suffix.isEmpty else { return false }
        return names.contains { !$0.isEmpty && $0 + suffix == definitionName }
    }

    private static func associatedNames(in genotype: String) -> Set<String> {
        guard let field = genotype.split(separator: "|").first(where: { $0.hasPrefix("haplotypes=") }) else { return [] }
        return Set(field.dropFirst("haplotypes=".count).split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }
}
