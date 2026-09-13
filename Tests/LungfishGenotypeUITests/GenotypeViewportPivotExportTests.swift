import XCTest
import LungfishKit
import LungfishIO
@testable import LungfishGenotypeUI

/// Covers routing the viewport's "Export Filtered Pivot" action to
/// `genotype export-pivot-xlsx` with the analyst's Min Reads and Min Percent
/// already applied.
///
/// Context: analysts were exporting the unfiltered pivot and stripping
/// low-support background by hand in Excel. Carrying the viewport thresholds
/// into the export removes that manual step.
final class GenotypeViewportPivotExportTests: XCTestCase {

    func testProjectionSerializesExactOrderedCallsAndRevisionContext() throws {
        let call = GenotypeViewProjectionHaplotypeCall(
            sample: "A1",
            locus: "MHC-DRB",
            haplotype1: "M4DR",
            haplotype2: "M4DR",
            haplotype1Status: "called",
            haplotype2Status: "called",
            haplotype1Source: "pipeline",
            haplotype2Source: "pipeline",
            baselineHaplotype1: "M4DR",
            baselineHaplotype2: "-",
            comment: "confirmed"
        )
        let sourceRevision = GenotypeViewProjectionSourceRevision(
            assayID: "assay",
            analysisRevisionID: "revision-7",
            definitionSetID: "definitions"
        )
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/run.lungfishgenotype"),
            analysisName: "Run",
            lens: "comparison",
            filters: ["matrixMinimumReads": "5"],
            sampleNames: ["A1"],
            rows: [],
            haplotypeCalls: [call],
            sourceRevision: sourceRevision
        )

        let projection = GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
        XCTAssertEqual(projection.haplotypeCalls, [call])
        XCTAssertEqual(projection.sourceRevision, sourceRevision)
        XCTAssertEqual(projection.filterContext, ["matrixMinimumReads": "5"])
        let decoded = try JSONDecoder().decode(
            GenotypeViewProjection.self,
            from: JSONEncoder().encode(projection)
        )
        XCTAssertEqual(decoded, projection)
    }

}
