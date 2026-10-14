import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI

/// Phase 2.10 lane B35, panel decision R2. Two smart cohorts of one sidecar
/// that resolve to one `cohort_id` would be exported twice under that id, and a
/// reader of the LabKey table could not tell them apart.
///
/// The ids here are Python `uuid.uuid5` values, as in
/// `GenotypeCohortIdentityExportTests`, so they share no code with the Swift
/// derivation. A stored id is written into the sidecar file as JSON.
final class GenotypeCohortIdCollisionTests: XCTestCase {
    typealias Pins = GenotypeCohortListingPinTests
    typealias Identity = GenotypeCohortIdentityExportTests

    /// The id of the third cohort named "Errors at MHC-A" in scope "bundle".
    static let errorsThirdID = "a93ed129-7806-592e-81b8-66fbf6128a02"

    // MARK: - What the export does at the base

    /// Two cohorts with different names that store one id (a cohort copied
    /// under a new name with its id) are exported twice with that id.
    func testTwoCohortsThatStoreOneIdAreExportedWithThatIdTwice() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-collision-stored")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Identity.makeFiveCohortBundle(in: root)
        let shared = Identity.storedElsewhereID
        try Identity.storeIDs([nil, shared, nil, nil, shared], in: bundle)

        let rows = Identity.rows(try await Identity.export(bundle, root: root))

        XCTAssertEqual(rows.map { $0.name }, Identity.fiveNames)
        XCTAssertEqual(rows.map { $0.id }, [
            Identity.incompleteID, shared, Identity.homozygousID, Identity.recombinantsID, shared,
        ])
    }

    /// Two cohorts with one scope and name that store one id (one cohort saved
    /// twice with its id) are exported twice with that id.
    func testTwoCohortsOfOneScopeAndNameThatStoreOneIdAreExportedWithThatIdTwice() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-collision-twins")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Pins.makeBundle(in: root, smartCohorts: Self.twinsOfErrors(count: 2))
        try Identity.storeIDs([Identity.errorsID, Identity.errorsID], in: bundle)

        let rows = Identity.rows(try await Identity.export(bundle, root: root))

        XCTAssertEqual(rows.map { $0.name }, ["Errors at MHC-A", "Errors at MHC-A"])
        XCTAssertEqual(rows.map { $0.id }, [Identity.errorsID, Identity.errorsID])
    }

    /// A UUID reads from either case, so ids stored as upper and lower case text
    /// are one id, and the export writes it in lower case twice.
    func testIdsStoredInUpperAndLowerCaseAreOneIdAndExportedTwice() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-collision-case")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Identity.makeFiveCohortBundle(in: root)
        let shared = Identity.storedElsewhereID
        try Identity.storeIDs([nil, shared.uppercased(), nil, nil, shared], in: bundle)

        let rows = Identity.rows(try await Identity.export(bundle, root: root))

        XCTAssertEqual(rows.map { $0.id }, [
            Identity.incompleteID, shared, Identity.homozygousID, Identity.recombinantsID, shared,
        ])
    }

    /// The second case of the brief, two cohorts with one scope and name that
    /// derive one id, cannot be built. A cohort that stores no id derives the id
    /// of its place among the cohorts of its scope and name, and moves past any
    /// id that a cohort stores or an earlier cohort derived (`resolvedIDs`). So
    /// only two stored ids can be equal, and these arrangements give distinct ids.
    func testCohortsOfOneScopeAndNameThatStoreNoSharedIdResolveToDistinctIds() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-collision-derived")
        defer { TestTempDirectory.cleanup(root) }

        let storedFirstPlace = try Pins.makeBundle(
            in: root.appendingPathComponent("a", isDirectory: true).createdFolder(),
            smartCohorts: Self.twinsOfErrors(count: 2)
        )
        try Identity.storeIDs([nil, Identity.errorsID], in: storedFirstPlace)
        let afterStoredFirstPlace = Identity.rows(try await Identity.export(storedFirstPlace, root: root))
        XCTAssertEqual(
            afterStoredFirstPlace.map { $0.id },
            [Identity.errorsSecondID, Identity.errorsID],
            "the cohort without an id moves past the id the other one stores"
        )

        let storedSecondPlace = try Pins.makeBundle(
            in: root.appendingPathComponent("b", isDirectory: true).createdFolder(),
            smartCohorts: Self.twinsOfErrors(count: 3)
        )
        try Identity.storeIDs([nil, nil, Identity.errorsSecondID], in: storedSecondPlace)
        let afterStoredSecondPlace = Identity.rows(try await Identity.export(storedSecondPlace, root: root))
        XCTAssertEqual(
            afterStoredSecondPlace.map { $0.id },
            [Identity.errorsID, Self.errorsThirdID, Identity.errorsSecondID]
        )
    }

    // MARK: - Fixture

    /// `count` cohorts named "Errors at MHC-A" in scope "bundle" that differ by
    /// their predicate, in sidecar order.
    static func twinsOfErrors(count: Int) -> [GenotypeCohortSmartFilter] {
        let predicates: [SmartCohortPredicate] = [.hasErrorAt(locus: "MHC-A"), .hasAnyComment, .needsHaplotypeReview]
        return predicates.prefix(count).map { predicate in
            var cohort = Pins.analystCohort
            cohort.predicate = predicate
            return cohort
        }
    }
}

private extension URL {
    /// This folder, created with its parents, for a test that builds two bundles.
    func createdFolder() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
