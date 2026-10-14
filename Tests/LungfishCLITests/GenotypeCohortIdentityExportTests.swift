import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI

/// Plan decisions O2 and G2. `genotype export-labkey` writes a `cohort_id` that
/// names the cohort, so deleting, dismissing, restoring or renaming one cohort
/// never renumbers another. A cohort stores an optional `id`. A cohort without
/// one gets a UUID version 5 over its scope and name, derived on read, and a
/// read writes nothing. The next save of the sidecar stores the derived value.
///
/// These tests work on the sidecar file as JSON wherever they need a stored id,
/// so they state the key `id` that older and newer readers share. The expected
/// ids are Python `uuid.uuid5` values of
/// `json.dumps([scope, name], separators=(",", ":"), ensure_ascii=False)`, with
/// `, n` appended for the n-th cohort of one scope and name when n is 2 or more,
/// under the namespace `EAE6B16C-E0F3-4099-B3D7-DB52CED9199C`. They share no code
/// with the Swift derivation.
final class GenotypeCohortIdentityExportTests: XCTestCase {
    typealias Pins = GenotypeCohortListingPinTests

    static let incompleteID = "31d2b132-01dd-5f19-bc0a-8878472f012f"
    static let needsReviewID = "df4ca8e2-bf22-50fc-8c94-bdb45c58a1f5"
    static let homozygousID = "5fd26aec-1025-5049-ae30-f43c219e9a7a"
    static let recombinantsID = "048c9d06-a36a-5243-beec-7f2f591d780a"
    static let errorsID = "3c5638b5-3d64-5064-ac68-20ae371e14d2"
    static let errorsSecondID = "8e1dcaba-dfbd-53c8-adaf-9ad629d5260a"
    static let errorsUserScopeID = "bcb2419c-de8d-5124-9463-9e07f479276a"
    static let brandNewID = "89fdcf67-c549-5109-ad54-2654973702e2"
    /// A stored id no derivation produces, for a cohort the sidecar names apart from the others.
    static let storedElsewhereID = "6a1f0c52-3b7d-4e0a-9c58-0d2b7e41a9f3"

    /// The ids of the five cohorts of `Pins.makeBundle`, in file order.
    static let fiveIDs = [incompleteID, needsReviewID, homozygousID, recombinantsID, errorsID]
    static let fiveNames = ["Incomplete haplotypes", "Needs review", "Homozygous", "Recombinants", "Errors at MHC-A"]

    // MARK: - Deleting, restoring and renaming

    func testDeletingACohortKeepsEveryOtherId() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-delete")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        let before = Self.idsByName(try await Self.export(bundle, root: root))
        XCTAssertEqual(before, Dictionary(uniqueKeysWithValues: zip(Self.fiveNames, Self.fiveIDs)))

        try Self.rewriteCohorts(in: bundle) { $0.removeAll { $0.name == "Needs review" } }

        var expected = before
        expected["Needs review"] = nil
        let after = Self.idsByName(try await Self.export(bundle, root: root))
        XCTAssertEqual(after, expected)
    }

    func testRestoringACohortAtTheEndOfTheFileGivesItItsOldIdAndLeavesTheOthers() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-restore")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        let before = Self.idsByName(try await Self.export(bundle, root: root))
        let homozygous = Pins.builtInCohorts[2]
        try Self.rewriteCohorts(in: bundle) { $0.removeAll { $0.name == "Homozygous" } }
        let dismissed = Self.rows(try await Self.export(bundle, root: root))
        XCTAssertEqual(
            dismissed.map { $0.id },
            [Self.incompleteID, Self.needsReviewID, Self.recombinantsID, Self.errorsID],
            "the cohorts after the dismissed one keep their ids"
        )

        try Self.rewriteCohorts(in: bundle) { $0.append(homozygous) }

        let restored = Self.rows(try await Self.export(bundle, root: root))
        XCTAssertEqual(restored.map { $0.name }, ["Incomplete haplotypes", "Needs review", "Recombinants", "Errors at MHC-A", "Homozygous"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restored.map { ($0.name, $0.id) }), before)
    }

    func testARenamedCohortKeepsItsStoredIdAndEveryOtherIdStays() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-rename")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        // The next save of the sidecar stores each derived id before any rename applies.
        try Self.storeIDs(Self.fiveIDs, in: bundle)

        try Self.editCohortObjects(in: bundle) { cohorts in
            cohorts[1]["name"] = "Needs review (strict)"
        }

        let rows = Self.rows(try await Self.export(bundle, root: root))
        XCTAssertEqual(rows.map { $0.name }, ["Incomplete haplotypes", "Needs review (strict)", "Homozygous", "Recombinants", "Errors at MHC-A"])
        XCTAssertEqual(rows.map { $0.id }, Self.fiveIDs)
    }

    func testAStoredIdWinsOverTheDerivedOne() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-stored")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        try Self.storeIDs([nil, nil, Self.storedElsewhereID, nil, nil], in: bundle)

        let rows = Self.rows(try await Self.export(bundle, root: root))

        XCTAssertEqual(
            rows.map { $0.id },
            [Self.incompleteID, Self.needsReviewID, Self.storedElsewhereID, Self.recombinantsID, Self.errorsID]
        )
    }

    func testTheScopeIsPartOfTheDerivedId() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-scope")
        defer { TestTempDirectory.cleanup(root) }
        var userScoped = Pins.analystCohort
        userScoped.scope = "user"
        let bundle = try Pins.makeBundle(in: root, smartCohorts: [Pins.analystCohort, userScoped])

        let rows = Self.rows(try await Self.export(bundle, root: root))

        XCTAssertEqual(rows.map { $0.id }, [Self.errorsID, Self.errorsUserScopeID])
    }

    // MARK: - A read writes nothing

    func testListingAndExportingAnOlderSidecarWriteNothingToTheBundle() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-read")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        let before = try Self.treeDigest(of: bundle)
        XCTAssertNotNil(before[GenotypeAnnotationSidecar.filename])

        let listing = try await Pins.listCohorts(bundle)
        let rows = Self.rows(try await Self.export(bundle, root: root))

        XCTAssertEqual(listing, Pins.noDismissalListing)
        XCTAssertEqual(rows.map { $0.id }, Self.fiveIDs, "the export derives the ids")
        XCTAssertEqual(try Self.treeDigest(of: bundle), before, "and writes none of them")
        let stored = try Self.cohortObjects(in: bundle).map { $0["id"] }
        XCTAssertTrue(stored.allSatisfy { $0 == nil }, "the file still stores no id")
    }

    // MARK: - Two cohorts with one scope and name

    func testTwoCohortsWithTheSameScopeAndNameGetDistinctIdsThatRepeatOnEveryExport() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-twins")
        defer { TestTempDirectory.cleanup(root) }
        var second = Pins.analystCohort
        second.predicate = .hasAnyComment
        let bundle = try Pins.makeBundle(in: root, smartCohorts: [Pins.analystCohort, second])

        let first = Self.rows(try await Self.export(bundle, root: root))
        let again = Self.rows(try await Self.export(bundle, root: root))

        XCTAssertEqual(first.map { $0.id }, [Self.errorsID, Self.errorsSecondID])
        XCTAssertEqual(again.map { $0.id }, first.map { $0.id })
        XCTAssertEqual(Set(first.map { $0.id }).count, 2)
    }

    func testTheSecondOfTwoCohortsKeepsItsStoredIdWhenTheFirstIsDeleted() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-twins-delete")
        defer { TestTempDirectory.cleanup(root) }
        var second = Pins.analystCohort
        second.predicate = .hasAnyComment
        let bundle = try Pins.makeBundle(in: root, smartCohorts: [Pins.analystCohort, second])
        try Self.storeIDs([Self.errorsID, Self.errorsSecondID], in: bundle)

        try Self.rewriteCohorts(in: bundle) { $0.removeFirst() }

        let rows = Self.rows(try await Self.export(bundle, root: root))
        XCTAssertEqual(rows.map { $0.id }, [Self.errorsSecondID])
    }

    // MARK: - apply-annotations

    func testApplyAnnotationsStoresTheDerivedIdsAtTheSaveAndTheExportStaysTheSame() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-apply-store")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        let before = Self.rows(try await Self.export(bundle, root: root))
        let patchURL = try Self.writePatch(cohorts: [], ids: [], in: root)

        let merge = try await GenotypeApplyAnnotationsSubcommand.apply(bundleURL: bundle, patchURL: patchURL)

        XCTAssertEqual(merge.appendedCounts.smartCohorts, 0)
        XCTAssertEqual(merge.skippedDuplicateCounts.smartCohorts, 0)
        XCTAssertEqual(try Self.storedIDs(in: bundle), Self.fiveIDs.map { Optional($0) })
        let after = Self.rows(try await Self.export(bundle, root: root))
        XCTAssertEqual(after.map { $0.id }, before.map { $0.id })
        XCTAssertEqual(before.map { $0.id }, Self.fiveIDs)
    }

    func testApplyAnnotationsStoresTheDerivedIdBeforeAPatchRenamesTheCohort() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-apply-rename")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        var renamed = Pins.builtInCohorts[2]
        renamed.name = "Homozygous (strict)"
        let patchURL = try Self.writePatch(cohorts: [renamed], ids: [Self.homozygousID], in: root)

        let merge = try await GenotypeApplyAnnotationsSubcommand.apply(bundleURL: bundle, patchURL: patchURL)

        XCTAssertEqual(merge.appendedCounts.smartCohorts, 0, "the same id on both sides is one cohort")
        XCTAssertEqual(merge.skippedDuplicateCounts.smartCohorts, 1)
        XCTAssertEqual(try Self.cohortObjects(in: bundle).map { $0["name"] as? String }, Self.fiveNames)
        XCTAssertEqual(try Self.storedIDs(in: bundle), Self.fiveIDs.map { Optional($0) })
    }

    func testApplyAnnotationsMergesByIdWhenBothSidesHaveOneAndByNameAndScopeOtherwise() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-id-apply-merge")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeFiveCohortBundle(in: root)
        try Self.storeIDs(Self.fiveIDs, in: bundle)
        var renamedErrors = Pins.analystCohort
        renamedErrors.name = "Errors at MHC-A, renamed"
        var otherErrors = Pins.analystCohort
        otherErrors.predicate = .hasAnyComment
        var homozygousWithoutID = Pins.builtInCohorts[2]
        homozygousWithoutID.description = "A patch from an older Lungfish."
        var brandNew = Pins.analystCohort
        brandNew.name = "Brand new"
        let patchURL = try Self.writePatch(
            cohorts: [renamedErrors, otherErrors, homozygousWithoutID, brandNew],
            ids: [Self.errorsID, Self.storedElsewhereID, nil, nil],
            in: root
        )

        let merge = try await GenotypeApplyAnnotationsSubcommand.apply(bundleURL: bundle, patchURL: patchURL)

        XCTAssertEqual(merge.skippedDuplicateCounts.smartCohorts, 2, "the same id, and no id with the same name and scope")
        XCTAssertEqual(merge.appendedCounts.smartCohorts, 2, "another id with the same name, and a new name")
        XCTAssertEqual(
            try Self.cohortObjects(in: bundle).map { $0["name"] as? String },
            Self.fiveNames + ["Errors at MHC-A", "Brand new"]
        )
        XCTAssertEqual(
            try Self.storedIDs(in: bundle),
            (Self.fiveIDs + [Self.storedElsewhereID, Self.brandNewID]).map { Optional($0) },
            "the appended cohort without an id stores the id derived from its scope and name"
        )
    }

    // MARK: - Fixtures

    static func makeFiveCohortBundle(in root: URL) throws -> URL {
        try Pins.makeBundle(in: root, smartCohorts: Pins.builtInCohorts + [Pins.analystCohort])
    }

    static func export(_ bundle: URL, root: URL) async throws -> String {
        try await Pins.exportLabKeySmartCohorts(bundle, root: root)
    }

    /// The rows of `smart_cohorts.csv` as `(cohort_id, cohort_name)`. No name in
    /// these tests holds a comma or a quote.
    static func rows(_ csv: String) -> [(id: String, name: String)] {
        csv.split(separator: "\n").dropFirst().map { line in
            let fields = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            return (String(fields[0]), String(fields[1]))
        }
    }

    private static func idsByName(_ csv: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: rows(csv).map { ($0.name, $0.id) })
    }

    private static func sidecarURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename)
    }

    /// Edits the cohorts through the model, which keeps whatever each one stores.
    private static func rewriteCohorts(
        in bundle: URL,
        _ edit: (inout [GenotypeCohortSmartFilter]) -> Void
    ) throws {
        var sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundle)
        edit(&sidecar.smartCohorts)
        try sidecar.encoded().write(to: sidecarURL(bundle), options: .atomic)
    }

    private static func cohortObjects(in bundle: URL) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL(bundle))) as? [String: Any]
        return try XCTUnwrap(object?["smartCohorts"] as? [[String: Any]])
    }

    /// Edits the cohort objects of the file as JSON, so a stored `id` is written as
    /// the key a reader sees.
    private static func editCohortObjects(in bundle: URL, _ edit: (inout [[String: Any]]) -> Void) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL(bundle))) as? [String: Any]
        )
        var cohorts = try XCTUnwrap(object["smartCohorts"] as? [[String: Any]])
        edit(&cohorts)
        object["smartCohorts"] = cohorts
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: sidecarURL(bundle), options: .atomic)
    }

    /// Stores `ids[i]` as the `id` of cohort `i`, and none for a `nil`.
    static func storeIDs(_ ids: [String?], in bundle: URL) throws {
        try editCohortObjects(in: bundle) { cohorts in
            for (index, id) in ids.enumerated() where index < cohorts.count {
                cohorts[index]["id"] = id
            }
        }
    }

    private static func storedIDs(in bundle: URL) throws -> [String?] {
        try cohortObjects(in: bundle).map { ($0["id"] as? String)?.lowercased() }
    }

    /// A patch sidecar holding `cohorts`, each with the stored id `ids[i]` or none.
    private static func writePatch(cohorts: [GenotypeCohortSmartFilter], ids: [String?], in root: URL) throws -> URL {
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        patch.smartCohorts = cohorts
        let url = root.appendingPathComponent("patch-\(UUID().uuidString).json")
        try patch.encoded().write(to: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var objects = (object["smartCohorts"] as? [[String: Any]]) ?? []
        for (index, id) in ids.enumerated() where index < objects.count {
            objects[index]["id"] = id
        }
        object["smartCohorts"] = objects
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return url
    }

    /// Every file and folder under `bundle` with the SHA-256 of each file.
    static func treeDigest(of bundle: URL) throws -> [String: String] {
        let fileManager = FileManager.default
        var digests: [String: String] = [:]
        for relative in fileManager.enumerator(atPath: bundle.path)?.compactMap({ $0 as? String }) ?? [] {
            var isDirectory: ObjCBool = false
            let path = bundle.appendingPathComponent(relative).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                digests[relative] = "directory"
            } else {
                let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
                digests[relative] = digest.map { String(format: "%02x", $0) }.joined()
            }
        }
        return digests
    }
}
