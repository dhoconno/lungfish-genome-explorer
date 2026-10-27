import XCTest
import LungfishCore
@testable import LungfishApp

/// The open path reads a lock Finder copied with a project as no lock on the copy,
/// so File > Open Project Folder… and the Welcome window open the copy with write
/// access and no alert. A lock of a live session on the folder being opened still
/// recommends read-only (3.0 lane PROJECT-LOCK, walk WF-2).
@MainActor
final class ProjectOpenWarningStateTests: XCTestCase {
    private var root: URL!
    private var original: URL { root.appendingPathComponent("P.lungfish", isDirectory: true) }
    private var copy: URL { root.appendingPathComponent("P.lungfish copy", isDirectory: true) }

    /// A closed project `P.lungfish` in a new folder that the test removes when it ends.
    private func makeOriginal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectOpenWarningStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        root = folder
        _ = try ProjectFile.create(at: original, name: "P")
    }

    func testCopiedLockIsNotReadOnly() throws {
        try makeOriginal()
        let store = try ProjectStore(opening: original, access: .writable)
        try FileManager.default.copyItem(at: original, to: copy)

        let warning = ProjectOpenWarningState.evaluate(projectURL: copy)

        XCTAssertFalse(warning.isReadOnlyRecommended, warning.warningMessage ?? "")
        withExtendedLifetime(store) {}
    }

    func testCopyOfAnOpenProjectPreparesWritableAndItsLockNamesTheCopy() throws {
        try makeOriginal()
        let store = try ProjectStore(opening: original, access: .writable)
        let originalLock = try Data(contentsOf: ProjectLockManager.lockURL(for: original))
        try FileManager.default.copyItem(at: original, to: copy)

        let prepared = try ProjectSession.prepareProject(at: copy)

        XCTAssertFalse(prepared.warning.isReadOnlyRecommended, prepared.warning.warningMessage ?? "")
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: copy))
        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: copy)?.projectPath, copy.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: ProjectLockManager.lockURL(for: original)), originalLock)
        withExtendedLifetime((store, prepared)) {}
    }

    func testCopiedLockIsNotReadOnlyAfterTheOriginalCloses() throws {
        try makeOriginal()
        do {
            let store = try ProjectStore(opening: original, access: .writable)
            try FileManager.default.copyItem(at: original, to: copy)
            withExtendedLifetime(store) {}
        }

        let prepared = try ProjectSession.prepareProject(at: copy)

        XCTAssertFalse(prepared.warning.isReadOnlyRecommended, prepared.warning.warningMessage ?? "")
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: copy))
        withExtendedLifetime(prepared) {}
    }

    func testFolderMovedWhileOpenStaysReadOnly() throws {
        try makeOriginal()
        let moved = root.appendingPathComponent("Moved.lungfish", isDirectory: true)
        let store = try ProjectStore(opening: original, access: .writable)
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertTrue(ProjectOpenWarningState.evaluate(projectURL: moved).isReadOnlyRecommended)
        withExtendedLifetime(store) {}
    }
}
