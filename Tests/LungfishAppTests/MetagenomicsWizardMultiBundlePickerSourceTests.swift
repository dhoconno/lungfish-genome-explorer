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

    /// The lockReason must describe the real batch behavior honestly at
    /// BOTH levels: runClassificationBatch (AppDelegate+Classification.swift)
    /// registers exactly ONE OperationCenter entry for N>1 samples and
    /// writes one merged classification-batch-summary.tsv, while internally
    /// still running one Kraken2/Bracken pass per sample
    /// (MetagenomicsSampleGrouper fan-out). Saying only "each sample gets
    /// its own run" hides the batch-level truth (one operations entry, one
    /// merged summary); saying only "one batch" would hide the per-sample
    /// truth. Mirrors the honest-copy standard set by the C6/commit
    /// 7a5041c6 review fix for ONT genotyping.
    func testClassificationWizardLockReasonDescribesExistingPerSampleBatchBehavior() throws {
        let src = try classificationWizardSource

        XCTAssertTrue(src.contains("lockReason:"))
        // Must mention both halves of the real behavior: one batch
        // operation with a merged summary, AND per-sample classification
        // within it.
        XCTAssertTrue(
            src.contains("one classification batch"),
            "lockReason copy must describe the single batch operation; source: \(src)"
        )
        XCTAssertTrue(
            src.contains("merged summary"),
            "lockReason copy must mention the merged batch summary; source: \(src)"
        )
        XCTAssertTrue(
            src.contains("classified separately within the batch"),
            "lockReason copy must describe the per-sample classification inside the batch; source: \(src)"
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

    /// Mirrors testClassificationWizardLockReasonDescribesExistingPerSampleBatchBehavior:
    /// runEsVirituBatch also registers exactly ONE OperationCenter entry for
    /// N>1 samples and writes one merged esviritu-batch-summary.tsv, while
    /// running one EsViritu pass per sample internally.
    func testEsVirituWizardLockReasonDescribesExistingPerSampleBatchBehavior() throws {
        let src = try esVirituWizardSource

        XCTAssertTrue(src.contains("lockReason:"))
        XCTAssertTrue(
            src.contains("one classification batch"),
            "lockReason copy must describe the single batch operation; source: \(src)"
        )
        XCTAssertTrue(
            src.contains("merged summary"),
            "lockReason copy must mention the merged batch summary; source: \(src)"
        )
        XCTAssertTrue(
            src.contains("classified separately within the batch"),
            "lockReason copy must describe the per-sample classification inside the batch; source: \(src)"
        )
    }

    func testEsVirituWizardExecutionPathUnchangedBySamplesMap() throws {
        let src = try esVirituWizardSource

        XCTAssertTrue(src.contains("let samples = groupedSamples"))
        XCTAssertTrue(src.contains("let configs = samples.map { sample in"))
    }
}
