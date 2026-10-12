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
        // N4 amended (5 to 0). Viral Recon keeps its fallback until it moves onto the descriptor in 2.10.
        XCTAssertEqual(spec.revision, "3.0.0", "NFCoreSupportedWorkflowCatalog.swift:148 falls back to 3.0.0 until Viral Recon moves onto the descriptor, so change both together")
    }
}
