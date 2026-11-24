// ReadTimeWriteTests+Classifiers.swift - A person's change in a classifier viewer writes nothing into the project (UX 6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The read-time case makes each change with no row click, since a click starts the row's detail load and the NAO-MGS
// detail load can write the sample's BAM into the result, a write older than view memory that the two classes below
// pin and name. The kept view still holds a selected row, so the restore's own select is checked to write nothing.

import XCTest
@testable import LungfishApp
@testable import LungfishKit
@testable import LungfishNaoMgsUI
import LungfishTestSupport

extension ReadTimeWriteTests {
    /// With a person's change in each classifier kind (samples, a sort or grouping, a filter, a selected row and the
    /// divider), a switch away and back and the quit's capture and flush, every file of the project keeps its bytes and
    /// its date, and the view sits in the store outside the project (VS A4, UX 6). The restore selects the kept row
    /// and writes nothing.
    @MainActor
    func testAClassifierViewChangeASwitchAndAQuitWriteNothingIntoTheProject() async throws {
        let root = try TestTempDirectory.make(prefix: "ReadTimeWriteClassifiers")
        defer { TestTempDirectory.cleanup(root) }
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        let drivers: [any ViewStateDriver] = ClassifierReadTimeDrivers.all
        var fixtures: [ViewSwitchFixture] = []
        for driver in drivers {
            let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
            try driver.prepare(fixture)
            fixtures.append(fixture)
        }
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        // The digest comes before the store reads the project, so a write by that read shows too.
        let before = try ProjectDigest(of: project)
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)

        let harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: store)
        for (driver, fixture) in zip(drivers, fixtures) {
            harness.select(fixture.item)
            let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
            XCTAssertTrue(shown, "\(driver.kind) did not show")
            try await driver.change(in: harness)
            let changed = try driver.read(in: harness)
            harness.select(other.item)
            let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
            XCTAssertTrue(left, "\(driver.kind) stayed after the switch")
            harness.select(fixture.item)
            let back = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
            XCTAssertTrue(back, "\(driver.kind) did not show again")
            await driver.settle(in: harness)
            XCTAssertEqual(try driver.read(in: harness), changed, "\(driver.kind): the view as left, its selected row too")
        }
        harness.split.viewerController.surfaceHost.captureActive()
        store.flushSynchronously()
        harness.close()

        let after = try ProjectDigest(of: project)
        XCTAssertEqual(after.entries, before.entries, "viewing, switching and the restore write nothing into the project (UX 6)")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path).filter { $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(kept.count, drivers.count, "each view sits in the store: \(kept)")
        let layouts = UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("org.lungfish.metadata-column-layout.") && $0.contains(root.lastPathComponent)
        }
        XCTAssertEqual(layouts.sorted(), [], "a table wrote its column layout to the account's defaults")
    }
}

/// The classifier drivers of the read-time case, each making its change with no row click.
@MainActor
enum ClassifierReadTimeDrivers {
    static var all: [any ViewStateDriver] { [NaoMgsViewStateDriver(clicksARow: false)] }
}

// MARK: - The NAO-MGS detail load's write (older than view memory)

/// Shows the NAO-MGS result of the view-switch fixture in a test window and returns the viewer and the result folder.
@MainActor
private func showNaoMgsResult(
    in harness: ViewSwitchWindowHarness, project: URL
) async throws -> (viewer: NaoMgsResultViewController, result: URL) {
    let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "NAO-MGS"), in: project)
    let result = try XCTUnwrap(fixture.item.url)
    let driver = NaoMgsViewStateDriver()
    harness.select(fixture.item)
    let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
    XCTAssertTrue(shown, "NAO-MGS did not show")
    return (try XCTUnwrap(driver.viewer(in: harness)), result)
}

/// Counts the calls of the viewer's materializer seam.
@MainActor
final class NaoMgsMaterializerCalls {
    var count = 0
    func add() { count += 1 }
}

/// The stand-in of `NaoMgsDetailLoadWriteConformanceTests`, run with no tool: a person's taxon click on a result with no
/// `bams/` folder asks the materializer for the sample's BAM, the on-demand fallback of the row's detail load
/// (`NaoMgsResultViewController` mini BAM load). The seam takes the call, so nothing is written.
@MainActor
final class NaoMgsDetailLoadWriteTests: XCTestCase {
    func testAPersonsTaxonClickAsksTheMaterializerForTheSamplesBam() async throws {
        let root = try TestTempDirectory.make(prefix: "NaoMgsDetailLoadWrite")
        defer { TestTempDirectory.cleanup(root) }
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let (viewer, result) = try await showNaoMgsResult(in: harness, project: project)
        let calls = NaoMgsMaterializerCalls()
        viewer.testMaterializationHook = { _ in await calls.add() }

        viewer.testSelectTaxonomyRow(0)
        let asked = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { calls.count > 0 }
        XCTAssertTrue(asked, "a person's taxon click asks the materializer for the sample's BAM")
        let bams = result.appendingPathComponent("bams", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bams.path), "the stand-in writes nothing")
    }
}

/// The write itself, with the managed samtools: a person's taxon click on a NAO-MGS result with no `bams/` folder
/// writes `bams/<sample>.bam` and its index into the result. `NaoMgsResultViewController`'s mini BAM load falls back to
/// `NaoMgsBamMaterializer.materializeAll`, which makes the folder (`NaoMgsBamMaterializer.swift`, `bamsDir`). It was in
/// the code before view memory, and the restore never reaches it. Filed for the manager as a detail load that writes
/// into a result (UX 6).
@MainActor
final class NaoMgsDetailLoadWriteConformanceTests: XCTestCase {
    func testAPersonsTaxonClickWritesTheSamplesBamIntoTheResult() async throws {
        guard NaoMgsResultViewController.naomgsLocateSamtools() != nil else {
            if ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1" {
                XCTFail("LUNGFISH_REQUIRE_TOOLS=1 and the managed samtools is not installed")
                return
            }
            throw XCTSkip("needs the managed samtools; NaoMgsDetailLoadWriteTests is the stand-in")
        }
        let root = try TestTempDirectory.make(prefix: "NaoMgsDetailLoadWriteConformance")
        defer { TestTempDirectory.cleanup(root) }
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let (viewer, result) = try await showNaoMgsResult(in: harness, project: project)
        let bams = result.appendingPathComponent("bams", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bams.path), "the result holds no bams folder before the click")

        viewer.testSelectTaxonomyRow(0)
        let applied = await waitUntil(budget: .lookup, pollInterval: .milliseconds(50)) { !viewer.testAppliedFallbackWrites.isEmpty }
        XCTAssertTrue(applied, "the detail load materialized the sample's BAM and showed it")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: bams.path))?.sorted() ?? []
        XCTAssertTrue(written.contains { $0.hasSuffix(".bam") }, "a person's taxon click writes the sample's BAM into the result: \(written)")
    }
}
