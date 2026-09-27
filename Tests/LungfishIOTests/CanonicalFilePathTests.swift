import XCTest
@testable import LungfishIO

final class CanonicalFilePathTests: XCTestCase {
    private var root: URL!
    private var physicalRoot: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonicalFilePathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        physicalRoot = try XCTUnwrap(root.path.withCString { realpath($0, nil) }.map { String(cString: $0) })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExistingAndMissingFilesUnderPrivateTempShareThePhysicalPrefix() throws {
        // Foundation strips a leading /private only for paths that exist, so
        // an existing file and its not-yet-written sibling used to canonicalise
        // to different prefixes.
        let existing = URL(fileURLWithPath: physicalRoot + "/exists.txt")
        try Data("x".utf8).write(to: existing)
        let missing = URL(fileURLWithPath: physicalRoot + "/missing.txt")

        XCTAssertEqual(existing.canonicalFilePath, physicalRoot + "/exists.txt")
        XCTAssertEqual(missing.canonicalFilePath, physicalRoot + "/missing.txt")
        XCTAssertEqual(
            URL(fileURLWithPath: physicalRoot + "/missingdir/deeper/file.txt").canonicalFilePath,
            physicalRoot + "/missingdir/deeper/file.txt"
        )
    }

    func testSymlinkedDirectoryResolvesToItsTarget() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = link.appendingPathComponent("out.txt")
        let viaReal = real.appendingPathComponent("out.txt")
        XCTAssertEqual(viaLink.canonicalFilePath, viaReal.canonicalFilePath)
        XCTAssertEqual(viaLink.canonicalFilePath, physicalRoot + "/real/out.txt")

        try Data("x".utf8).write(to: viaReal)
        XCTAssertEqual(viaLink.canonicalFilePath, viaReal.canonicalFilePath, "unchanged once the file exists")
        XCTAssertEqual(viaLink.canonicalFileURL.path, viaReal.canonicalFilePath)
    }

    func testTmpAndVarAliasesResolveToPrivate() {
        XCTAssertEqual(URL(fileURLWithPath: "/tmp").canonicalFilePath, "/private/tmp")
        XCTAssertEqual(URL(fileURLWithPath: "/tmp/never-created-\(UUID().uuidString)/x").canonicalFilePath.hasPrefix("/private/tmp/never-created-"), true)
        XCTAssertEqual(URL(fileURLWithPath: "/private/tmp/../tmp/x").canonicalFilePath, "/private/tmp/x")
    }
}
