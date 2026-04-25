// PrimerTrimThenIVarTests.swift - End-to-end primer-trim + iVar auto-confirm chain
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp
@testable import LungfishWorkflow

/// Walks the full chain: run `BAMPrimerTrimPipeline`, wrap the trimmed BAM
/// (alongside the provenance sidecar the pipeline wrote next to it) into a
/// ReferenceBundle, and confirm the variant-calling dialog state auto-confirms
/// the iVar primer-trim attestation without requiring the user to check the box.
///
/// Skips when ivar/samtools are not installed at ~/.lungfish/conda.
@MainActor
final class PrimerTrimThenIVarTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerTrimThenIVarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPrimerTrimThenIVarCallsVariantsWithoutAttestationWarning() async throws {
        let sourceBAMURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PrimerTrim/
            .deletingLastPathComponent()  // LungfishIntegrationTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")

        guard FileManager.default.fileExists(atPath: sourceBAMURL.path) else {
            throw XCTSkip("sarscov2 test BAM fixture missing at \(sourceBAMURL.path)")
        }

        let schemeBundleURL = TestFixtures.mt192765Integration.bundleURL
        let scheme = try PrimerSchemeBundle.load(from: schemeBundleURL)

        // Bundle layout: tempDir/bundle/alignments/trimmed.bam + .bai + .primer-trim-provenance.json.
        let bundleURL = tempDir.appendingPathComponent("project.lungfishref", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        let trimmedBAM = alignmentsDir.appendingPathComponent("trimmed.bam")

        let runner = NativeToolRunner()
        let request = BAMPrimerTrimRequest(
            sourceBAMURL: sourceBAMURL,
            primerSchemeBundle: scheme,
            outputBAMURL: trimmedBAM
        )

        let result: BAMPrimerTrimResult
        do {
            result = try await BAMPrimerTrimPipeline.run(
                request,
                targetReferenceName: "MT192765.1",
                runner: runner
            )
        } catch let err as NativeToolError {
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                throw XCTSkip("ivar/samtools not installed in ~/.lungfish; skipping integration test. \(err)")
            default:
                throw err
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputBAMURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path),
                      "Pipeline must drop the sidecar next to the trimmed BAM so auto-confirm finds it.")

        // Build a reference bundle around the trimmed BAM. sourcePath is bundle-relative.
        let manifest = BundleManifest(
            name: "Integration Bundle",
            identifier: "bundle.test.\(UUID().uuidString)",
            source: SourceInfo(organism: "Virus", assembly: "Test", database: "Test"),
            alignments: [
                AlignmentTrackInfo(
                    id: "trimmed-aln",
                    name: "Primer-trimmed Alignment",
                    format: .bam,
                    sourcePath: "alignments/trimmed.bam",
                    indexPath: "alignments/trimmed.bam.bai"
                )
            ]
        )
        let bundle = ReferenceBundle(url: bundleURL, manifest: manifest)

        let state = BAMVariantCallingDialogState(bundle: bundle, sidebarItems: [])

        XCTAssertNotNil(state.autoConfirmedPrimerTrim,
                        "The pipeline's sidecar must drive the dialog state's auto-confirm.")
        XCTAssertEqual(state.autoConfirmedPrimerTrim?.primerScheme.bundleName, "mt192765-integration")
        XCTAssertTrue(state.ivarPrimerTrimConfirmed)

        state.selectCaller(.ivar)
        XCTAssertTrue(state.readinessText.contains("Primer-trimmed by Lungfish"),
                      "Readiness text should announce the Lungfish-run trim, got: \(state.readinessText)")
    }
}
