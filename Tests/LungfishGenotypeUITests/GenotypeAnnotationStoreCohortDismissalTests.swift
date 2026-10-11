import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// Plan decision S13. Deleting a built-in smart cohort records a dismissal
/// in the sidecar settings, so it stays deleted after reopen. The record of
/// the edit that first writes the built-ins names the cohorts it seeds.
/// Restore Built-In Cohorts empties the dismissals and brings them back with
/// its own recorded edit, and an analyst's own cohort with a built-in's name
/// is never replaced.
@MainActor
final class GenotypeAnnotationStoreCohortDismissalTests: XCTestCase {
    private static let builtInNames = ["Incomplete haplotypes", "Needs review", "Homozygous", "Recombinants"]

    func testADeletedBuiltInStaysDeletedAfterReopenAndReopeningWritesNothing() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try open(layout)
        try store.addSampleNote(sample: "Animal-1", body: "First note")

        try store.deleteSmartCohort(name: "Homozygous", scope: "bundle")

        let onDisk = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(onDisk.smartCohorts.map(\.name), ["Incomplete haplotypes", "Needs review", "Recombinants"])
        XCTAssertEqual(onDisk.settings.dismissedBuiltInSmartCohorts, ["Homozygous"])
        XCTAssertEqual(onDisk.auditLog.map(\.action), ["addSampleNote", "deleteSmartCohort"])
        try assertRecord(layout, action: "deleteSmartCohort", seeded: nil)
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        let reopened = try open(layout)

        XCTAssertEqual(reopened.sidecar.smartCohorts.map(\.name), ["Incomplete haplotypes", "Needs review", "Recombinants"])
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
    }

    func testTheFirstEditThatWritesTheBuiltInsNamesThemInItsRecordAndTheNextNamesNone() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try open(layout)

        try store.addSampleNote(sample: "Animal-1", body: "First note")
        try assertRecord(layout, action: "addSampleNote", seeded: Self.builtInNames)

        try store.addSampleNote(sample: "Animal-1", body: "Second note")
        try assertRecord(layout, action: "addSampleNote", seeded: nil)
    }

    func testDeletingAnUnsavedBuiltInFirstSeedsOnlyTheOthersAndNamesThem() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try open(layout)

        try store.deleteSmartCohort(name: "Homozygous", scope: "bundle")

        let onDisk = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(onDisk.smartCohorts.map(\.name), ["Incomplete haplotypes", "Needs review", "Recombinants"])
        XCTAssertEqual(onDisk.settings.dismissedBuiltInSmartCohorts, ["Homozygous"])
        try assertRecord(layout, action: "deleteSmartCohort", seeded: ["Incomplete haplotypes", "Needs review", "Recombinants"])
        XCTAssertEqual(store.sidecar, onDisk)
        XCTAssertEqual(try open(layout).sidecar.smartCohorts.map(\.name), onDisk.smartCohorts.map(\.name))
    }

    func testRestoreBringsTheDismissedBuiltInsBackWithItsOwnRecordedEdit() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try open(layout)
        try store.deleteSmartCohort(name: "Homozygous", scope: "bundle")
        try store.deleteSmartCohort(name: "Needs review", scope: "bundle")
        XCTAssertTrue(store.canRestoreBuiltInSmartCohorts)

        let restored = try store.restoreBuiltInSmartCohorts(author: "reviewer")

        XCTAssertEqual(restored, ["Needs review", "Homozygous"])
        let onDisk = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(onDisk.smartCohorts.map(\.name), ["Incomplete haplotypes", "Recombinants", "Needs review", "Homozygous"])
        XCTAssertNil(onDisk.settings.dismissedBuiltInSmartCohorts)
        let settingsObject = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: Data(contentsOf: layout.annotationURL)) as? [String: Any])?["settings"] as? [String: Any]
        )
        XCTAssertNil(settingsObject["dismissedBuiltInSmartCohorts"], "an empty list writes no key, as an older sidecar has none")
        let audit = try XCTUnwrap(onDisk.auditLog.last)
        XCTAssertEqual(audit.action, "restoreBuiltInSmartCohorts")
        XCTAssertEqual(audit.author, "reviewer")
        XCTAssertEqual(audit.before, "Homozygous, Needs review")
        XCTAssertEqual(audit.after, "Needs review, Homozygous")
        let envelope = try assertRecord(layout, action: "restoreBuiltInSmartCohorts", seeded: nil)
        XCTAssertEqual(envelope.options.explicit["restoredBuiltInSmartCohorts"], .array([.string("Needs review"), .string("Homozygous")]))
        XCTAssertEqual(envelope.options.explicit["clearedDismissals"], .array([.string("Homozygous"), .string("Needs review")]))
        XCTAssertFalse(store.canRestoreBuiltInSmartCohorts)
        XCTAssertEqual(Set(try open(layout).sidecar.smartCohorts.map(\.name)), Set(Self.builtInNames))
    }

    func testRestoreWithNothingToRestoreWritesNothing() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try open(layout)
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        XCTAssertFalse(store.canRestoreBuiltInSmartCohorts)
        XCTAssertEqual(try store.restoreBuiltInSmartCohorts(), [])

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
    }

    func testAnAnalystCohortWithABuiltInsNameIsNeverReplacedBySeedingOrRestore() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let own = GenotypeCohortSmartFilter(
            name: "Homozygous", description: "My homozygous rule", scope: "bundle",
            isStarred: true, predicate: .hasErrorAtAnyLocus
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        sidecar.smartCohorts = [own]
        sidecar.settings.dismissedBuiltInSmartCohorts = ["Recombinants"]
        try sidecar.encoded().write(to: layout.annotationURL)

        let store = try open(layout)
        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), ["Homozygous", "Incomplete haplotypes", "Needs review"])
        XCTAssertEqual(store.sidecar.smartCohorts.first, own)

        XCTAssertEqual(try store.restoreBuiltInSmartCohorts(), ["Recombinants"])

        let onDisk = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertEqual(onDisk.smartCohorts.map(\.name), ["Homozygous", "Incomplete haplotypes", "Needs review", "Recombinants"])
        XCTAssertEqual(onDisk.smartCohorts.first, own)
        try assertRecord(layout, action: "restoreBuiltInSmartCohorts", seeded: ["Incomplete haplotypes", "Needs review"])
    }

    func testDeletingAnAnalystCohortWithABuiltInsNameStaysDeleted() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try open(layout)
        try store.saveSmartCohort(GenotypeCohortSmartFilter(
            name: "Homozygous", scope: "bundle", isStarred: false, predicate: .hasAnyComment
        ))
        try assertRecord(layout, action: "saveSmartCohort", seeded: ["Incomplete haplotypes", "Needs review", "Recombinants"])

        try store.deleteSmartCohort(name: "Homozygous", scope: "bundle")

        XCTAssertFalse(try open(layout).sidecar.smartCohorts.map(\.name).contains("Homozygous"))
    }

    func testDeletingAnAnalystCohortRecordsNoDismissal() throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        let store = try open(layout)
        try store.saveSmartCohort(GenotypeCohortSmartFilter(
            name: "Analyst custom", scope: "bundle", isStarred: true, predicate: .hasErrorAtAnyLocus
        ))

        try store.deleteSmartCohort(name: "Analyst custom", scope: "bundle")

        let onDisk = try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
        XCTAssertNil(onDisk.settings.dismissedBuiltInSmartCohorts)
        XCTAssertEqual(onDisk.smartCohorts.map(\.name), Self.builtInNames)
    }

    func testAReadOnlyBundleDeletesAndRestoresForTheSessionOnly() throws {
        try XCTSkipIf(getuid() == 0, "a read-only folder is writable to root")
        let layout = try makeFreshBundle()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: layout.bundleURL.path)
            TestTempDirectory.cleanup(layout.root)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: layout.bundleURL.path)
        let store = try open(layout)
        let before = try GenotypeBundleTreeSnapshot.entries(of: layout.root)

        try store.deleteSmartCohort(name: "Homozygous", scope: "bundle")
        XCTAssertFalse(store.sidecar.smartCohorts.map(\.name).contains("Homozygous"))
        XCTAssertEqual(try store.restoreBuiltInSmartCohorts(), ["Homozygous"])

        XCTAssertTrue(store.sidecar.smartCohorts.map(\.name).contains("Homozygous"))
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: layout.root), before)
    }

    // MARK: - Fixtures

    private struct Layout {
        let root: URL
        let bundleURL: URL

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }
    }

    private func makeFreshBundle() throws -> Layout {
        let root = try TestTempDirectory.make(prefix: "GenotypeCohortDismissal")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(#"{"analysis":"cohort-dismissal"}"#.utf8).write(
            to: bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return Layout(root: root, bundleURL: bundleURL)
    }

    /// Opens the store the way the viewer and the Inspector do for a haplotyped result.
    private func open(_ layout: Layout) throws -> GenotypeAnnotationStore {
        try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: true)
    }

    /// The record of the last publication names `action` and, when `seeded`
    /// is not nil, exactly the built-in cohorts it wrote for the first time.
    @discardableResult
    private func assertRecord(
        _ layout: Layout,
        action: String,
        seeded: [String]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProvenanceEnvelope {
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: layout.annotationURL)),
            file: file, line: line
        )
        XCTAssertEqual(envelope.options.explicit["action"], .string(action), file: file, line: line)
        XCTAssertEqual(
            envelope.options.explicit["seededBuiltInSmartCohorts"],
            seeded.map { .array($0.map(ParameterValue.string)) },
            file: file, line: line
        )
        return envelope
    }
}
