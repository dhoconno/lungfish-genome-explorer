// PipelinePinTests.swift - Guards that pipeline pins are sourced from the dependency manifest
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class PipelinePinTests: XCTestCase {
    func testTaxTriageDefaultsComeFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.pipeline(id: "taxtriage"))
        let pin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        XCTAssertEqual(pin, NextflowPipelinePin(spec), "the descriptor is the one reader of TaxTriage's lock entry (N4)")
        XCTAssertEqual(TaxTriageConfig.githubReleaseVersion(for: spec.revision, pin: pin), spec.releaseVersion)
    }

    func testViralreconPinComesFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.pipeline(id: "nf-core-viralrecon"))
        let entry = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon"))
        XCTAssertEqual(entry.pinnedVersion, spec.revision)
        let pin = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        XCTAssertEqual(pin, NextflowPipelinePin(spec), "the descriptor is the one reader of Viral Recon's lock entry (N4)")
        // Phase 2.10 N2. The lock pins the commit tag 3.0.0 names (a lightweight tag), `-r` takes the commit, and the
        // tag is the release beside it, so upstream moving the tag cannot change what runs. No fallback is left.
        XCTAssertEqual(spec.revision, "395079f1d24dce731ac22e03d7a5e71f110103fc", "the commit of tag 3.0.0")
        XCTAssertEqual(spec.releaseVersion, "3.0.0")
    }
}
