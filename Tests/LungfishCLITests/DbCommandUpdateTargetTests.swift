// DbCommandUpdateTargetTests.swift - Target resolution for `lungfish conda db update`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Exercises which installed rows `db update` addresses and what it exits with, through
/// the built CLI binary against an isolated storage root.
///
/// The contract under test is an exit code paired with what the sibling read commands
/// say, and that only exists at the process boundary. The defects covered are two routes
/// to the same silent false success: `--all` printing "No databases have an update
/// available" and exiting 0 while `db list` advertised one, and `--all` selecting only
/// databases it then skips, changing nothing while still exiting 0.
///
/// Every test here is offline. The seeded rows are the locally built Kraken2 special
/// databases (SILVA, Greengenes), which the catalog describes with a `kraken2Special`
/// recipe and no URL, so `updateDatabase` rejects them as `updateNotSupported` during
/// resolution and never opens a connection. That makes target resolution and the exit
/// contract observable without downloading a multi-hundred-megabyte index. The download
/// path itself is covered by `DatabaseUpdateFlowTests` against a stub installer.
final class DbCommandUpdateTargetTests: XCTestCase {

    private var cliBinaryURL: URL? {
        let buildProductsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return CLITestBinaryResolver.cliBinaryURL(
            repoRoot: CLITestBinaryResolver.repositoryRoot(containing: #filePath),
            buildProductsDirectory: buildProductsDirectory
        )
    }

    /// A locally built database advertising an update is selected by `--all`, skipped
    /// because it cannot be updated in place, and the run exits non-zero because it
    /// changed nothing.
    ///
    /// Skipping is right per-database when other databases still update; when it accounts
    /// for the whole run, exiting 0 would tell a sweep script the databases are current.
    func testUpdateAllExitsNonZeroWhenEverySelectedDatabaseIsSkipped() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLocallyBuiltRow(in: root, name: "SILVA")

        let list = try runCLI(["conda", "db", "list"], storageRoot: root)
        XCTAssertEqual(list.exitCode, 0, "stderr:\n\(list.stderr)")
        let row = try XCTUnwrap(
            list.stdout.split(separator: "\n").first { $0.hasPrefix("SILVA ") },
            "no SILVA row in db list output:\n\(list.stdout)"
        )
        // Precondition: db list is advertising an update for the seeded row.
        XCTAssertTrue(
            row.contains("yes ("),
            "expected db list to advertise an update for the seeded row:\n\(row)"
        )

        let update = try runCLI(["conda", "db", "update", "--all", "--yes"], storageRoot: root)

        // It must not claim there was nothing to do: db list says otherwise.
        XCTAssertFalse(
            update.stdout.contains("No databases have an update available"),
            "db update --all claimed there was nothing to update while db list advertised one:\n"
            + "list row: \(row)\nupdate stdout:\n\(update.stdout)"
        )
        // It resolved the row (rather than dropping it for having no catalogID) and
        // skipped it for the right reason.
        XCTAssertTrue(update.stdout.contains("Skipped"), "update stdout:\n\(update.stdout)")
        XCTAssertTrue(
            update.stdout.contains("rebuilt by reinstalling"),
            "the skip should name the locally-built reason:\n\(update.stdout)"
        )
        // Nothing was applied, so this is not a success.
        XCTAssertTrue(
            update.stdout.contains("No database was updated"),
            "a run that applied nothing must say so:\n\(update.stdout)"
        )
        XCTAssertEqual(
            update.exitCode, CLIExitCode.failure.rawValue,
            "db update --all applied nothing and must not exit 0:\n\(update.stdout)"
        )
    }

    /// A row registered from disk carries no `catalogID`. Addressing it by catalog id must
    /// find it, rather than reporting it absent from the registry it is plainly listed in.
    func testUpdateByCatalogIDResolvesARowRegisteredWithoutCatalogIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLocallyBuiltRow(in: root, name: "SILVA")

        let result = try runCLI(
            ["conda", "db", "update", "kraken2-special-silva", "--yes"],
            storageRoot: root
        )

        // Resolution succeeded: the failure is the locally-built skip, not a lookup miss.
        XCTAssertFalse(
            (result.stdout + result.stderr).contains("not found in registry"),
            "db update could not resolve an installed row that db list shows:\n\(result.stdout)"
        )
        XCTAssertTrue(result.stdout.contains("Skipped"), "stdout:\n\(result.stdout)")
    }

    /// The display name is what `db list` prints, so it addresses the row too.
    func testUpdateByDisplayNameResolvesTheInstalledRow() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLocallyBuiltRow(in: root, name: "SILVA")

        let result = try runCLI(["conda", "db", "update", "SILVA", "--yes"], storageRoot: root)

        XCTAssertFalse(
            (result.stdout + result.stderr).contains("not found in registry"),
            "db update rejected the display name db list prints:\n\(result.stdout)"
        )
        XCTAssertTrue(result.stdout.contains("Skipped"), "stdout:\n\(result.stdout)")
    }

    /// An identifier that names nothing installed is still a lookup failure.
    func testUpdateReportsAnUnknownIdentifierAsNotFound() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLocallyBuiltRow(in: root, name: "SILVA")

        let result = try runCLI(
            ["conda", "db", "update", "kraken2-not-a-database", "--yes"],
            storageRoot: root
        )

        XCTAssertTrue(
            (result.stdout + result.stderr).contains("not found in registry"),
            "stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        )
        XCTAssertNotEqual(result.exitCode, 0)
    }

    /// With nothing advertising an update, "nothing to update" is the truth and 0 is right.
    func testUpdateAllExitsZeroWhenNothingAdvertisesAnUpdate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // No seeded rows at all: every catalog entry is `missing`, and a database that is
        // not installed does not advertise an update.

        let result = try runCLI(["conda", "db", "update", "--all", "--yes"], storageRoot: root)

        XCTAssertTrue(
            result.stdout.contains("No databases have an update available"),
            "stdout:\n\(result.stdout)"
        )
        XCTAssertEqual(result.exitCode, 0, "stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
    }

    // MARK: - Helpers

    /// Writes an installed row for a locally built Kraken2 special database, with a null
    /// `catalogID`, which is how a database registered from disk is recorded and therefore
    /// how the rows in a real user's registry look.
    ///
    /// Locally built databases are the offline seam: their catalog entry carries a
    /// `kraken2Special` recipe rather than an archive URL, so `updateDatabase` resolves the
    /// row and then rejects it without any network access.
    private func seedLocallyBuiltRow(in root: URL, name: String) throws {
        let databases = root.appendingPathComponent("databases", isDirectory: true)
        let payload = databases.appendingPathComponent("kraken2/\(name.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "seed".write(
                to: payload.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }

        // An installed version the manifest has moved past, so the row advertises an
        // update. Derived from the pinned version rather than hardcoded, so a later bump
        // cannot quietly turn this into an up-to-date row that asserts nothing.
        let pinned = MetagenomicsDatabaseInfo.builtInCatalog
            .first { $0.name == name }?
            .version
        let installedVersion = "\(pinned ?? "kraken2-special-v1")-installed-older"
        XCTAssertNotEqual(installedVersion, pinned, "seeded row must differ from the pinned version")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let row: [String: Any] = [
            "name": name,
            "tool": "kraken2",
            "version": installedVersion,
            "sizeBytes": 1024,
            "sizeOnDisk": 1024,
            "description": "User-imported Kraken2 database",
            "path": payload.absoluteString,
            "isExternal": false,
            "status": "ready",
            "recommendedRAM": 1024,
            "installedAt": timestamp,
            "lastUpdated": timestamp,
        ]
        let manifest: [String: Any] = ["version": 1, "databases": [row]]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(
            to: databases.appendingPathComponent("metagenomics-db-registry.json"),
            options: .atomic
        )
    }

    private func runCLI(
        _ arguments: [String],
        storageRoot: URL
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            cliBinaryURL,
            "CLI binary not built at expected path - run `swift build --product lungfish-cli` before these process tests"
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment
        merged["LUNGFISH_STORAGE_ROOT"] = storageRoot.path
        process.environment = merged

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Both pipes are drained before waiting: a child that fills either 64KB buffer
        // while we block in waitUntilExit would deadlock.
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-update-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
