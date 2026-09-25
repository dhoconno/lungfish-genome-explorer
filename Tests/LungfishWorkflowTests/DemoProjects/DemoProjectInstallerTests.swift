// DemoProjectInstallerTests.swift - Verify, install, replace and status logic
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class DemoProjectInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var archiveURL: URL!
    private var installDir: URL!
    private var trash: TestTrash!

    override func setUpWithError() throws {
        tempDir = try DemoProjectFixtures.makeTempDirectory("install")
        archiveURL = tempDir.appendingPathComponent("fixture.zip")
        try DemoProjectFixtures.writeProjectArchive(to: archiveURL)
        installDir = tempDir.appendingPathComponent("LGE Demo Projects", isDirectory: true)
        trash = TestTrash(directory: tempDir.appendingPathComponent("Trash", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func installer(loader: FixtureArchiveLoader? = nil, appVersion: String = "2026.9.44") -> DemoProjectInstaller {
        DemoProjectInstaller(
            loader: loader ?? FixtureArchiveLoader(fixtureURL: archiveURL),
            appVersion: appVersion,
            trash: trash.handler,
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    // MARK: - Install

    func testInstallsVerifiedProjectAndWritesRecord() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL)
        let phases = PhaseRecorder()
        let result = try await installer().install(project, into: installDir, replaceExisting: false) { phases.append($0) }

        XCTAssertEqual(result.projectURL, installDir.appendingPathComponent(DemoProjectFixtures.folderName, isDirectory: true))
        XCTAssertFalse(result.replacedPreviousCopy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.projectURL.appendingPathComponent("metadata.json").path))

        let record = try XCTUnwrap(DemoProjectInstaller.readRecord(inProjectAt: result.projectURL))
        XCTAssertEqual(record.id, "demo-fixture")
        XCTAssertEqual(record.version, "2026.9.44")
        XCTAssertEqual(record.sha256, project.archive.sha256)
        XCTAssertEqual(record.installedAt, Date(timeIntervalSince1970: 1_790_000_000))

        let raw = try String(contentsOf: result.projectURL.appendingPathComponent(".lgedemo.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"installedAt\""))
        XCTAssertTrue(raw.contains("\"sha256\""))

        XCTAssertEqual(visibleAndStagingItems(), [DemoProjectFixtures.folderName])
        XCTAssertTrue(phases.values.contains(.verifying))
        XCTAssertTrue(phases.values.contains(.extracting))
        XCTAssertEqual(phases.values.last, .installing)
    }

    func testAcceptsASingleProjectFolderUnderAnotherName() async throws {
        let renamed = tempDir.appendingPathComponent("renamed.zip")
        try DemoProjectFixtures.writeProjectArchive(to: renamed, folderName: "Other Name.lungfish")
        let project = try DemoProjectFixtures.project(archiveURL: renamed)
        let result = try await installer(loader: FixtureArchiveLoader(fixtureURL: renamed))
            .install(project, into: installDir, replaceExisting: false)
        XCTAssertEqual(result.projectURL.lastPathComponent, DemoProjectFixtures.folderName)
    }

    func testSizeMismatchInstallsNothing() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL, overrideBytes: 999_999)
        await assertInstallFails(project) { error in
            guard case .sizeMismatch(let expected, _) = error else { return false }
            return expected == 999_999
        }
    }

    func testChecksumMismatchInstallsNothing() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL, overrideSHA: String(repeating: "ab", count: 32))
        await assertInstallFails(project) { error in
            guard case .checksumMismatch(let expected, _) = error else { return false }
            return expected == String(repeating: "ab", count: 32)
        }
    }

    func testPlaceholderChecksumIsRefusedBeforeDownloading() async throws {
        let loader = FixtureArchiveLoader(fixtureURL: archiveURL)
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL, overrideSHA: String(repeating: "0", count: 64), overrideBytes: 0)
        do {
            _ = try await installer(loader: loader).install(project, into: installDir, replaceExisting: false)
            XCTFail("expected refusal")
        } catch let error as DemoProjectError {
            XCTAssertEqual(error, .archiveNotPublished(title: "Demo Fixture"))
        }
        XCTAssertTrue(loader.requestedURLs.isEmpty)
    }

    func testTooOldAppIsRefused() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL, minimumAppVersion: "2027.1.0")
        await assertInstallFails(project, installer: installer(appVersion: "2026.9.44")) { error in
            error == .requiresNewerApp(title: "Demo Fixture", minimumVersion: "2027.1.0")
        }
    }

    func testNotFoundAndOfflineErrorsPropagateAndLeaveNothingBehind() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL)
        await assertInstallFails(project, installer: installer(loader: FixtureArchiveLoader(fixtureURL: nil))) { error in
            if case .notFound = error { return true }
            return false
        }
        await assertInstallFails(project, installer: installer(loader: FixtureArchiveLoader(fixtureURL: archiveURL, error: DemoProjectError.offline))) {
            $0 == .offline
        }
        XCTAssertTrue(DemoProjectError.offline.localizedDescription.contains("not connected to the internet"))
        XCTAssertTrue(DemoProjectError.notFound(URL(string: "https://example.invalid/a.zip")!).localizedDescription.contains("404"))
    }

    func testTransportErrorMapping() {
        XCTAssertEqual(URLSessionDemoProjectArchiveLoader.mapTransportError(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(URLSessionDemoProjectArchiveLoader.mapTransportError(URLError(.cannotFindHost)), .offline)
        XCTAssertEqual(URLSessionDemoProjectArchiveLoader.mapTransportError(URLError(.cancelled)), .cancelled)
    }

    func testUnsafeArchiveLeavesNoHalfExtractedFolder() async throws {
        let evil = tempDir.appendingPathComponent("evil.zip")
        try TestZipWriter.write([
            .file("\(DemoProjectFixtures.folderName)/metadata.json", "{}"),
            .symlink("\(DemoProjectFixtures.folderName)/escape", to: "../../../../etc"),
        ], to: evil)
        let project = try DemoProjectFixtures.project(archiveURL: evil)
        await assertInstallFails(project, installer: installer(loader: FixtureArchiveLoader(fixtureURL: evil))) { error in
            if case .unsafeArchive = error { return true }
            return false
        }
    }

    func testMissingProjectFolderIsReported() async throws {
        let loose = tempDir.appendingPathComponent("loose.zip")
        try TestZipWriter.write([.file("readme.txt", "no project here")], to: loose)
        let project = try DemoProjectFixtures.project(archiveURL: loose)
        await assertInstallFails(project, installer: installer(loader: FixtureArchiveLoader(fixtureURL: loose))) {
            $0 == .projectFolderMissing(DemoProjectFixtures.folderName)
        }
    }

    // MARK: - Existing copies

    func testExistingCopyIsNotTouchedWithoutReplace() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL)
        let existing = try makeExistingCopy(version: "2026.9.40")
        let loader = FixtureArchiveLoader(fixtureURL: archiveURL)
        do {
            _ = try await installer(loader: loader).install(project, into: installDir, replaceExisting: false)
            XCTFail("expected alreadyInstalled")
        } catch let error as DemoProjectError {
            XCTAssertEqual(error, .alreadyInstalled(existing))
        }
        XCTAssertTrue(loader.requestedURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.appendingPathComponent("my-notes.txt").path))
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testReplaceMovesOldCopyToTrashAfterTheNewOneIsReady() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL)
        let existing = try makeExistingCopy(version: "2026.9.40")

        let result = try await installer().install(project, into: installDir, replaceExisting: true)

        XCTAssertTrue(result.replacedPreviousCopy)
        XCTAssertEqual(trash.trashed, [existing])
        let trashedCopy = try XCTUnwrap(result.previousCopyTrashURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedCopy.appendingPathComponent("my-notes.txt").path),
                      "the old copy must be recoverable from the Trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.projectURL.appendingPathComponent("my-notes.txt").path))
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: result.projectURL)?.version, "2026.9.44")
        XCTAssertEqual(visibleAndStagingItems(), [DemoProjectFixtures.folderName])
    }

    func testFailedReplaceKeepsTheOldCopy() async throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL, overrideSHA: String(repeating: "cd", count: 32))
        let existing = try makeExistingCopy(version: "2026.9.40")
        do {
            _ = try await installer().install(project, into: installDir, replaceExisting: true)
            XCTFail("expected checksum failure")
        } catch {}
        XCTAssertTrue(trash.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.appendingPathComponent("my-notes.txt").path))
    }

    // MARK: - Status

    func testStatusReflectsTheInstalledRecord() throws {
        let project = try DemoProjectFixtures.project(archiveURL: archiveURL, version: "2026.9.44")
        XCTAssertEqual(DemoProjectInstaller.status(for: project, in: installDir), .notDownloaded)
        XCTAssertEqual(DemoProjectInstallStatus.notDownloaded.label, "Not downloaded")

        let existing = try makeExistingCopy(version: nil)
        XCTAssertEqual(DemoProjectInstaller.status(for: project, in: installDir), .downloaded(version: nil))

        try writeRecord(into: existing, version: "2026.9.44")
        XCTAssertEqual(DemoProjectInstaller.status(for: project, in: installDir), .downloaded(version: "2026.9.44"))
        XCTAssertEqual(DemoProjectInstaller.status(for: project, in: installDir).label, "Downloaded")

        try writeRecord(into: existing, version: "2026.9.40")
        let status = DemoProjectInstaller.status(for: project, in: installDir)
        XCTAssertEqual(status, .updateAvailable(installedVersion: "2026.9.40", availableVersion: "2026.9.44"))
        XCTAssertEqual(status.label, "Update available")
        XCTAssertEqual(status.token, "update-available")
        XCTAssertTrue(status.isInstalled)
    }

    func testDefaultInstallDirectory() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(DemoProjectInstaller.defaultInstallDirectory(homeDirectory: home).path, "/Users/example/Documents/LGE Demo Projects")
    }

    // MARK: - Helpers

    private func makeExistingCopy(version: String?) throws -> URL {
        let existing = installDir.appendingPathComponent(DemoProjectFixtures.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing.appendingPathComponent("my-notes.txt"))
        if let version { try writeRecord(into: existing, version: version) }
        return existing
    }

    private func writeRecord(into projectURL: URL, version: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = DemoProjectInstallRecord(id: "demo-fixture", version: version, sha256: "x", installedAt: Date())
        try encoder.encode(record).write(to: projectURL.appendingPathComponent(".lgedemo.json"))
    }

    /// Everything in the install folder, including hidden staging folders.
    private func visibleAndStagingItems() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: installDir.path)) ?? []).sorted()
    }

    private func assertInstallFails(
        _ project: DemoProject,
        installer: DemoProjectInstaller? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ matches: (DemoProjectError) -> Bool
    ) async {
        do {
            _ = try await (installer ?? self.installer()).install(project, into: installDir, replaceExisting: false)
            XCTFail("expected failure", file: file, line: line)
        } catch let error as DemoProjectError {
            XCTAssertTrue(matches(error), "unexpected error \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        let target = installDir.appendingPathComponent(project.projectFolderName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "no project may be installed", file: file, line: line)
        XCTAssertEqual(visibleAndStagingItems(), [], "no staging folder may be left behind", file: file, line: line)
    }
}

private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [DemoProjectInstallPhase] = []

    var values: [DemoProjectInstallPhase] {
        lock.withLock { _values }
    }

    func append(_ phase: DemoProjectInstallPhase) {
        lock.withLock { _values.append(phase) }
    }
}
