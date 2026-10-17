// MappingViewerBundlePublicationLocationTests.swift - Where a mapping viewer candidate may be published to
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 review A62, Fix 9 (K11). `MappingViewerBundlePublicationService.publishCandidate` renames the hidden
// candidate bundle of a Map Reads onto a reference bundle to the final one, and refuses a final bundle that is not
// next to its candidate (`invalidCandidateLocation`). Lane A62 rewrote that guard, because a project spelled under
// `/private` failed it. `standardizedFileURL` drops a leading `/private` from a path that exists (the candidate) and
// keeps it on a path that does not exist yet (the final bundle of a first publication), so the two folders no longer
// matched. The case that proves the fix on the app and on `lungfish-cli map` is MappingRoutePrivateProjectReplayTests,
// which needs minimap2, samtools and the built CLI and so runs in the integration tier. These four cases run the guard
// alone on bare candidate folders, in the unit tier, so a regression of the guard fails a unit gate too.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class MappingViewerBundlePublicationLocationTests: XCTestCase {
    private static let payload = Data("new-viewer".utf8)

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingViewerLocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// K11. The folder is spelled the way `realpath` gives it (`/private/var/folders/...`), the candidate exists in it,
    /// and the final bundle does not, which is how a first publication meets the guard. The guard has to see both
    /// bundles in one folder, and the publication has to run to its end.
    func testAFinalBundleSpelledUnderPrivateIsAdjacentToItsExistingCandidate() throws {
        let folder = try Self.privateSpelling(of: tempDirectory)
        XCTAssertTrue(folder.path.hasPrefix("/private/"), "the folder is not spelled under /private: \(folder.path)")
        let candidate = try makeCandidate(in: folder)
        let finalBundle = folder.appendingPathComponent("x.lungfishref", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalBundle.path))

        var published: URL?
        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidate,
            finalBundleURL: finalBundle
        ) { published = $0 }

        XCTAssertEqual(published?.lastPathComponent, "x.lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalBundle.path), "x.lungfishref was not published")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path), "the candidate is still in \(folder.path)")
        XCTAssertEqual(try Data(contentsOf: finalBundle.appendingPathComponent("sentinel")), Self.payload)
    }

    /// A final bundle in a sibling folder is not adjacent to the candidate, and nothing is moved.
    func testAFinalBundleInAnotherFolderIsRefused() throws {
        let folderA = tempDirectory.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDirectory.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let candidate = try makeCandidate(in: folderA)
        let finalBundle = folderB.appendingPathComponent("x.lungfishref", isDirectory: true)

        XCTAssertThrowsError(
            try MappingViewerBundlePublicationService.publishCandidate(
                candidateBundleURL: candidate,
                finalBundleURL: finalBundle
            ) { _ in
                XCTFail("Finalization must not run for a final bundle in another folder.")
            }
        ) { error in
            guard case MappingViewerBundlePublicationError.invalidCandidateLocation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: candidate.appendingPathComponent("sentinel")), Self.payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalBundle.path))
    }

    /// A final bundle with the candidate's own name is the candidate, and nothing is moved.
    func testAFinalBundleWithTheCandidatesNameIsRefused() throws {
        let candidate = try makeCandidate(in: tempDirectory)

        XCTAssertThrowsError(
            try MappingViewerBundlePublicationService.publishCandidate(
                candidateBundleURL: candidate,
                finalBundleURL: candidate
            ) { _ in
                XCTFail("Finalization must not run for a final bundle that is the candidate.")
            }
        ) { error in
            guard case MappingViewerBundlePublicationError.invalidCandidateLocation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: candidate.appendingPathComponent("sentinel")), Self.payload)
    }

    /// The widening of lane A62 (its deviation 1). A final bundle named through a symbolic link to the candidate's
    /// folder is in that folder, so it is accepted, where the old guard compared the two spellings and refused it. The
    /// bundle is published inside the one physical folder.
    func testAFinalBundleInAFolderSpelledThroughASymlinkIsAccepted() throws {
        let folderA = tempDirectory.appendingPathComponent("A", isDirectory: true)
        let link = tempDirectory.appendingPathComponent("L", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folderA)
        let candidate = try makeCandidate(in: folderA)
        let finalBundle = link.appendingPathComponent("x.lungfishref", isDirectory: true)

        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidate,
            finalBundleURL: finalBundle
        ) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderA.appendingPathComponent("x.lungfishref").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalBundle.path), "x.lungfishref is not reachable through the link")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path), "the candidate is still in \(folderA.path)")
    }

    // MARK: - Fixtures

    /// A candidate `.x.candidate-<UUID>.lungfishref` in `folder` that holds one file, as a prepared candidate is before
    /// its first publication.
    private func makeCandidate(in folder: URL) throws -> URL {
        let candidate = folder.appendingPathComponent(".x.candidate-\(UUID().uuidString).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Self.payload.write(to: candidate.appendingPathComponent("sentinel"))
        return candidate
    }

    /// `folder` in the spelling `realpath` gives, which is `/private/var/folders/...` for a folder under `/var/folders`.
    /// Foundation's `resolvingSymlinksInPath` and `standardizedFileURL` give the other spelling back.
    private static func privateSpelling(of folder: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = try XCTUnwrap(realpath(folder.path, &buffer), "realpath could not resolve \(folder.path)")
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
