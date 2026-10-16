import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// Phase 2.8 decisions O2 and G2 in the app. A smart cohort stores an optional
/// `id`. The four built-in cohorts carry fixed ids equal to the derivation from
/// their scope and name. Opening a bundle writes no id, and the next save of the
/// whole sidecar stores the derived id of every cohort that stores none. It
/// derives over the edited cohorts, which gives each cohort the id the export
/// derived before the edit because no app edit renames a cohort or removes part
/// of a group of one scope and name.
@MainActor
final class GenotypeAnnotationStoreCohortIdentityTests: XCTestCase {
    private static let builtInNames = ["Incomplete haplotypes", "Needs review", "Homozygous", "Recombinants"]

    /// Python `uuid.uuid5` values of `["bundle", <name>]` under the Lungfish
    /// namespace, written out so they stay fixed whatever the derivation does.
    private static let builtInIDs = [
        "31D2B132-01DD-5F19-BC0A-8878472F012F",
        "DF4CA8E2-BF22-50FC-8C94-BDB45C58A1F5",
        "5FD26AEC-1025-5049-AE30-F43C219E9A7A",
        "048C9D06-A36A-5243-BEEC-7F2F591D780A",
    ]

    // MARK: - The built-in cohorts

    func testTheBuiltInCohortsCarryTheFixedIDsOfTheirDerivation() {
        let builtIns = GenotypeAnnotationStore.builtInSmartCohorts

        XCTAssertEqual(builtIns.map(\.name), Self.builtInNames)
        XCTAssertEqual(builtIns.map { $0.id?.uuidString }, Self.builtInIDs.map { Optional($0) })
        for cohort in builtIns {
            XCTAssertEqual(cohort.id, GenotypeCohortSmartFilter.derivedID(scope: cohort.scope, name: cohort.name), cohort.name)
        }
    }

    // MARK: - Opening and saving

    func testOpeningAnOlderSidecarStoresNoIDAndShowsTheBuiltInsWithTheirFixedIDs() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        try writeSidecar(layout, cohorts: [Self.cohort("Analyst custom")])
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: true)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before, "opening writes nothing")
        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), ["Analyst custom"] + Self.builtInNames)
        XCTAssertNil(store.sidecar.smartCohorts[0].id, "the analyst's cohort stores no id until a save")
        XCTAssertEqual(store.sidecar.smartCohorts.dropFirst().map { $0.id?.uuidString }, Self.builtInIDs.map { Optional($0) })
        XCTAssertEqual(try onDisk(layout).smartCohorts.map(\.id), [nil])
    }

    func testTheFirstSaveStoresTheDerivedIDOfEveryCohortInTheFile() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        try writeSidecar(layout, cohorts: [Self.cohort("Analyst custom"), Self.cohort("Other"), Self.cohort("Analyst custom")])
        let derivedBefore = try onDisk(layout).resolvedSmartCohortIDs
        XCTAssertEqual(Set(derivedBefore).count, 3)
        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: false)

        try await store.addSampleNote(sample: "Animal-1", body: "First note")

        let saved = try onDisk(layout)
        XCTAssertEqual(saved.smartCohorts.map(\.id), derivedBefore.map { Optional($0) })
        XCTAssertEqual(saved.resolvedSmartCohortIDs, derivedBefore, "storing the ids changed no id")
        XCTAssertEqual(store.sidecar, saved, "the window shows what the file holds")
    }

    func testAnEditThatPublishesAReplayedResultLeavesTheCohortsAsTheFileHoldsThem() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        try writeSidecar(layout, cohorts: [Self.cohort("Analyst custom")])
        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: false)

        try await store.upsertMatrixComment(body: "Replayed", targets: [.column(sample: "Animal-1")], author: "analyst")

        XCTAssertEqual(try onDisk(layout).smartCohorts.map(\.id), [nil], "a replayed edit publishes exactly its replayed result")
        try await store.addSampleNote(sample: "Animal-1", body: "A whole-sidecar save")
        XCTAssertEqual(
            try onDisk(layout).smartCohorts.map(\.id),
            [GenotypeCohortSmartFilter.derivedID(scope: "bundle", name: "Analyst custom")].map { Optional($0) }
        )
    }

    // MARK: - Delete, restore and rename

    func testDeletingAndRestoringABuiltInKeepsEveryIDAndGivesTheRestoredCohortItsFixedID() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: true)
        try await store.saveSmartCohort(Self.cohort("Analyst custom"))
        let before = try idsByName(layout)
        XCTAssertEqual(before.count, 5)
        XCTAssertEqual(before["Homozygous"], Self.builtInIDs[2])

        try await store.deleteSmartCohort(name: "Homozygous", scope: "bundle")

        var expected = before
        expected["Homozygous"] = nil
        XCTAssertEqual(try idsByName(layout), expected, "no other cohort changes its id")

        let restored1 = try await store.restoreBuiltInSmartCohorts()
        XCTAssertEqual(restored1, ["Homozygous"])

        XCTAssertEqual(try idsByName(layout), before, "the restored cohort has the id it had, at the end of the list")
    }

    func testANewCohortStoresTheIDDerivedFromItsScopeAndNameAndSavingItAgainKeepsIt() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: false)
        let derived = GenotypeCohortSmartFilter.derivedID(scope: "bundle", name: "Analyst custom")

        try await store.saveSmartCohort(Self.cohort("Analyst custom"))
        XCTAssertEqual(try idsByName(layout), ["Analyst custom": derived.uuidString])

        var changed = Self.cohort("Analyst custom")
        changed.predicate = .hasErrorAtAnyLocus
        try await store.saveSmartCohort(changed)

        let saved = try onDisk(layout)
        XCTAssertEqual(saved.smartCohorts.map(\.id), [derived])
        XCTAssertEqual(saved.smartCohorts.first?.predicate, .hasErrorAtAnyLocus)
    }

    func testASavedCohortThatIsRenamedInTheFileKeepsItsIDThroughTheNextSave() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let first = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: true)
        try await first.addSampleNote(sample: "Animal-1", body: "First note")
        var sidecar = try onDisk(layout)
        XCTAssertEqual(sidecar.smartCohorts.map { $0.id?.uuidString }, Self.builtInIDs.map { Optional($0) })
        sidecar.smartCohorts[1].name = "Needs review (strict)"
        try sidecar.encoded().write(to: layout.annotationURL)

        let second = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: false)
        try await second.addSampleNote(sample: "Animal-1", body: "Second note")

        let saved = try onDisk(layout)
        XCTAssertEqual(saved.smartCohorts.map(\.name), ["Incomplete haplotypes", "Needs review (strict)", "Homozygous", "Recombinants"])
        XCTAssertEqual(saved.smartCohorts.map { $0.id?.uuidString }, Self.builtInIDs.map { Optional($0) })
    }

    func testARenamedBuiltInIsNeitherSeededNorRestoredAgainUnderItsOldName() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        var renamed = GenotypeAnnotationStore.builtInSmartCohorts[1]
        renamed.name = "Needs review (strict)"
        try writeSidecar(layout, cohorts: [renamed])

        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: true)

        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), ["Needs review (strict)", "Incomplete haplotypes", "Homozygous", "Recombinants"])
        let restored2 = try await store.restoreBuiltInSmartCohorts()
        XCTAssertEqual(restored2, [])
        try await store.addSampleNote(sample: "Animal-1", body: "A whole-sidecar save")
        let ids = try onDisk(layout).smartCohorts.compactMap(\.id)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(ids).count, 4, "no id is stored twice")
    }

    // MARK: - A cohort edit that is the first save

    func testADeleteThatIsTheFirstSaveStoresTheIDsTheExportDerivedBeforeIt() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let derived = try writeOlderSidecarWithTwins(layout)
        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: true)

        try await store.deleteSmartCohort(name: "Other", scope: "bundle")

        let saved = try onDisk(layout)
        XCTAssertEqual(saved.smartCohorts.map(\.name), ["Errors", "Errors", "Late"] + Self.builtInNames)
        XCTAssertEqual(Array(saved.smartCohorts.prefix(3).map(\.id)), [derived[0], derived[2], derived[3]].map { Optional($0) })
        XCTAssertEqual(saved.smartCohorts.dropFirst(3).map { $0.id?.uuidString }, Self.builtInIDs.map { Optional($0) })
    }

    func testANewCohortThatIsTheFirstSaveKeepsEveryIDTheExportDerived() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let derived = try writeOlderSidecarWithTwins(layout)
        let store = try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: true)

        try await store.saveSmartCohort(Self.cohort("New"))

        let saved = try onDisk(layout)
        XCTAssertEqual(Array(saved.smartCohorts.prefix(4).map(\.id)), derived.map { Optional($0) })
        XCTAssertEqual(saved.smartCohorts.last?.id, GenotypeCohortSmartFilter.derivedID(scope: "bundle", name: "New"))
    }

    // MARK: - Fixtures

    private struct Layout {
        let root: URL
        let bundleURL: URL

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }
    }

    private static func cohort(_ name: String) -> GenotypeCohortSmartFilter {
        GenotypeCohortSmartFilter(name: name, scope: "bundle", isStarred: true, predicate: .hasAnyComment)
    }

    private func makeFreshBundle() throws -> Layout {
        let root = try TestTempDirectory.make(prefix: "GenotypeCohortIdentity")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(#"{"analysis":"cohort-identity"}"#.utf8).write(
            to: bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return Layout(root: root, bundleURL: bundleURL)
    }

    /// Writes the sidecar an older Lungfish saved, holding `cohorts` and no ids.
    private func writeSidecar(_ layout: Layout, cohorts: [GenotypeCohortSmartFilter]) throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        sidecar.smartCohorts = cohorts
        try sidecar.encoded().write(to: layout.annotationURL)
    }

    /// Writes an older sidecar that holds two cohorts of one scope and name apart,
    /// and returns the ids the export derives from it.
    private func writeOlderSidecarWithTwins(_ layout: Layout) throws -> [UUID] {
        var twin = Self.cohort("Errors")
        twin.predicate = .hasErrorAtAnyLocus
        try writeSidecar(layout, cohorts: [Self.cohort("Errors"), Self.cohort("Other"), twin, Self.cohort("Late")])
        return try onDisk(layout).resolvedSmartCohortIDs
    }

    private func onDisk(_ layout: Layout) throws -> GenotypeAnnotationSidecar {
        try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
    }

    private func idsByName(_ layout: Layout) throws -> [String: String] {
        let sidecar = try onDisk(layout)
        return Dictionary(uniqueKeysWithValues: zip(sidecar.smartCohorts.map(\.name), sidecar.smartCohorts.map { $0.id?.uuidString ?? "none" }))
    }
}
