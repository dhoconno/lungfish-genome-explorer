// ProvenanceCommandToolRootTests.swift - The managed tool root a shown command reads, read once by its caller
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import XCTest
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.45, M875 TOOLROOT-ONCE (UX 5, SWIFT 2 of the 12.25 review). `display` shows a tool under the
/// root its caller passes by the tool's name. The caller reads `PortablePath.defaultManagedRoots` once, off the main
/// actor, and `display` reads no storage configuration of its own, so the default root is nil.
final class ProvenanceCommandToolRootTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/Users/someone/Studies/Commands.lungfish", isDirectory: true)

    /// A command whose first word lies under the root the caller passes shows the tool's name, and its project path
    /// shows relative to the project.
    func testAManagedToolPathShowsByNameWhenTheRootIsReadOnce() {
        let root = URL(fileURLWithPath: "/Volumes/Store/conda", isDirectory: true)
        let command = "/Volumes/Store/conda/envs/samtools/bin/samtools sort -o "
            + "/Users/someone/Studies/Commands.lungfish/Analyses/m/x.bam"

        XCTAssertEqual(
            ProvenanceCommandPresentation.display(command, projectURL: project, fileExists: { _ in true }, toolRoot: root),
            "samtools sort -o Analyses/m/x.bam"
        )
    }

    /// With no root passed, a tool under this Mac's managed tool root shows whole, because `display` no longer reads
    /// the storage configuration at each call. At the base the default read it and showed `samtools`.
    func testTheDefaultShowsAManagedToolPathWhole() {
        let tool = PortablePath.defaultManagedRoots.toolRoot.appendingPathComponent("envs/samtools/bin/samtools").path
        let command = "'\(tool)' --version"

        XCTAssertEqual(
            ProvenanceCommandPresentation.display(command, projectURL: project, fileExists: { _ in true }),
            command
        )
    }
}
