import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeWorkbookRevisionServiceTests: XCTestCase {
    func testExplicitUpdateRetainsAllCandidateCategoriesAndUnnameableEvidenceWithNameOnlyTints() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-workbook")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(
            showKnown: false,
            showSharedCandidates: false,
            showSingletonCandidates: false,
            tints: [
                .sharedNovel: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
                .singletonNovel: AnnotationColor(red: 0, green: 1, blue: 0, alpha: 0.5),
                .sharedExtension: AnnotationColor(red: 0, green: 0, blue: 1, alpha: 1),
                .singletonExtension: AnnotationColor(red: 1, green: 1, blue: 0, alpha: 0.25),
            ]
        )
        try sidecar.encoded().write(to: annotationURL)

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)
        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_000) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)
        let after = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertNotEqual(before, after, "Only the explicit update action may rewrite current.xlsx")
        let inspection = try inspectCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["candidateNames"], "Mafa-A1*018:01:01:01_5nt_nov|Mafa-A1*018:01:01:01_5nt_nov|Mafa-B*001:01_ext|Mafa-B*002:01_ext")
        XCTAssertEqual(inspection["candidateNameFills"], "FFFF0000|8000FF00|FF0000FF|40FFFF00")
        XCTAssertEqual(inspection["candidateIDFills"], "00000000|00000000|00000000|00000000")
        XCTAssertEqual(inspection["editableCandidateCount"], "4")
        XCTAssertEqual(inspection["editableNameFills"], "FFFF0000|8000FF00|FF0000FF|40FFFF00")
        XCTAssertEqual(inspection["analystFormula"], "=SUM(D1:D3)")
        XCTAssertEqual(inspection["analystFill"], "FF123456")
        XCTAssertEqual(inspection["candidateShapedAnalystFormula"], "=1+1")
        XCTAssertEqual(inspection["unnameableIDs"], "cluster-u|cluster-u")
        XCTAssertEqual(inspection["unnameableQueries"], "cluster-u-a|cluster-u-z")
        XCTAssertEqual(
            inspection["legacyCandidateRows"],
            Array(repeating: "reciprocal-minimap2|Mafa-A1*018:01:01:01_5nt_nov|Mafa-A1*018:01:01:01|Mafa-A1*018:01:01:01|novel|5|5|0|1000|1000|100|100||", count: 4).joined(separator: "||")
        )
        XCTAssertEqual(
            inspection["legacyUnnameableRows"],
            Array(repeating: "reciprocal-unnameable||||un-nameable|||||||||", count: 4).joined(separator: "||")
        )
        XCTAssertFalse((inspection["allText"] ?? "").contains("_0nt_nov"))
        XCTAssertEqual(updated.mhcCandidateArtifacts?.schemaVersion, 1)
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let provenanceData = try Data(contentsOf: provenanceURL)
        let provenance = try XCTUnwrap(String(data: provenanceData, encoding: .utf8))
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: provenanceData)
        XCTAssertTrue(provenance.contains("mhcCandidateTints"))
        XCTAssertTrue(provenance.contains("mhcCandidateVisibilityFiltersApplied"))
        XCTAssertTrue(provenance.contains("openpyxl-runtime"))
        XCTAssertEqual(envelope.options.explicit["action"], .string("update-current-workbook"))
        XCTAssertTrue(provenanceURL.lastPathComponent.contains("update-current-workbook"))
        let pythonStep = try XCTUnwrap(envelope.steps.first(where: { $0.toolName.contains("python openpyxl") }))
        XCTAssertNotNil(pythonStep.startedAt)
        XCTAssertNotNil(pythonStep.completedAt)
        XCTAssertGreaterThanOrEqual(pythonStep.wallTimeSeconds ?? -1, 0)
        XCTAssertTrue(pythonStep.inputs.allSatisfy { $0.path.hasPrefix(fixture.bundleURL.path) })
        XCTAssertTrue(pythonStep.outputs.allSatisfy {
            ($0.originPath ?? $0.path).hasPrefix(fixture.bundleURL.path)
        })
        let durableReplayArgv = try XCTUnwrap(pythonStep.durableReplayArgv)
        XCTAssertTrue(pythonStep.argv.joined(separator: " ").contains(".staging"), "Actual argv should retain execution origin")
        XCTAssertFalse(durableReplayArgv.joined(separator: " ").contains(".staging"))
        XCTAssertFalse(pythonStep.reproducibleCommand.contains(".staging"))
        XCTAssertTrue(durableReplayArgv.dropFirst().allSatisfy {
            $0.isEmpty || $0.hasPrefix(fixture.bundleURL.path)
        })
        for filename in ["apply-current-workbook-overrides.py", "candidate-config.json", "haplotype-calls.json"] {
            let descriptor = try XCTUnwrap(pythonStep.inputs.first(where: { $0.path.hasSuffix(filename) }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.path))
            XCTAssertEqual(descriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: descriptor.path)))
        }
        XCTAssertEqual(envelope.steps.last?.toolName, "lungfish-internal atomic workbook bundle exchange")
        XCTAssertEqual(envelope.output?.path, fixture.bundleURL.path)
        XCTAssertTrue(envelope.outputs.allSatisfy { $0.path.hasPrefix(fixture.bundleURL.path) })
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, pythonStep.wallTimeSeconds ?? 0)

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)
        let secondInspection = try inspectCandidateWorkbook(currentURL)
        XCTAssertEqual(secondInspection["editableCandidateCount"], "4")
        XCTAssertEqual(secondInspection["analystFormula"], "=SUM(D1:D3)")
        XCTAssertEqual(secondInspection["analystFill"], "FF123456")
        XCTAssertEqual(secondInspection["candidateShapedAnalystFormula"], "=1+1")
        XCTAssertEqual(secondInspection["managedBeginCount"], "1")
        XCTAssertEqual(secondInspection["managedEndCount"], "1")
    }

    func testCandidateUpdateUsesUnifiedPivotFallbackWhenFullSequencingSheetIsAbsent() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "candidate-fallback")
        try installCandidateArtifacts(in: fixture.bundleURL)

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectCandidateWorkbook(try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))
        XCTAssertEqual(inspection["unifiedCandidateCount"], "4")
        XCTAssertEqual(inspection["unifiedCandidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
    }

    func testBundleCloneAttemptsCopyOnWriteAndFallbackPublishesEquivalentWorkbook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "clone-fallback")
        let before = try ProvenanceFileHasher.sha256(
            of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        let attempted = expectation(description: "copy-on-write clone attempted")

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            bundleCloneAttemptObserver: { attempted.fulfill() },
            forceBundleCloneFallback: true
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        wait(for: [attempted], timeout: 0.1)
        XCTAssertNotEqual(
            try ProvenanceFileHasher.sha256(
                of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
            ),
            before
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL))
    }

    func testBundleCloneFallbackRemovesPartialCloneAndCopiesWithoutCopyfile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "partial-clone-fallback")
        let attempts = SendableFlagBox()

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            bundleCopyPrimitive: { _, destination, _ in
                attempts.set((attempts.value ?? 0) + 1)
                try? FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                try? Data("partial-clone".utf8).write(
                    to: destination.appendingPathComponent("partial.txt")
                )
                errno = ENOTSUP
                return -1
            }
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertEqual(attempts.value, 1, "copyfile is only the clone attempt; fallback is descriptor-based")
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.bundleURL.appendingPathComponent("partial.txt").path
            )
        )
    }

    func testDefaultBundleCopyPrimitiveReceivesRecursiveCloneNoFollowFlags() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "clone-flags")
        let observedFlags = SendableFlagBox()

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            bundleCopyPrimitive: { source, destination, copyFlags in
                observedFlags.set(copyFlags)
                return Darwin.copyfile(
                    source.path,
                    destination.path,
                    nil,
                    copyfile_flags_t(copyFlags)
                )
            }
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let expected = UInt32(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_EXCL
        )
        XCTAssertEqual(observedFlags.value, expected)
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testNestedBundleSymlinkIsRejectedBeforeCopyPrimitiveRuns() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "clone-symlink")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.bundleURL.appendingPathComponent("artifacts/nested-unsafe-link"),
            withDestinationURL: outside
        )
        let observedFlags = SendableFlagBox()

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                bundleCopyPrimitive: { _, _, flags in
                    observedFlags.set(flags)
                    return 1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertNil(observedFlags.value)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testMalformedCandidateArtifactFailsWithoutMutatingWorkbookOrManifest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-rollback")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let candidateJSONURL = fixture.bundleURL
            .appendingPathComponent("artifacts/mhc-candidates/candidate-alleles.json")
        try Data("{malformed".utf8).write(to: candidateJSONURL, options: .atomic)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent("artifacts/workbooks/updates").path
        ))
    }

    func testAmbiguousManagedCandidateMarkersFailClosedWithoutBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "ambiguous-candidate-markers")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb["Full Sequencing Results 1"].append(["LGE MHC Candidate Alleles [BEGIN]"])
wb.save(path)
"""#, currentURL.path])
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testMalformedCandidateDoesNotCreateInitiallyAbsentCurrentWorkbookOrRevisionArtifacts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-no-current")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try FileManager.default.removeItem(at: currentURL)
        try writeManifestWithoutCurrent(in: fixture.bundleURL)
        let candidateJSONURL = fixture.bundleURL.appendingPathComponent("artifacts/mhc-candidates/candidate-alleles.json")
        try Data("{malformed".utf8).write(to: candidateJSONURL, options: .atomic)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testFinalProvenanceFailureAtomicallyRestoresEntireBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-provenance-rollback")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    if checkpoint == "before-final-provenance" {
                        throw NSError(domain: "InjectedFinalProvenanceFailure", code: 1)
                    }
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testPostExchangeFailureRestoresEntireBundleBeforeRevisionManifestPublication() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "post-exchange-rollback")
        let before = try bundleSnapshot(fixture.bundleURL)
        let originalRevisionCount = fixture.manifest.workbookRevisions?.count

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "post-exchange" else { return }
                    let visible = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
                    if visible.workbookRevisions?.count != originalRevisionCount {
                        throw NSError(domain: "RevisionManifestPublishedEarly", code: 1)
                    }
                    throw NSError(domain: "InjectedPostExchangeFailure", code: 1)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertEqual((error as NSError).domain, "InjectedPostExchangeFailure")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testFreshLoaderRecoversHardStopImmediatelyAfterWorkbookExchange() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "hard-stop-recovery")
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertEqual((error as NSError).domain, "SimulatedSIGKILL")
        }
        let markerURL = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        XCTAssertEqual(marker["schemaVersion"] as? Int, 3)
        XCTAssertNotNil(marker["attestationID"] as? String)
        XCTAssertEqual(marker["phase"] as? String, "prepared")
        XCTAssertEqual(marker["workflowName"] as? String, "Genotype Workbook Update")
        XCTAssertFalse((marker["argv"] as? [String] ?? []).isEmpty)
        XCTAssertNotNil(marker["oldManifest"] as? [String: Any])
        XCTAssertNotNil(marker["newManifest"] as? [String: Any])
        XCTAssertNotNil(marker["oldCurrentWorkbook"] as? [String: Any])
        XCTAssertNotNil(marker["newCurrentWorkbook"] as? [String: Any])
        XCTAssertNotNil(marker["oldGenerationIdentity"] as? [String: Any])
        XCTAssertNotNil(marker["newGenerationIdentity"] as? [String: Any])
        XCTAssertNotNil(marker["transactionRootIdentity"] as? [String: Any])

        _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.contains("workbook-update-recovery") && $0.hasSuffix(".json")
        })
    }

    func testFreshLoaderDiscardsProvenUnpublishedStageAfterPreExchangeHardStop() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "pre-exchange-hard-stop")
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-transaction-marker-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction.json"
            ).path
        ))
    }

    func testRecoveryWithoutDetachedAttestationFailsClosedWithoutMutatingEitherGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attestationRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(attestationRoot.path, 0o700), 0)
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "missing-detached-attestation")

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        let attestationID = try XCTUnwrap(marker["attestationID"] as? String)
        let attestationURL = attestationRoot.appendingPathComponent("\(attestationID).json")
        let stagingURL = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        try FileManager.default.removeItem(at: attestationURL)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagingBefore = try bundleSnapshot(stagingURL)
        let markerBefore = try Data(contentsOf: markerURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        ) { error in
            XCTAssertTrue(error is ONTGenotypeWorkbookUpdateRecoveryError)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("ambiguous"))
        }

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagingURL), stagingBefore)
        XCTAssertEqual(try Data(contentsOf: markerURL), markerBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attestationURL.path))
    }

    func testRecoveryRejectsSymlinkedDetachedAttestationWithoutMutatingEitherGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attestationRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(attestationRoot.path, 0o700), 0)
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "symlinked-detached-attestation")

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        let attestationID = try XCTUnwrap(marker["attestationID"] as? String)
        let attestationURL = attestationRoot.appendingPathComponent("\(attestationID).json")
        let retainedURL = root.appendingPathComponent("retained-attestation.json")
        try FileManager.default.moveItem(at: attestationURL, to: retainedURL)
        try FileManager.default.createSymbolicLink(at: attestationURL, withDestinationURL: retainedURL)
        let stagingURL = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagingBefore = try bundleSnapshot(stagingURL)
        let markerBefore = try Data(contentsOf: markerURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("ambiguous"))
        }

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagingURL), stagingBefore)
        XCTAssertEqual(try Data(contentsOf: markerURL), markerBefore)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: attestationURL.path),
            retainedURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
    }

    func testAsyncLoaderFinishesCleanupAfterHardStopFollowingCommittedManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "committed-hard-stop")
        let priorRevisionCount = fixture.manifest.workbookRevisions?.count ?? 0

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let loaded = try await ONTGenotypeResultBundle.loadResultAsync(from: fixture.bundleURL)

        XCTAssertGreaterThan(loaded.manifest.workbookRevisions?.count ?? 0, priorRevisionCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testLoaderAllowsExternalCurrentWorkbookEditWhenNoTransactionIsActive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "workbook-integrity")
        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try Data("tampered-current-workbook".utf8).write(to: currentURL, options: .atomic)

        let loaded = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        XCTAssertEqual(loaded.artifacts.workbookURL, currentURL)
    }

    func testAmbiguousHardStopRecoveryPreservesBothGenerationsAndFailsClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "ambiguous-hard-stop")

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction.json"
        )
        let markerObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        let stagingPath = try XCTUnwrap(markerObject["stagingBundlePath"] as? String)
        let stagingURL = URL(fileURLWithPath: stagingPath, isDirectory: true)
        let stagingManifest = try ONTGenotypeResultBundle.loadManifest(from: stagingURL)
        let stagingCurrentURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(stagingManifest.currentWorkbookPath),
            in: stagingURL
        )
        try Data("ambiguous-generation".utf8).write(to: stagingCurrentURL, options: .atomic)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagingBefore = try bundleSnapshot(stagingURL)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagingURL), stagingBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.contains("workbook-update-recovery") && $0.hasSuffix(".json")
        })
    }

    func testCraftedMarkerCannotRedirectRecoveryToByteIdenticalUnrelatedStage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "crafted-marker-stage")
        let markerURL = try interruptWorkbookPublicationAfterExchange(fixture: fixture, root: root)
        var marker = try markerObject(at: markerURL)
        let genuineRoot = URL(
            fileURLWithPath: try XCTUnwrap(marker["transactionRootPath"] as? String),
            isDirectory: true
        )
        let genuineStage = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        let rogueRoot = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-crafted.staging",
            isDirectory: true
        )
        let rogueStage = rogueRoot.appendingPathComponent(fixture.bundleURL.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: rogueRoot, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: genuineStage, to: rogueStage)
        let sentinel = rogueRoot.appendingPathComponent("unrelated-sentinel.txt")
        try Data("must-survive".utf8).write(to: sentinel)
        marker["transactionRootPath"] = rogueRoot.path
        marker["stagingBundlePath"] = rogueStage.path
        try writeMarkerObject(marker, to: markerURL)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let genuineBefore = try bundleSnapshot(genuineRoot)
        let rogueBefore = try bundleSnapshot(rogueRoot)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(genuineRoot), genuineBefore)
        XCTAssertEqual(try bundleSnapshot(rogueRoot), rogueBefore)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("must-survive".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testRecoveryRejectsTransactionRootInodeSubstitutionWithoutDeletingEitherTree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "marker-inode-substitution")
        let markerURL = try interruptWorkbookPublicationAfterExchange(fixture: fixture, root: root)
        let marker = try markerObject(at: markerURL)
        let transactionRoot = URL(
            fileURLWithPath: try XCTUnwrap(marker["transactionRootPath"] as? String),
            isDirectory: true
        )
        let retainedRoot = root.appendingPathComponent("retained-genuine-transaction-root", isDirectory: true)
        try FileManager.default.moveItem(at: transactionRoot, to: retainedRoot)
        try FileManager.default.copyItem(at: retainedRoot, to: transactionRoot)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let retainedBefore = try bundleSnapshot(retainedRoot)
        let replacementBefore = try bundleSnapshot(transactionRoot)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(retainedRoot), retainedBefore)
        XCTAssertEqual(try bundleSnapshot(transactionRoot), replacementBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testRecoveryRejectsSymlinkedTransactionRootBeforeAnyGenerationSwap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "marker-root-symlink")
        let markerURL = try interruptWorkbookPublicationAfterExchange(fixture: fixture, root: root)
        let marker = try markerObject(at: markerURL)
        let transactionRoot = URL(
            fileURLWithPath: try XCTUnwrap(marker["transactionRootPath"] as? String),
            isDirectory: true
        )
        let retainedRoot = root.appendingPathComponent("retained-symlink-target", isDirectory: true)
        try FileManager.default.moveItem(at: transactionRoot, to: retainedRoot)
        try FileManager.default.createSymbolicLink(at: transactionRoot, withDestinationURL: retainedRoot)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let retainedBefore = try bundleSnapshot(retainedRoot)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(retainedRoot), retainedBefore)
        var info = stat()
        XCTAssertEqual(Darwin.lstat(transactionRoot.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testPreManifestFailureRestoresEntireBundleWithOldManifestStillVisible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "pre-manifest-rollback")
        let before = try bundleSnapshot(fixture.bundleURL)
        let originalRevisionCount = fixture.manifest.workbookRevisions?.count

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-revision-manifest" else { return }
                    let visible = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
                    if visible.workbookRevisions?.count != originalRevisionCount {
                        throw NSError(domain: "RevisionManifestPublishedEarly", code: 1)
                    }
                    throw NSError(domain: "InjectedPreManifestFailure", code: 1)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertEqual((error as NSError).domain, "InjectedPreManifestFailure")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testRollbackFailureRetainsJournaledGenerationsAndNextRunRecoversPrior() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "rollback-failure-recovery")
        let beforeManifest = fixture.manifest

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    if checkpoint == "post-exchange" {
                        throw NSError(domain: "InjectedPublicationFailure", code: 1)
                    }
                    if checkpoint == "before-rollback-exchange" {
                        throw NSError(domain: "InjectedRollbackFailure", code: 1)
                    }
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.bundleURL.path))
        let receiptURL = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-failure.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        let markerURL = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction.json"
        )
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        XCTAssertEqual(marker["phase"] as? String, "rollbackFailed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(marker["stagingBundlePath"] as? String)
        ))

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        let recovered = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        XCTAssertGreaterThan(recovered.workbookRevisions?.count ?? 0, beforeManifest.workbookRevisions?.count ?? 0)
    }

    func testSymlinkUpdatesPathIsRejectedWithoutAnyBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-updates")
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let updatesURL = fixture.bundleURL.appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updatesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: updatesURL, withDestinationURL: outside)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testAbsoluteSymlinkRevisionsPathIsRejectedBeforeExternalOrBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-revisions")
        let outside = root.appendingPathComponent("outside-revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        let revisionsURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/revisions",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: revisionsURL, withDestinationURL: outside)
        let before = try bundleSnapshot(fixture.bundleURL)
        let outsideBefore = try Data(contentsOf: sentinel)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), outsideBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testRelativeSymlinkProvenancePathIsRejectedBeforeExternalOrBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-provenance")
        let outside = root.appendingPathComponent("outside-provenance", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: provenanceURL.path,
            withDestinationPath: "../../../outside-provenance"
        )
        let before = try bundleSnapshot(fixture.bundleURL)
        let outsideBefore = try Data(contentsOf: sentinel)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), outsideBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testIntermediateWorkbooksSymlinkIsRejectedBeforeHistoryOrProvenanceWrites() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-workbooks")
        let workbooksURL = fixture.bundleURL.appendingPathComponent("artifacts/workbooks", isDirectory: true)
        let outside = root.appendingPathComponent("outside-workbooks", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: workbooksURL.appendingPathComponent("current.xlsx"),
            to: outside.appendingPathComponent("current.xlsx")
        )
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: workbooksURL)
        try FileManager.default.createSymbolicLink(at: workbooksURL, withDestinationURL: outside)
        let before = try bundleSnapshot(fixture.bundleURL)
        let outsideBefore = try bundleSnapshot(outside)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertEqual(try bundleSnapshot(outside), outsideBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testFIFOAnywhereInSourceBundleIsRejectedBeforeStagingOrMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-fifo")
        let fifoURL = fixture.bundleURL.appendingPathComponent("artifacts/unsafe.fifo")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testCancellationDuringPythonLeavesEntireBundleUnchanged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-cancelled")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let fakePythonURL = root.appendingPathComponent("slow-python")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: fakePythonURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakePythonURL.path)
        let before = try bundleSnapshot(fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(pythonExecutableURL: fakePythonURL)

        let update = Task {
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        }
        let stagePrefix = ".\(fixture.bundleURL.lastPathComponent).workbook-update-"
        var observedStage = false
        for _ in 0..<100 {
            let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
            if siblings.contains(where: { $0.hasPrefix(stagePrefix) }) {
                observedStage = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(observedStage, "The test must cancel while the Python update transaction is staged")
        update.cancel()

        do {
            _ = try await update.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(stagePrefix) })
        )
    }

    func testManualExcelSaveAfterPythonConflictsAndSurvivesWithoutMetadataMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance", isDirectory: true
        )
        let provenanceBefore = try directorySnapshot(provenanceURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-python-before-source-conflict-check" else { return }
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z99"] = "manual-save-survives"
wb.save(path)
"""#, currentURL.path], executableURL: pythonURL)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try directorySnapshot(provenanceURL), provenanceBefore)
        let manualValue = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z99"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(manualValue.trimmingCharacters(in: .whitespacesAndNewlines), "manual-save-survives")
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testManualExcelSaveAtPreWALBoundaryConflictsAndSurvivesWithoutMetadataMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-pre-wal-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance", isDirectory: true
        )
        let provenanceBefore = try directorySnapshot(provenanceURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-transaction-marker-source-conflict-check" else { return }
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z98"] = "manual-save-pre-wal-survives"
wb.save(path)
"""#, currentURL.path], executableURL: pythonURL)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try directorySnapshot(provenanceURL), provenanceBefore)
        let manualValue = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z98"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(manualValue.trimmingCharacters(in: .whitespacesAndNewlines), "manual-save-pre-wal-survives")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testManualExcelSaveAtPreExchangeBoundaryConflictsAndSurvivesWithoutMetadataMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-pre-exchange-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance", isDirectory: true
        )
        let provenanceBefore = try directorySnapshot(provenanceURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-exchange-source-conflict-check" else { return }
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z97"] = "manual-save-pre-exchange-survives"
wb.save(path)
"""#, currentURL.path], executableURL: pythonURL)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try directorySnapshot(provenanceURL), provenanceBefore)
        let manualValue = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z97"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(manualValue.trimmingCharacters(in: .whitespacesAndNewlines), "manual-save-pre-exchange-survives")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testReadOnlyBundleAndParentLoadWithoutCreatingAdjacentLock() throws {
        let root = try temporaryDirectory()
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "readonly-load")
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL)
        try? FileManager.default.removeItem(at: lockURL)
        defer {
            try? chmodTreeWritable(root)
            try? FileManager.default.removeItem(at: root)
        }
        try chmodTreeReadOnly(fixture.bundleURL)
        XCTAssertEqual(chmod(root.path, S_IRUSR | S_IXUSR), 0)

        let loaded = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(loaded.bundleURL, fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testSidecarDisplayEditAloneDoesNotMutateCurrentWorkbook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "sidecar-only")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay.showSingletonCandidates = false
        try sidecar.encoded().write(
            to: fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename),
            options: .atomic
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testConcurrentExplicitUpdateConflictsBeforeWorkbookMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-concurrent")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let before = try Data(contentsOf: currentURL)
        let lock = try DarwinFullLengthONTMHCRunLock.acquire(outputDirectoryURL: fixture.bundleURL)
        defer { lock.release() }

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try Data(contentsOf: currentURL), before)
    }

    func testExplicitUpdateRejectsSymlinkCurrentWorkbookWithoutMutatingTarget() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-symlink")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let outside = root.appendingPathComponent("outside.xlsx")
        try makeMinimalMCMWorkbook(at: outside)
        let outsideBefore = try Data(contentsOf: outside)
        try FileManager.default.removeItem(at: currentURL)
        try FileManager.default.createSymbolicLink(at: currentURL, withDestinationURL: outside)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideBefore)
    }

    func testWorkbookRevisionPreservesMHCCandidateArtifactManifest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "candidate-preservation", includeCurrent: true)
        let reference = ONTMHCArtifactReference(
            path: "artifacts/mhc-candidates/candidate-alleles.json",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 42
        )
        let candidateArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: 1,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: reference,
            candidateFASTA: reference,
            unnameableJSON: reference,
            unnameableFASTA: reference
        )
        let manifest = ONTGenotypeResultBundleManifest(
            schemaVersion: fixture.manifest.schemaVersion,
            kind: fixture.manifest.kind,
            outputName: fixture.manifest.outputName,
            analysisName: fixture.manifest.analysisName,
            primaryWorkbookPath: fixture.manifest.primaryWorkbookPath,
            currentWorkbookPath: fixture.manifest.currentWorkbookPath,
            workbookRevisions: fixture.manifest.workbookRevisions,
            longSummaryCSVPath: fixture.manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: fixture.manifest.sampleSummaryCSVPath,
            statsJSONPath: fixture.manifest.statsJSONPath,
            provenancePath: fixture.manifest.provenancePath,
            mhcCandidateArtifacts: candidateArtifacts
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)
        let replacement = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: replacement)

        let updated = try GenotypeWorkbookRevisionService()
            .importRevisedWorkbook(from: replacement, into: fixture.bundleURL)

        XCTAssertEqual(updated.mhcCandidateArtifacts, candidateArtifacts)
    }

    func testApplyHaplotypeOverridesPatchesCurrentWorkbookAndRecordsSidecarProvenance() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "mcm")
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-04T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-DP",
                slot: .h1,
                originalCall: "M4DP",
                overrideCall: "M3DP",
                reasonTag: .analystJudgment,
                rationale: "Manual curation from review viewport.",
                author: "curator",
                timestamp: "2026-06-04T12:00:00Z"
            )
        ]
        sidecar.append(audit: GenotypeAnnotationSidecar.AuditEntry(
            action: "override",
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            before: "M4DP",
            after: "M3DP",
            color: nil,
            reason: "analyst-judgment",
            rationale: "Manual curation from review viewport.",
            author: "curator",
            timestamp: "2026-06-04T12:00:00Z"
        ))
        try sidecar.encoded().write(to: annotationURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_000) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides(
            [
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: "MHC-DP",
                    haplotype1: "M3DP",
                    haplotype2: "M7DP",
                    status: "called",
                    notes: "Manual override"
                ),
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: "MHC-DRB",
                    haplotype1: "M2DR",
                    haplotype2: "M4DR",
                    status: "called",
                    notes: "DRB should not be written to current workbook calls"
                )
            ],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectMCMWorkbook(try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))
        XCTAssertEqual(inspection["abbreviatedDPHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["abbreviatedDPHaplotype2"], "M7DP")
        XCTAssertEqual(inspection["fullDPAHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["fullDPBHaplotype2"], "M7DP")
        XCTAssertEqual(inspection["customDPHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["abbreviatedDRBHaplotype1"], "")
        XCTAssertEqual(inspection["abbreviatedDRBHaplotype2"], "")
        XCTAssertEqual(inspection["fullDRBHaplotype1"], "")
        XCTAssertEqual(inspection["fullDRBHaplotype2"], "")
        XCTAssertFalse(inspection["abbreviatedComments"]?.contains("DRB should not be written") == true)
        XCTAssertFalse(inspection["fullComments"]?.contains("DRB should not be written") == true)
        XCTAssertEqual(inspection["guideWorkbookUpdateSource"], "Lungfish.app Review viewport")
        XCTAssertEqual(inspection["guideUpdatedHaplotypeCalls"], "1")
        XCTAssertEqual(inspection["guideAuditEntries"], "1")
        XCTAssertEqual(inspection["hasOverridesSheet"], "true")
        XCTAssertEqual(inspection["hasAuditLogSheet"], "true")
        XCTAssertEqual(
            inspection["firstOverrideRow"],
            "DW472|MHC-DP|h1|M4DP|M3DP|analyst-judgment|Manual curation from review viewport.|curator|2026-06-04T12:00:00Z"
        )
        XCTAssertEqual(
            inspection["firstAuditRow"],
            "override|DW472|MHC-DP|h1|M4DP|M3DP|analyst-judgment|Manual curation from review viewport.|curator|2026-06-04T12:00:00Z"
        )
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .externalEditSnapshot } == true)
        let imported = try XCTUnwrap(updatedManifest.workbookRevisions?.last)
        let provenancePath = try XCTUnwrap(imported.provenancePath)
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: fixture.bundleURL)
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains("annotations.json"))
        XCTAssertTrue(provenance.contains("update-current-workbook"))
    }

    func testApplyHaplotypeOverridesWritesMatrixAnnotationsToCurrentWorkbook() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "matrix")
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mamu-I*expected",
            sample: "AR3628"
        )
        sidecar.matrixStyles = [
            .init(
                target: target,
                style: .init(
                    fillColor: "#FFF2CC",
                    textColor: "#C00000",
                    borderColor: "#666666",
                    isBold: true,
                    isItalic: true
                ),
                author: "curator",
                timestamp: "2026-06-30T12:00:00Z"
            )
        ]
        sidecar.matrixComments = [
            .init(
                target: target,
                body: "Expected genotype missing from reads.",
                author: "curator",
                timestamp: "2026-06-30T12:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 6_000) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let inspection = try inspectGenericMatrixWorkbook(try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))
        XCTAssertEqual(inspection["hasMatrixAnnotationsSheet"], "true")
        XCTAssertEqual(inspection["matrixAnnotationStyleRow"], "style|cell|MHC-B|Mamu-I*expected|AR3628|#FFF2CC|#C00000|#666666|true|true|curator|2026-06-30T12:00:00Z|")
        XCTAssertEqual(inspection["matrixAnnotationCommentRow"], "comment|cell|MHC-B|Mamu-I*expected|AR3628||||||curator|2026-06-30T12:00:00Z|Expected genotype missing from reads.")
        XCTAssertEqual(inspection["cellFillSuffix"], "FFF2CC")
        XCTAssertEqual(inspection["cellTextColorSuffix"], "C00000")
        XCTAssertEqual(inspection["cellBorderSuffix"], "666666")
        XCTAssertEqual(inspection["cellBold"], "true")
        XCTAssertEqual(inspection["cellItalic"], "true")
        XCTAssertTrue(inspection["cellComment"]?.contains("Expected genotype missing from reads.") == true)
        XCTAssertEqual(inspection["guideMatrixStyles"], "1")
        XCTAssertEqual(inspection["guideMatrixComments"], "1")
    }

    func testImportRevisedWorkbookKeepsPrimaryAndSnapshotsPreviousCurrent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let importedURL = root.appendingPathComponent("collaborator.xlsx")
        try workbookData("collaborator edit").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 1_800) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Collaborator edit")

        let primaryWorkbookURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: fixture.bundleURL)
        let currentWorkbookURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        XCTAssertEqual(try Data(contentsOf: primaryWorkbookURL), workbookData("primary"))
        XCTAssertEqual(try Data(contentsOf: currentWorkbookURL), workbookData("collaborator edit"))
        XCTAssertEqual(updatedManifest.primaryWorkbookPath, fixture.manifest.primaryWorkbookPath)
        XCTAssertEqual(updatedManifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")

        let snapshot = try XCTUnwrap(updatedManifest.workbookRevisions?.first { revision in
            revision.path.hasPrefix("artifacts/workbooks/revisions/")
        })
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(for: snapshot.path, in: fixture.bundleURL)),
            workbookData("current")
        )
        let imported = try XCTUnwrap(updatedManifest.workbookRevisions?.last)
        XCTAssertEqual(imported.role, .imported)
        XCTAssertEqual(imported.path, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(imported.sourceFilename, importedURL.lastPathComponent)
        XCTAssertNotNil(imported.provenancePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ONTGenotypeResultBundle.resolvedURL(
                for: try XCTUnwrap(imported.provenancePath),
                in: fixture.bundleURL
            ).path
        ))
    }

    func testImportRevisedWorkbookPreservesActiveAIHaplotypeRevisionFields() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let aiRevision = ONTGenotypeHaplotypeAnalysisRevision(
            id: "haprev-ai-0001",
            method: .aiRefinement,
            path: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/haplotype-analysis.json",
            predecessorID: nil,
            predecessorPath: fixture.manifest.haplotypeAnalysisPath,
            createdAt: "2026-06-14T18:00:00Z",
            reviewState: .needsReview,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 123,
            provenancePath: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/ai-haplotyping.lungfish-provenance.json",
            provider: "openai",
            model: "gpt-5-mini",
            promptTemplateID: "lungfish.ai-haplotyping.refinement",
            promptTemplateVersion: "2026-06-14.1",
            promptHash: "sha256:\(String(repeating: "b", count: 64))",
            evidenceSnapshotPath: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/evidence-registry.json",
            validationReportPath: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/validation-report.json"
        )
        let manifestWithAIRevision = ONTGenotypeResultBundleManifest(
            schemaVersion: fixture.manifest.schemaVersion,
            kind: fixture.manifest.kind,
            outputName: fixture.manifest.outputName,
            analysisName: fixture.manifest.analysisName,
            primaryWorkbookPath: fixture.manifest.primaryWorkbookPath,
            currentWorkbookPath: fixture.manifest.currentWorkbookPath,
            workbookRevisions: fixture.manifest.workbookRevisions,
            longSummaryCSVPath: fixture.manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: fixture.manifest.sampleSummaryCSVPath,
            statsJSONPath: fixture.manifest.statsJSONPath,
            provenancePath: fixture.manifest.provenancePath,
            haplotypeAnalysisPath: aiRevision.path,
            haplotypeDefinitionSetID: fixture.manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: fixture.manifest.haplotypeAssayID,
            createdAt: fixture.manifest.createdAt,
            activeHaplotypeAnalysisRevisionID: aiRevision.id,
            haplotypeAnalysisRevisions: [aiRevision]
        )
        try ONTGenotypeResultBundle.writeManifest(manifestWithAIRevision, to: fixture.bundleURL)
        let importedURL = root.appendingPathComponent("collaborator.xlsx")
        try workbookData("collaborator edit").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 1_900) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Collaborator edit")
        let persistedManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)

        for manifest in [updatedManifest, persistedManifest] {
            XCTAssertEqual(manifest.haplotypeAnalysisPath, aiRevision.path)
            XCTAssertEqual(manifest.activeHaplotypeAnalysisRevisionID, aiRevision.id)
            XCTAssertEqual(manifest.haplotypeAnalysisRevisions, [aiRevision])
        }
    }

    func testImportMigratesOldPrimaryOnlyBundleBeforeReplacingCurrent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "legacy", includeCurrent: false)
        let importedURL = root.appendingPathComponent("reviewed.xlsx")
        try workbookData("reviewed").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 2_400) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Reviewed")

        XCTAssertEqual(updatedManifest.primaryWorkbookPath, "legacy.xlsx")
        XCTAssertEqual(updatedManifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.primaryWorkbookURL(for: fixture.bundleURL)),
            workbookData("primary")
        )
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)),
            workbookData("reviewed")
        )
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .initialCurrentCopy } == true)
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .imported } == true)
    }

    func testImportRejectsNonXLSXWithoutChangingManifestOrCurrentWorkbook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let invalidURL = root.appendingPathComponent("not-a-workbook.txt")
        try Data("not a workbook".utf8).write(to: invalidURL)
        let originalManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let originalCurrent = try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService().importRevisedWorkbook(
                from: invalidURL,
                into: fixture.bundleURL,
                label: "bad"
            )
        )

        XCTAssertEqual(try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL), originalManifest)
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)),
            originalCurrent
        )
    }

    func testApplyHaplotypeOverridesUsesInjectedPythonExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let fakePythonURL = root.appendingPathComponent("fake-python")
        let invocationLogURL = root.appendingPathComponent("python-argv.txt")
        try """
        #!/bin/sh
        printf '%s\n' "$0" "$@" > "\(invocationLogURL.path)"
        echo "fake python used" >&2
        exit 73
        """.write(to: fakePythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakePythonURL.path
        )

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: fakePythonURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("fake python used"))
        }

        let invocation = try String(contentsOf: invocationLogURL, encoding: .utf8)
        XCTAssertTrue(invocation.hasPrefix(fakePythonURL.path))
        XCTAssertTrue(invocation.contains("apply-current-workbook-overrides.py"))
    }

    func testImportSnapshotsExternalEditBeforeManagedReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try workbookData("manual direct edit").write(to: currentURL)
        let importedURL = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 3_600) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Replacement")

        let externalSnapshot = try XCTUnwrap(updatedManifest.workbookRevisions?.first { revision in
            revision.role == .externalEditSnapshot
                && revision.path.hasPrefix("artifacts/workbooks/revisions/")
        })
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(for: externalSnapshot.path, in: fixture.bundleURL)),
            workbookData("manual direct edit")
        )
        XCTAssertEqual(try Data(contentsOf: currentURL), workbookData("replacement"))
    }

    private func makeBundle(
        in root: URL,
        outputName: String,
        includeCurrent: Bool
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        try workbookData("primary").write(to: primaryWorkbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)

        let currentWorkbookPath: String?
        let revisions: [ONTGenotypeWorkbookRevision]?
        if includeCurrent {
            let currentURL = bundleURL
                .appendingPathComponent("artifacts/workbooks", isDirectory: true)
                .appendingPathComponent("current.xlsx")
            try FileManager.default.createDirectory(
                at: currentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try workbookData("current").write(to: currentURL)
            currentWorkbookPath = "artifacts/workbooks/current.xlsx"
            revisions = [
                ONTGenotypeWorkbookRevision(
                    id: "initial-current-copy",
                    role: .initialCurrentCopy,
                    path: "artifacts/workbooks/current.xlsx",
                    label: "Initial editable workbook",
                    sourceFilename: primaryWorkbookURL.lastPathComponent,
                    createdAt: "2026-06-02T00:00:00Z",
                    user: "tester",
                    predecessorPath: primaryWorkbookURL.lastPathComponent,
                    sha256: try ProvenanceFileHasher.sha256(of: currentURL),
                    sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
                    provenancePath: nil
                )
            ]
        } else {
            currentWorkbookPath = nil
            revisions = nil
        }

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func writeMinimalNativeArtifacts(
        in bundleURL: URL,
        outputName: String
    ) throws -> (genotypeCSV: URL, sampleCSV: URL, statsJSON: URL, provenance: URL) {
        let genotypeCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        SampleA,allele1,1,1
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        SampleA,1,1
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 1,
          "totalAlignments": 1,
          "passedAlignments": 1,
          "retainedUniqueReads": 1,
          "retainedUniquePercentOfTotalReads": 100.0,
          "assignedUniqueRetainedReads": 1,
          "unassignedUniqueRetainedReads": 0
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)
        return (genotypeCSVURL, sampleCSVURL, statsJSONURL, provenanceURL)
    }

    private func makeMCMWorkbookBundle(
        in root: URL,
        outputName: String
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        let currentURL = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMCMWorkbook(at: primaryWorkbookURL)
        try FileManager.default.copyItem(at: primaryWorkbookURL, to: currentURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)
        let currentRevision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: "artifacts/workbooks/current.xlsx",
            label: "Initial editable workbook",
            sourceFilename: primaryWorkbookURL.lastPathComponent,
            createdAt: "2026-06-02T00:00:00Z",
            user: "tester",
            predecessorPath: primaryWorkbookURL.lastPathComponent,
            sha256: try ProvenanceFileHasher.sha256(of: currentURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
            provenancePath: nil
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [currentRevision],
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func makeGenericMatrixWorkbookBundle(
        in root: URL,
        outputName: String
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        let currentURL = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalGenericMatrixWorkbook(at: primaryWorkbookURL)
        try FileManager.default.copyItem(at: primaryWorkbookURL, to: currentURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)
        let currentRevision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: "artifacts/workbooks/current.xlsx",
            label: "Initial editable workbook",
            sourceFilename: primaryWorkbookURL.lastPathComponent,
            createdAt: "2026-06-30T00:00:00Z",
            user: "tester",
            predecessorPath: primaryWorkbookURL.lastPathComponent,
            sha256: try ProvenanceFileHasher.sha256(of: currentURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
            provenancePath: nil
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [currentRevision],
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func makeMinimalGenericMatrixWorkbook(at url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = Workbook()
ws = wb.active
ws.title = "matrix"
ws.append(["Animal ID", None, None, "AR3628"])
ws.append(["GS ID", "Total", "Average", "AR3628"])
ws.append(["Filtered exact-match read count", None, None, 12])
ws.append([])
ws.append(["Comments", "Subtotal", "# Obs.", None])
ws.append(["Genotype", "Total", "# Obs.", "AR3628"])
ws.append(["Mamu-I*expected", 5, 1, 5])
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func makeMinimalMCMWorkbook(at url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = Workbook()
guide = wb.active
guide.title = "Interpretation Guide"
guide.append(["Field", "Interpretation"])
guide.append(["Haplotype min reads", "10"])

abbr = wb.create_sheet("Abbreviated Haplotypes")
headers = [
    "Client ID", "GS ID", "Mapped Read Count", "Haplotype 1", "Haplotype 2", None,
    "MHC-A Haplotype 1", "MHC-B Haplotype 1", "MHC-DRB Haplotype 1", "MHC-DQA/B Haplotype 1", "MHC-DPA/B Haplotype 1",
    None,
    "MHC-A Haplotype 2", "MHC-B Haplotype 2", "MHC-DRB Haplotype 2", "MHC-DQA/B Haplotype 2", "MHC-DPA/B Haplotype 2",
    "Comments",
]
abbr.append(headers)
abbr.append(["DW472", "DW472", 100, "M4", "M7", None, "M4A", "M4B", None, "M4DQ", "M4DP", None, "M7A", "M7B", None, "M7DQ", "M7DP", None])

full = wb.create_sheet("Full Sequencing Results 1")
full.cell(1, 1).value = "Client ID"
full.cell(1, 4).value = "DW472"
full.cell(2, 1).value = "GS ID"
full.cell(2, 4).value = "DW472"
full.cell(3, 1).value = "Mapped Read Count"
full.cell(3, 4).value = 100
for row, label in enumerate([
    "MHC-A Haplotype 1", "MHC-A Haplotype 2",
    "MHC-B Haplotype 1", "MHC-B Haplotype 2",
    "MHC-DRB Haplotype 1", "MHC-DRB Haplotype 2",
    "MHC-DQA Haplotype 1", "MHC-DQA Haplotype 2",
    "MHC-DQB Haplotype 1", "MHC-DQB Haplotype 2",
    "MHC-DPA Haplotype 1", "MHC-DPA Haplotype 2",
    "MHC-DPB Haplotype 1", "MHC-DPB Haplotype 2",
    "Comments",
], start=4):
    full.cell(row, 1).value = label
    full.cell(row, 4).value = "" if "DRB" in label else "old"

# Legacy start-only managed block followed by analyst-authored content. Updates
# must migrate only the generated rows and preserve everything after them.
full.append(["LGE MHC Candidate Alleles"])
full.append(["Provisional Name", "Stable Cluster ID", "Locus", "Classification", "Support Class", "sample-a"])
full.append(["Mafa-A1*001:01_1nt_nov", "legacy-cluster", "Mafa-A1", "novel", "singleton", 3])
full.append(["Analyst_A1_1nt_nov", "analyst-candidate-shaped", "Mafa-A1", "novel", "singleton", "=1+1"])
full.append(["Analyst Calculation", None, None, "=SUM(D1:D3)"])
full.cell(full.max_row, 1).fill = PatternFill(fill_type="solid", fgColor="FF123456")

legacy_headers = [
    "unmatched_sequence_id", "match_source", "closest_match_id", "closest_reference", "closest_reference_name",
    "match_class", "nucleotides_different", "snp_differences", "indel_bases", "aligned_bases", "score",
    "percent_identity", "query_coverage", "evalue", "bitscore",
]
stale = ["legacy", "legacy-blast", "Mafa-A1*018:01:01:01_0SNP", "stale-ref", "stale-ref-name", "exact", 99, 99, 99, 99, 99, 12.5, 9.5, "1e-20", 777]
for name in ["Unmatched Clusters", "Unmatched Shared Pivot", "MHC-like Unmatched Clusters", "MHC-like Unmatched Pivot"]:
    legacy = wb.create_sheet(name)
    legacy.append(legacy_headers)
    candidate_row = list(stale)
    candidate_row[0] = "cluster-1"
    legacy.append(candidate_row)
    unnameable_row = list(stale)
    unnameable_row[0] = "cluster-u"
    legacy.append(unnameable_row)

custom = wb.create_sheet("Custom Sort")
custom.append(headers)
custom.append(["MHC heterozygous  MCM animals"] + [None for _ in headers[1:]])
custom.append(["DW472", "DW472", 100, "M4", "M7", None, "M4A", "M4B", None, "M4DQ", "M4DP", None, "M7A", "M7B", None, "M7DQ", "M7DP", None])
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func inspectMCMWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def header_map(ws):
    values = {}
    for col in range(1, ws.max_column + 1):
        value = ws.cell(1, col).value
        if value:
            values[str(value)] = col
    return values

def sample_row(ws, sample):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == sample:
            return row
    return None

def sample_col(ws, sample):
    for col in range(1, ws.max_column + 1):
        for row in range(1, min(ws.max_row, 4) + 1):
            if ws.cell(row, col).value == sample:
                return col
    return None

def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

def guide_value(label):
    guide = wb["Interpretation Guide"]
    row = row_for(guide, label)
    return None if row is None else guide.cell(row, 2).value

abbr = wb["Abbreviated Haplotypes"]
custom = wb["Custom Sort"]
full = wb["Full Sequencing Results 1"]
abbr_headers = header_map(abbr)
custom_headers = header_map(custom)
abbr_row = sample_row(abbr, "DW472")
custom_row = sample_row(custom, "DW472")
full_col = sample_col(full, "DW472")

def text(value):
    return "" if value is None else str(value)

def row_values(sheet, row_index, col_count):
    if sheet not in wb.sheetnames or wb[sheet].max_row < row_index:
        return ""
    ws = wb[sheet]
    return "|".join(text(ws.cell(row_index, col).value) for col in range(1, col_count + 1))

payload = {
    "hasOverridesSheet": str("Overrides" in wb.sheetnames).lower(),
    "hasAuditLogSheet": str("Audit Log" in wb.sheetnames).lower(),
    "abbreviatedDPHaplotype1": text(abbr.cell(abbr_row, abbr_headers["MHC-DPA/B Haplotype 1"]).value),
    "abbreviatedDPHaplotype2": text(abbr.cell(abbr_row, abbr_headers["MHC-DPA/B Haplotype 2"]).value),
    "abbreviatedDRBHaplotype1": text(abbr.cell(abbr_row, abbr_headers["MHC-DRB Haplotype 1"]).value),
    "abbreviatedDRBHaplotype2": text(abbr.cell(abbr_row, abbr_headers["MHC-DRB Haplotype 2"]).value),
    "abbreviatedComments": text(abbr.cell(abbr_row, abbr_headers["Comments"]).value),
    "customDPHaplotype1": text(custom.cell(custom_row, custom_headers["MHC-DPA/B Haplotype 1"]).value),
    "fullDPAHaplotype1": text(full.cell(row_for(full, "MHC-DPA Haplotype 1"), full_col).value),
    "fullDPBHaplotype2": text(full.cell(row_for(full, "MHC-DPB Haplotype 2"), full_col).value),
    "fullDRBHaplotype1": text(full.cell(row_for(full, "MHC-DRB Haplotype 1"), full_col).value),
    "fullDRBHaplotype2": text(full.cell(row_for(full, "MHC-DRB Haplotype 2"), full_col).value),
    "fullComments": text(full.cell(row_for(full, "Comments"), full_col).value),
    "guideWorkbookUpdateSource": guide_value("Workbook update source"),
    "guideUpdatedHaplotypeCalls": text(guide_value("Workbook updated haplotype calls")),
    "guideAuditEntries": text(guide_value("Workbook update audit entries")),
    "firstOverrideRow": row_values("Overrides", 2, 9),
    "firstAuditRow": row_values("Audit Log", 2, 10),
}

legacy_fields = [
    "match_source", "closest_match_id", "closest_reference", "closest_reference_name", "match_class",
    "nucleotides_different", "snp_differences", "indel_bases", "aligned_bases", "score",
    "percent_identity", "query_coverage", "evalue", "bitscore",
]
candidate_legacy = []
unnameable_legacy = []
for name in ["Unmatched Clusters", "Unmatched Shared Pivot", "MHC-like Unmatched Clusters", "MHC-like Unmatched Pivot"]:
    if name not in wb.sheetnames:
        continue
    ws = wb[name]
    headers = [text(cell.value) for cell in ws[1]]
    candidate_legacy.append("|".join(text(ws.cell(2, headers.index(field) + 1).value) for field in legacy_fields))
    unnameable_legacy.append("|".join(text(ws.cell(3, headers.index(field) + 1).value) for field in legacy_fields))
payload["legacyCandidateRows"] = "||".join(candidate_legacy)
payload["legacyUnnameableRows"] = "||".join(unnameable_legacy)
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }

    private func inspectGenericMatrixWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["matrix"]
cell = ws["D7"]

def text(value):
    return "" if value is None else str(value)

def color_suffix(color):
    value = getattr(color, "rgb", None)
    if not value:
        return ""
    return str(value)[-6:]

def row_values(sheet, row_index, col_count):
    if sheet not in wb.sheetnames or wb[sheet].max_row < row_index:
        return ""
    ws = wb[sheet]
    return "|".join(text(ws.cell(row_index, col).value) for col in range(1, col_count + 1))

def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

def guide_value(label):
    guide = wb["Interpretation Guide"]
    row = row_for(guide, label)
    return "" if row is None else text(guide.cell(row, 2).value)

payload = {
    "hasMatrixAnnotationsSheet": str("Matrix Annotations" in wb.sheetnames).lower(),
    "matrixAnnotationStyleRow": row_values("Matrix Annotations", 2, 13),
    "matrixAnnotationCommentRow": row_values("Matrix Annotations", 3, 13),
    "cellFillSuffix": color_suffix(cell.fill.fgColor),
    "cellTextColorSuffix": color_suffix(cell.font.color),
    "cellBorderSuffix": color_suffix(cell.border.left.color),
    "cellBold": str(bool(cell.font.bold)).lower(),
    "cellItalic": str(bool(cell.font.italic)).lower(),
    "cellComment": "" if cell.comment is None else cell.comment.text,
    "guideMatrixStyles": guide_value("Workbook update matrix styles"),
    "guideMatrixComments": guide_value("Workbook update matrix comments"),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }

    private func installCandidateArtifacts(in bundleURL: URL) throws {
        let directory = bundleURL.appendingPathComponent("artifacts/mhc-candidates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidateFASTAURL = directory.appendingPathComponent("candidate-alleles.fasta")
        let unnameableFASTAURL = directory.appendingPathComponent("unnameable-clusters.fasta")
        let bases = Array("ACGT")
        try (1...4).map { ">cluster-\($0)\n" + String(repeating: bases[$0 % 4], count: 40) }
            .joined(separator: "\n").appending("\n")
            .write(to: candidateFASTAURL, atomically: true, encoding: .utf8)
        try ">cluster-u\n".appending(String(repeating: "N", count: 40)).appending("\n")
            .write(to: unnameableFASTAURL, atomically: true, encoding: .utf8)
        let candidateFASTA = try artifactReference(candidateFASTAURL, relativeTo: bundleURL)
        let unnameableFASTA = try artifactReference(unnameableFASTAURL, relativeTo: bundleURL)
        let selected = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "candidate-query",
            referenceName: "reference-allele",
            readGroupID: nil,
            referenceStart: 10,
            cigar: "1000M"
        )
        let specs: [(String, String, ONTMHCCandidateClassification, ONTMHCCandidateSupportClass, Int)] = [
            ("cluster-1", "Mafa-A1*018:01:01:01_5nt_nov", .novel, .shared, 5),
            ("cluster-2", "Mafa-A1*018:01:01:01_5nt_nov", .novel, .singleton, 5),
            ("cluster-3", "Mafa-B*001:01_ext", .extension, .shared, 0),
            ("cluster-4", "Mafa-B*002:01_ext", .extension, .singleton, 0),
        ]
        let candidates = specs.map { id, name, classification, support, snps in
            ONTMHCCandidateRecord(
                stableClusterID: id,
                provisionalName: name,
                locus: name.hasPrefix("Mafa-A") ? "Mafa-A1" : "Mafa-B",
                classification: classification,
                supportClass: support,
                closestReferenceName: classification == .novel ? "Mafa-A1*018:01:01:01" : String(name.dropLast(4)),
                closestReferenceClass: classification == .novel ? .genomicDNA : .cDNA,
                snpCount: snps,
                insertedBases: 0,
                deletedBases: classification == .extension ? 200 : 0,
                longGapBases: classification == .extension ? 200 : 0,
                comparableBases: 1_000,
                shorterCoverage: 1,
                identity: 1,
                mappingQuality: 60,
                alignmentScore: 1_000,
                independentSampleCount: support == .shared ? 2 : 1,
                occurrenceCount: support == .shared ? 2 : 1,
                totalClusterReads: id == "cluster-1" ? 10 : (support == .shared ? 6 : 4),
                supportingSampleIDs: support == .shared ? ["sample-a", "sample-b"] : ["sample-a"],
                fastaRecordID: id,
                sequenceSHA256: String(repeating: String(id.last!), count: 64),
                selectedEvidence: ONTMHCEvidenceLocator(
                    bamPath: selected.bamPath,
                    queryName: id,
                    referenceName: selected.referenceName,
                    readGroupID: nil,
                    referenceStart: selected.referenceStart,
                    cigar: selected.cigar
                )
            )
        }
        var observations: [ONTMHCCandidateObservation] = []
        for candidate in candidates {
            observations.append(candidateObservation(candidate.stableClusterID, sample: "sample-a", reads: candidate.stableClusterID == "cluster-1" ? 7 : 4))
            if candidate.supportClass == .shared {
                observations.append(candidateObservation(candidate.stableClusterID, sample: "sample-b", reads: candidate.stableClusterID == "cluster-1" ? 3 : 2))
            }
        }
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: candidateFASTA,
            candidates: candidates.reversed(),
            observations: observations.reversed()
        )
        let unnameable = ONTMHCUnnameableRecord(
            stableClusterID: "cluster-u",
            reason: .unresolvedLocus,
            failedMetrics: ["identity": 0.7],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["sample-a"],
            fastaRecordID: "cluster-u",
            sequenceSHA256: String(repeating: "f", count: 64),
            evidence: [
                .init(bamPath: "artifacts/alignments/z.bam", queryName: "cluster-u-z", referenceName: "ref-z", readGroupID: "sample-z", referenceStart: 90, cigar: "900M"),
                .init(bamPath: "artifacts/alignments/a.bam", queryName: "cluster-u-a", referenceName: "ref-a", readGroupID: "sample-a", referenceStart: 10, cigar: "800M"),
            ]
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: unnameableFASTA,
            clusters: [unnameable],
            observations: [candidateObservation("cluster-u", sample: "sample-a", reads: 4)]
        )
        let candidateJSONURL = directory.appendingPathComponent("candidate-alleles.json")
        let unnameableJSONURL = directory.appendingPathComponent("unnameable-clusters.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(candidateDocument).write(to: candidateJSONURL, options: .atomic)
        try encoder.encode(unnameableDocument).write(to: unnameableJSONURL, options: .atomic)
        let artifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: 1,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: try artifactReference(candidateJSONURL, relativeTo: bundleURL),
            candidateFASTA: candidateFASTA,
            unnameableJSON: try artifactReference(unnameableJSONURL, relativeTo: bundleURL),
            unnameableFASTA: unnameableFASTA
        )
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        let updated = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            mhcCandidateArtifacts: artifacts
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundleURL)
    }

    private func artifactReference(_ url: URL, relativeTo bundleURL: URL) throws -> ONTMHCArtifactReference {
        ONTMHCArtifactReference(
            path: String(url.standardizedFileURL.path.dropFirst(bundleURL.standardizedFileURL.path.count + 1)),
            sha256: try ProvenanceFileHasher.sha256(of: url),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
        )
    }

    private func candidateObservation(_ cluster: String, sample: String, reads: Int) -> ONTMHCCandidateObservation {
        ONTMHCCandidateObservation(
            stableClusterID: cluster,
            sampleID: sample,
            readGroupID: sample,
            sourceClusterIDs: ["source-\(cluster)-\(sample)"],
            sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
            aggregatedSampleReadCount: reads,
            evidence: []
        )
    }

    private func inspectCandidateWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def text(value):
    return "" if value is None else str(value)

def argb(cell):
    value = getattr(cell.fill.fgColor, "rgb", None)
    return text(value) or "00000000"

candidate = wb["Candidate Alleles"]
unnameable = wb["Un-nameable Clusters"]
candidate_ids = [text(candidate.cell(row, 1).value) for row in range(2, candidate.max_row + 1)]
candidate_names = [text(candidate.cell(row, 2).value) for row in range(2, candidate.max_row + 1)]
payload = {
    "candidateIDs": "|".join(candidate_ids),
    "candidateNames": "|".join(candidate_names),
    "candidateNameFills": "|".join(argb(candidate.cell(row, 2)) for row in range(2, candidate.max_row + 1)),
    "candidateIDFills": "|".join(argb(candidate.cell(row, 1)) for row in range(2, candidate.max_row + 1)),
    "unnameableIDs": "|".join(text(unnameable.cell(row, 1).value) for row in range(2, unnameable.max_row + 1)),
    "unnameableQueries": "|".join(text(unnameable.cell(row, 14).value) for row in range(2, unnameable.max_row + 1)),
    "allText": "|".join(text(cell.value) for ws in wb.worksheets for row in ws.iter_rows() for cell in row),
}
if "Full Sequencing Results 1" in wb.sheetnames:
    ws = wb["Full Sequencing Results 1"]
    begin_label = "LGE MHC Candidate Alleles [BEGIN]"
    end_label = "LGE MHC Candidate Alleles [END]"
    marker = next((row for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == begin_label), None)
    end = next((row for row in range((marker or 0) + 1, ws.max_row + 1) if text(ws.cell(row, 1).value) == end_label), None)
    rows = list(range(marker + 2, end)) if marker and end else []
    payload["editableCandidateCount"] = str(len(rows))
    payload["editableNameFills"] = "|".join(argb(ws.cell(row, 1)) for row in rows)
    analyst = next((row for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == "Analyst Calculation"), None)
    payload["analystFormula"] = text(ws.cell(analyst, 4).value) if analyst else ""
    payload["analystFill"] = argb(ws.cell(analyst, 1)) if analyst else ""
    analyst_candidate = next((row for row in range(1, ws.max_row + 1) if text(ws.cell(row, 2).value) == "analyst-candidate-shaped"), None)
    payload["candidateShapedAnalystFormula"] = text(ws.cell(analyst_candidate, 6).value) if analyst_candidate else ""
    payload["managedBeginCount"] = str(sum(1 for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == begin_label))
    payload["managedEndCount"] = str(sum(1 for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == end_label))
else:
    payload["editableCandidateCount"] = "0"
    payload["editableNameFills"] = ""
    payload["analystFormula"] = ""
    payload["analystFill"] = ""
    payload["candidateShapedAnalystFormula"] = ""
    payload["managedBeginCount"] = "0"
    payload["managedEndCount"] = "0"
if "Unified Genotype Pivot" in wb.sheetnames:
    ws = wb["Unified Genotype Pivot"]
    rows = [row for row in range(2, ws.max_row + 1) if text(ws.cell(row, 1).value).startswith("candidate-")]
    payload["unifiedCandidateCount"] = str(len(rows))
    payload["unifiedCandidateIDs"] = "|".join(text(ws.cell(row, 4).value) for row in rows)
else:
    payload["unifiedCandidateCount"] = "0"
    payload["unifiedCandidateIDs"] = ""
legacy_fields = [
    "match_source", "closest_match_id", "closest_reference", "closest_reference_name", "match_class",
    "nucleotides_different", "snp_differences", "indel_bases", "aligned_bases", "score",
    "percent_identity", "query_coverage", "evalue", "bitscore",
]
candidate_legacy = []
unnameable_legacy = []
for name in ["Unmatched Clusters", "Unmatched Shared Pivot", "MHC-like Unmatched Clusters", "MHC-like Unmatched Pivot"]:
    if name not in wb.sheetnames:
        continue
    ws = wb[name]
    headers = [text(cell.value) for cell in ws[1]]
    candidate_legacy.append("|".join(text(ws.cell(2, headers.index(field) + 1).value) for field in legacy_fields))
    unnameable_legacy.append("|".join(text(ws.cell(3, headers.index(field) + 1).value) for field in legacy_fields))
payload["legacyCandidateRows"] = "||".join(candidate_legacy)
payload["legacyUnnameableRows"] = "||".join(unnameable_legacy)
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    private func pythonCanImportOpenpyxl() -> Bool {
        (try? runPython(["-c", "import openpyxl"])) != nil
    }

    private var testPythonExecutableURL: URL? {
        let bundled = URL(fileURLWithPath: "/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    private func runPython(_ arguments: [String]) throws -> String {
        let process = Process()
        if let testPythonExecutableURL {
            process.executableURL = testPythonExecutableURL
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + arguments
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GenotypeWorkbookRevisionServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err]
            )
        }
        return out
    }

    private static func runPythonStatic(
        _ arguments: [String],
        executableURL: URL?
    ) throws -> String {
        let process = Process()
        if let executableURL {
            process.executableURL = executableURL
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + arguments
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GenotypeWorkbookRevisionServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText]
            )
        }
        return output
    }

    private func directorySnapshot(_ directoryURL: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [:] }
        var snapshot: [String: Data] = [:]
        let rootCount = directoryURL.pathComponents.count
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil))
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            snapshot[url.pathComponents.dropFirst(rootCount).joined(separator: "/")] = try Data(contentsOf: url)
        }
        return snapshot
    }

    private func chmodTreeReadOnly(_ root: URL) throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var directories = [root]
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                directories.append(url)
            } else {
                XCTAssertEqual(chmod(url.path, S_IRUSR), 0)
            }
        }
        for directory in directories.reversed() {
            XCTAssertEqual(chmod(directory.path, S_IRUSR | S_IXUSR), 0)
        }
    }

    private func chmodTreeWritable(_ root: URL) throws {
        _ = chmod(root.path, S_IRWXU)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        while let url = enumerator.nextObject() as? URL {
            _ = chmod(url.path, S_IRWXU)
        }
    }

    private func workbookData(_ label: String) -> Data {
        var data = Data([0x50, 0x4b, 0x03, 0x04])
        data.append(Data(label.utf8))
        return data
    }

    private func bundleSnapshot(_ bundleURL: URL) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        let rootPath = bundleURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw NSError(domain: "GenotypeWorkbookRevisionServiceTests", code: 2)
        }
        while let url = enumerator.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            let relative = String(path.dropFirst(rootPath.count + 1))
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                snapshot[relative] = "directory"
            case S_IFREG:
                snapshot[relative] = "file:\(info.st_size):\(try ProvenanceFileHasher.sha256(of: url))"
            case S_IFLNK:
                snapshot[relative] = "symlink:\(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))"
            default:
                snapshot[relative] = "special:\(info.st_mode & S_IFMT)"
            }
        }
        return snapshot
    }

    private func interruptWorkbookPublicationAfterExchange(
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        root: URL
    ) throws -> URL {
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        return markerURL
    }

    private func markerObject(at markerURL: URL) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
    }

    private func writeMarkerObject(_ object: [String: Any], to markerURL: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: markerURL, options: .atomic)
    }

    private func writeManifestWithoutCurrent(in bundleURL: URL) throws {
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        let updated = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: nil,
            workbookRevisions: nil,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            mhcCandidateArtifacts: manifest.mhcCandidateArtifacts
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundleURL)
    }

    private func assertNoWorkbookUpdateStage(for bundleURL: URL) throws {
        let parent = bundleURL.deletingLastPathComponent()
        let prefix = ".\(bundleURL.lastPathComponent).workbook-update-"
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .contains(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".staging") })
        )
    }

    private func serviceThatFailsIfStagingBegins() -> GenotypeWorkbookRevisionService {
        GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            publicationFailureInjector: { checkpoint in
                if checkpoint == "after-stage-created" {
                    throw NSError(domain: "UnexpectedWorkbookUpdateStaging", code: 1)
                }
            }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookRevisionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class SendableFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt32?

    var value: UInt32? { lock.withLock { stored } }
    func set(_ value: UInt32) { lock.withLock { stored = value } }
}
