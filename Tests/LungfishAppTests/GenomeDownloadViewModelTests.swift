// GenomeDownloadViewModelTests.swift - Unit tests for GenomeDownloadViewModel
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

/// Unit tests for ``GenomeDownloadViewModel``.
///
/// Tests cover:
/// - Initialization with default and custom dependencies
/// - Tool pre-flight validation
/// - Sendable conformance
/// - BundleBuildError cases
final class GenomeDownloadViewModelTests: XCTestCase {

    // MARK: - Initialization

    func testInitializationCreatesViewModel() {
        let viewModel = GenomeDownloadViewModel()
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithCustomNCBIService() {
        let customService = NCBIService(apiKey: "test-key-123")
        let viewModel = GenomeDownloadViewModel(ncbiService: customService)
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithCustomToolRunner() {
        let toolRunner = NativeToolRunner.shared
        let viewModel = GenomeDownloadViewModel(toolRunner: toolRunner)
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithCustomAnnotationConverter() {
        let converter = AnnotationConverter()
        let viewModel = GenomeDownloadViewModel(annotationConverter: converter)
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithAllCustomDependencies() {
        let ncbiService = NCBIService()
        let toolRunner = NativeToolRunner.shared
        let converter = AnnotationConverter()
        let viewModel = GenomeDownloadViewModel(
            ncbiService: ncbiService,
            toolRunner: toolRunner,
            annotationConverter: converter
        )
        XCTAssertNotNil(viewModel)
    }

    // MARK: - Sendable Conformance

    func testViewModelCanBeSentAcrossIsolationBoundaries() async {
        let viewModel = GenomeDownloadViewModel()

        // If GenomeDownloadViewModel were not Sendable, this would produce a
        // compiler diagnostic under strict concurrency checking.
        let returned = await Task.detached {
            return viewModel
        }.value

        XCTAssertNotNil(returned)
    }

    // MARK: - Tool Pre-flight Validation

    func testValidateToolsDoesNotThrowWhenToolsAvailable() async throws {
        // If tools are present in the build, validation should succeed.
        // This test may fail on machines without tools, which is expected.
        let viewModel = GenomeDownloadViewModel()
        do {
            try await viewModel.validateTools()
        } catch let error as BundleBuildError {
            // Only missingTools is acceptable here
            switch error {
            case .missingTools(let names):
                // Expected on machines without bgzip/samtools
                XCTAssertFalse(names.isEmpty, "Missing tools list should not be empty")
            default:
                XCTFail("Unexpected BundleBuildError: \(error)")
            }
        }
    }

    // MARK: - BundleBuildError Cases

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
}
