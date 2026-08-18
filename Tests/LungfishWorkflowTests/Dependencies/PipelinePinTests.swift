// PipelinePinTests.swift - Guards that pipeline pins are sourced from the dependency manifest
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class PipelinePinTests: XCTestCase {
    func testTaxTriageDefaultsComeFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.pipeline(id: "taxtriage"))
        XCTAssertEqual(TaxTriageConfig.defaultRevision, spec.revision)
        XCTAssertEqual(TaxTriageConfig.defaultGithubReleaseVersion, spec.releaseVersion)
        XCTAssertEqual(TaxTriageConfig.pipelineRepository, spec.repository)
        XCTAssertEqual(TaxTriageConfig.githubReleaseVersion(for: spec.revision), spec.releaseVersion)
    }

    func testViralreconPinComesFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.pipeline(id: "nf-core-viralrecon"))
        let entry = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon"))
        XCTAssertEqual(entry.pinnedVersion, spec.revision)
    }
}
