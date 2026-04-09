// ClassifierExtractionDialogTests.swift — Functional tests for the unified extraction dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class ClassifierExtractionDialogTests: XCTestCase {

    // MARK: - View model — format + toggle

    func testModel_defaultFormat_isFASTQ() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        XCTAssertEqual(m.format, .fastq)
    }

    func testModel_defaultIncludeUnmappedMates_isFalse() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        XCTAssertFalse(m.includeUnmappedMates)
    }

    func testModel_unmappedMatesToggle_hiddenForKraken2() {
        let m = ClassifierExtractionDialogViewModel(tool: .kraken2, selectionCount: 1, suggestedName: "x")
        XCTAssertFalse(m.showsUnmappedMatesToggle)
    }

    func testModel_unmappedMatesToggle_visibleForBAMTools() {
        for tool in [ClassifierTool.esviritu, .taxtriage, .naomgs, .nvd] {
            let m = ClassifierExtractionDialogViewModel(tool: tool, selectionCount: 1, suggestedName: "x")
            XCTAssertTrue(m.showsUnmappedMatesToggle, "Expected unmapped-mates toggle visible for \(tool.displayName)")
        }
    }

    // MARK: - Clipboard cap

    func testModel_clipboardDisabledOverCap() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.estimatedReadCount = 10_001
        XCTAssertTrue(m.clipboardDisabledDueToCap)
        XCTAssertNotNil(m.clipboardDisabledTooltip)
        XCTAssertFalse(m.clipboardDisabledTooltip?.isEmpty ?? true)
    }

    func testModel_clipboardEnabledAtCap() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.estimatedReadCount = 10_000
        XCTAssertFalse(m.clipboardDisabledDueToCap)
        XCTAssertNil(m.clipboardDisabledTooltip)
    }

    // MARK: - Primary button label

    func testModel_primaryButton_isCreateBundleForBundleDestination() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.destination = .bundle
        XCTAssertEqual(m.primaryButtonTitle, "Create Bundle")
    }

    func testModel_primaryButton_isSaveForFileDestination() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.destination = .file
        XCTAssertEqual(m.primaryButtonTitle, "Save")
    }

    func testModel_primaryButton_isCopyForClipboardDestination() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.destination = .clipboard
        XCTAssertEqual(m.primaryButtonTitle, "Copy")
    }

    func testModel_primaryButton_isShareForShareDestination() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.destination = .share
        XCTAssertEqual(m.primaryButtonTitle, "Share")
    }

    // MARK: - Name field visibility

    func testModel_nameField_visibleForBundleAndFile() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.destination = .bundle
        XCTAssertTrue(m.destination.showsNameField)
        m.destination = .file
        XCTAssertTrue(m.destination.showsNameField)
    }

    func testModel_nameField_hiddenForClipboardAndShare() {
        let m = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "x")
        m.destination = .clipboard
        XCTAssertFalse(m.destination.showsNameField)
        m.destination = .share
        XCTAssertFalse(m.destination.showsNameField)
    }

    // MARK: - Bundle clobber defense (Phase 2 review-2 forwarded item)

    /// Verifies the ISO8601DateFormatter.shortStamp helper used by
    /// resolveDestination's bundle disambiguation suffix produces a stable,
    /// filename-safe format. The orchestrator's resolveDestination is private,
    /// so we exercise the underlying timestamp helper directly.
    func testShortStamp_producesFilenameSafeFormat() {
        let stamp = ISO8601DateFormatter.shortStamp(Date())
        XCTAssertEqual(stamp.count, 15, "Expected yyyyMMdd'T'HHmmss = 15 chars, got '\(stamp)'")
        XCTAssertTrue(stamp.contains("T"), "Stamp should contain literal 'T' separator")
        // Format sanity: all digits except the T separator
        let digits = stamp.replacingOccurrences(of: "T", with: "")
        XCTAssertEqual(digits.count, 14, "Expected 14 digits after stripping 'T'")
        XCTAssertTrue(digits.allSatisfy { $0.isNumber }, "Stamp digits must all be 0-9")
        // No characters that are unsafe in filenames on macOS or POSIX systems.
        let unsafe = CharacterSet(charactersIn: "/:\\?*\"<>|")
        XCTAssertNil(stamp.rangeOfCharacter(from: unsafe), "Stamp must contain no filename-unsafe characters")
    }

    /// Pinned date check: feeding a known instant must produce the expected
    /// UTC string. Catches accidental timezone-localization regressions.
    func testShortStamp_pinnedUTCDate() {
        // 2026-04-09T14:45:21Z
        let comps = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2026, month: 4, day: 9,
            hour: 14, minute: 45, second: 21
        )
        guard let date = comps.date else {
            XCTFail("Failed to construct test date")
            return
        }
        let stamp = ISO8601DateFormatter.shortStamp(date)
        XCTAssertEqual(stamp, "20260409T144521")
    }

    // MARK: - CLI command reconstruction

    func testBuildCLIString_bundle_roundTripsAsByClassifier() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/fake.sqlite"),
            selections: [
                ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001803"], taxIds: [])
            ],
            suggestedName: "my-extract"
        )
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        let dest: ExtractionDestination = .bundle(
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            displayName: "my-extract",
            metadata: ExtractionMetadata(sourceDescription: "x", toolName: "EsViritu")
        )
        let cli = TaxonomyReadExtractionAction.buildCLIString(context: ctx, options: options, destination: dest)
        XCTAssertTrue(cli.contains("--by-classifier"), "missing --by-classifier in: \(cli)")
        XCTAssertTrue(cli.contains("--tool esviritu"), "missing --tool esviritu in: \(cli)")
        XCTAssertTrue(cli.contains("--sample S1"), "missing --sample S1 in: \(cli)")
        XCTAssertTrue(cli.contains("--accession NC_001803"), "missing --accession NC_001803 in: \(cli)")
        XCTAssertTrue(cli.contains("--bundle"), "missing --bundle in: \(cli)")
        XCTAssertTrue(cli.contains("--bundle-name my-extract"), "missing --bundle-name in: \(cli)")
    }

    func testBuildCLIString_kraken2_includesTaxon() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .kraken2,
            resultPath: URL(fileURLWithPath: "/tmp/k2-result"),
            selections: [
                ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [9606, 562])
            ],
            suggestedName: "kr2"
        )
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        let dest: ExtractionDestination = .file(URL(fileURLWithPath: "/tmp/out.fastq"))
        let cli = TaxonomyReadExtractionAction.buildCLIString(context: ctx, options: options, destination: dest)
        XCTAssertTrue(cli.contains("--tool kraken2"), "missing --tool kraken2 in: \(cli)")
        XCTAssertTrue(cli.contains("--taxon 9606"), "missing --taxon 9606 in: \(cli)")
        XCTAssertTrue(cli.contains("--taxon 562"), "missing --taxon 562 in: \(cli)")
        XCTAssertFalse(cli.contains("--include-unmapped-mates"), "unexpected --include-unmapped-mates in: \(cli)")
    }

    /// Phase 3 deviation: classifier extraction emits --read-format (not
    /// --format) so the flag doesn't collide with GlobalOptions.format.
    func testBuildCLIString_formatFasta_flaggedAsReadFormat() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .nvd,
            resultPath: URL(fileURLWithPath: "/tmp/fake"),
            selections: [ClassifierRowSelector(sampleId: nil, accessions: ["c1"], taxIds: [])],
            suggestedName: "fa"
        )
        let options = ExtractionOptions(format: .fasta, includeUnmappedMates: false)
        let dest: ExtractionDestination = .file(URL(fileURLWithPath: "/tmp/o.fasta"))
        let cli = TaxonomyReadExtractionAction.buildCLIString(context: ctx, options: options, destination: dest)
        XCTAssertTrue(cli.contains("--read-format fasta"), "missing --read-format fasta in: \(cli)")
        // Sanity: must NOT emit the colliding --format flag
        XCTAssertFalse(cli.contains(" --format "), "must not emit bare --format (collides with GlobalOptions.format) in: \(cli)")
    }

    /// `--include-unmapped-mates` only when the option is set.
    func testBuildCLIString_includeUnmappedMates_emittedWhenTrue() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/fake.sqlite"),
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_x"], taxIds: [])],
            suggestedName: "u"
        )
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: true)
        let dest: ExtractionDestination = .file(URL(fileURLWithPath: "/tmp/o.fastq"))
        let cli = TaxonomyReadExtractionAction.buildCLIString(context: ctx, options: options, destination: dest)
        XCTAssertTrue(cli.contains("--include-unmapped-mates"), "missing --include-unmapped-mates in: \(cli)")
    }

    /// Clipboard / share destinations are GUI-only and the CLI string should
    /// flag them as not directly executable.
    func testBuildCLIString_clipboardDestination_isAnnotatedAsGUIOnly() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/fake.sqlite"),
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_y"], taxIds: [])],
            suggestedName: "c"
        )
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        let dest: ExtractionDestination = .clipboard(format: .fastq, cap: 10_000)
        let cli = TaxonomyReadExtractionAction.buildCLIString(context: ctx, options: options, destination: dest)
        XCTAssertTrue(cli.contains("clipboard"), "expected clipboard annotation in: \(cli)")
        XCTAssertTrue(cli.contains("GUI only"), "expected GUI-only annotation in: \(cli)")
    }
}
