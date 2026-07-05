import XCTest
@testable import LungfishCore

final class ManagedStorageLocationTests: XCTestCase {
    func testDefaultLocationUsesDotLungfishRoot() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let location = ManagedStorageLocation.defaultLocation(homeDirectory: home)

        XCTAssertEqual(location.rootURL.path, "/Users/tester/.lungfish")
        XCTAssertEqual(location.condaRootURL.path, "/Users/tester/.lungfish/conda")
        XCTAssertEqual(location.databaseRootURL.path, "/Users/tester/.lungfish/databases")
    }

    func testValidationRejectsResolvedPathsContainingSpaces() {
        let base = URL(fileURLWithPath: "/Volumes/My SSD/Lungfish", isDirectory: true)
        let result = ManagedStorageLocation.validateSelection(base)

        XCTAssertEqual(result, .invalid(.containsSpaces))
        XCTAssertEqual(
            ManagedStorageLocation.ValidationError.containsSpaces.errorDescription,
            "The selected location resolves to a path with spaces. Managed tool installs still require a space-free path, so choose a folder whose full path has no spaces or rename the external volume."
        )
    }

    func testValidationRejectsProjectNestedPath() {
        let base = URL(fileURLWithPath: "/Users/tester/Project.lungfish/Support", isDirectory: true)
        let result = ManagedStorageLocation.validateSelection(base)

        XCTAssertEqual(result, .invalid(.nestedInsideProject))
    }

    func testValidationRejectsNonFileURLAsUnsupportedFilesystem() throws {
        let remote = try XCTUnwrap(URL(string: "smb://example.invalid/Lungfish"))

        XCTAssertEqual(
            ManagedStorageLocation.validateSelection(remote),
            .invalid(.unsupportedFilesystem)
        )
    }

    func testValidationRejectsFileWhereDirectoryIsExpected() throws {
        let root = try temporaryDirectory()
        let fileURL = root.appendingPathComponent("managed-storage")
        try Data("not a directory".utf8).write(to: fileURL)

        XCTAssertEqual(
            ManagedStorageLocation.validateSelection(fileURL),
            .invalid(.unreachable)
        )
    }

    func testValidationAcceptsCreatableDirectoryUnderWritableParent() throws {
        let root = try temporaryDirectory()
        let creatable = root
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("managed-storage", isDirectory: true)

        XCTAssertEqual(ManagedStorageLocation.validateSelection(creatable), .valid)
    }

    func testValidationRejectsCreatableDirectoryUnderUnwritableParent() throws {
        let root = try temporaryDirectory()
        let lockedParent = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent.path)
        }

        let creatable = lockedParent.appendingPathComponent("managed-storage", isDirectory: true)

        XCTAssertEqual(
            ManagedStorageLocation.validateSelection(creatable),
            .invalid(.notWritable)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedStorageLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
