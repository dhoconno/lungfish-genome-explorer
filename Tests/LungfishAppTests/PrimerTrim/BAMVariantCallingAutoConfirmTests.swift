// BAMVariantCallingAutoConfirmTests.swift - iVar checkbox auto-confirms when BAM has Lungfish trim provenance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class BAMVariantCallingAutoConfirmTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMVariantCallingAutoConfirmTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testIvarCheckboxAutoConfirmsWhenSidecarIndicatesLungfishTrim() throws {
        let bundle = try makeBundleWithPrimerTrimSidecar(schemeName: "QIASeqDIRECT-SARS2")
        let state = BAMVariantCallingDialogState(bundle: bundle, sidebarItems: [])

        XCTAssertNotNil(state.autoConfirmedPrimerTrim, "expected sidecar to be discovered")
        XCTAssertEqual(state.autoConfirmedPrimerTrim?.primerScheme.bundleName, "QIASeqDIRECT-SARS2")
        XCTAssertTrue(state.ivarPrimerTrimConfirmed, "checkbox should auto-confirm when sidecar present")

        state.selectCaller(.ivar)
        XCTAssertTrue(state.readinessText.contains("Primer-trimmed by Lungfish"),
                      "readiness text should reference the auto-confirmed trim, got: \(state.readinessText)")
        XCTAssertTrue(state.readinessText.contains("QIASeqDIRECT-SARS2"))
    }

    @MainActor
    func testIvarCheckboxIsUserAttestedForBAMsWithoutSidecar() throws {
        let bundle = try makeBundleWithoutSidecar()
        let state = BAMVariantCallingDialogState(bundle: bundle, sidebarItems: [])

        XCTAssertNil(state.autoConfirmedPrimerTrim)
        XCTAssertFalse(state.ivarPrimerTrimConfirmed, "user must attest manually when no sidecar present")

        state.selectCaller(.ivar)
        XCTAssertTrue(state.readinessText.contains("Confirm the BAM was primer-trimmed"),
                      "expected user-attestation prompt, got: \(state.readinessText)")
    }

    @MainActor
    func testSidecarWithWrongOperationIsRejected() throws {
        // A JSON file with operation != "primer-trim" must not auto-confirm,
        // since the sidecar contract is operation-scoped.
        let bundle = try makeBundleWithPrimerTrimSidecar(
            schemeName: "QIASeqDIRECT-SARS2",
            operationOverride: "mark-duplicates"
        )
        let state = BAMVariantCallingDialogState(bundle: bundle, sidebarItems: [])

        XCTAssertNil(state.autoConfirmedPrimerTrim)
        XCTAssertFalse(state.ivarPrimerTrimConfirmed)
    }

    @MainActor
    func testCorruptSidecarIsTreatedAsAbsent() throws {
        let bundle = try makeBundleWithSidecarFile(content: Data("{not-json".utf8))
        let state = BAMVariantCallingDialogState(bundle: bundle, sidebarItems: [])

        XCTAssertNil(state.autoConfirmedPrimerTrim)
        XCTAssertFalse(state.ivarPrimerTrimConfirmed)
    }

    // MARK: - Test bundle builders

    private func makeBundleWithPrimerTrimSidecar(
        schemeName: String,
        operationOverride: String = "primer-trim"
    ) throws -> ReferenceBundle {
        let provenance = BAMPrimerTrimProvenance(
            operation: operationOverride,
            primerScheme: .init(
                bundleName: schemeName,
                bundleSource: "built-in",
                bundleVersion: "1.0.0",
                canonicalAccession: "MN908947.3"
            ),
            sourceBAMRelativePath: "alignments/sample.sorted.bam",
            ivarVersion: "1.4.2",
            ivarTrimArgs: ["trim", "-b", "primers.bed"],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(provenance)
        return try makeBundleWithSidecarFile(content: data)
    }

    private func makeBundleWithoutSidecar() throws -> ReferenceBundle {
        return try makeBundle(includeSidecar: nil)
    }

    private func makeBundleWithSidecarFile(content: Data) throws -> ReferenceBundle {
        return try makeBundle(includeSidecar: content)
    }

    private func makeBundle(includeSidecar sidecar: Data?) throws -> ReferenceBundle {
        let bundleURL = tempDir.appendingPathComponent("Bundle-\(UUID().uuidString).lungfishref", isDirectory: true)
        let sourcePath = "alignments/sample.sorted.bam"
        let indexPath = "\(sourcePath).bai"
        let sourceURL = bundleURL.appendingPathComponent(sourcePath)
        let indexURL = bundleURL.appendingPathComponent(indexPath)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: Data("BAM-bytes".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: indexURL.path, contents: Data("BAI-bytes".utf8)))

        if let sidecar {
            // Sidecar lives at `<bam-sans-ext>.primer-trim-provenance.json`, matching
            // what BAMPrimerTrimPipeline writes next to the trimmed BAM.
            let sidecarURL = sourceURL
                .deletingPathExtension()
                .appendingPathExtension("primer-trim-provenance.json")
            try sidecar.write(to: sidecarURL)
        }

        let manifest = BundleManifest(
            name: "Bundle",
            identifier: "bundle.test.\(UUID().uuidString)",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample 1",
                    format: .bam,
                    sourcePath: sourcePath,
                    indexPath: indexPath
                )
            ]
        )

        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }
}
