// DemoProjectProvenanceLoadTests.swift - Loading the released MHC demo project and reading its provenance moves no byte
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.4 changes how LGE writes provenance. Before it does, these tests pin
// what the code reads today from real bytes an earlier LGE wrote. The released
// MHC demo archive is installed with the real DemoProjectInstaller, every
// sidecar is read every way the app and the CLI read one, and a snapshot of
// the whole project taken before and after must be identical. What the reader
// decodes is also compared with an expected file captured on unchanged code,
// which the writer lanes must leave as it is.

import XCTest
@testable import LungfishWorkflow

final class DemoProjectProvenanceLoadTests: XCTestCase {
    private static let captureKey = "LUNGFISH_CAPTURE_DEMO_PROVENANCE"
    private static let annotatedReferenceRoot =
        "Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref/.lungfish-provenance.json"

    private var workRoot: URL!

    override func setUpWithError() throws {
        workRoot = try DemoProjectFixtures.makeTempDirectory("provenance-load")
    }

    override func tearDownWithError() throws {
        if let workRoot { try? FileManager.default.removeItem(at: workRoot) }
    }

    private func installProject() async throws -> URL {
        try await DemoProjectInstallHarness.install(
            DemoProjectArchiveFixtures.mhcGenotyping,
            archive: DemoProjectArchiveFixtures.mhcArchiveURL,
            under: workRoot
        )
    }

    // MARK: - The fixture

    func testCommittedArchiveIsTheReleasedFile() throws {
        let archive = DemoProjectArchiveFixtures.mhcArchiveURL
        let pinned = DemoProjectArchiveFixtures.mhcGenotyping.archive
        XCTAssertEqual(try DemoProjectTreeSnapshot.sha256(ofFileAt: archive.path), pinned.sha256)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value,
            pinned.bytes
        )
        XCTAssertNoThrow(try DemoProjectInstaller.verifyArchive(
            at: archive,
            expectedBytes: pinned.bytes,
            expectedSHA256: pinned.sha256
        ))

        let readme = try String(
            contentsOf: DemoProjectArchiveFixtures.directory.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains(pinned.sha256), "the README names the SHA-256")
        XCTAssertTrue(readme.contains(pinned.url.absoluteString), "the README names the origin URL")
        XCTAssertTrue(readme.contains("110,747 bytes"), "the README names the size")
    }

    func testInstallsThroughTheRealInstallerAndHoldsTwentySevenProvenanceFiles() async throws {
        let project = try await installProject()
        XCTAssertEqual(project.lastPathComponent, "MHC Genotyping.lungfish")

        let record = try XCTUnwrap(DemoProjectInstaller.readRecord(inProjectAt: project))
        XCTAssertEqual(record.id, "mhc-genotyping")
        XCTAssertEqual(record.version, "2026.9.58")
        XCTAssertEqual(record.sha256, DemoProjectArchiveFixtures.mhcGenotyping.archive.sha256)

        // 84 archive entries, less the project folder itself, plus the install record.
        let snapshot = try DemoProjectTreeSnapshot.capture(of: project)
        XCTAssertEqual(snapshot.directoryCount, 34)
        XCTAssertEqual(snapshot.fileCount, 50)
        XCTAssertEqual(snapshot.entries.count, 84)

        let sidecars = try DemoProvenanceReads.sidecarURLs(in: project)
        XCTAssertEqual(sidecars.count, 27)
        XCTAssertEqual(
            sidecars.filter { $0.lastPathComponent == ".lungfish-provenance.json" }.count, 4,
            "a root sidecar for each of the two FASTQ bundles, the reference bundle and the MHC reference bundle"
        )
        XCTAssertEqual(
            sidecars.filter { $0.lastPathComponent.hasSuffix(".lungfishhaplotypedef.json.provenance.json") }.count, 1,
            "the haplotype definition keeps its own spelling of a sidecar name"
        )
    }

    // MARK: - The checks themselves

    /// A snapshot that cannot see a change proves nothing, so this shows that
    /// it sees each kind of change a read could make.
    func testSnapshotNoticesEveryKindOfChange() throws {
        let fileManager = FileManager.default
        let root = workRoot.appendingPathComponent("net", isDirectory: true)
        let file = root.appendingPathComponent("a/file.txt")
        let other = root.appendingPathComponent("a/b/other.txt")
        try fileManager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: file)
        try Data("two".utf8).write(to: other)
        let pastDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try fileManager.setAttributes([.modificationDate: pastDate], ofItemAtPath: file.path)

        let base = try DemoProjectTreeSnapshot.capture(of: root)
        XCTAssertEqual(try DemoProjectTreeSnapshot.capture(of: root).differences(from: base), [])

        func assertSeen(_ change: String, _ edit: () throws -> Void) throws {
            let before = try DemoProjectTreeSnapshot.capture(of: root)
            try edit()
            let seen = try DemoProjectTreeSnapshot.capture(of: root).differences(from: before)
            XCTAssertFalse(seen.isEmpty, "the snapshot missed \(change)")
        }
        try assertSeen("a rewrite of the same bytes") { try Data("one".utf8).write(to: file) }
        try fileManager.setAttributes([.modificationDate: pastDate], ofItemAtPath: file.path)
        try assertSeen("a touched modification date") {
            try fileManager.setAttributes([.modificationDate: pastDate.addingTimeInterval(60)], ofItemAtPath: file.path)
        }
        try assertSeen("a changed byte") { try Data("ONE".utf8).write(to: file) }
        try assertSeen("a changed permission") {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try assertSeen("a new file") { try Data().write(to: root.appendingPathComponent("a/new.txt")) }
        try assertSeen("a removed file") { try fileManager.removeItem(at: other) }
        try assertSeen("a new empty folder") {
            try fileManager.createDirectory(at: root.appendingPathComponent("a/empty"), withIntermediateDirectories: false)
        }
        try assertSeen("a removed folder") { try fileManager.removeItem(at: root.appendingPathComponent("a/b")) }
        try assertSeen("a new link") {
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("a/link").path, withDestinationPath: "file.txt")
        }
    }

    /// The exporter is a real writer, so a folder for its output inside the
    /// project must show in the snapshot. That is what a clean comparison in
    /// the reading test rests on.
    func testSnapshotSeesWhatAnExportWritesWhenItsFolderIsInsideTheProject() async throws {
        let project = try await installProject()
        let byMistake = project.appendingPathComponent("exports-written-by-mistake", isDirectory: true)

        let before = try DemoProjectTreeSnapshot.capture(of: project)
        let outcome = try DemoProvenanceReads.run(
            projectURL: project,
            exportRoot: byMistake,
            scope: DemoProvenanceReads.Scope(deepSidecarLimit: 1, payloadSelectionLimit: 0)
        )
        let changes = try DemoProjectTreeSnapshot.capture(of: project).differences(from: before)

        XCTAssertEqual(outcome.problems, [])
        XCTAssertGreaterThan(outcome.exportCount, 0)
        XCTAssertTrue(
            changes.contains { $0.hasPrefix("added exports-written-by-mistake/") && $0.contains("run.sh") },
            "the snapshot missed the exports written into the project: \(changes.prefix(5))"
        )
    }

    /// The mask is what keeps the expected file the same on every Mac, so it
    /// is tested on its own.
    func testPathMaskTurnsEachRootBackIntoItsToken() throws {
        let project = workRoot.appendingPathComponent("mask/LGE Demo Projects/Demo.lungfish", isDirectory: true)
        let working = URL(fileURLWithPath: "/work/space", isDirectory: true)
        let mask = DemoProvenancePathMask(projectURL: project, workingDirectory: working)
        let projectPath = project.standardizedFileURL.path

        XCTAssertEqual(mask.apply(projectPath), "@/")
        XCTAssertEqual(mask.apply(projectPath + "/Imports/reads.fastq.gz"), "@/Imports/reads.fastq.gz")
        XCTAssertEqual(mask.apply("--output=" + projectPath + "/out"), "--output=@/out")
        XCTAssertEqual(mask.apply("/tmp/scratch/in.fastq"), "<tmp>/scratch/in.fastq")
        XCTAssertEqual(mask.apply("/private/tmp/scratch/in.fastq"), "<tmp>/scratch/in.fastq")
        XCTAssertEqual(mask.apply("/var/tmp/scratch/in.fastq"), "<tmp>/scratch/in.fastq")
        XCTAssertEqual(mask.apply("@/Imports/reads.fastq.gz"), "@/Imports/reads.fastq.gz")
        XCTAssertEqual(mask.apply("<tool-root>/envs/samtools/bin/samtools"), "<tool-root>/envs/samtools/bin/samtools")

        // The placeholder keeps its own spelling, so a reader that began to
        // resolve it to a path that does not exist would show.
        XCTAssertEqual(mask.apply("<workspace>/scratch/in.fastq"), "<workspace>/scratch/in.fastq")
        // A file parameter is read with URL(fileURLWithPath:), which puts the
        // working directory in front of a relative placeholder.
        XCTAssertEqual(mask.apply("/work/space/<workspace>/scratch/in.fastq"), "<workspace>/scratch/in.fastq")
        XCTAssertEqual(
            mask.apply("{\"type\":\"file\",\"value\":\"/work/space/<workspace>/in.fastq\"}"),
            "{\"type\":\"file\",\"value\":\"<workspace>/in.fastq\"}"
        )
        let atRoot = DemoProvenancePathMask(
            projectURL: project,
            workingDirectory: URL(fileURLWithPath: "/", isDirectory: true)
        )
        XCTAssertEqual(atRoot.apply("/<workspace>/scratch/in.fastq"), "<workspace>/scratch/in.fastq")

        // Paths that only look like a root stay as they are.
        XCTAssertEqual(mask.apply("/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli"), "/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli")
        XCTAssertEqual(mask.apply("/usr/local/tmp/tool"), "/usr/local/tmp/tool")
        XCTAssertEqual(mask.apply("/tmpfiles/tool"), "/tmpfiles/tool")
        XCTAssertEqual(mask.apply("/work/space/other/file"), "/work/space/other/file")
        XCTAssertEqual(mask.apply("lungfish-cli"), "lungfish-cli")

        XCTAssertEqual(mask.leaks(in: "<tmp>/scratch and @/Imports and <workspace>/in.fastq"), [])
        XCTAssertEqual(mask.leaks(in: "/tmp/scratch"), ["/tmp"])
        XCTAssertEqual(mask.leaks(in: "/work/space/other/file"), ["/work/space"])
        XCTAssertTrue(mask.leaks(in: projectPath + "/Imports").contains(projectPath))
    }

    // MARK: - Reading

    /// Installs the project, reads its provenance every way LGE does, and
    /// checks three things about the result.
    ///
    /// 1. No byte of the project moved. A snapshot of every file and folder,
    ///    with size, SHA-256, permissions and modification time, is equal
    ///    before and after.
    /// 2. Every sidecar decodes, and the reader accepts the released shape.
    /// 3. What the reader decodes equals the expected file. With
    ///    LUNGFISH_CAPTURE_DEMO_PROVENANCE=1 the expected file is written from
    ///    the current code, once, and the test refuses to overwrite it. The
    ///    unit tier never sets the variable.
    func testReadingTheReleasedProjectMovesNoByteAndDecodesAsCaptured() async throws {
        let project = try await installProject()
        let exports = try DemoProjectInstallHarness.exportRoot(under: workRoot)
        XCTAssertFalse(
            exports.standardizedFileURL.path.hasPrefix(project.standardizedFileURL.path + "/"),
            "exports must land outside the project"
        )

        let before = try DemoProjectTreeSnapshot.capture(of: project)
        let outcome = try DemoProvenanceReads.run(projectURL: project, exportRoot: exports)
        let after = try DemoProjectTreeSnapshot.capture(of: project)

        // 1. Nothing moved.
        XCTAssertEqual(
            after.differences(from: before), [],
            "loading the project and reading its provenance changed the project"
        )

        // 2. What the reads covered, and what the reader makes of the released shape.
        XCTAssertEqual(outcome.problems, [], "a reader refused, threw or came back empty on released bytes")
        XCTAssertEqual(outcome.sidecars.count, 27)
        XCTAssertEqual(outcome.lineage.count, 27)
        XCTAssertEqual(outcome.deepSidecarCount, 27)
        // Six folders carry a bundle extension, one of them inside a provenance roll-up.
        XCTAssertEqual(outcome.finder.filter(\.isBundle).count, 6)
        XCTAssertEqual(outcome.finder.filter { !$0.isBundle }.count, 21)
        // Two exports for each sidecar and for each bundle the finder resolved.
        let resolvedBundles = outcome.finder.filter { $0.isBundle && $0.sidecar != nil }.count
        XCTAssertEqual(outcome.exportCount, 2 * (27 + resolvedBundles))
        let exported = try FileManager.default.subpathsOfDirectory(atPath: exports.path)
        XCTAssertTrue(exported.contains { $0.hasSuffix("provenance.json") })
        XCTAssertTrue(exported.contains { $0.hasSuffix("run.sh") })

        for sidecar in outcome.sidecars {
            XCTAssertEqual(sidecar.decodedBy, "envelope", sidecar.sidecar)
            XCTAssertTrue(sidecar.strictAccepts, "\(sidecar.sidecar) is accepted by the strict reader")
            XCTAssertEqual(sidecar.exitStatus, 0, sidecar.sidecar)
            XCTAssertEqual(sidecar.rawStatus, "completed", sidecar.sidecar)
            XCTAssertFalse(sidecar.argv.isEmpty, sidecar.sidecar)
            XCTAssertEqual(sidecar.durableReplayArgv, sidecar.argv, "\(sidecar.sidecar) records its replay command as run")
            XCTAssertFalse(sidecar.outputs.isEmpty, sidecar.sidecar)
            XCTAssertFalse(sidecar.reproducibleCommand.isEmpty, sidecar.sidecar)
            XCTAssertEqual(sidecar.decodedStatus, "completed", "\(sidecar.sidecar) decodes as a completed run")
            XCTAssertFalse(sidecar.steps.isEmpty, sidecar.sidecar)
            XCTAssertTrue(sidecar.steps.allSatisfy { $0.exitStatus == 0 }, "\(sidecar.sidecar) records every step as exit 0")
        }
        // The third-party tools and versions that the demo ran live only in the steps.
        let thirdParty = Set(
            outcome.sidecars.flatMap(\.steps)
                .filter { !$0.toolVersion.hasPrefix("Lungfish") }
                .map { "\($0.toolName) \($0.toolVersion)" }
        )
        XCTAssertEqual(thirdParty, ["bgzip 1.24", "clumpify.sh 40.02", "samtools 1.24", "seqkit 2.13.0"])
        XCTAssertEqual(outcome.sidecars.flatMap(\.steps).count, 46)
        // The one embedded legacy run is the annotated reference's root record.
        XCTAssertEqual(
            outcome.sidecars.filter { $0.embeddedRun != nil }.map(\.sidecar),
            [Self.annotatedReferenceRoot]
        )
        let embedded = outcome.sidecars.first { $0.sidecar == Self.annotatedReferenceRoot }?.embeddedRun
        XCTAssertEqual(embedded?.status, "completed")
        XCTAssertEqual(embedded?.stepCount, 3)

        // 3. The decoded replay projection equals the captured expected file.
        if let scratch = DemoProvenanceReads.demoBuildScratchFolder() {
            throw XCTSkip(
                "A demo build scratch folder exists on this Mac, so the reader resolves <workspace> paths to real files. "
                    + "The expected file is neither compared nor captured while it exists."
                    + " Remove \(scratch.lastPathComponent) from the temporary folder to compare."
            )
        }
        let pinned = DemoProjectArchiveFixtures.mhcGenotyping
        let actual = DemoProvenanceExpectedFile(
            formatVersion: DemoProvenanceExpectedFile.currentFormatVersion,
            readingNotes: DemoProvenanceExpectedFile.notes,
            archive: DemoProvenanceExpectedFile.Archive(
                id: pinned.id,
                version: pinned.version,
                bytes: pinned.archive.bytes,
                sha256: pinned.archive.sha256
            ),
            sidecars: outcome.sidecars,
            finder: outcome.finder,
            lineage: outcome.lineage
        )
        let rendered = actual.render()
        let reread = try JSONDecoder().decode(DemoProvenanceExpectedFile.self, from: Data(rendered.utf8))
        XCTAssertEqual(reread, actual, "the written layout reads back to the same value")
        XCTAssertEqual(
            DemoProvenancePathMask(projectURL: project).leaks(in: rendered), [],
            "the projection holds text that belongs to the Mac that ran the test"
        )

        let expectedURL = DemoProjectArchiveFixtures.mhcExpectedURL
        if ProcessInfo.processInfo.environment[Self.captureKey] == "1" {
            guard !FileManager.default.fileExists(atPath: expectedURL.path) else {
                XCTFail("Refusing to overwrite \(expectedURL.lastPathComponent). Unset \(Self.captureKey) to compare.")
                return
            }
            try FileManager.default.createDirectory(
                at: expectedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(rendered.utf8).write(to: expectedURL, options: .withoutOverwriting)
        }
        guard FileManager.default.fileExists(atPath: expectedURL.path) else {
            XCTFail("No expected file at \(expectedURL.lastPathComponent). Capture it on unchanged code with \(Self.captureKey)=1.")
            return
        }
        let expected = try DemoProvenanceExpectedFile.load(from: expectedURL)
        XCTAssertEqual(
            actual.differences(from: expected), [],
            "the reader no longer decodes the released bytes as the expected file records"
        )
    }
}
