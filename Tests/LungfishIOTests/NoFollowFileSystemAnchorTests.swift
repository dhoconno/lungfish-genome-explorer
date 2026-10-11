import Darwin
import Foundation
import XCTest
@testable import LungfishIO

/// Anchoring of `NoFollowFileSystem.openDirectoryHierarchy`.
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

    /// Plan decision V3. Outside every project and bundle the destination
    /// folder is the anchor, so a link above it is followed. Before V3 the
    /// walk started at `/` and refused it, which rolled back verified conda
    /// installs and opened protected folders such as `~/Documents`.
    func testSymlinkAboveDestinationIsFollowedWithoutProject() throws {
        let real = root.appendingPathComponent("real/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("real")
        )

        let descriptor = try NoFollowFileSystem.openDirectoryHierarchy(
            link.appendingPathComponent("sub")
        )
        defer { Darwin.close(descriptor) }
        try assertDescriptor(descriptor, isSameDirectoryAs: real)
    }

    /// `/tmp` and `/var` are links macOS installs to `/private`, and
    /// `standardizedFileURL` spells `/private/tmp` as `/tmp`. A folder
    /// anchored at either opens through that platform alias.
    func testTmpAndPrivateTmpOpenAsPrivateTmp() throws {
        for path in ["/tmp", "/private/tmp"] {
            let descriptor = try NoFollowFileSystem.openDirectoryHierarchy(
                URL(fileURLWithPath: path, isDirectory: true)
            )
            defer { Darwin.close(descriptor) }
            try assertDescriptor(descriptor, isSameDirectoryAs: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        }
    }

    /// The general open keeps refusing it, because recovery code checks LGE's
    /// own work and operation folders with it. A record writer's destination
    /// opens through `openDestinationFolder`, pinned below.
    func testDestinationThatIsItselfASymlinkIsRejectedWithoutProject() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(link)) {
            let code = ($0 as? POSIXError)?.code
            XCTAssertTrue(code == .ELOOP || code == .ENOTDIR, "\(String(describing: code))")
        }
    }

    /// Plan decision V3. Outside every project and bundle a record writer's
    /// destination is the user's own layout, so a folder that is itself a
    /// link opens as the real folder it names. `convert` and `genotype
    /// export` into an output folder reached through a link rely on it.
    func testDestinationFolderThatIsItselfASymlinkOpensAsItsRealFolderWithoutProject() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let descriptor = try NoFollowFileSystem.openDestinationFolder(link)
        defer { Darwin.close(descriptor) }
        try assertDescriptor(descriptor, isSameDirectoryAs: real)

        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        let fileLink = root.appendingPathComponent("file-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        XCTAssertThrowsError(try NoFollowFileSystem.openDestinationFolder(fileLink)) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .ENOTDIR)
        }
    }

    /// A record writer's destination still refuses a link below a
    /// `.lungfish*` anchor and an anchor that is itself a link.
    func testDestinationFolderRefusesLinksBelowAProjectOrBundle() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        let bundle = root.appendingPathComponent("runs/S1.lungfishfastq", isDirectory: true)
        let realProject = root.appendingPathComponent("real.lungfish", isDirectory: true)
        for folder in [outside, project, bundle, realProject] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let plantedInProject = project.appendingPathComponent("planted", isDirectory: true)
        let plantedInBundle = bundle.appendingPathComponent("derived", isDirectory: true)
        let linkedProject = root.appendingPathComponent("linked.lungfish", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: plantedInProject, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: plantedInBundle, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: linkedProject, withDestinationURL: realProject)

        for refused in [plantedInProject, plantedInBundle, linkedProject] {
            XCTAssertThrowsError(
                try NoFollowFileSystem.openDestinationFolder(refused),
                refused.lastPathComponent
            )
        }
    }

    func testSymlinkBelowBundleOutsideProjectIsRejected() throws {
        let bundle = root.appendingPathComponent("runs/S1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let planted = bundle.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)

        XCTAssertThrowsError(try NoFollowFileSystem.openDirectoryHierarchy(planted))
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
