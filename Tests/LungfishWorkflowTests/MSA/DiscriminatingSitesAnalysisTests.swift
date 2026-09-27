import XCTest
@testable import LungfishWorkflow

/// A small synthetic alignment exercises every rule the analysis enforces.
///
/// Columns are laid out so each one isolates one behaviour (1-based columns):
///   1  all targets A, all exclusions G          -> discriminating
///   2  all rows A                               -> conserved, not discriminating
///   3  targets A, one exclusion A               -> only 2 of 3 exclusions differ
///   4  targets A/A/C                            -> targets disagree
///   5  targets A, exclusions N/-/G              -> no-call handling
///   6  target gap                               -> skipped entirely
///   7  all targets T, all exclusions C          -> discriminating, near col 1
final class DiscriminatingSitesAnalysisTests: XCTestCase {
    private typealias Row = DiscriminatingSitesAnalysis.Row

    //                                 col 1234567
    private let targets = [
        Row(name: "t1", sequence: "AAAAA-T"),
        Row(name: "t2", sequence: "AAAAA-T"),
        Row(name: "t3", sequence: "AAACA-T"),
    ]
    private let exclusions = [
        Row(name: "x1", sequence: "GAAGNGC"),
        Row(name: "x2", sequence: "GAGG-GC"),
        Row(name: "x3", sequence: "GAGGGGC"),
    ]

    private func analyze(
        tolerance: Int = 0,
        minimumDifferences: Int? = nil,
        windowLength: Int = 25
    ) throws -> DiscriminatingSitesAnalysis.Report {
        try DiscriminatingSitesAnalysis.analyze(
            targets: targets,
            exclusions: exclusions,
            options: .init(
                targetMismatchTolerance: tolerance,
                minimumExclusionDifferences: minimumDifferences,
                windowLength: windowLength
            )
        )
    }

    func testReportsOnlyFullyDiscriminatingColumnsAtDefaultTolerance() throws {
        let report = try analyze()
        XCTAssertEqual(report.sites.map(\.column), [1, 7])
        XCTAssertEqual(report.sites.map(\.targetBase), ["A", "T"])
        XCTAssertEqual(report.targetNames, ["t1", "t2", "t3"])
        XCTAssertEqual(report.exclusionNames, ["x1", "x2", "x3"])
        XCTAssertEqual(report.alignedLength, 7)
    }

    func testConservedColumnIsNotDiscriminating() throws {
        // Column 2 is identical everywhere, the exact trap the feature exists
        // to expose: conservation across targets is not specificity.
        XCTAssertFalse(try analyze().sites.contains { $0.column == 2 })
    }

    func testColumnWithAMatchingExclusionIsExcludedUnlessThresholdLowered() throws {
        XCTAssertFalse(try analyze().sites.contains { $0.column == 3 })

        let relaxed = try analyze(minimumDifferences: 2)
        let site = try XCTUnwrap(relaxed.sites.first { $0.column == 3 })
        XCTAssertEqual(site.exclusionDifferenceCount, 2)
        XCTAssertEqual(site.exclusionMatchCount, 1)
        XCTAssertEqual(site.exclusionDifferences.map(\.name), ["x2", "x3"])
    }

    func testDisagreeingTargetsAreExcludedUntilToleranceAllowsThem() throws {
        XCTAssertFalse(try analyze().sites.contains { $0.column == 4 })

        let tolerant = try analyze(tolerance: 1)
        let site = try XCTUnwrap(tolerant.sites.first { $0.column == 4 })
        XCTAssertEqual(site.targetBase, "A")
        XCTAssertEqual(site.dissentingTargets, [.init(name: "t3", base: "C")])
        XCTAssertEqual(site.exclusionDifferenceCount, 3)
    }

    func testAmbiguousAndGappedExclusionBasesCountAsNoCallNotDifference() throws {
        // Column 5: x1 has N, x2 has a gap, x3 has G. Only x3 truly differs, so
        // the column must not pass the strict threshold; an ambiguous row may
        // never manufacture apparent specificity.
        XCTAssertFalse(try analyze().sites.contains { $0.column == 5 })

        let site = try XCTUnwrap(try analyze(minimumDifferences: 1).sites.first { $0.column == 5 })
        XCTAssertEqual(site.exclusionNoCallCount, 2)
        XCTAssertEqual(site.exclusionDifferenceCount, 1)
        XCTAssertEqual(site.exclusionDifferences.map(\.base), ["G"])
    }

    func testColumnWhereATargetHasAGapIsSkipped() throws {
        XCTAssertFalse(try analyze(minimumDifferences: 1).sites.contains { $0.column == 6 })
    }

    func testTemplatePositionsSkipTemplateGaps() throws {
        let report = try analyze()
        // Template t1 is AAAAA-T, so column 7 is template base 6, not 7.
        XCTAssertEqual(report.sites.first { $0.column == 1 }?.templatePosition, 1)
        XCTAssertEqual(report.sites.first { $0.column == 7 }?.templatePosition, 6)
    }

    func testExclusionBasesSummarizesDistinctBases() throws {
        let site = try XCTUnwrap(try analyze().sites.first { $0.column == 1 })
        XCTAssertEqual(site.exclusionBases, "G")
        XCTAssertEqual(site.exclusionDifferences.map(\.name), ["x1", "x2", "x3"])
    }

    // MARK: - Candidate windows

    func testWindowGathersClusteredSitesAndReportsSpan() throws {
        let report = try analyze(windowLength: 25)
        let window = try XCTUnwrap(report.windows.first)
        XCTAssertEqual(window.siteCount, 2)
        XCTAssertEqual(window.columns, [1, 7])
        XCTAssertEqual(window.templatePositions, [1, 6])
        XCTAssertEqual(window.startTemplatePosition, 1)
        XCTAssertEqual(window.endTemplatePosition, 6)
    }

    func testWindowShorterThanTheSiteSpacingYieldsNoWindow() throws {
        // Sites sit at template 1 and 6, so a 5 bp oligo cannot span both.
        XCTAssertTrue(try analyze(windowLength: 5).windows.isEmpty)
    }

    func testWindowsRankStrongestFirstAndDropSubsumedRuns() throws {
        // Three sites 10 bases apart: a 25 bp window holds the first two and
        // the last two, while a 30 bp window holds all three and must subsume
        // the smaller runs rather than listing them alongside.
        let targets = [Row(name: "t1", sequence: String(repeating: "A", count: 31))]
        var exclusion = Array(repeating: Character("A"), count: 31)
        for index in [0, 10, 20] { exclusion[index] = "G" }
        let exclusions = [Row(name: "x1", sequence: String(exclusion))]

        let wide = try DiscriminatingSitesAnalysis.analyze(
            targets: targets, exclusions: exclusions,
            options: .init(windowLength: 30))
        XCTAssertEqual(wide.sites.map(\.column), [1, 11, 21])
        XCTAssertEqual(wide.windows.count, 1)
        XCTAssertEqual(wide.windows[0].siteCount, 3)

        let narrow = try DiscriminatingSitesAnalysis.analyze(
            targets: targets, exclusions: exclusions,
            options: .init(windowLength: 15))
        XCTAssertEqual(narrow.windows.map(\.templatePositions), [[1, 11], [11, 21]])
    }

    func testSitesInTemplateGapsAreNotPlacedInWindows() throws {
        // A discriminating column that the template does not cover cannot be
        // reached by an oligo designed on that template.
        let targets = [Row(name: "t1", sequence: "A-A")]
        let exclusions = [Row(name: "x1", sequence: "GGG")]
        let report = try DiscriminatingSitesAnalysis.analyze(
            targets: targets, exclusions: exclusions, options: .init(windowLength: 25))
        XCTAssertEqual(report.sites.map(\.column), [1, 3])
        XCTAssertEqual(report.windows.first?.templatePositions, [1, 2])
    }

    // MARK: - Validation

    func testRejectsEmptyTargetsAndExclusions() {
        let row = [Row(name: "a", sequence: "AC")]
        XCTAssertThrowsError(try DiscriminatingSitesAnalysis.analyze(targets: [], exclusions: row)) {
            XCTAssertEqual($0 as? DiscriminatingSitesAnalysis.Failure, .noTargets)
        }
        XCTAssertThrowsError(try DiscriminatingSitesAnalysis.analyze(targets: row, exclusions: [])) {
            XCTAssertEqual($0 as? DiscriminatingSitesAnalysis.Failure, .noExclusions)
        }
    }

    func testRejectsRaggedAlignment() {
        XCTAssertThrowsError(try DiscriminatingSitesAnalysis.analyze(
            targets: [Row(name: "t", sequence: "ACGT")],
            exclusions: [Row(name: "x", sequence: "ACG")]
        )) { XCTAssertEqual($0 as? DiscriminatingSitesAnalysis.Failure, .unequalWidths) }
    }

    func testRejectsToleranceThatWouldAcceptEveryColumn() {
        // A tolerance equal to the target count would let a column qualify with
        // no agreeing target at all.
        XCTAssertThrowsError(try DiscriminatingSitesAnalysis.analyze(
            targets: targets, exclusions: exclusions,
            options: .init(targetMismatchTolerance: 3)
        )) {
            XCTAssertEqual(
                $0 as? DiscriminatingSitesAnalysis.Failure,
                .invalidTolerance(3, targetCount: 3))
        }
    }

    func testRejectsDuplicateRowNamesAcrossTargetsAndExclusions() {
        XCTAssertThrowsError(try DiscriminatingSitesAnalysis.analyze(
            targets: [Row(name: "same", sequence: "A")],
            exclusions: [Row(name: "same", sequence: "G")]
        )) {
            XCTAssertEqual($0 as? DiscriminatingSitesAnalysis.Failure, .duplicateRowName("same"))
        }
    }

    func testRejectsZeroWindowLength() {
        XCTAssertThrowsError(try DiscriminatingSitesAnalysis.analyze(
            targets: targets, exclusions: exclusions, options: .init(windowLength: 0)
        )) {
            XCTAssertEqual($0 as? DiscriminatingSitesAnalysis.Failure, .invalidWindowLength(0))
        }
    }

    // MARK: - Serialization

    func testSiteTSVCarriesHeaderAndPerColumnDetail() throws {
        let tsv = DiscriminatingSitesReportFormatter.siteTSV(for: try analyze())
        let lines = tsv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, DiscriminatingSitesReportFormatter.siteColumns.joined(separator: "\t"))
        XCTAssertEqual(lines.count, 3)
        let fields = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(fields[0], "1")
        XCTAssertEqual(fields[1], "1")
        XCTAssertEqual(fields[2], "A")
        XCTAssertEqual(fields[3], "3")
        XCTAssertEqual(fields[7], "x1:G;x2:G;x3:G")
        XCTAssertTrue(tsv.hasSuffix("\n"))
    }

    func testWindowTSVCarriesHeaderAndSpan() throws {
        let lines = DiscriminatingSitesReportFormatter.windowTSV(for: try analyze())
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, DiscriminatingSitesReportFormatter.windowColumns.joined(separator: "\t"))
        XCTAssertEqual(lines[1].split(separator: "\t").map(String.init), ["1", "6", "1", "7", "2", "1;6"])
    }

    func testJSONRoundTripsThroughTheReportSchema() throws {
        let report = try analyze()
        let decoded = try JSONDecoder().decode(
            DiscriminatingSitesAnalysis.Report.self,
            from: try DiscriminatingSitesReportFormatter.json(for: report))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.schemaVersion, DiscriminatingSitesAnalysis.Report.schemaVersion)
    }

    func testSummaryLinesNameTargetsExclusionsAndWindows() throws {
        let lines = DiscriminatingSitesReportFormatter.summaryLines(for: try analyze())
        XCTAssertEqual(lines[0], "Targets: 3 (template t1)")
        XCTAssertEqual(lines[1], "Exclusions: 3")
        XCTAssertEqual(lines[2], "Discriminating columns: 2")
        XCTAssertEqual(lines[3], "Candidate windows (25 bp): 1")
    }
}
