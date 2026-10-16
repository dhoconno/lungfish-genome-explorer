// DatabaseBrowserNoProjectDownloadPinTests.swift - Where a Database Browser download with no project landed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A60 M1 (plan row K2, decision C2). At base 4586560ed a download from the Database
// Browser with no project began its row, ran and recorded no command, for the genome, GenBank,
// virus, Pathoplexus and SRA rows alike. A genome row took the in-process route whatever the hidden
// key held and made its batch folder in the system scratch folder, and the import copied each bundle
// into the user's `Downloads/Lungfish Downloads` folder (AppDelegate+Classification.swift), which the
// row never named. Lane A60 M2 refuses such a download before any row
// (DatabaseBrowserNoProjectDownloadRefusalTests), which replaced the two pins of the row.
//
// The two pins left hold the in-process route the hidden keys still reach. Its batch folder with no
// project is in the system scratch folder, and the import never keeps a bundle from there in place.
// No test here writes into the user's Downloads folder.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishTestSupport

@MainActor
final class DatabaseBrowserNoProjectDownloadPinTests: XCTestCase {
    /// One kind of browser row, with what a person downloads through it.
    struct Kind {
        let name: String
        let source: DatabaseSource
        let searchType: NCBISearchType
        let accession: String
        let organism: String?
        /// The noun the No Project Open refusal names.
        let thing: String
    }

    static let kinds: [Kind] = [
        Kind(name: "genome", source: .ncbi, searchType: .genome, accession: "GCF_003047895.1", organism: nil,
             thing: "genome assemblies"),
        Kind(name: "GenBank", source: .ncbi, searchType: .nucleotide, accession: "MN908947.3", organism: nil,
             thing: "GenBank records"),
        Kind(name: "virus", source: .ncbi, searchType: .virus, accession: "NC_045512.2", organism: nil,
             thing: "virus records"),
        Kind(name: "Pathoplexus", source: .pathoplexus, searchType: .nucleotide, accession: "PP_0012345", organism: "mpox",
             thing: "Pathoplexus records"),
        Kind(name: "SRA", source: .ena, searchType: .nucleotide, accession: "SRR11140748", organism: nil,
             thing: "SRA runs"),
    ]

    /// No route context, and the context a main window with no project gives the browser
    /// (`currentOperationRouteContext`), which names the window and no project.
    static let noProjectContexts: [OperationRouteContext?] = [
        nil,
        OperationRouteContext(projectURL: nil, windowStateScopeID: UUID()),
    ]

    func testTheBatchFolderOfARowWithNoProjectIsInTheSystemScratchFolder() throws {
        let folder = try BatchDownloadFolder(projectURL: nil).url()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(
            folder.deletingLastPathComponent().standardizedFileURL.path,
            ProjectTempDirectory.systemTemporaryDirectory().standardizedFileURL.path)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("batch-"), folder.lastPathComponent)
    }

    func testTheImportCopiesABundleFromTheScratchFolderInsteadOfKeepingIt() {
        // With no project and no working folder the import copies the bundle into the user's
        // Downloads/Lungfish Downloads folder and removes the one it was given, so the row's
        // bundle URL named a removed path. No test writes into the user's Downloads folder, so
        // this pins the rule that sends it there.
        let bundle = ProjectTempDirectory.systemTemporaryDirectory()
            .appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("GCF_960000001.1.lungfishref", isDirectory: true)
        XCTAssertFalse(DownloadImportRouting.shouldPreserveInPlace(
            downloadedURL: bundle, projectURL: nil, workingDirectoryURL: nil))
    }

    // MARK: - Helpers

    static func batchFolders(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { $0.hasPrefix("batch-") })
    }
}

/// An NCBI client that refuses every request and records the URL it was asked for.
actor RefusingNCBIClient: HTTPClient {
    private(set) var requestedURLs: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestedURLs.append(request.url?.absoluteString ?? "")
        throw URLError(.cannotConnectToHost)
    }
}
