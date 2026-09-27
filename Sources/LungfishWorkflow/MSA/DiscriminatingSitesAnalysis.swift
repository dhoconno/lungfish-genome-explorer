import Foundation

/// Finds the alignment columns that separate a target lineage from a panel of
/// sequences the assay must not amplify.
///
/// A design that is conserved across every target is not automatically
/// specific: the same conserved base is usually shared with the exclusion
/// panel, so a primer or probe sitting on it binds both. Specificity comes
/// from the opposite property, a column where all targets agree on one base
/// and the exclusion sequences carry a different one. Placing a primer 3' end
/// or a probe over such a column is what makes the assay discriminate, because
/// a 3'-terminal mismatch blocks extension and a probe mismatch costs enough
/// duplex stability to suppress the signal.
///
/// The analysis reports one record per qualifying column plus the windows where
/// several of them cluster, since a designer needs several discriminating
/// columns inside one oligo or one amplicon rather than isolated sites.
public enum DiscriminatingSitesAnalysis {
    /// Bases treated as concrete evidence. Anything else (gaps, `N`, IUPAC
    /// ambiguity codes) is "no call" and never counts as agreement or as a
    /// difference, so an ambiguous exclusion row can never manufacture
    /// apparent specificity.
    static let canonicalBases: Set<Character> = ["A", "C", "G", "T"]

    public struct Options: Codable, Equatable, Sendable {
        /// How many target rows may carry a base other than the consensus and
        /// still let the column qualify. 0 (the default) demands that every
        /// target agrees, which is what an assay covering the whole lineage
        /// needs.
        public let targetMismatchTolerance: Int
        /// How many exclusion sequences must differ for the column to be
        /// reported. `nil` means "all of them", the strictest and the default.
        public let minimumExclusionDifferences: Int?
        /// The width, in template bases, used to gather clustered columns into
        /// candidate windows. A probe length is the useful default.
        public let windowLength: Int

        public init(
            targetMismatchTolerance: Int = 0,
            minimumExclusionDifferences: Int? = nil,
            windowLength: Int = 25
        ) {
            self.targetMismatchTolerance = targetMismatchTolerance
            self.minimumExclusionDifferences = minimumExclusionDifferences
            self.windowLength = windowLength
        }
    }

    /// One exclusion sequence that carries a different base at a column.
    public struct ExclusionDifference: Codable, Equatable, Sendable {
        public let name: String
        public let base: String

        public init(name: String, base: String) {
            self.name = name
            self.base = base
        }
    }

    /// A column where the targets agree and the exclusion panel does not.
    public struct Site: Codable, Equatable, Sendable {
        /// 1-based alignment column.
        public let column: Int
        /// 1-based position in the template row, or `nil` when the template
        /// has a gap in this column.
        public let templatePosition: Int?
        /// The base every (tolerated) target carries.
        public let targetBase: String
        /// Target rows that differ, permitted only by a nonzero tolerance.
        public let dissentingTargets: [ExclusionDifference]
        /// Exclusion sequences carrying a different concrete base.
        public let exclusionDifferences: [ExclusionDifference]
        /// Exclusion sequences with no concrete base here (gap or ambiguity).
        public let exclusionNoCallCount: Int
        /// Exclusion sequences that match the target base, so are not
        /// discriminated at this column.
        public let exclusionMatchCount: Int

        public var exclusionDifferenceCount: Int { exclusionDifferences.count }

        /// The distinct exclusion bases, sorted, for compact display.
        public var exclusionBases: String {
            String(Set(exclusionDifferences.map(\.base).joined()).sorted())
        }

        public init(
            column: Int,
            templatePosition: Int?,
            targetBase: String,
            dissentingTargets: [ExclusionDifference],
            exclusionDifferences: [ExclusionDifference],
            exclusionNoCallCount: Int,
            exclusionMatchCount: Int
        ) {
            self.column = column
            self.templatePosition = templatePosition
            self.targetBase = targetBase
            self.dissentingTargets = dissentingTargets
            self.exclusionDifferences = exclusionDifferences
            self.exclusionNoCallCount = exclusionNoCallCount
            self.exclusionMatchCount = exclusionMatchCount
        }
    }

    /// A run of discriminating columns close enough to sit under one oligo.
    public struct Window: Codable, Equatable, Sendable {
        public let startColumn: Int
        public let endColumn: Int
        public let startTemplatePosition: Int?
        public let endTemplatePosition: Int?
        public let siteCount: Int
        public let columns: [Int]
        public let templatePositions: [Int]

        public init(
            startColumn: Int,
            endColumn: Int,
            startTemplatePosition: Int?,
            endTemplatePosition: Int?,
            siteCount: Int,
            columns: [Int],
            templatePositions: [Int]
        ) {
            self.startColumn = startColumn
            self.endColumn = endColumn
            self.startTemplatePosition = startTemplatePosition
            self.endTemplatePosition = endTemplatePosition
            self.siteCount = siteCount
            self.columns = columns
            self.templatePositions = templatePositions
        }
    }

    public struct Row: Equatable, Sendable {
        public let name: String
        public let sequence: String

        public init(name: String, sequence: String) {
            self.name = name
            self.sequence = sequence
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public static let schemaVersion = 1
        public let schemaVersion: Int
        public let targetNames: [String]
        public let exclusionNames: [String]
        public let templateName: String
        public let alignedLength: Int
        public let options: Options
        public let sites: [Site]
        public let windows: [Window]

        public var siteCount: Int { sites.count }

        public init(
            targetNames: [String],
            exclusionNames: [String],
            templateName: String,
            alignedLength: Int,
            options: Options,
            sites: [Site],
            windows: [Window]
        ) {
            schemaVersion = Self.schemaVersion
            self.targetNames = targetNames
            self.exclusionNames = exclusionNames
            self.templateName = templateName
            self.alignedLength = alignedLength
            self.options = options
            self.sites = sites
            self.windows = windows
        }
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case noTargets
        case noExclusions
        case unequalWidths
        case invalidTolerance(Int, targetCount: Int)
        case invalidWindowLength(Int)
        case duplicateRowName(String)

        public var errorDescription: String? {
            switch self {
            case .noTargets:
                "Discriminating-sites analysis needs at least one target sequence."
            case .noExclusions:
                "Discriminating-sites analysis needs at least one exclusion sequence."
            case .unequalWidths:
                "Target and exclusion rows must come from one alignment and share a width."
            case .invalidTolerance(let tolerance, let targetCount):
                "A target mismatch tolerance of \(tolerance) is not usable with \(targetCount) target sequences."
            case .invalidWindowLength(let length):
                "The candidate-window length must be at least 1 base, not \(length)."
            case .duplicateRowName(let name):
                "Row name '\(name)' appears more than once, so targets and exclusions cannot be told apart."
            }
        }
    }

    /// Computes the report. `templateIndex` selects which target row supplies
    /// the reported template coordinates.
    public static func analyze(
        targets: [Row],
        exclusions: [Row],
        templateIndex: Int = 0,
        options: Options = .init()
    ) throws -> Report {
        guard !targets.isEmpty else { throw Failure.noTargets }
        guard !exclusions.isEmpty else { throw Failure.noExclusions }
        guard options.windowLength >= 1 else { throw Failure.invalidWindowLength(options.windowLength) }
        guard options.targetMismatchTolerance >= 0,
              options.targetMismatchTolerance < targets.count else {
            throw Failure.invalidTolerance(options.targetMismatchTolerance, targetCount: targets.count)
        }

        let allRows = targets + exclusions
        var seen = Set<String>()
        for row in allRows where !seen.insert(row.name).inserted {
            throw Failure.duplicateRowName(row.name)
        }
        let width = allRows[0].sequence.count
        guard allRows.allSatisfy({ $0.sequence.count == width }), width > 0 else {
            throw Failure.unequalWidths
        }
        let template = targets[min(max(templateIndex, 0), targets.count - 1)]

        let targetMatrix = targets.map { Array($0.sequence.uppercased()) }
        let exclusionMatrix = exclusions.map { Array($0.sequence.uppercased()) }
        let templateMap = templatePositions(for: template.sequence)
        let requiredDifferences = options.minimumExclusionDifferences ?? exclusions.count

        var sites: [Site] = []
        for column in 0..<width {
            guard let site = evaluate(
                column: column,
                targets: targets,
                exclusions: exclusions,
                targetMatrix: targetMatrix,
                exclusionMatrix: exclusionMatrix,
                templateMap: templateMap,
                tolerance: options.targetMismatchTolerance,
                requiredDifferences: requiredDifferences
            ) else { continue }
            sites.append(site)
        }

        return Report(
            targetNames: targets.map(\.name),
            exclusionNames: exclusions.map(\.name),
            templateName: template.name,
            alignedLength: width,
            options: options,
            sites: sites,
            windows: windows(for: sites, windowLength: options.windowLength)
        )
    }

    private static func evaluate(
        column: Int,
        targets: [Row],
        exclusions: [Row],
        targetMatrix: [[Character]],
        exclusionMatrix: [[Character]],
        templateMap: [Int?],
        tolerance: Int,
        requiredDifferences: Int
    ) -> Site? {
        // Every target needs a concrete base. A gap or ambiguity in even one
        // target means the lineage is not reliably typed here, so an oligo
        // anchored on this column would not be dependable.
        var targetBases: [Character] = []
        targetBases.reserveCapacity(targetMatrix.count)
        for row in targetMatrix {
            let base = row[column]
            guard canonicalBases.contains(base) else { return nil }
            targetBases.append(base)
        }

        var counts: [Character: Int] = [:]
        for base in targetBases { counts[base, default: 0] += 1 }
        // Ties are resolved by base order so the result never depends on
        // dictionary iteration order.
        guard let consensus = counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).first?.key else {
            return nil
        }
        let agreeing = counts[consensus] ?? 0
        guard targetBases.count - agreeing <= tolerance else { return nil }

        let dissenting = targetBases.enumerated()
            .filter { $0.element != consensus }
            .map { ExclusionDifference(name: targets[$0.offset].name, base: String($0.element)) }

        var differences: [ExclusionDifference] = []
        var noCall = 0
        var matches = 0
        for (index, row) in exclusionMatrix.enumerated() {
            let base = row[column]
            if !canonicalBases.contains(base) {
                noCall += 1
            } else if base == consensus {
                matches += 1
            } else {
                differences.append(ExclusionDifference(name: exclusions[index].name, base: String(base)))
            }
        }
        guard differences.count >= requiredDifferences else { return nil }

        return Site(
            column: column + 1,
            templatePosition: templateMap[column],
            targetBase: String(consensus),
            dissentingTargets: dissenting,
            exclusionDifferences: differences,
            exclusionNoCallCount: noCall,
            exclusionMatchCount: matches
        )
    }

    /// 0-based column to 1-based template position, `nil` at template gaps.
    static func templatePositions(for sequence: String) -> [Int?] {
        var map: [Int?] = []
        map.reserveCapacity(sequence.count)
        var position = 0
        for base in sequence {
            if base == "-" || base == "." {
                map.append(nil)
            } else {
                position += 1
                map.append(position)
            }
        }
        return map
    }

    /// Groups the sites into maximal windows of `windowLength` template bases.
    ///
    /// Windows are measured in template coordinates, because that is the space
    /// an oligo occupies; sites in template gaps cannot be covered by an oligo
    /// on this template and are skipped. Only windows holding more than one
    /// site are reported, and a window contained in an earlier, larger one is
    /// dropped so the list stays readable.
    static func windows(for sites: [Site], windowLength: Int) -> [Window] {
        let placed = sites.compactMap { site -> (site: Site, position: Int)? in
            guard let position = site.templatePosition else { return nil }
            return (site, position)
        }
        guard placed.count > 1 else { return [] }

        var candidates: [Window] = []
        for (index, anchor) in placed.enumerated() {
            let group = placed[index...].prefix { $0.position < anchor.position + windowLength }
            guard group.count > 1 else { continue }
            let members = Array(group)
            candidates.append(Window(
                startColumn: members[0].site.column,
                endColumn: members[members.count - 1].site.column,
                startTemplatePosition: members[0].position,
                endTemplatePosition: members[members.count - 1].position,
                siteCount: members.count,
                columns: members.map(\.site.column),
                templatePositions: members.map(\.position)
            ))
        }

        // Drop any window whose site set is a subset of another's, then rank
        // the survivors by site count so the strongest region reads first.
        var kept: [Window] = []
        for candidate in candidates {
            let columns = Set(candidate.columns)
            let isSubsumed = candidates.contains { other in
                other.columns.count > candidate.columns.count && columns.isSubset(of: Set(other.columns))
            }
            if !isSubsumed, !kept.contains(where: { Set($0.columns) == columns }) {
                kept.append(candidate)
            }
        }
        return kept.sorted {
            ($0.siteCount, -($0.startTemplatePosition ?? 0)) > ($1.siteCount, -($1.startTemplatePosition ?? 0))
        }
    }
}
