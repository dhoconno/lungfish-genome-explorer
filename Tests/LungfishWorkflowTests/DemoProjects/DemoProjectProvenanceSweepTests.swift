// DemoProjectProvenanceSweepTests.swift - Every released demo archive in a local folder loads and reads without moving a byte
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Only the MHC archive is committed. The other nine demo archives are large,
// and fetching them is an owner action. This sweep covers whichever of them
// sit in a local folder, for example the golden cache, and it skips when the
// folder is not named. The unit tier never sets the variable, so it never
// downloads anything and never depends on a cache.

import XCTest
@testable import LungfishWorkflow

/// For each archive that the bundled catalogue lists, that sits in the folder
/// named by LUNGFISH_DEMO_ARCHIVE_DIR under the catalogue's file name, and
/// whose size and SHA-256 match the catalogue, this installs the project with
/// the real installer and applies the checks of `DemoProjectProvenanceLoadTests`
/// that need no expected file.
///
/// - The snapshot of the whole project is identical after every read.
/// - Every provenance file decodes with the tolerant reader, and no read, walk
///   or export throws.
final class DemoProjectProvenanceSweepTests: XCTestCase {
    static let folderKey = "LUNGFISH_DEMO_ARCHIVE_DIR"

    /// A large project can hold thousands of sidecars and payload files, and
    /// each lineage walk and export reads the whole project's sidecars. The
    /// decode and strict checks still cover every sidecar. The walks, exports
    /// and finder lookups cover an evenly spaced sample of at most this many.
    static let largeProjectScope = DemoProvenanceReads.Scope(deepSidecarLimit: 100, payloadSelectionLimit: 300)

    func testEveryCataloguedArchiveInTheFolderLoadsAndReadsWithoutMovingAByte() async throws {
        guard let folderPath = ProcessInfo.processInfo.environment[Self.folderKey], !folderPath.isEmpty else {
            throw XCTSkip("Set \(Self.folderKey) to a folder of released demo archives to run this sweep.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("\(Self.folderKey) does not name a folder.")
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let catalogue = try DemoProjectManifest.loadBundled()

        var swept: [String] = []
        var skipped: [String] = []
        for project in catalogue.projects {
            let archive = folder.appendingPathComponent(project.archive.url.lastPathComponent)
            guard FileManager.default.fileExists(atPath: archive.path) else {
                skipped.append("\(project.id) is not in the folder")
                continue
            }
            do {
                try DemoProjectInstaller.verifyArchive(
                    at: archive,
                    expectedBytes: project.archive.bytes,
                    expectedSHA256: project.archive.sha256
                )
            } catch {
                skipped.append("\(project.id) does not match the catalogue, \(error.localizedDescription)")
                continue
            }
            swept.append(try await sweep(project, archive: archive))
        }

        print("[demo-sweep] \(swept.count) of \(catalogue.projects.count) catalogued archives swept from \(folderPath)")
        for line in swept { print("[demo-sweep] swept \(line)") }
        for line in skipped { print("[demo-sweep] skipped \(line)") }
        XCTAssertFalse(
            swept.isEmpty,
            "\(Self.folderKey) holds no archive that matches the catalogue by name, size and SHA-256. Skipped: \(skipped)"
        )
    }

    /// Installs one archive, reads it, and returns a one-line summary.
    private func sweep(_ project: DemoProject, archive: URL) async throws -> String {
        let workRoot = try DemoProjectFixtures.makeTempDirectory("provenance-sweep")
        defer { try? FileManager.default.removeItem(at: workRoot) }
        let installed = try await DemoProjectInstallHarness.install(project, archive: archive, under: workRoot)
        let exports = try DemoProjectInstallHarness.exportRoot(under: workRoot)

        let before = try DemoProjectTreeSnapshot.capture(of: installed)
        let outcome = try DemoProvenanceReads.run(
            projectURL: installed,
            exportRoot: exports,
            scope: Self.largeProjectScope
        )
        let after = try DemoProjectTreeSnapshot.capture(of: installed)

        XCTAssertEqual(
            after.differences(from: before), [],
            "\(project.id) changed while its provenance was read"
        )
        XCTAssertEqual(outcome.problems, [], "\(project.id) holds a provenance file that a reader refused or threw on")
        let sidecarCount = try DemoProvenanceReads.sidecarURLs(in: installed).count
        XCTAssertGreaterThan(sidecarCount, 0, "\(project.id) holds no provenance file")
        XCTAssertEqual(outcome.sidecars.count, sidecarCount, "\(project.id) holds a provenance file that did not decode")

        func count(_ route: String) -> Int { outcome.sidecars.filter { $0.decodedBy == route }.count }
        return "\(project.id) \(project.version) with \(sidecarCount) sidecars "
            + "(\(count("envelope")) envelope, \(count("workflowRun")) bare run, \(count("primitiveAdapter")) adapter, "
            + "\(outcome.sidecars.filter(\.strictAccepts).count) accepted strictly), "
            + "\(outcome.finder.count) finder lookups, \(outcome.deepSidecarCount) lineage walks, "
            + "\(outcome.exportCount) exports, \(before.entries.count) entries identical after the reads"
    }
}
