import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI

/// Phase 2.10 lane B35, panel decision R2. `genotype list-cohorts` prints the
/// id of each smart cohort in a last column headed `id`, the lower-case UUID
/// that `genotype export-labkey` writes as `cohort_id`. An analyst can then see
/// which id a cohort carries, and which cohorts share one when the export
/// refuses. The listing only reads, so it prints a sidecar that the export
/// refuses.
///
/// The header word is `id`, one lower-case word like the five before it, and it
/// parallels `name`, which is the `cohort_name` column of the CSV.
final class GenotypeCohortListingIdTests: XCTestCase {
    typealias Pins = GenotypeCohortListingPinTests
    typealias Identity = GenotypeCohortIdentityExportTests
    typealias Collision = GenotypeCohortIdCollisionTests

    func testTheHeaderAddsOneWordAfterTheFiveItHadBefore() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-header")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Identity.makeFiveCohortBundle(in: root)

        let table = Self.table(try await Pins.listCohorts(bundle))

        XCTAssertEqual(table.first, ["starred", "name", "scope", "matches", "description", "id"])
        XCTAssertTrue(table.allSatisfy { $0.count == 6 }, "every row has six columns")
    }

    /// The id column is the `cohort_id` column of the export, row for row, for
    /// a stored id in either case and for ids that are derived.
    func testTheIdColumnIsTheCohortIdOfTheExportForEveryRow() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-export")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Identity.makeFiveCohortBundle(in: root)
        try Identity.storeIDs([nil, Collision.sharedID.uppercased(), nil, nil, Collision.otherSharedID], in: bundle)

        let listing = Self.table(try await Pins.listCohorts(bundle)).dropFirst()
        let exported = Identity.rows(try await Identity.export(bundle, root: root))

        XCTAssertEqual(listing.map { Self.cell($0, 1) }, exported.map { $0.name })
        XCTAssertEqual(listing.map { Self.cell($0, 5) }, exported.map { $0.id })
        XCTAssertEqual(listing.map { Self.cell($0, 5) }, [
            Identity.incompleteID, Collision.sharedID, Identity.homozygousID, Identity.recombinantsID, Collision.otherSharedID,
        ])
    }

    /// Two cohorts with one scope and name show their two ids, which is how an
    /// analyst tells them apart.
    func testTwoCohortsOfOneScopeAndNameShowTheirDistinctIds() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-twins")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Pins.makeBundle(in: root, smartCohorts: Collision.twinsOfErrors(count: 2))

        let table = Self.table(try await Pins.listCohorts(bundle)).dropFirst()

        XCTAssertEqual(table.map { Self.cell($0, 1) }, ["Errors at MHC-A", "Errors at MHC-A"])
        XCTAssertEqual(table.map { Self.cell($0, 5) }, [Identity.errorsID, Identity.errorsSecondID])
    }

    /// The listing does not refuse. It prints the two rows with the one id that
    /// the export refuses.
    func testTwoCohortsThatShareAnIdAreBothListedWithThatId() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-shared")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Collision.makeBundleWithSharedID(in: root)

        let table = Self.table(try await Pins.listCohorts(bundle)).dropFirst()

        XCTAssertEqual(table.map { Self.cell($0, 1) }, Identity.fiveNames)
        XCTAssertEqual(table.map { Self.cell($0, 5) }, [
            Identity.incompleteID, Collision.sharedID, Identity.homozygousID, Identity.recombinantsID, Collision.sharedID,
        ])
    }

    /// A bundle with no cohort prints the header alone, now with `id`.
    func testABundleWithNoCohortPrintsTheHeaderAlone() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-listing-empty")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Pins.makeBundle(in: root, smartCohorts: [])

        let listing = try await Pins.listCohorts(bundle)

        XCTAssertEqual(listing, "starred\tname\tscope\tmatches\tdescription\tid\n")
    }

    /// Column `index` of `row`, or a marker when the row is shorter, so a missing
    /// column fails the test and does not stop the run.
    private static func cell(_ row: [String], _ index: Int) -> String {
        index < row.count ? row[index] : "<no column \(index)>"
    }

    /// The rows of a listing, each split at its tabs.
    private static func table(_ listing: String) -> [[String]] {
        listing.split(separator: "\n").map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }
}
