// MetagenomicsWizardMultiBundlePickerSourceTests.swift - Multi-bundle picker
// retrofit for Kraken2/EsViritu wizards (round-2 backlog item 6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task background: ClassificationWizardSheet (Kraken2) and EsVirituWizardSheet
// already batch per-sample correctly via MetagenomicsSampleGrouper -- each
// selected FASTQ bundle becomes its own sample, and one classifier run is
// executed per sample (visible today via each sheet's "Batch Samples"
// section). They were documented exceptions in the original campaign
// (already N-bundle-aware) rather than adopting the shared
// MultiBundleRunModePicker component the other multi-bundle-aware wizards
// (MAFFT, Savont/pbaa, ONT genotyping -- see FASTQOperationToolPanesSourceTests)
// use. This retrofit adds the shared picker in PER-BUNDLE-LOCKED state so
// the multi-bundle UX reads consistently across every wizard, following the
// honest-copy precedent from the C6/commit 7a5041c6 review fix (the
// lockReason must describe what execution ACTUALLY does, not what a future
// state might do). Display-only: execution (MetagenomicsSampleGrouper-driven
// one-run-per-sample fan-out) is untouched by this change.
//
// Mirrors the source-scanning test idiom established by
// FASTQOperationToolPanesSourceTests (testMAFFTPaneRendersCombineLockedMultiBundleRunModePicker
// et al.) rather than rendering SwiftUI views directly.

import XCTest

final class MetagenomicsWizardMultiBundlePickerSourceTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var classificationWizardSource: String {
        get throws { try source("Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift") }
    }

    private var esVirituWizardSource: String {
        get throws { try source("Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift") }
    }

    // MARK: - ClassificationWizardSheet (Kraken2)

    func testClassificationWizardRendersPerBundleLockedMultiBundleRunModePicker() throws {
        let src = try classificationWizardSource

        XCTAssertTrue(src.contains("import LungfishKit"))
        XCTAssertTrue(src.contains("classificationMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(src.contains("allowedModes: [.perBundle]"))
        XCTAssertTrue(src.contains("defaultMode: .perBundle"))
        XCTAssertTrue(src.contains("MultiBundleRunModePicker("))
        XCTAssertTrue(src.contains("bundleCount: groupedSamples.count"))
        XCTAssertTrue(src.contains("policy: Self.classificationMultiBundleRunPolicy"))
    }

    /// The lockReason must describe the real per-sample batch behavior
    /// (MetagenomicsSampleGrouper fans out one Kraken2/Bracken run per
    /// sample already), not an aspirational combined-run mode that doesn't
    /// exist for this tool. Mirrors the honest-copy standard set by the
    /// C6/commit 7a5041c6 review fix for ONT genotyping.
    func testClassificationWizardLockReasonDescribesExistingPerSampleBatchBehavior() throws {
        let src = try classificationWizardSource

        XCTAssertTrue(src.contains("lockReason:"))
        // Must mention that each sample already gets its own run -- the
        // real, current execution semantics -- not "will run as one batch"
        // (which would be a combined-mode claim this tool doesn't support).
        XCTAssertTrue(
            src.contains("one Kraken2") || src.contains("per sample") || src.contains("each sample"),
            "lockReason copy must describe the existing per-sample batch behavior; source: \(src)"
        )
    }

    /// Execution must remain untouched: performRun still maps groupedSamples
    /// 1:1 to ClassificationConfig entries via MetagenomicsSampleGrouper,
    /// with no new run-mode branching introduced by this display-only change.
    func testClassificationWizardExecutionPathUnchangedBySamplesMap() throws {
        let src = try classificationWizardSource

        XCTAssertTrue(src.contains("let samples = groupedSamples"))
        XCTAssertTrue(src.contains("let configs = samples.map { sample in"))
    }

    // MARK: - EsVirituWizardSheet

    func testEsVirituWizardRendersPerBundleLockedMultiBundleRunModePicker() throws {
        let src = try esVirituWizardSource

        XCTAssertTrue(src.contains("import LungfishKit"))
        XCTAssertTrue(src.contains("esVirituMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(src.contains("allowedModes: [.perBundle]"))
        XCTAssertTrue(src.contains("defaultMode: .perBundle"))
        XCTAssertTrue(src.contains("MultiBundleRunModePicker("))
        XCTAssertTrue(src.contains("bundleCount: groupedSamples.count"))
        XCTAssertTrue(src.contains("policy: Self.esVirituMultiBundleRunPolicy"))
    }

    func testEsVirituWizardLockReasonDescribesExistingPerSampleBatchBehavior() throws {
        let src = try esVirituWizardSource

        XCTAssertTrue(src.contains("lockReason:"))
        XCTAssertTrue(
            src.contains("one EsViritu") || src.contains("per sample") || src.contains("each sample"),
            "lockReason copy must describe the existing per-sample batch behavior; source: \(src)"
        )
    }

    func testEsVirituWizardExecutionPathUnchangedBySamplesMap() throws {
        let src = try esVirituWizardSource

        XCTAssertTrue(src.contains("let samples = groupedSamples"))
        XCTAssertTrue(src.contains("let configs = samples.map { sample in"))
    }
}
