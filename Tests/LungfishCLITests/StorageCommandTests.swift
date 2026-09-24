import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore

final class StorageCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    func testStorageCommandParsesDedupeAndInfo() throws {
        let help = StorageCommand.helpMessage()
        XCTAssertTrue(help.contains("dedupe"))
        XCTAssertTrue(help.contains("info"))

        let dry = try StorageCommand.parseAsRoot(["dedupe", "--roots", "/a", "/b", "--format", "json"])
        let dryCommand = try XCTUnwrap(dry as? StorageCommand.DedupeSubcommand)
        XCTAssertEqual(dryCommand.roots, ["/a", "/b"])
        XCTAssertFalse(dryCommand.apply)

        let apply = try StorageCommand.parseAsRoot(["dedupe", "--apply"])
        XCTAssertTrue(try XCTUnwrap(apply as? StorageCommand.DedupeSubcommand).apply)

        XCTAssertThrowsError(try StorageCommand.parseAsRoot(["dedupe", "--dry-run", "--apply"]))
        XCTAssertThrowsError(try StorageCommand.parseAsRoot(["dedupe", "--roots", "relative/path"]))
        XCTAssertTrue(try StorageCommand.parseAsRoot(["info", "--format", "json"]) is StorageCommand.InfoSubcommand)
    }

    func testDefaultRootsAreExistingChannelRoots() throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let preview = home.appendingPathComponent(".lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".lungfish-shared", isDirectory: true), withIntermediateDirectories: true
        )
        XCTAssertEqual(
            StorageCommand.defaultRoots(homeDirectory: home).map(\.lastPathComponent),
            [".lungfish", ".lungfish-shared"]
        )
    }

    func testDedupeRunsAgainstExplicitRootsThroughTheSharedService() async throws {
        let roots = ["preview", "stable"].map { tempDir.appendingPathComponent($0, isDirectory: true) }
        var payload = Data(count: 32 * 1024)
        payload.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8(truncatingIfNeeded: index) }
        }
        for root in roots {
            let file = root.appendingPathComponent("databases/kraken2/viral/hash.k2d")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: file)
        }
        let command = try XCTUnwrap(
            try StorageCommand.parseAsRoot(["dedupe", "--apply", "--format", "json", "--roots"] + roots.map(\.path))
                as? StorageCommand.DedupeSubcommand
        )
        try await command.run()

        let report = try ManagedStorageDeduplicator().dryRun(ManagedStorageDedupeOptions(roots: roots))
        XCTAssertEqual(report.bytesReclaimable, 0)
        for root in roots {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(ManagedStorageDeduplicator.logFilename).path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("databases/kraken2/viral/hash.k2d")), payload)
        }
    }
}
