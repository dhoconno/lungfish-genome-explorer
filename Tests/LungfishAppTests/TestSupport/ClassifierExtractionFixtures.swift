// ClassifierExtractionFixtures.swift — Shared fixture builder for classifier extraction tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import XCTest

/// Factory that builds minimal per-tool classifier result layouts backed by
/// the flag-augmented `Tests/Fixtures/sarscov2/test.paired_end.sorted.markers.bam`
/// for all BAM-backed tools and the existing `Tests/Fixtures/kraken2-mini/`
/// fixture for Kraken2.
///
/// The fixtures are written to a throwaway directory under the test's
/// temporary directory. Tests are responsible for cleaning up via `defer`.
///
/// ## I4 fixture augmentation
///
/// The per-tool BAM is the "markers" variant that adds three synthetic records
/// carrying 0x100 / 0x400 / 0x800 flag bits on top of the original 200-read
/// sarscov2 BAM. This gives the I4 count-sequence invariant real teeth: the
/// `samtools view -c -F 0x404` filtered count (199) differs from the raw
/// count (203) by 4, so any regression that removes the flag mask fails the
/// resolver/MarkdupService equality assertion.
///
/// ## Thread safety
///
/// All methods are static and file-system-only. Safe to call from any test.
enum ClassifierExtractionFixtures {

    // MARK: - Repository root

    /// The lungfish-genome-browser repository root, derived from `#filePath`.
    ///
    /// `#filePath` resolves to the absolute path of the current Swift source
    /// file; we walk up 4 levels (`TestSupport` → `LungfishAppTests` → `Tests`
    /// → repo root).
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TestSupport
            .deletingLastPathComponent() // LungfishAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    // MARK: - Sarscov2 source

    /// The sarscov2 markers BAM path — the flag-augmented variant (adds
    /// synthetic 0x100/0x400/0x800 records) of the original sarscov2 test BAM.
    /// Used for all 4 BAM-backed classifier fixtures so the I4 invariant test
    /// exercises the 0x404 flag mask non-trivially (199 filtered vs 203 raw).
    static var sarscov2BAM: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.markers.bam")
    }

    static var sarscov2BAMIndex: URL {
        sarscov2BAM.appendingPathExtension("bai")
    }

    // MARK: - Per-tool fixture builders

    /// Builds a minimal classifier result layout that places the sarscov2
    /// markers BAM at the expected per-tool location.
    ///
    /// - Returns: A tuple `(resultPath, projectRoot)` where `resultPath` is the
    ///   URL to pass to the resolver and `projectRoot` is the directory the
    ///   bundle destination should land under.
    /// - Throws: `XCTSkip` if the sarscov2 fixture BAM is missing.
    static func buildFixture(
        tool: ClassifierTool,
        sampleId: String
    ) throws -> (resultPath: URL, projectRoot: URL) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: sarscov2BAM.path),
              fm.fileExists(atPath: sarscov2BAMIndex.path) else {
            throw XCTSkip("sarscov2 markers fixture BAM missing at \(sarscov2BAM.path)")
        }

        // Project root with a .lungfish marker so resolveProjectRoot finds it.
        let projectRoot = fm.temporaryDirectory.appendingPathComponent("clfx-\(tool.rawValue)-\(UUID().uuidString)")
        let marker = projectRoot.appendingPathComponent(".lungfish")
        try fm.createDirectory(at: marker, withIntermediateDirectories: true)

        // Result subdirectory inside the project.
        let resultDir = projectRoot.appendingPathComponent("analyses/\(tool.rawValue)-result")
        try fm.createDirectory(at: resultDir, withIntermediateDirectories: true)

        switch tool {
        case .esviritu:
            let bam = resultDir.appendingPathComponent("\(sampleId).sorted.bam")
            try fm.copyItem(at: sarscov2BAM, to: bam)
            try fm.copyItem(at: sarscov2BAMIndex, to: bam.appendingPathExtension("bai"))
            return (resultPath: resultDir.appendingPathComponent("fake.sqlite"), projectRoot: projectRoot)

        case .taxtriage:
            let subdir = resultDir.appendingPathComponent("minimap2")
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            let bam = subdir.appendingPathComponent("\(sampleId).bam")
            try fm.copyItem(at: sarscov2BAM, to: bam)
            try fm.copyItem(at: sarscov2BAMIndex, to: bam.appendingPathExtension("bai"))
            return (resultPath: resultDir.appendingPathComponent("fake.sqlite"), projectRoot: projectRoot)

        case .naomgs:
            let subdir = resultDir.appendingPathComponent("bams")
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            let bam = subdir.appendingPathComponent("\(sampleId).sorted.bam")
            try fm.copyItem(at: sarscov2BAM, to: bam)
            try fm.copyItem(at: sarscov2BAMIndex, to: bam.appendingPathExtension("bai"))
            return (resultPath: resultDir.appendingPathComponent("fake.sqlite"), projectRoot: projectRoot)

        case .nvd:
            let bam = resultDir.appendingPathComponent("\(sampleId).bam")
            try fm.copyItem(at: sarscov2BAM, to: bam)
            try fm.copyItem(at: sarscov2BAMIndex, to: bam.appendingPathExtension("bai"))
            return (resultPath: resultDir.appendingPathComponent("fake.sqlite"), projectRoot: projectRoot)

        case .kraken2:
            // The existing kraken2-mini fixture lives at
            // Tests/Fixtures/kraken2-mini/SRR35517702/classification-result.json
            // and references input files outside the test environment. Full
            // extraction would require a self-contained fixture (Phase 7
            // work). For now, point the resultPath at the SRR result dir if
            // present, else skip.
            let miniDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/kraken2-mini/SRR35517702")
            guard fm.fileExists(atPath: miniDir.path) else {
                throw XCTSkip("kraken2-mini fixture missing at \(miniDir.path)")
            }
            let sidecar = miniDir.appendingPathComponent("classification-result.json")
            guard fm.fileExists(atPath: sidecar.path) else {
                throw XCTSkip("kraken2-mini classification-result.json missing")
            }
            return (resultPath: miniDir, projectRoot: projectRoot)
        }
    }

    /// Reads the first reference name from the sarscov2 markers BAM header.
    /// Used by BAM-backed classifier tests as the "selected accession".
    static func sarscov2FirstReference() async throws -> String {
        let refs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: sarscov2BAM,
            runner: .shared
        )
        guard let first = refs.first else {
            throw XCTSkip("sarscov2 BAM has no references")
        }
        return first
    }

    /// A one-row selection for the given tool + sarscov2 fixture.
    ///
    /// For BAM-backed tools: `accessions` = [first BAM reference], `sampleId` = the provided `sampleId`.
    /// For Kraken2: `taxIds` = [first taxon with non-zero clade count], `sampleId` = nil.
    static func defaultSelection(for tool: ClassifierTool, sampleId: String) async throws -> [ClassifierRowSelector] {
        if tool.usesBAMDispatch {
            let ref = try await sarscov2FirstReference()
            return [ClassifierRowSelector(sampleId: sampleId, accessions: [ref], taxIds: [])]
        } else {
            // Kraken2: pick a taxon with non-zero clade reads from the fixture.
            let (resultPath, _) = try buildFixture(tool: .kraken2, sampleId: sampleId)
            let result: ClassificationResult
            do {
                result = try ClassificationResult.load(from: resultPath)
            } catch {
                throw XCTSkip("kraken2-mini fixture cannot be loaded: \(error)")
            }
            guard let taxon = result.tree.allNodes().first(where: { $0.readsClade > 0 && $0.taxId != 0 }) else {
                throw XCTSkip("kraken2-mini has no classified taxa")
            }
            return [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [taxon.taxId])]
        }
    }

    // MARK: - Samtools path

    /// Locates the `samtools` binary on the test host.
    ///
    /// Used by I4 invariant tests that call `MarkdupService.countReads(...)`
    /// as a ground-truth oracle. Prefers the `NativeToolRunner` cached path
    /// so tests match the resolver's dispatch, falling back to common
    /// homebrew locations if the runner can't find it.
    static func resolveSamtoolsPath() async -> String {
        if let url = try? await NativeToolRunner.shared.findTool(.samtools) {
            return url.path
        }
        let candidates = [
            "/opt/homebrew/bin/samtools",
            "/usr/local/bin/samtools",
            "/usr/bin/samtools",
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            return p
        }
        return "samtools"
    }
}
