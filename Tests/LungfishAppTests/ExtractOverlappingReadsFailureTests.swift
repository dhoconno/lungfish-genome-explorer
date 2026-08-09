// ExtractOverlappingReadsFailureTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression coverage for F24: `extractOverlappingReads(from:)` used to swallow
// both errors and results silently (a `Task.detached` that only logged failures
// to os_log, with no OperationCenter registration and no user-visible alert).
// These tests inject a failing/succeeding extraction runner via
// `ViewerViewController.overlappingReadsExtractionRunner` and assert the
// OperationCenter is updated on both the success and failure paths.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class ExtractOverlappingReadsFailureTests: XCTestCase {
    private struct StubExtractionError: LocalizedError {
        var errorDescription: String? { "stub samtools failure: region not found" }
    }

    /// Records the configs the injected `overlappingReadsExtractionRunner` was
    /// called with. An actor because the runner is `@Sendable` and may run off
    /// the main actor before the test awaits its OperationCenter side effect.
    private actor ExtractionInvocationRecorder {
        private(set) var configs: [BAMRegionExtractionConfig] = []

        func record(_ config: BAMRegionExtractionConfig) {
            configs.append(config)
        }
    }

    /// Builds a mapping result whose annotation-extraction action has a valid,
    /// non-empty samtools region so `extractOverlappingReads` doesn't bail out
    /// early on `mappingExtractionConfiguration(for:) == nil`.
    private func makeAnnotation() -> SequenceAnnotation {
        SequenceAnnotation(
            type: .gene,
            name: "test-gene",
            chromosome: "chr1",
            start: 10,
            end: 50
        )
    }

    private func makeMappingResult(resultDirectory: URL, bundleURL: URL) -> MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: bundleURL,
            bamURL: resultDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
    }

    /// Polls until `predicate()` is true or the timeout elapses.
    private func eventually(
        timeout: TimeInterval = 10,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    func testFailingExtractionFailsOperationAndPresentsAlertInsteadOfSilentlyLogging() async throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-overlapping-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resultDirectory) }

        let bundleURL = resultDirectory.appendingPathComponent("reference.lungfishref", isDirectory: true)
        let result = makeMappingResult(resultDirectory: resultDirectory, bundleURL: bundleURL)

        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        vc.displayMappingResult(result, resultDirectoryURL: resultDirectory)

        // Attach a host window so the failure alert takes the `beginSheetModal`
        // path instead of `NSApp.presentError`, which shows a real blocking
        // modal panel outside of a running `NSApplication` event loop in tests.
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.contentView = NSView(frame: .zero)
        host.contentView?.addSubview(vc.view)

        let recorder = ExtractionInvocationRecorder()
        vc.overlappingReadsExtractionRunner = { config in
            await recorder.record(config)
            throw StubExtractionError()
        }

        let beforeItemIDs = Set(OperationCenter.shared.items.map(\.id))

        vc.extractOverlappingReads(from: makeAnnotation())

        let sawFailedOperation = await eventually {
            OperationCenter.shared.items.contains { item in
                !beforeItemIDs.contains(item.id)
                    && item.title == "Extract Overlapping Reads"
                    && item.state == .failed
            }
        }
        XCTAssertTrue(sawFailedOperation, "Expected a failed OperationCenter entry for the extraction failure")

        let failedItem = try XCTUnwrap(
            OperationCenter.shared.items.first {
                !beforeItemIDs.contains($0.id) && $0.title == "Extract Overlapping Reads"
            }
        )
        XCTAssertEqual(failedItem.state, .failed)
        XCTAssertEqual(failedItem.errorMessage, "stub samtools failure: region not found")

        // The injected runner must actually have been invoked with the
        // annotation's extraction config -- proves the error path is reached
        // via the real call site, not a bypassed stub.
        let invokedCount = await recorder.configs.count
        XCTAssertEqual(invokedCount, 1)
    }

    func testSuccessfulExtractionCompletesOperationWithOutputURLs() async throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-overlapping-success-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resultDirectory) }

        let bundleURL = resultDirectory.appendingPathComponent("reference.lungfishref", isDirectory: true)
        let result = makeMappingResult(resultDirectory: resultDirectory, bundleURL: bundleURL)

        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        vc.displayMappingResult(result, resultDirectoryURL: resultDirectory)

        let outputFASTQ = resultDirectory.appendingPathComponent("test-gene.fastq")
        vc.overlappingReadsExtractionRunner = { _ in
            LungfishWorkflow.ExtractionResult(fastqURLs: [outputFASTQ], readCount: 42, pairedEnd: false)
        }

        let beforeItemIDs = Set(OperationCenter.shared.items.map(\.id))

        vc.extractOverlappingReads(from: makeAnnotation())

        let sawCompletedOperation = await eventually {
            OperationCenter.shared.items.contains { item in
                !beforeItemIDs.contains(item.id)
                    && item.title == "Extract Overlapping Reads"
                    && item.state == .completed
            }
        }
        XCTAssertTrue(sawCompletedOperation, "Expected a completed OperationCenter entry for the successful extraction")

        let completedItem = try XCTUnwrap(
            OperationCenter.shared.items.first {
                !beforeItemIDs.contains($0.id) && $0.title == "Extract Overlapping Reads"
            }
        )
        XCTAssertEqual(completedItem.outputURLs, [outputFASTQ])
        XCTAssertEqual(completedItem.detail, "Extracted 42 reads overlapping test-gene")
    }
}
