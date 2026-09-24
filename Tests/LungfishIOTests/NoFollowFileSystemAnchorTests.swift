import Darwin
import Foundation
import XCTest
@testable import LungfishIO

/// Anchoring of `NoFollowFileSystem.openDirectoryHierarchy` (NEW-11).
///
/// The live failure (an `openat` of `~/Desktop` blocking without the folder
/// TCC grant) cannot be reproduced in a test process. These tests pin the
/// anchoring logic that avoids that open: symlinks above the project or bundle
/// are followed, symlinks inside it are still rejected.
final class NoFollowFileSystemAnchorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoFollowAnchorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - trustedAnchor

    func testTrustedAnchorIsOutermostLungfishComponent() {
        let url = URL(fileURLWithPath: "/Users/x/Desktop/P.lungfish/Refs/g.lungfishref/tracks")
        XCTAssertEqual(
            NoFollowFileSystem.trustedAnchor(for: url)?.path,
            "/Users/x/Desktop/P.lungfish"
        )
    }

    func testTrustedAnchorFallsBackToBundleOutsideProject() {
        let url = URL(fileURLWithPath: "/Volumes/d/runs/S1.lungfishfastq/derived")
        XCTAssertEqual(
            NoFollowFileSystem.trustedAnchor(for: url)?.path,
            "/Volumes/d/runs/S1.lungfishfastq"
        )
    }

    func testTrustedAnchorIsNilOutsideProjectsAndIgnoresDotLungfishStorageRoot() {
        XCTAssertNil(NoFollowFileSystem.trustedAnchor(
            for: URL(fileURLWithPath: "/Users/x/Documents/plain/dir")
        ))
        XCTAssertNil(NoFollowFileSystem.trustedAnchor(
            for: URL(fileURLWithPath: "/Users/x/.lungfish/conda")
        ))
    }

    // MARK: - openDirectoryHierarchy

    func testSymlinkAboveProjectAnchorIsFollowed() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        let project = real.appendingPathComponent("P.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Data/sub"),
            withIntermediateDirectories: true
        )
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = link.appendingPathComponent("P.lungfish/Data/sub", isDirectory: true)
        let descriptor = try NoFollowFileSystem.openDirectoryHierarchy(viaLink)
        defer { Darwin.close(descriptor) }
        try assertDescriptor(descriptor, isSameDirectoryAs: project.appendingPathComponent("Data/sub"))
    }

    func testSymlinkAboveAnchorIsStillRejectedWithoutProject() throws {
        let real = root.appendingPathComponent("real/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("real")
        )

        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(
            link.appendingPathComponent("sub")
        ))
    }

    func testSymlinkBelowProjectAnchorIsRejected() throws {
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let planted = project.appendingPathComponent("planted", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: planted,
            withDestinationURL: root.appendingPathComponent("outside")
        )

        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(planted)) {
            // O_NOFOLLOW|O_DIRECTORY on a symlink reports ELOOP or ENOTDIR.
            let code = ($0 as? POSIXError)?.code
            XCTAssertTrue(code == .ELOOP || code == .ENOTDIR, "\(String(describing: code))")
        }
        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(
            planted.appendingPathComponent("sub")
        ))
    }

    func testSymlinkedBundleInsideProjectIsRejected() throws {
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        let realBundle = root.appendingPathComponent("elsewhere.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBundle, withIntermediateDirectories: true)
        let linkedBundle = project.appendingPathComponent("g.lungfishref", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedBundle, withDestinationURL: realBundle)

        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(linkedBundle))
    }

    func testProjectAnchorThatIsItselfASymlinkIsRejected() throws {
        let realProject = root.appendingPathComponent("real.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realProject.appendingPathComponent("Data"),
            withIntermediateDirectories: true
        )
        let linkedProject = root.appendingPathComponent("linked.lungfish", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedProject, withDestinationURL: realProject)

        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(linkedProject))
        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(
            linkedProject.appendingPathComponent("Data")
        ))
    }

    func testNestedCreationInsideProjectWorks() throws {
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        let nested = project.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let store = DurableAtomicFileStore()
        try store.create(Data("x".utf8), named: "record.json", in: nested)
        XCTAssertEqual(
            try Data(contentsOf: nested.appendingPathComponent("record.json")),
            Data("x".utf8)
        )

        let tempDirectory = try ProjectTempDirectory.create(prefix: "anchor-", in: project)
        XCTAssertTrue(tempDirectory.path.hasPrefix(project.path))
    }

    func testExplicitAnchorMustBeAncestor() throws {
        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(a, anchoredAt: b)) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EINVAL)
        }
    }

    func testExplicitAnchorFollowsLinksAboveAndRejectsLinksBelow() throws {
        let real = root.appendingPathComponent("real/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("real")
        )
        let anchor = link.appendingPathComponent("inner", isDirectory: true)
        let descriptor = try NoFollowFileSystem.openDirectoryHierarchy(anchor, anchoredAt: anchor)
        Darwin.close(descriptor)

        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("planted"),
            withDestinationURL: root
        )
        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(
            anchor.appendingPathComponent("planted"),
            anchoredAt: anchor
        ))
    }

    private func assertDescriptor(
        _ descriptor: Int32,
        isSameDirectoryAs url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var opened = stat()
        var expected = stat()
        XCTAssertEqual(Darwin.fstat(descriptor, &opened), 0, file: file, line: line)
        XCTAssertEqual(Darwin.lstat(url.path, &expected), 0, file: file, line: line)
        XCTAssertEqual(opened.st_ino, expected.st_ino, file: file, line: line)
        XCTAssertEqual(opened.st_dev, expected.st_dev, file: file, line: line)
    }
}
