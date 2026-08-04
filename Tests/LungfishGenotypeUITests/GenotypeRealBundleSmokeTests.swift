// GenotypeRealBundleSmokeTests.swift - optional smoke against a local real bundle

import XCTest
import AppKit
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeRealBundleSmokeTests: XCTestCase {
    private let realBundleEnvironmentKey = "LUNGFISH_GENOTYPE_REAL_BUNDLE"

    private func loadRealBundleOrSkip() throws -> ONTGenotypeResultBundleData {
        guard let realBundlePath = ProcessInfo.processInfo.environment[realBundleEnvironmentKey],
              !realBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set \(realBundleEnvironmentKey) to run the optional real genotype bundle smoke test")
        }
        let url = URL(fileURLWithPath: realBundlePath)
        guard FileManager.default.fileExists(atPath: realBundlePath) else {
            throw XCTSkip("Real genotype bundle not found at \(realBundlePath)")
        }
        return try ONTGenotypeResultBundle.loadResult(from: url)
    }

    func testRealBundleLoadsAnalysisAndCalls() throws {
        let result = try loadRealBundleOrSkip()
        XCTAssertFalse(result.samples.isEmpty, "Expect samples in the real bundle")
        XCTAssertFalse(result.calls.isEmpty, "Expect raw calls in the real bundle")
        XCTAssertNotNil(result.haplotypeAnalysis, "Real bundle should carry a haplotype analysis")
    }

    func testObservedLociIndexIncludesNonAnalyzedLoci() throws {
        let result = try loadRealBundleOrSkip()
        let index = GenotypeObservedLociIndex.build(from: result)
        let analyzed = (result.haplotypeAnalysis?.samples.first?.calls.map(\.locus)) ?? []
        let observedOnly = index.loci.filter { !analyzed.contains($0) }
        XCTAssertFalse(observedOnly.isEmpty,
            "Bundle observes non-analyzed loci (e.g. MHC-AG, MHC-F, MHC-G); the index must include them")
    }

    func testViewportConfiguresWithRealBundleWithoutCrash() throws {
        let result = try loadRealBundleOrSkip()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        // Force a layout pass to exercise the panel constraints.
        controller.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        // Configure should populate the view hierarchy without crashing;
        // the view's accessibility label is set by the controller.
        XCTAssertEqual(controller.view.accessibilityLabel(), "Genotype result viewport")
    }

    func testLegacyMiSeqBundleUsesSynchronizedPresentationSelector() throws {
        let result = try loadRealBundleOrSkip()
        guard result.manifest.kind == "ont-barcode-genotype",
              result.manifest.workflowKind == nil,
              result.manifest.workflowMode == nil,
              result.haplotypeAnalysis?.assayID == "MHC-exon2-miSeq" else {
            throw XCTSkip("Real bundle is not the beta19 ONT-sample-bundle miSeq result shape")
        }
        guard case .ineligible = GenotypeManualHaplotypeEligibility.evaluate(result) else {
            return XCTFail("A result with persisted haplotype calls must not enter manual genotype-only mode")
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        XCTAssertEqual(
            controller.testingLensControlLabels,
            ["Haplotype Calls", "Genotype Matrix"]
        )
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
    }

    func testCohortSubjectBuilderProducesOneSubjectPerSample() throws {
        let result = try loadRealBundleOrSkip()
        let sidecar = try ONTGenotypeResultBundleData
            .loadOrCreateAnnotationSidecar(forBundleAt: result.bundleURL)
        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(result: result, sidecar: sidecar)
        XCTAssertEqual(subjects.count, result.samples.count)
    }

    func testNeedsReviewCohortReturnsAtLeastOneSubject() throws {
        let result = try loadRealBundleOrSkip()
        let sidecar = try ONTGenotypeResultBundleData
            .loadOrCreateAnnotationSidecar(forBundleAt: result.bundleURL)
        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(result: result, sidecar: sidecar)
        let predicate: SmartCohortPredicate = .any([
            .hasErrorAtAnyLocus,
            .qcStatus([.review, .lowSupport]),
            .hasAnalystFlag(.needsReview),
        ])
        let matched = subjects.filter { predicate.evaluate($0) }
        XCTAssertFalse(matched.isEmpty,
            "Real bundle should have at least some samples in the Needs review cohort " +
            "(most carry ERR: TMH / ERR: TMG / ERR: NO HAP at one or more loci)")
    }

    func testManualHaplotypingDigestSurfacesObservedGenotypes() throws {
        let result = try loadRealBundleOrSkip()
        let digest = GenotypeManualHaplotypingDigest.build(from: result.calls)
        XCTAssertFalse(digest.observations.isEmpty,
            "Digest should surface observed genotypes across analyzed and non-analyzed loci")
        // Confirm at least one MHC-AG observation (non-analyzed locus in MCM set).
        let mhcAG = digest.observations.first { $0.locus == "MHC-AG" }
        XCTAssertNotNil(mhcAG, "Bundle observes MHC-AG genotypes")
    }
}
