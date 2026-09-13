import XCTest
import LungfishIO
@testable import LungfishCLI

final class GenotypePivotThresholdTests: XCTestCase {
    private func makeProjection() -> GenotypeMatrixBaseProjection {
        func call(_ sample: String, _ genotype: String, _ reads: Int, _ retained: Int) -> ONTGenotypeCall {
            ONTGenotypeCall(
                sample: sample,
                genotype: genotype,
                passedAlignments: reads * 2,
                passedUniqueReads: reads,
                sampleTotalReads: retained * 2,
                sampleUniqueRetainedReads: retained,
                sampleUniqueRetainedPercent: 50,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        let calls = [
            call("Animal1", "01_Mamu-A1_Strong", 90, 1_000),
            call("Animal1", "01_Mamu-A1_Middle", 10, 1_000),
            call("Animal1", "03_Mamu-B_Background", 4, 1_000),
            call("Animal2", "01_Mamu-A1_Strong", 60, 100),
            call("Animal2", "01_Mamu-A1_Middle", 8, 100),
        ]
        let samples = [
            ONTGenotypeSampleResult(
                sample: "Animal1",
                passedAlignments: 208,
                passedUniqueReads: 1_000,
                sampleTotalReads: 2_000,
                sampleUniqueRetainedPercent: 50,
                calls: calls.filter { $0.sample == "Animal1" }
            ),
            ONTGenotypeSampleResult(
                sample: "Animal2",
                passedAlignments: 136,
                passedUniqueReads: 100,
                sampleTotalReads: 200,
                sampleUniqueRetainedPercent: 50,
                calls: calls.filter { $0.sample == "Animal2" }
            ),
        ]
        return GenotypeMatrixBaseProjection(
            calls: calls,
            samples: samples,
            candidateDocument: nil,
            logicalSampleNames: samples.map(\.sample),
            candidateSettings: .default
        )
    }

    func testSharedProjectorUsesUniqueReadFloorAndOmitsEmptyRows() {
        let rows = makeProjection().derive(
            .init(matrixMinimumReads: 10)
        ).rows
        let middle = rows.first { $0.genotype == "01_Mamu-A1_Middle" }
        XCTAssertEqual(middle?.support(for: "Animal1")?.passedUniqueReads, 10)
        XCTAssertNil(middle?.support(for: "Animal2"))
        XCTAssertFalse(rows.contains { $0.genotype == "03_Mamu-B_Background" })
    }

    func testSharedProjectorKeepsKnownPercentDenominatorsDistinct() {
        let projection = makeProjection()
        let viewed = projection.derive(
            .init(matrixMinimumPercent: 5, matrixDenominator: .viewedLocus)
        ).rows
        let retained = projection.derive(
            .init(matrixMinimumPercent: 5, matrixDenominator: .sampleRetained)
        ).rows
        XCTAssertNotNil(
            viewed.first { $0.genotype == "01_Mamu-A1_Middle" }?
                .support(for: "Animal1")
        )
        XCTAssertNil(
            retained.first { $0.genotype == "01_Mamu-A1_Middle" }?
                .support(for: "Animal1")
        )
    }

    func testParsesReviewedFiltersAndDefaults() throws {
        let command = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output", "/tmp/out.xlsx",
            "--min-reads", "25",
            "--min-percent", "1.5",
            "--percent-basis", "viewed-locus",
            "--force",
        ])
        XCTAssertEqual(command.minReads, 25)
        XCTAssertEqual(command.minPercent, 1.5)
        XCTAssertEqual(command.percentBasis, .viewedLocus)
        XCTAssertTrue(command.force)

        let defaults = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output", "/tmp/out.xlsx",
        ])
        XCTAssertEqual(defaults.minReads, 0)
        XCTAssertEqual(defaults.minPercent, 0)
        XCTAssertEqual(defaults.percentBasis, .sampleRetained)
        XCTAssertFalse(defaults.force)
    }

    func testRetiresSourceWorkbookAndKeepEmptyRowsOptions() {
        let base = [
            "--bundle", "/tmp/b.lungfishgenotype",
            "--output", "/tmp/o.xlsx",
        ]
        XCTAssertThrowsError(
            try GenotypeExportPivotXlsxSubcommand.parse(
                base + ["--source-workbook", "/tmp/source.xlsx"]
            )
        )
        XCTAssertThrowsError(
            try GenotypeExportPivotXlsxSubcommand.parse(base + ["--keep-empty-rows"])
        )
    }

    func testRejectsNegativeAndOutOfRangeFilters() {
        let base = [
            "--bundle", "/tmp/b.lungfishgenotype",
            "--output", "/tmp/o.xlsx",
        ]
        for arguments in [
            ["--min-reads=-1"],
            ["--min-percent=-1"],
            ["--min-percent", "101"],
        ] {
            XCTAssertThrowsError(
                try GenotypeExportPivotXlsxSubcommand.parse(base + arguments)
            )
        }
    }
}
