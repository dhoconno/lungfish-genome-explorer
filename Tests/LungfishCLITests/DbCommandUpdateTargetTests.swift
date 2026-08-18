// DbCommandUpdateTargetTests.swift - Target resolution for `lungfish conda db update`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Exercises which installed rows `db update` can actually address, through the built CLI
/// binary against an isolated storage root.
///
/// The contract under test is an exit code paired with what the sibling read commands say,
/// and that only exists at the process boundary: the defect these cover was `--all`
/// printing "No databases have an update available" and exiting 0 while `db list` in the
/// same root advertised an update, so a sweep script recorded a successful update that
/// never happened.
final class DbCommandUpdateTargetTests: XCTestCase {

    private var cliBinaryURL: URL? {
        let buildProductsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return CLITestBinaryResolver.cliBinaryURL(
            repoRoot: CLITestBinaryResolver.repositoryRoot(containing: #filePath),
            buildProductsDirectory: buildProductsDirectory
        )
    }

    /// `db list` advertising an update and `db update --all` finding none is the exact
    /// false success this covers: the two commands must agree that there is work to do.
    ///
    /// The run is cut off as soon as it commits to a target, because committing to one is
    /// the whole assertion and carrying on would download the real multi-hundred-megabyte
    /// index. `updateDatabase` stages into a sibling directory and only swaps on success,
    /// so an interrupted run leaves the seeded payload untouched.
    func testUpdateAllCommitsToTheTargetListAdvertises() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedCatalogIDLessViralRow(in: root)

        let list = try runCLI(["conda", "db", "list"], storageRoot: root)
        XCTAssertEqual(list.exitCode, 0, "stderr:\n\(list.stderr)")
        // Anchored to the start of the row: "EsViritu Viral DB" is also in this table and
        // merely containing "Viral" would match it instead.
        let viralRow = try XCTUnwrap(
            list.stdout.split(separator: "\n").first { $0.hasPrefix("Viral ") },
            "no Viral row in db list output:\n\(list.stdout)"
        )
        // Precondition: the seeded row is advertising an update.
        XCTAssertTrue(
            viralRow.contains("yes ("),
            "expected db list to advertise an update for the seeded row:\n\(viralRow)"
        )

        let update = try runCLIUntilTargetIsCommitted(
            ["conda", "db", "update", "--all", "--yes"],
            storageRoot: root
        )

        XCTAssertFalse(
            update.contains("No databases have an update available"),
            "db update --all claimed there was nothing to update while db list advertised one:\n"
            + "list row: \(viralRow)\nupdate output:\n\(update)"
        )
        XCTAssertTrue(
            update.contains("Updating Viral"),
            "db update --all did not commit to the row db list advertises:\n\(update)"
        )
    }

    /// A row with no catalog identity is addressable by its catalog id, rather than
    /// reported as absent from the registry it is plainly listed in.
    func testUpdateByCatalogIDResolvesARowRegisteredWithoutCatalogIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedCatalogIDLessViralRow(in: root)

        let output = try runCLIUntilTargetIsCommitted(
            ["conda", "db", "update", "kraken2-viral", "--yes"],
            storageRoot: root
        )

        XCTAssertFalse(
            output.contains("not found in registry"),
            "db update could not resolve an installed row that db list shows:\n\(output)"
        )
        XCTAssertTrue(output.contains("Downloading Viral"), "output:\n\(output)")
    }

    /// The display name is what `db list` prints, so it addresses the row too.
    func testUpdateByDisplayNameResolvesTheInstalledRow() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedCatalogIDLessViralRow(in: root)

        let output = try runCLIUntilTargetIsCommitted(
            ["conda", "db", "update", "Viral", "--yes"],
            storageRoot: root
        )

        XCTAssertFalse(
            output.contains("not found in registry"),
            "db update rejected the display name db list prints:\n\(output)"
        )
        XCTAssertTrue(output.contains("Downloading Viral"), "output:\n\(output)")
    }

    // MARK: - Helpers

    /// Writes an installed Kraken2 Viral row with a null `catalogID`, which is how a
    /// database registered from disk is recorded and therefore how the rows in a real
    /// user's registry look.
    private func seedCatalogIDLessViralRow(in root: URL) throws {
        let databases = root.appendingPathComponent("databases", isDirectory: true)
        let payload = databases.appendingPathComponent("kraken2/viral", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "old".write(
                to: payload.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }

        // An installed version the manifest has moved past, so the row advertises an
        // update. Read from the manifest rather than hardcoded, so a later bump of the
        // pinned version does not quietly turn this row into an up-to-date one and leave
        // the test asserting nothing.
        let pinned = ManagedToolLock.bundled.database(id: "kraken2-viral")?.version
        let installedVersion = (pinned == "20240904") ? "20230605" : "20240904"
        XCTAssertNotEqual(installedVersion, pinned, "seeded row must be older than the pinned version")

        let row: [String: Any] = [
            "name": "Viral",
            "tool": "kraken2",
            "version": installedVersion,
            "sizeBytes": 1024,
            "sizeOnDisk": 1024,
            "description": "User-imported Kraken2 database",
            "path": payload.absoluteString,
            "isExternal": false,
            "status": "ready",
            "recommendedRAM": 1024,
            "installedAt": ISO8601DateFormatter().string(from: Date()),
            "lastUpdated": ISO8601DateFormatter().string(from: Date()),
        ]
        let manifest: [String: Any] = ["version": 1, "databases": [row]]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(
            to: databases.appendingPathComponent("metagenomics-db-registry.json"),
            options: .atomic
        )
    }

    /// Runs the CLI and returns its output as soon as it has committed to an update
    /// target, terminating it there.
    ///
    /// Target resolution is the whole assertion; what follows it is a real download of a
    /// real index, which a unit test must not perform. The command is killed once it
    /// prints the progress line that only appears after a target is resolved, or when it
    /// exits on its own (the "nothing to update" path, which resolves nothing and is
    /// itself a result worth returning).
    ///
    /// Killing mid-download is safe for the seeded root: `updateDatabase` stages into a
    /// sibling directory and swaps only after the payload verifies, so an interrupted run
    /// never touches the installed copy.
    private func runCLIUntilTargetIsCommitted(
        _ arguments: [String],
        storageRoot: URL,
        timeout: TimeInterval = 25
    ) throws -> String {
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

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        // Read incrementally so the decision to stop can be made from the output itself.
        // readDataToEndOfFile would block until the download finished, which is the thing
        // being avoided.
        let handle = pipe.fileHandleForReading
        var output = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF: the process exited on its own.
            output += String(decoding: chunk, as: UTF8.self)
            // "Downloading" is printed by the progress callback, which is only reached
            // once a target has been resolved and the transfer has begun.
            if output.contains("Downloading") || output.contains("No databases have an update available") {
                break
            }
        }

        if process.isRunning {
            process.terminate()
        }
        // Drain whatever is buffered so the pipe's writer end can close, then reap.
        _ = try? handle.readToEnd()
        process.waitUntilExit()
        return output
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
