// ReadsToVariantsEndToEndTests.swift — Phase 12 end-to-end regression net.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Exercises the post-mapping reads-to-variants pipeline against the small
// `sarscov2` fixture (~200 read pairs, MT192765.1 reference) to act as the
// regression net for the new TSV-to-VCF converter, GFF passthrough, and
// `bam adopt-mapping` work shipped in Phases 1–11.
//
// Adaptations from the planned spec:
//
//   * `BundleCreator.createBundle(...)` and `ReadMapper.map(...)` are not
//     part of the public API. We invoke `BundleCreateSubcommand` via
//     `parse(_:)` for the bundle step.
//   * `lungfish map` ultimately calls `ManagedMappingPipeline`, which calls
//     `CondaManager.ensureMicromamba()`. That helper requires the bundled
//     `Tools/micromamba` binary to be reachable through
//     `RuntimeResourceLocator`. When `swift test` runs, `Bundle.main` points
//     at Xcode's `swiftpm-testing-helper` (inside `/Applications/Xcode.app`),
//     which trips `isInsideAppBundle` and disables the source-tree fallback,
//     so the bundled micromamba is invisible. Rather than drag in that whole
//     bootstrap pipeline (it has its own coverage in mapping tests), we
//     stage the pre-aligned `test.paired_end.sorted.bam` fixture as a
//     mapping-result directory and exercise the `bam adopt-mapping` →
//     primer-trim → variants call path that *is* the regression net.
//   * The small `sarscov2` fixture is anchored to MT192765.1, so we use the
//     `mt192765-integration` primer scheme (which targets MT192765.1) rather
//     than the QIASeqDIRECT-SARS2 scheme (which targets MN908947.3).
//   * The test is gated by `LUNGFISH_LIVE_PIPELINE_TESTS=1` because it
//     requires the managed conda envs (samtools, ivar, lofreq, bcftools,
//     tabix, bgzip) provisioned at `~/.lungfish/conda/envs`. This matches
//     the gating pattern used by `IVarConverterViralReconParityTests`.

import Testing
import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

@Suite("ReadsToVariantsEndToEnd")
struct ReadsToVariantsEndToEndTests {

    @Test("full reads-to-variants pipeline produces both iVar and LoFreq VCFs")
    func fullPipeline() async throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_LIVE_PIPELINE_TESTS"] == "1" else {
            // Opt-in only; this test runs real bioinformatics tools and takes
            // 30s–2min. Set LUNGFISH_LIVE_PIPELINE_TESTS=1 to enable.
            return
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reads-to-variants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Bundle from fixture reference. The CreateSubcommand lays the
        //    bundle down at `<outputDir>/<name>.lungfishref`.
        let fixtureRef = TestFixtures.sarscov2.reference
        let bundleName = "MT192765.1"
        let create = try BundleCreateSubcommand.parse([
            "--fasta", fixtureRef.path,
            "--name", bundleName,
            "--output-dir", scratch.path
        ])
        try await create.run()
        let bundleURL = scratch.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))

        // 2. Stage the pre-aligned fixture BAM as a mapping-result directory.
        //    See the file header for why we don't shell out to `lungfish map`
        //    inside the swift test runner.
        let mappingDir = scratch.appendingPathComponent("mapping", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestFixtures.sarscov2.sortedBam,
            to: mappingDir.appendingPathComponent("sorted.bam")
        )
        try FileManager.default.copyItem(
            at: TestFixtures.sarscov2.bamIndex,
            to: mappingDir.appendingPathComponent("sorted.bam.bai")
        )
        try "{}".write(
            to: mappingDir.appendingPathComponent("mapping-provenance.json"),
            atomically: true,
            encoding: .utf8
        )

        // 3. Adopt the mapping into the bundle as a new alignment track.
        let adopt = try BAMCommand.AdoptMappingSubcommand.parse([
            "--bundle", bundleURL.path,
            "--mapping-result", mappingDir.path,
            "--name", "minimap2"
        ])
        try await adopt.run()
        let manifest1 = try BundleManifest.load(from: bundleURL)
        let mappedTrackID = try #require(
            manifest1.alignments.first(where: { $0.name == "minimap2" })?.id,
            "adopt-mapping should add an alignment track named 'minimap2'"
        )

        // 4. Primer-trim using the MT192765.1-anchored test scheme.
        let primersURL = TestFixtures.mt192765Integration.bundleURL
        let trim = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", bundleURL.path,
            "--alignment-track", mappedTrackID,
            "--scheme", primersURL.path,
            "--name", "primer-trimmed"
        ])
        try await trim.run()
        let manifest2 = try BundleManifest.load(from: bundleURL)
        let trimmedTrackID = try #require(
            manifest2.alignments.first(where: { $0.name == "primer-trimmed" })?.id,
            "primer-trim should add an alignment track named 'primer-trimmed'"
        )

        // 5. iVar call against the primer-trimmed track.
        let iVarCall = try VariantsCommand.CallSubcommand.parse([
            "--bundle", bundleURL.path,
            "--alignment-track", trimmedTrackID,
            "--caller", "ivar",
            "--name", "iVar variants",
            "--ivar-primer-trimmed"
        ])
        try await iVarCall.run()

        // 6. LoFreq call against the un-trimmed mapped track.
        let lofreqCall = try VariantsCommand.CallSubcommand.parse([
            "--bundle", bundleURL.path,
            "--alignment-track", mappedTrackID,
            "--caller", "lofreq",
            "--name", "LoFreq variants"
        ])
        try await lofreqCall.run()

        // 7. Final manifest assertions: two alignment tracks (minimap2 +
        //    primer-trimmed), two variant tracks (iVar + LoFreq).
        let manifestFinal = try BundleManifest.load(from: bundleURL)
        #expect(manifestFinal.alignments.count == 2)
        #expect(manifestFinal.variants.count == 2)
        let variantNames = manifestFinal.variants.map(\.name)
        #expect(variantNames.contains("iVar variants"))
        #expect(variantNames.contains("LoFreq variants"))
    }
}
