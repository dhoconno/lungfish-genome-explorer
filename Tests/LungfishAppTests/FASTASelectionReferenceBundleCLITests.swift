// FASTASelectionReferenceBundleCLITests.swift - Selected FASTA reference bundle routing tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class FASTASelectionReferenceBundleCLITests: XCTestCase {
    func testBuildsExistingExtractContigsBundleArgumentsForOneAndManyRows() {
        let source = URL(fileURLWithPath: "/tmp/savont.fasta")
        let project = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        XCTAssertEqual(
            FASTASelectionReferenceBundleCLI.arguments(
                sourceURL: source,
                sequenceIDs: ["cluster-1"],
                projectURL: project,
                bundleName: "Reviewed clusters"
            ),
            ["extract", "contigs", "--contigs", source.path, "--contig", "cluster-1",
             "--bundle", "--project-root", project.path, "--bundle-name", "Reviewed clusters"]
        )
        XCTAssertEqual(
            FASTASelectionReferenceBundleCLI.arguments(
                sourceURL: source,
                sequenceIDs: ["cluster-2", "cluster-1"],
                projectURL: project,
                bundleName: "Reviewed clusters"
            ).filter { $0 == "--contig" }.count,
            2
        )
    }

    func testReadsBundlePathFromCLIOutput() {
        XCTAssertEqual(
            FASTASelectionReferenceBundleCLI.bundleURL(from: "note\n/tmp/project/Reference Sequences/Reviewed.lungfishref\n")?.path,
            "/tmp/project/Reference Sequences/Reviewed.lungfishref"
        )
        XCTAssertNil(FASTASelectionReferenceBundleCLI.bundleURL(from: "no bundle path"))
    }
}
