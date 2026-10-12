import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI

/// What `genotype list-cohorts` and `genotype export-labkey` print for the
/// smart cohorts of a bundle whose sidecar holds the four built-in cohorts and
/// one of the analyst's own. Both commands read only the file. Plan decision
/// S13 records a deleted built-in in the sidecar settings, and these pins show
/// that a bundle with no dismissal prints as it did before. The sidecars here
/// store no cohort id, as every sidecar saved before Phase 2.8 stores none, so
/// the export derives each `cohort_id` from the cohort's scope and name (plan
/// decisions O2 and G2). The expected ids are Python `uuid.uuid5` values of
/// `json.dumps([scope, name], separators=(",", ":"), ensure_ascii=False)` under
/// the namespace `EAE6B16C-E0F3-4099-B3D7-DB52CED9199C`, so they share no code
/// with the Swift derivation.
final class GenotypeCohortListingPinTests: XCTestCase {
    static let noDismissalListing = """
    starred\tname\tscope\tmatches\tdescription
    *\tIncomplete haplotypes\tbundle\t2\tSamples with unresolved, not-assayed, or error haplotype slots.
    *\tNeeds review\tbundle\t2\tIncomplete haplotypes, low support, or analyst-flagged samples.
    -\tHomozygous\tbundle\t0\tSamples whose H1 equals H2 at every called locus.
    -\tRecombinants\tbundle\t0\tSamples carrying a rec* haplotype at any locus.
    *\tErrors at MHC-A\tbundle\t0\tSamples that fail to call any haplotype at MHC-A.

    """

    static let noDismissalSmartCohortsCSV = """
    cohort_id,cohort_name,predicate_json,created_at,sample_count
    31D2B132-01DD-5F19-BC0A-8878472F012F,Incomplete haplotypes,"{""kind"":""needsHaplotypeReview""}",2026-05-22T10:00:00Z,2
    DF4CA8E2-BF22-50FC-8C94-BDB45C58A1F5,Needs review,"{""children"":[{""kind"":""needsHaplotypeReview""},{""kind"":""qcStatus"",""set"":[""lowSupport"",""review""]},{""kind"":""hasAnalystFlag"",""value"":""needsReview""}],""kind"":""any""}",2026-05-22T10:00:00Z,2
    5FD26AEC-1025-5049-AE30-F43C219E9A7A,Homozygous,"{""kind"":""isHomozygousAcrossAll""}",2026-05-22T10:00:00Z,0
    048C9D06-A36A-5243-BEEC-7F2F591D780A,Recombinants,"{""kind"":""hasRegionalRecombinant""}",2026-05-22T10:00:00Z,0
    3C5638B5-3D64-5064-AC68-20AE371E14D2,Errors at MHC-A,"{""kind"":""hasErrorAt"",""locus"":""MHC-A""}",2026-05-22T10:00:00Z,0

    """

    func testListCohortsOfABundleWithNoDismissalsPrintsEveryCohortTheFileHolds() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-pin")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundle(in: root, smartCohorts: Self.builtInCohorts + [Self.analystCohort])

        let listing = try await Self.listCohorts(bundle)

        XCTAssertEqual(listing, Self.noDismissalListing)
    }

    func testExportLabKeyOfABundleWithNoDismissalsWritesEveryCohortTheFileHolds() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-labkey-pin")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundle(in: root, smartCohorts: Self.builtInCohorts + [Self.analystCohort])

        let csv = try await Self.exportLabKeySmartCohorts(bundle, root: root)

        XCTAssertEqual(csv, Self.noDismissalSmartCohortsCSV)
    }

    /// The sidecar the app saves after Phase 2.8 stores each cohort's id, which
    /// for these cohorts is the id the older sidecar derives. Both commands
    /// print what they printed for the older sidecar.
    func testASidecarThatStoresTheDerivedIdsPrintsTheSameListingAndTheSameCSV() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-stored")
        defer { TestTempDirectory.cleanup(root) }
        let stored = (Self.builtInCohorts + [Self.analystCohort]).map { cohort -> GenotypeCohortSmartFilter in
            var copy = cohort
            copy.id = GenotypeCohortSmartFilter.derivedID(scope: cohort.scope, name: cohort.name)
            return copy
        }
        let bundle = try Self.makeBundle(in: root, smartCohorts: stored)

        let listing = try await Self.listCohorts(bundle)
        let csv = try await Self.exportLabKeySmartCohorts(bundle, root: root)

        XCTAssertEqual(listing, Self.noDismissalListing)
        XCTAssertEqual(csv, Self.noDismissalSmartCohortsCSV)
    }

    // MARK: - A dismissed built-in (S13)

    /// The sidecar the app writes when the analyst deletes the built-in
    /// Homozygous cohort. The cohort leaves `smartCohorts` and its name is
    /// recorded as a dismissal.
    static func makeBundleWithDismissedHomozygous(in root: URL) throws -> URL {
        var settings = GenotypeAnnotationSidecar.Settings.default
        settings.dismissedBuiltInSmartCohorts = ["Homozygous"]
        return try makeBundle(
            in: root,
            smartCohorts: (builtInCohorts + [analystCohort]).filter { $0.name != "Homozygous" },
            settings: settings
        )
    }

    func testListCohortsOfABundleWithADismissedBuiltInDiffersOnlyByThatCohort() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-dismissed")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundleWithDismissedHomozygous(in: root)

        let listing = try await Self.listCohorts(bundle)

        let expected = Self.noDismissalListing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("-\tHomozygous\t") }
            .joined(separator: "\n")
        XCTAssertEqual(listing, expected)
    }

    /// `cohort_id` names the cohort and not its place in the file (plan
    /// decision O2), so the rows after the dismissed one keep their ids and the
    /// export is the export without that cohort, row for row.
    func testExportLabKeyOfABundleWithADismissedBuiltInDiffersOnlyByThatCohort() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-labkey-dismissed")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundleWithDismissedHomozygous(in: root)

        let csv = try await Self.exportLabKeySmartCohorts(bundle, root: root)

        let baseRows = Self.noDismissalSmartCohortsCSV.split(separator: "\n").dropFirst()
            .filter { !$0.contains(",Homozygous,") }
        let rows = csv.split(separator: "\n")
        XCTAssertEqual(rows.first, Self.noDismissalSmartCohortsCSV.split(separator: "\n").first)
        XCTAssertEqual(Array(rows.dropFirst()), Array(baseRows))
    }

    // MARK: - Fixture

    /// The built-in smart cohorts as an older Lungfish wrote them with a
    /// bundle's first edit, with no stored id. The command line holds no copy of
    /// this list.
    static let builtInCohorts: [GenotypeCohortSmartFilter] = [
        GenotypeCohortSmartFilter(
            name: "Incomplete haplotypes",
            description: "Samples with unresolved, not-assayed, or error haplotype slots.",
            scope: "bundle", isStarred: true, predicate: .needsHaplotypeReview
        ),
        GenotypeCohortSmartFilter(
            name: "Needs review",
            description: "Incomplete haplotypes, low support, or analyst-flagged samples.",
            scope: "bundle", isStarred: true,
            predicate: .any([.needsHaplotypeReview, .qcStatus([.review, .lowSupport]), .hasAnalystFlag(.needsReview)])
        ),
        GenotypeCohortSmartFilter(
            name: "Homozygous",
            description: "Samples whose H1 equals H2 at every called locus.",
            scope: "bundle", isStarred: false, predicate: .isHomozygousAcrossAll
        ),
        GenotypeCohortSmartFilter(
            name: "Recombinants",
            description: "Samples carrying a rec* haplotype at any locus.",
            scope: "bundle", isStarred: false, predicate: .hasRegionalRecombinant
        ),
    ]

    static let analystCohort = GenotypeCohortSmartFilter(
        name: "Errors at MHC-A",
        description: "Samples that fail to call any haplotype at MHC-A.",
        scope: "bundle", isStarred: true, predicate: .hasErrorAt(locus: "MHC-A")
    )

    /// A haplotyped two-animal bundle. AnimalA has an unresolved second
    /// haplotype at MHC-DQ and AnimalB has no haplotype at MHC-DRB.
    static func makeBundle(
        in root: URL,
        smartCohorts: [GenotypeCohortSmartFilter],
        settings: GenotypeAnnotationSidecar.Settings = .default
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("cohorts.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("workbook".utf8).write(to: bundleURL.appendingPathComponent("cohorts.xlsx"))
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json"))
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        AnimalA,01_M1A_A1_063,42,39,100,46,46.0,1000,60,6.0
        AnimalA,02_M3A_A2_010,30,30,100,46,46.0,1000,60,6.0
        AnimalB,13_Mafa_DRB1_06,12,12,90,4,4.4,1000,60,6.0
        """.write(to: bundleURL.appendingPathComponent("cohorts.retained-demux-genotypes.csv"), atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        AnimalA,72,69,100,46.0,1000,6.0
        AnimalB,12,12,90,4.4,1000,6.0
        """.write(to: bundleURL.appendingPathComponent("cohorts.retained-demux-samples.csv"), atomically: true, encoding: .utf8)
        try """
        {"totalInputReads": 1000, "totalAlignments": 120, "passedAlignments": 84, "retainedUniqueReads": 60,
         "retainedUniquePercentOfTotalReads": 6.0, "assignedUniqueRetainedReads": 53, "unassignedUniqueRetainedReads": 7}
        """.write(to: bundleURL.appendingPathComponent("cohorts.retained-demux-stats.json"), atomically: true, encoding: .utf8)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus",
            speciesName: "Macaca fascicularis",
            generatedAt: "2026-05-22T10:00:00Z",
            samples: [
                GenotypeHaplotypeSampleAnalysis(sample: "AnimalA", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-A", sourceLocus: "Mafa-A", haplotype1: "M1A", haplotype2: "M3A",
                        status: .called, matchedHaplotypes: [], observedGenotypeCount: 2,
                        observedGenotypes: ["01_M1A_A1_063", "02_M3A_A2_010"]
                    ),
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-DQ", sourceLocus: "Mafa-DQ", haplotype1: "M2DQ", haplotype2: "?",
                        status: .unresolvedSecondHaplotype, matchedHaplotypes: [], observedGenotypeCount: 2,
                        observedGenotypes: ["05_M2DQ_DQ_001", "06_DQ_novel"]
                    ),
                ]),
                GenotypeHaplotypeSampleAnalysis(sample: "AnimalB", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-DRB", sourceLocus: "Mafa-DRB", haplotype1: "ERR: NO HAP", haplotype2: "ERR: NO HAP",
                        status: .noHaplotype, matchedHaplotypes: [], observedGenotypeCount: 1,
                        observedGenotypes: ["13_Mafa_DRB1_06"]
                    ),
                ]),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(analysis).write(to: bundleURL.appendingPathComponent("haplotype-analysis.json"))
        try ONTGenotypeResultBundle.writeManifest(ONTGenotypeResultBundleManifest(
            outputName: "cohorts",
            analysisName: "Cohorts",
            primaryWorkbookPath: "cohorts.xlsx",
            longSummaryCSVPath: "cohorts.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "cohorts.retained-demux-samples.csv",
            statsJSONPath: "cohorts.retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json",
            haplotypeAnalysisPath: "haplotype-analysis.json",
            haplotypeDefinitionSetID: "mauritian-cynomolgus-macaques",
            createdAt: "2026-05-22T10:00:00Z"
        ), to: bundleURL)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T10:00:00Z")
        sidecar.smartCohorts = smartCohorts
        sidecar.settings = settings
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        return bundleURL
    }

    static func listCohorts(_ bundle: URL) async throws -> String {
        let command = try GenotypeListCohortsSubcommand.parse(["--bundle", bundle.path])
        return try await captureStandardOutput { try await command.run() }
    }

    /// The `smart_cohorts.csv` that `genotype export-labkey` writes.
    static func exportLabKeySmartCohorts(_ bundle: URL, root: URL) async throws -> String {
        let outputDir = root.appendingPathComponent("labkey-\(UUID().uuidString)", isDirectory: true)
        let command = try GenotypeExportLabKeySubcommand.parse([
            "--bundle", bundle.path, "--output-dir", outputDir.path,
        ])
        try await command.run()
        return try String(contentsOf: outputDir.appendingPathComponent("smart_cohorts.csv"), encoding: .utf8)
    }

    private static func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let thrown { throw thrown }
        return String(decoding: data, as: UTF8.self)
    }
}
