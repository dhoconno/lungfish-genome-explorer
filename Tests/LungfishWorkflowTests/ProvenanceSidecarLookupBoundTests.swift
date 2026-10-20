// ProvenanceSidecarLookupBoundTests.swift - What the sidecar lookup returns and which folders it lists
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// Pins and defect tests of lane 13.34 (PROV-SIDECAR-WALK). The pins were taken at the base before the
/// climb was bounded, and the comment of a pin names what the fix changed in it.
///
/// The lookup that finds a record's sidecar climbs at most five folders from the input's folder, ends at
/// the project root and probes a shared folder above the input instead of listing it. Its seam
/// (`findProvenanceReading(for:sharedFolders:listing:)`) reports each folder it lists with the number of
/// entries, so each test states the sidecar one lookup returns and the folders it read. Every case lives
/// under `TestTempDirectory`, one folder below the scratch folder, and the shared folders are passed in,
/// so a test lists no real home, Downloads or temp folder except the one that checks the default set.
final class ProvenanceSidecarLookupBoundTests: XCTestCase {
    private var scratch: URL!
    private var caseRoot: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "sidecar-bound")
        caseRoot = scratch.appendingPathComponent("case", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - Pins

    /// (a) A record above the project root is not found, and the climb lists `run`, `Analyses` and
    /// `Project.lungfish` only, never `Outer`. This is the fix's one predicted change inside a project.
    /// At the base the record was found and the climb listed `Outer` as its fourth folder, since the
    /// `Outer` record answers there (the base walks four folders here, not five).
    func testARecordAboveTheProjectRootIsNotFound() throws {
        let file = try payload("Outer/Project.lungfish/Analyses/run/out.txt")
        let run = file.deletingLastPathComponent()
        let analyses = run.deletingLastPathComponent()
        let project = analyses.deletingLastPathComponent()
        let outer = project.deletingLastPathComponent()
        let record = outer.appendingPathComponent(".lungfish-provenance.json")
        try writeRecord(at: record, producing: file)

        let result = walk(file)

        XCTAssertNil(result.sidecar)
        XCTAssertEqual(result.folders, paths([run, analyses, project]))
    }

    /// (b) A bundle inside a project, with the record of the run folder that holds the bundle. The
    /// climb passes the bundle and finds the record. The enumerator of the bundle's `alignments` folder
    /// is the third listing. This holds at the base and after the fix, and a bundle that ended the climb
    /// would lose it.
    func testPinARunFolderRecordIsFoundAboveABundleInsideAProject() throws {
        let bam = try payload("Project.lungfish/Analyses/run/Viewer.lungfishref/alignments/x.bam")
        let alignments = bam.deletingLastPathComponent()
        let bundle = alignments.deletingLastPathComponent()
        let run = bundle.deletingLastPathComponent()
        let record = run.appendingPathComponent(".lungfish-provenance.json")
        try writeRecord(at: record, producing: bundle)

        let result = walk(bam)

        XCTAssertEqual(result.sidecar, path(record))
        XCTAssertEqual(result.folders, paths([alignments, bundle, alignments, run]))
    }

    /// (c) No project root. A run folder record with a workflow name is found by the listing of the
    /// folder that holds it. This holds at the base and after the fix, and a lookup that listed only the
    /// input's own folder would lose it.
    func testPinARunFolderRecordIsFoundForAnInputWithNoRoot() throws {
        let tsv = try payload("run1/sub/x.tsv")
        let sub = tsv.deletingLastPathComponent()
        let run1 = sub.deletingLastPathComponent()
        let record = run1.appendingPathComponent("panel-provenance.json")
        try writeRecord(at: record, producing: sub)

        let result = walk(tsv)

        XCTAssertEqual(result.sidecar, path(record))
        XCTAssertEqual(result.folders, paths([sub, run1]))
        XCTAssertEqual(
            ProvenanceRecorder.findProvenanceReading(for: tsv)?.sidecarURL.standardizedFileURL.path,
            path(record),
            "The public entry should find the same record."
        )
    }

    /// (d1) No root, with a shared parent. The CLI sidecar of an output folder sits in the shared folder
    /// beside the folder it describes. The base found it by listing the shared folder, and the fix finds
    /// it by probing the name `run1.lungfish-provenance.json`, so the shared folder is no longer listed.
    func testTheSidecarOfAnOutputFolderIsFoundInASharedParent() throws {
        let tsv = try payload("Shared/run1/sub/x.tsv")
        let sub = tsv.deletingLastPathComponent()
        let run1 = sub.deletingLastPathComponent()
        let shared = run1.deletingLastPathComponent()
        let record = shared.appendingPathComponent("run1.lungfish-provenance.json")
        try writeRecord(at: record, producing: run1)

        let result = walk(tsv, shared: [shared])

        XCTAssertEqual(result.sidecar, path(record))
        XCTAssertEqual(result.folders, paths([sub, run1]))
    }

    /// (d2) The same tree, with the canonical record of the shared folder listing the input's folder.
    /// The base found it by listing and the fix finds it by probing `.lungfish-provenance.json`.
    func testTheCanonicalRecordOfASharedParentIsFound() throws {
        let tsv = try payload("Shared/run1/sub/x.tsv")
        let sub = tsv.deletingLastPathComponent()
        let run1 = sub.deletingLastPathComponent()
        let shared = run1.deletingLastPathComponent()
        let record = shared.appendingPathComponent(".lungfish-provenance.json")
        try writeRecord(at: record, producing: sub)

        let result = walk(tsv, shared: [shared])

        XCTAssertEqual(result.sidecar, path(record))
        XCTAssertEqual(result.folders, paths([sub, run1]))
    }

    /// (e) The one record the fix loses outside a project. A workflow-named record that lies directly in
    /// a shared folder and lists a file in a subfolder was found at the base by listing the shared
    /// folder. The shared folder is now only probed for fixed names, so the lookup returns nil (the
    /// predicted change, a Known limit).
    func testAWorkflowNamedRecordInASharedParentIsNotFound() throws {
        let tsv = try payload("Shared/run1/sub/x.tsv")
        let sub = tsv.deletingLastPathComponent()
        let run1 = sub.deletingLastPathComponent()
        let shared = run1.deletingLastPathComponent()
        let record = shared.appendingPathComponent("panel-provenance.json")
        try writeRecord(at: record, producing: sub)

        let result = walk(tsv, shared: [shared])

        XCTAssertNil(result.sidecar)
        XCTAssertEqual(result.folders, paths([sub, run1]))
    }

    /// (f) A bundle with no project, selected as a folder. The record beside the bundle is found by the
    /// listing of the folder that holds the bundle. The bundle is listed twice, once before the climb
    /// and once as its first folder. This holds at the base and after the fix.
    func testPinTheRecordBesideABundleWithNoProjectIsFound() throws {
        let inside = try payload("out/X.lungfishref/payload.txt")
        let bundle = inside.deletingLastPathComponent()
        let out = bundle.deletingLastPathComponent()
        let record = out.appendingPathComponent("X.lungfishref.lungfish-provenance.json")
        try writeRecord(at: record, producing: bundle)

        let result = walk(bundle)

        XCTAssertEqual(result.sidecar, path(record))
        XCTAssertEqual(result.folders, paths([bundle, bundle, out]))
        XCTAssertEqual(
            ProvenanceRecorder.findProvenanceReading(for: bundle)?.sidecarURL.standardizedFileURL.path,
            path(record),
            "The public entry should find the same record."
        )
    }

    // MARK: - Defect tests

    /// The lookup lists no folder above the project root. `Crowded` holds 2,000 empty files, 200 records
    /// and the project, so a lookup that listed it would list 2,201 entries and read the 200 records,
    /// none of which names the input. The climb ends at `Project.lungfish`, so the lookup lists `run`,
    /// `Analyses` and `Project.lungfish` only. At the base it also lists `Crowded` and `case`.
    func testTheLookupListsNoFolderAboveTheProjectRoot() throws {
        let crowded = try makeCrowdedFolder()
        let file = try payload("Crowded/Project.lungfish/Analyses/run/out.txt")
        let run = file.deletingLastPathComponent()
        let analyses = run.deletingLastPathComponent()
        let project = analyses.deletingLastPathComponent()

        let (result, seconds) = timedWalk(file)
        print("[13.34 cost] crowded folder above the project root: \(seconds) s, "
              + "\(result.listings.count) folders, \(result.entryTotal) entries")

        XCTAssertNil(result.sidecar)
        XCTAssertFalse(result.folders.contains(path(crowded)), "The folder above the root should not be listed.")
        XCTAssertEqual(result.folders, paths([run, analyses, project]))
        XCTAssertLessThan(result.entryTotal, 200, "None of the 200 records of the crowded folder should be read.")
    }

    /// With no project, a shared folder above the input's own folder is probed and never listed. The test
    /// names `Crowded` as shared, so the lookup from `Crowded/a/b/x.txt` lists `b` and `a` only. At the
    /// base it also lists `Crowded`, `case` and the scratch folder.
    func testTheLookupListsNoSharedFolderAboveTheInput() throws {
        let crowded = try makeCrowdedFolder()
        let file = try payload("Crowded/a/b/x.txt")
        let b = file.deletingLastPathComponent()
        let a = b.deletingLastPathComponent()

        let (result, seconds) = timedWalk(file, shared: [crowded])
        print("[13.34 cost] crowded folder above an input with no root: \(seconds) s, "
              + "\(result.listings.count) folders, \(result.entryTotal) entries")

        XCTAssertNil(result.sidecar)
        XCTAssertFalse(result.folders.contains(path(crowded)), "The shared folder should not be listed.")
        XCTAssertEqual(result.folders, paths([b, a]))
        XCTAssertLessThan(result.entryTotal, 200, "None of the 200 records of the crowded folder should be read.")
    }

    // MARK: - The default shared folders

    /// The default set is the temp folder, the home folder and the user's Downloads, Desktop and
    /// Documents folders, and every ancestor of one of them is shared. A folder made under the temp
    /// folder is not shared. The test lists nothing and reads no record.
    func testTheDefaultSharedFoldersAreTheTempAndHomeFoldersAndTheirAncestors() {
        let fileManager = FileManager.default
        let sharedPaths = ProvenanceRecorder.sharedFolderPaths(ProvenanceRecorder.defaultSharedFolders())
        func isShared(_ url: URL) -> Bool {
            ProvenanceRecorder.isSharedFolder(url, among: sharedPaths)
        }
        let temp = fileManager.temporaryDirectory
        let home = fileManager.homeDirectoryForCurrentUser
        XCTAssertTrue(isShared(temp))
        XCTAssertTrue(isShared(temp.deletingLastPathComponent()))
        XCTAssertTrue(isShared(home))
        XCTAssertTrue(isShared(home.deletingLastPathComponent()))
        XCTAssertTrue(isShared(URL(fileURLWithPath: "/")))
        let userFolders: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory, .desktopDirectory, .documentDirectory,
        ]
        for directory in userFolders {
            for folder in fileManager.urls(for: directory, in: .userDomainMask) {
                XCTAssertTrue(isShared(folder), "\(folder.path) should be shared.")
            }
        }
        XCTAssertFalse(isShared(scratch), "A folder made under the temp folder is not shared.")
        XCTAssertFalse(isShared(caseRoot))
        if temp.standardizedFileURL.path.hasPrefix("/var/") {
            XCTAssertTrue(
                isShared(URL(fileURLWithPath: "/private" + temp.standardizedFileURL.path)),
                "The temp folder spelled through /private should compare equal."
            )
        }
    }

    /// A lookup with the default shared folders never lists the temp folder. The case sits under it, so
    /// the fourth folder of the climb from `a/x.txt` is the temp folder, which holds thousands of
    /// entries on a busy Mac. The base listed it, which took seconds.
    func testTheDefaultSharedFoldersKeepTheTempFolderUnlisted() throws {
        let file = try payload("a/x.txt")
        let a = file.deletingLastPathComponent()

        let result = walk(file, shared: ProvenanceRecorder.defaultSharedFolders())

        XCTAssertNil(result.sidecar)
        XCTAssertEqual(result.folders, paths([a, caseRoot, scratch]))
    }

    // MARK: - Fixtures

    private struct Listing: Equatable {
        let path: String
        let entries: Int
    }

    private struct Walk {
        let sidecar: String?
        let listings: [Listing]
        var folders: [String] { listings.map(\.path) }
        var entryTotal: Int { listings.map(\.entries).reduce(0, +) }
    }

    /// One lookup through the seam, with the sidecar it returned and every listing it made, in order.
    private func walk(_ input: URL, shared: [URL] = []) -> Walk {
        var listings: [Listing] = []
        let found = ProvenanceRecorder.findProvenanceReading(
            for: input,
            sharedFolders: shared,
            listing: { folder, entries in
                listings.append(Listing(path: folder.standardizedFileURL.path, entries: entries))
            }
        )
        return Walk(sidecar: found?.sidecarURL.standardizedFileURL.path, listings: listings)
    }

    private func timedWalk(_ input: URL, shared: [URL] = []) -> (Walk, String) {
        var result: Walk?
        let elapsed = ContinuousClock().measure { result = walk(input, shared: shared) }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (result ?? Walk(sidecar: nil, listings: []), String(format: "%.3f", seconds))
    }

    private func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func paths(_ urls: [URL]) -> [String] {
        urls.map(path)
    }

    /// A small payload file under the case, with the folders above it made.
    private func payload(_ relative: String) throws -> URL {
        let url = caseRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("data\n".utf8).write(to: url)
        return url
    }

    /// A canonical record that lists `produced` as an output, written with the writer's own encode.
    private func writeRecord(at sidecar: URL, producing produced: URL) throws {
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            workflowName: "sidecar bound pin",
            toolName: "pin-tool",
            argv: ["pin-tool", "run"],
            outputs: [
                ProvenanceFileDescriptor(
                    path: produced.standardizedFileURL.path,
                    checksumSHA256: String(repeating: "a", count: 64),
                    fileSize: 4,
                    role: .output
                ),
            ],
            exitStatus: 0,
            status: .completed
        )
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try ProvenanceWriter.recordBytes(envelope, sanitizedFor: nil).write(to: sidecar)
    }

    /// `<case>/Crowded` with 2,000 empty files and 200 records named `rNNN-provenance.json`, each
    /// listing a path outside the case.
    private func makeCrowdedFolder() throws -> URL {
        let crowded = caseRoot.appendingPathComponent("Crowded", isDirectory: true)
        try FileManager.default.createDirectory(at: crowded, withIntermediateDirectories: true)
        for index in 0..<2_000 {
            let name = String(format: "empty-%04d.dat", index)
            FileManager.default.createFile(atPath: crowded.appendingPathComponent(name).path, contents: nil)
        }
        for index in 0..<200 {
            let name = String(format: "r%03d", index)
            try writeRecord(
                at: crowded.appendingPathComponent("\(name)-provenance.json"),
                producing: URL(fileURLWithPath: "/elsewhere/\(name)/out.dat")
            )
        }
        return crowded
    }
}
