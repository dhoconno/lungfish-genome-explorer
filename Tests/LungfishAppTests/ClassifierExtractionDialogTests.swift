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

    func testDialogSourceUsesSharedHelpInventory() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("import LungfishKit"))
        XCTAssertTrue(source.contains("LungfishHelpContent.classifierExtractionSummary"))
        XCTAssertTrue(source.contains("LungfishHelpContent.classifierExtractionFormat"))
        XCTAssertTrue(source.contains("LungfishHelpContent.classifierExtractionUnmappedMates"))
        XCTAssertTrue(source.contains("LungfishHelpContent.classifierExtractionDestination"))
        XCTAssertTrue(source.contains("LungfishHelpContent.classifierExtractionName"))
        XCTAssertTrue(source.contains("LungfishHelpContent.classifierExtractFASTQ"))
    }

    func testBlastPopoverAvoidsConfirmatoryLanguageAndShowsReviewParameters() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishKit/BlastConfigPopoverView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.localizedCaseInsensitiveContains("independent verification"))
        XCTAssertTrue(source.contains("NCBI BLASTN nt for review"))
        XCTAssertTrue(source.contains("LungfishHelpContent.classifierBlastReadCount"))
        XCTAssertTrue(source.contains("Reads leave the app for NCBI"))
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

    /// Verifies the `ISO8601DateFormatter.shortStamp` helper used by
    /// `resolveDestination`'s bundle disambiguation suffix produces a stable,
    /// filename-safe format: `yyyyMMdd'T'HHmmss-XXXX` (20 chars) where XXXX is
    /// a 4-character random base36 disambiguator.
    func testShortStamp_producesFilenameSafeFormat() {
        let stamp = ISO8601DateFormatter.shortStamp(Date())
        XCTAssertEqual(stamp.count, 20, "Expected yyyyMMdd'T'HHmmss-XXXX = 20 chars, got '\(stamp)'")
        XCTAssertTrue(stamp.contains("T"), "Stamp should contain literal 'T' separator")
        XCTAssertTrue(stamp.contains("-"), "Stamp should contain '-' separating timestamp and random suffix")
        // Split into timestamp and random parts.
        let parts = stamp.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2, "Expected exactly one '-' separator in '\(stamp)'")
        let timestampPart = String(parts[0])
        let randomPart = String(parts[1])
        // Timestamp part: 15 chars, all digits except T separator.
        XCTAssertEqual(timestampPart.count, 15, "Timestamp part should be 15 chars")
        let tDigits = timestampPart.replacingOccurrences(of: "T", with: "")
        XCTAssertEqual(tDigits.count, 14, "Expected 14 digits after stripping 'T'")
        XCTAssertTrue(tDigits.allSatisfy { $0.isNumber }, "Timestamp digits must all be 0-9")
        // Random part: 4 lowercase base36 characters.
        XCTAssertEqual(randomPart.count, 4, "Random suffix must be exactly 4 chars")
        let base36 = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertTrue(
            randomPart.unicodeScalars.allSatisfy { base36.contains($0) },
            "Random suffix '\(randomPart)' must use lowercase base36 alphabet"
        )
        // No characters that are unsafe in filenames on macOS or POSIX systems.
        let unsafe = CharacterSet(charactersIn: "/:\\?*\"<>|")
        XCTAssertNil(stamp.rangeOfCharacter(from: unsafe), "Stamp must contain no filename-unsafe characters")
    }

    /// Pinned date check: feeding a known instant must produce a stamp whose
    /// timestamp prefix matches the expected UTC string. The random suffix
    /// is non-deterministic, so we assert prefix + suffix shape independently.
    /// Catches accidental timezone-localization regressions.
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
        XCTAssertTrue(stamp.hasPrefix("20260409T144521-"), "Stamp must start with pinned UTC prefix, got '\(stamp)'")
        XCTAssertEqual(stamp.count, 20, "Expected 20-char stamp, got '\(stamp)'")
        // Suffix (post '-') must be 4 lowercase alphanumeric chars.
        let suffix = String(stamp.suffix(4))
        let base36 = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertTrue(
            suffix.unicodeScalars.allSatisfy { base36.contains($0) },
            "Pinned-date suffix '\(suffix)' must be base36"
        )
    }

    /// Same-second collision defense (Phase 4 review-1 critical #1): two
    /// calls inside the same wall-clock second MUST produce different suffixes
    /// so back-to-back Create-Bundle clicks don't silently overwrite each
    /// other in `ReadExtractionService.createBundle` (which removes-then-moves
    /// the target directory unconditionally).
    ///
    /// The random suffix is 4 base36 characters (36^4 ≈ 1.7M combinations),
    /// so the probability of collision across 2 rapid calls is ~6e-7. We
    /// run 8 successive pairs and require at least one difference; if every
    /// pair collided the test statistically cannot pass on a non-broken impl.
    func testShortStamp_twoRapidCalls_produceDifferentStrings() {
        var anyDifferent = false
        for _ in 0..<8 {
            let s1 = ISO8601DateFormatter.shortStamp(Date())
            let s2 = ISO8601DateFormatter.shortStamp(Date())
            if s1 != s2 {
                anyDifferent = true
                break
            }
        }
        XCTAssertTrue(anyDifferent, "shortStamp must produce unique output across rapid calls")
    }

    // MARK: - resolveDestination .bundle disambiguation

    /// Bundle destination with the default (suggested) name MUST apply the
    /// timestamp suffix so rapid-fire Create-Bundle clicks don't clobber.
    func testResolveDestination_bundle_withDefaultName_appendsTimestamp() async throws {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/test-extract.sqlite"),
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001"], taxIds: [])],
            suggestedName: "default-name"
        )
        let model = ClassifierExtractionDialogViewModel(
            tool: .esviritu,
            selectionCount: 1,
            suggestedName: "default-name"
        )
        model.destination = .bundle
        // Leave model.name == ctx.suggestedName — should get the suffix.
        let dest = try await TaxonomyReadExtractionAction.shared.resolveDestinationForTesting(
            model: model,
            context: ctx
        )
        guard case .bundle(_, let displayName, _) = dest else {
            XCTFail("Expected .bundle, got \(dest)")
            return
        }
        XCTAssertTrue(displayName.hasPrefix("default-name-"), "Expected suggestedName prefix, got '\(displayName)'")
        XCTAssertTrue(displayName.contains("T"), "Expected timestamp marker 'T' in '\(displayName)'")
        XCTAssertGreaterThan(displayName.count, "default-name".count, "Suffix should lengthen the name")
    }

    /// Bundle destination with a custom name (user-edited) MUST NOT append
    /// the timestamp suffix — we trust the user's chosen name verbatim.
    func testResolveDestination_bundle_withCustomName_doesNotAppendTimestamp() async throws {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/test-extract.sqlite"),
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001"], taxIds: [])],
            suggestedName: "default-name"
        )
        let model = ClassifierExtractionDialogViewModel(
            tool: .esviritu,
            selectionCount: 1,
            suggestedName: "default-name"
        )
        model.destination = .bundle
        model.name = "my-custom-name"  // User customized — should NOT get suffix.
        let dest = try await TaxonomyReadExtractionAction.shared.resolveDestinationForTesting(
            model: model,
            context: ctx
        )
        guard case .bundle(_, let displayName, _) = dest else {
            XCTFail("Expected .bundle, got \(dest)")
            return
        }
        XCTAssertEqual(displayName, "my-custom-name", "Custom name should be used verbatim without any suffix")
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
        // With sampleId: nil, the builder must NOT emit a --sample flag
        // (Phase 4 review-1 test gap).
        XCTAssertFalse(cli.contains(" --sample "), "unexpected --sample when sampleId is nil, in: \(cli)")
    }

    /// Defensive: if a selector arrives with BOTH accessions and taxIds
    /// (not realistic today — BAM tools use accessions, Kraken2 uses taxIds —
    /// but the builder doesn't enforce separation), all three flag groups
    /// must appear in the emitted CLI. Pins the builder behavior against
    /// future selector-construction bugs.
    func testBuildCLIString_mixedAccessionsAndTaxons_emitsAll() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .nvd,
            resultPath: URL(fileURLWithPath: "/tmp/mix"),
            selections: [
                ClassifierRowSelector(sampleId: "S", accessions: ["a1", "a2"], taxIds: [9606])
            ],
            suggestedName: "mix"
        )
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        let dest: ExtractionDestination = .file(URL(fileURLWithPath: "/tmp/o.fastq"))
        let cli = TaxonomyReadExtractionAction.buildCLIString(context: ctx, options: options, destination: dest)
        XCTAssertTrue(cli.contains("--sample S"), "missing --sample S in: \(cli)")
        XCTAssertTrue(cli.contains("--accession a1"), "missing --accession a1 in: \(cli)")
        XCTAssertTrue(cli.contains("--accession a2"), "missing --accession a2 in: \(cli)")
        XCTAssertTrue(cli.contains("--taxon 9606"), "missing --taxon 9606 in: \(cli)")
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

    func testFileProvenanceOptions_useReplayableClassifierCLIArgv() {
        let outputURL = URL(fileURLWithPath: "/tmp/out.fastq")
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .nvd,
            resultPath: URL(fileURLWithPath: "/tmp/nvd-results/fake.sqlite"),
            selections: [
                ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001"], taxIds: [])
            ],
            suggestedName: "nvd-extract"
        )
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: true)
        let recorded = TaxonomyReadExtractionAction.optionsByRecordingFileProvenanceForTesting(
            options,
            context: ctx,
            destination: .file(outputURL)
        )

        let provenance = recorded.fileProvenance
        let argv = provenance?.argv ?? []
        XCTAssertEqual(Array(argv.prefix(4)), ["lungfish-cli", "extract", "reads", "--by-classifier"])
        XCTAssertTrue(argv.contains("--tool"))
        XCTAssertTrue(argv.contains("nvd"))
        XCTAssertTrue(argv.contains("--output"))
        XCTAssertTrue(argv.contains(outputURL.path))
        XCTAssertFalse(argv.contains("Lungfish.app"))
        XCTAssertFalse(argv.contains("--destination"))
        XCTAssertEqual(provenance?.explicitOptions["destination"]?.stringValue, "file")
        XCTAssertEqual(provenance?.explicitOptions["outputPath"]?.fileValue?.path, outputURL.path)
        XCTAssertEqual(provenance?.resolved["samtoolsExcludeFlags"]?.integerValue, 0x400)
    }

    func testFileProvenanceOptions_recordsNaoMgsReadNameAllowlist() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .naomgs,
            resultPath: URL(fileURLWithPath: "/tmp/naomgs/hits.sqlite"),
            selections: [
                ClassifierRowSelector(
                    sampleId: "S1",
                    accessions: ["ACC_1"],
                    taxIds: [123],
                    readNameAllowlist: ["read-B", "read-A"]
                )
            ],
            suggestedName: "naomgs-extract"
        )
        let recorded = TaxonomyReadExtractionAction.optionsByRecordingFileProvenanceForTesting(
            ExtractionOptions(),
            context: ctx,
            destination: .file(URL(fileURLWithPath: "/tmp/naomgs.fastq"))
        )

        let explicit = recorded.fileProvenance?.explicitOptions
        let allowlist = explicit?["readNameAllowlist"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(allowlist, ["read-A", "read-B"])
        XCTAssertEqual(explicit?["readNameAllowlistCount"]?.integerValue, 2)
        XCTAssertEqual(explicit?["readNameAllowlistAppliedBy"]?.stringValue, "samtools view -N")
        XCTAssertEqual(explicit?["readNameAllowlistSHA256"]?.stringValue?.count, 64)
        XCTAssertEqual(
            recorded.fileProvenance?.resolved["readNameAllowlistSHA256"]?.stringValue,
            explicit?["readNameAllowlistSHA256"]?.stringValue
        )
    }

    func testFileProvenanceOptions_leavesBundleAndClipboardUnchanged() {
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/fake.sqlite"),
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_y"], taxIds: [])],
            suggestedName: "c"
        )
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        let bundle = TaxonomyReadExtractionAction.optionsByRecordingFileProvenanceForTesting(
            options,
            context: ctx,
            destination: .bundle(
                projectRoot: URL(fileURLWithPath: "/tmp/project"),
                displayName: "extract",
                metadata: ExtractionMetadata(sourceDescription: "x", toolName: "EsViritu")
            )
        )
        let clipboard = TaxonomyReadExtractionAction.optionsByRecordingFileProvenanceForTesting(
            options,
            context: ctx,
            destination: .clipboard(format: .fastq, cap: 10_000)
        )

        XCTAssertNil(bundle.fileProvenance)
        XCTAssertNil(clipboard.fileProvenance)
    }

    // MARK: - TaskBox cancel contract (Phase 4 review-2 critical #1)

    /// Pins the two-task-cancel contract that underpins the dialog's Cancel
    /// button. The `TaskBox` must be able to hold both the pre-flight estimate
    /// task AND the in-flight extraction task, and cancelling one must not
    /// affect the other being cancelled independently. Both tasks must honor
    /// cancellation so the dialog's `onCancel` closure can tear down whichever
    /// is currently running (estimate before Create Bundle, extraction after).
    ///
    /// This test exercises the building block the critical #1 fix depends on;
    /// the full integration path through `present()` + `startExtraction()` is
    /// gated on a real `NSWindow` and `ClassifierReadResolver` so is not
    /// directly unit-testable today. See review-2 disposition.
    func testTaskBox_cancelBothTasks_cancelsSeparately() async {
        let box = TaxonomyReadExtractionAction.TaskBox()

        // Sentinel flags captured by the detached task bodies.
        actor Sentinel {
            var cancelled: Bool = false
            func mark() { cancelled = true }
        }
        let s1 = Sentinel()
        let s2 = Sentinel()

        box.estimateTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            await s1.mark()
        }
        box.extractionTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            await s2.mark()
        }

        // Simulate the dialog's onCancel closure: cancel both handles.
        box.estimateTask?.cancel()
        box.extractionTask?.cancel()

        // Wait for both bodies to observe the cancel and mark their sentinels.
        await box.estimateTask?.value
        await box.extractionTask?.value

        let c1 = await s1.cancelled
        let c2 = await s2.cancelled
        XCTAssertTrue(c1, "estimateTask should have been cancelled")
        XCTAssertTrue(c2, "extractionTask should have been cancelled")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
