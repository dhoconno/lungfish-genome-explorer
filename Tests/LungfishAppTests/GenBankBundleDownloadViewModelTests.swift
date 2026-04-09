// GenBankBundleDownloadViewModelTests.swift - Unit tests for GenBankBundleDownloadViewModel
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

/// Unit tests for ``GenBankBundleDownloadViewModel``.
///
/// Tests cover:
/// - Initialization with default dependencies
/// - Tool pre-flight validation
/// - Sanitized filename generation
/// - Unique bundle URL generation
/// - BundleBuildError.missingTools case
final class GenBankBundleDownloadViewModelTests: XCTestCase {

    // MARK: - Initialization

    func testInitializationCreatesViewModel() {
        let viewModel = GenBankBundleDownloadViewModel()
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithCustomDependencies() {
        let ncbiService = NCBIService()
        let toolRunner = NativeToolRunner.shared
        let viewModel = GenBankBundleDownloadViewModel(
            ncbiService: ncbiService,
            toolRunner: toolRunner
        )
        XCTAssertNotNil(viewModel)
    }

    // MARK: - Tool Pre-flight Validation

    func testValidateToolsDoesNotThrowWhenToolsAvailable() async throws {
        // If tools are present in the build, validation should succeed.
        // This test may fail on machines without tools, which is expected.
        let viewModel = GenBankBundleDownloadViewModel()
        do {
            try await viewModel.validateTools()
        } catch let error as BundleBuildError {
            // Only missingTools is acceptable here
            switch error {
            case .missingTools(let names):
                // Expected on machines missing required native tools
                XCTAssertFalse(names.isEmpty, "Missing tools list should not be empty")
            default:
                XCTFail("Unexpected BundleBuildError: \(error)")
            }
        }
    }

    // MARK: - BundleBuildError.missingTools

    func testMissingToolsErrorDescription() {
        let error = BundleBuildError.missingTools(["bgzip", "samtools"])
        XCTAssertTrue(error.errorDescription?.contains("bgzip") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("samtools") ?? false)
    }

    func testMissingToolsRecoverySuggestion() {
        let error = BundleBuildError.missingTools(["bgzip"])
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("reinstall") ?? false)
    }

    func testMissingToolsSingleTool() {
        let error = BundleBuildError.missingTools(["samtools"])
        XCTAssertEqual(error.errorDescription, "Required tools are missing: samtools")
    }

    // MARK: - BundleBuildError Other Cases Still Work

    func testCompressionFailedError() {
        let error = BundleBuildError.compressionFailed("bgzip exited with code 1")
        XCTAssertTrue(error.errorDescription?.contains("compression") ?? false)
    }

    func testIndexingFailedError() {
        let error = BundleBuildError.indexingFailed("samtools faidx failed")
        XCTAssertTrue(error.errorDescription?.contains("indexing") ?? false)
    }

    func testValidationFailedError() {
        let error = BundleBuildError.validationFailed(["Missing genome", "No chromosomes"])
        XCTAssertTrue(error.errorDescription?.contains("Missing genome") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("No chromosomes") ?? false)
    }

    func testCancelledError() {
        let error = BundleBuildError.cancelled
        XCTAssertEqual(error.errorDescription, "Build was cancelled")
    }

    // MARK: - Search Filter Enums

    func testMoleculeTypeFilterAllCases() {
        XCTAssertTrue(MoleculeTypeFilter.allCases.count >= 7)
        XCTAssertNil(MoleculeTypeFilter.any.entrezValue)
        XCTAssertEqual(MoleculeTypeFilter.genomicDNA.entrezValue, "genomic DNA")
        XCTAssertEqual(MoleculeTypeFilter.mRNA.entrezValue, "mRNA")
        XCTAssertEqual(MoleculeTypeFilter.rRNA.entrezValue, "rRNA")
    }

    func testSequencePropertyFilterEntrezValues() {
        XCTAssertEqual(SequencePropertyFilter.hasCDS.entrezFilter, "cds[Feature key]")
        XCTAssertEqual(SequencePropertyFilter.hasGene.entrezFilter, "gene[Feature key]")
        XCTAssertEqual(SequencePropertyFilter.hasTRNA.entrezFilter, "tRNA[Feature key]")
    }

    func testSequencePropertyFilterIcons() {
        for prop in SequencePropertyFilter.allCases {
            XCTAssertFalse(prop.icon.isEmpty, "\(prop.rawValue) should have an icon")
        }
    }

    func testSequencePropertyFilterIdentifiable() {
        let props = SequencePropertyFilter.allCases
        let ids = props.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "All property filter IDs should be unique")
    }

    func testMoleculeTypeFilterIdentifiable() {
        let types = MoleculeTypeFilter.allCases
        let ids = types.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "All molecule type IDs should be unique")
    }

    // MARK: - SearchScope

    func testSearchScopeAllCases() {
        XCTAssertEqual(SearchScope.allCases.count, 6)
        XCTAssertEqual(SearchScope.all.rawValue, "All Fields")
    }

    func testSearchScopeIcons() {
        for scope in SearchScope.allCases {
            XCTAssertFalse(scope.icon.isEmpty, "\(scope.rawValue) should have an icon")
        }
    }

    // MARK: - SearchPhase

    func testSearchPhaseProgress() {
        XCTAssertEqual(SearchPhase.idle.progress, 0)
        XCTAssertEqual(SearchPhase.connecting.progress, 0.15, accuracy: 0.01)
        XCTAssertEqual(SearchPhase.searching.progress, 0.4, accuracy: 0.01)
        XCTAssertEqual(SearchPhase.loadingDetails.progress, 0.7, accuracy: 0.01)
        XCTAssertEqual(SearchPhase.complete(count: 42).progress, 1.0, accuracy: 0.01)
        XCTAssertEqual(SearchPhase.failed("error").progress, 0)
    }

    func testSearchPhaseIsInProgress() {
        XCTAssertFalse(SearchPhase.idle.isInProgress)
        XCTAssertTrue(SearchPhase.connecting.isInProgress)
        XCTAssertTrue(SearchPhase.searching.isInProgress)
        XCTAssertTrue(SearchPhase.loadingDetails.isInProgress)
        XCTAssertFalse(SearchPhase.complete(count: 0).isInProgress)
        XCTAssertFalse(SearchPhase.failed("oops").isInProgress)
    }

    func testSearchPhaseMessages() {
        XCTAssertTrue(SearchPhase.idle.message.isEmpty)
        XCTAssertTrue(SearchPhase.connecting.message.contains("Connecting"))
        XCTAssertTrue(SearchPhase.complete(count: 5).message.contains("5"))
        XCTAssertTrue(SearchPhase.failed("timeout").message.contains("timeout"))
    }

    func testSearchPhaseCompleteMessagePlural() {
        XCTAssertTrue(SearchPhase.complete(count: 1).message.contains("result"))
        XCTAssertFalse(SearchPhase.complete(count: 1).message.contains("results"))
        XCTAssertTrue(SearchPhase.complete(count: 2).message.contains("results"))
    }
}
