import Darwin
import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeWorkbookRevisionServiceTests: XCTestCase {
    func testPublicWorkbookRevisionOutcomeAndLegacyWrapperMatchCommittedManifest() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let outcomeRoot = try temporaryDirectory()
        let legacyRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: outcomeRoot)
            try? FileManager.default.removeItem(at: legacyRoot)
        }
        let outcomeFixture = try makeMCMWorkbookBundle(
            in: outcomeRoot,
            outputName: "public-outcome"
        )
        let legacyFixture = try makeMCMWorkbookBundle(
            in: legacyRoot,
            outputName: "legacy-outcome"
        )
        let outcomeService = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_400) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL:
                outcomeRoot.appendingPathComponent(
                    "attestations",
                    isDirectory: true
                )
        )

        let outcome: GenotypeWorkbookRevisionOutcome =
            try outcomeService.applyHaplotypeOverridesWithOutcome(
                [],
                annotationSidecarURL: nil,
                into: outcomeFixture.bundleURL
            )
        let legacyManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_400) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL:
                legacyRoot.appendingPathComponent(
                    "attestations",
                    isDirectory: true
                )
        ).applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: legacyFixture.bundleURL
        )

        XCTAssertNil(outcome.cleanupPendingWarning)
        XCTAssertEqual(
            outcome.manifest,
            try ONTGenotypeResultBundle.loadManifest(
                from: outcomeFixture.bundleURL
            )
        )
        XCTAssertEqual(
            legacyManifest,
            try ONTGenotypeResultBundle.loadManifest(
                from: legacyFixture.bundleURL
            )
        )
    }

    func testCommittedCleanupFailureReturnsSuccessWarningWithoutSecondRetiredGeneration()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "committed-cleanup-warning"
        )
        let beforeRevisionCount = fixture.manifest.workbookRevisions?.count ?? 0
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )

        let outcome = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: attestationRoot,
            workbookCleanupFailureInjector: { checkpoint in
                guard checkpoint == "during-workbook-cleanup-traversal" else {
                    return
                }
                throw NSError(
                    domain: "InjectedCommittedCleanupFailure",
                    code: 5
                )
            }
        ).applyHaplotypeOverridesWithOutcome(
            [
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: "MHC-DP",
                    haplotype1: "Latest-DP-1",
                    haplotype2: "Latest-DP-2",
                    status: "called",
                    notes: "latest assignments"
                ),
            ],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        XCTAssertEqual(
            outcome.cleanupPendingWarning,
            "Workbook updated; retired-generation cleanup pending."
        )
        XCTAssertEqual(
            outcome.manifest,
            try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        )
        XCTAssertGreaterThan(
            outcome.manifest.workbookRevisions?.count ?? 0,
            beforeRevisionCount
        )
        let pending = try workbookCleanupArtifacts(in: root)
        XCTAssertEqual(
            pending.filter {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-cleanup-pending-"
                )
            }.count,
            1
        )
        XCTAssertEqual(
            pending.filter {
                $0.lastPathComponent.contains(".workbook-cleanup-state-")
            }.count,
            1
        )
        let inspection = try inspectMCMWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(
                for: fixture.bundleURL
            )
        )
        XCTAssertEqual(inspection["abbreviatedDPHaplotype1"], "Latest-DP-1")
        XCTAssertEqual(inspection["abbreviatedDPHaplotype2"], "Latest-DP-2")
    }

    func testCommittedCleanupPreparationFailureReturnsSuccessWarningAndRemainsRecoverable()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "committed-cleanup-preparation-warning"
        )
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )

        let outcome = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: attestationRoot,
            workbookCleanupFailureInjector: { checkpoint in
                guard checkpoint
                    == "after-workbook-cleanup-detach-hard-stop" else {
                    return
                }
                throw NSError(
                    domain: "InjectedCommittedCleanupPreparationFailure",
                    code: 5
                )
            }
        ).applyHaplotypeOverridesWithOutcome(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        XCTAssertEqual(
            outcome.cleanupPendingWarning,
            "Workbook updated; retired-generation cleanup pending."
        )
        XCTAssertEqual(
            outcome.manifest,
            try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        )
        XCTAssertTrue(
            try workbookCleanupArtifacts(in: root).contains {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-cleanup-pending-"
                )
            }
        )

        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: fixture.bundleURL,
            attestationRootURL: attestationRoot
        )
        XCTAssertNoThrow(
            try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        )
        try assertNoRetiredWorkbookGeneration(in: root)
    }

    func testLegacyManifestWrapperReturnsCommittedManifestWhenCleanupRemainsPending()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "legacy-cleanup-warning"
        )

        let returned = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "attestations",
                isDirectory: true
            ),
            workbookCleanupFailureInjector: { checkpoint in
                guard checkpoint == "during-workbook-cleanup-traversal" else {
                    return
                }
                throw NSError(
                    domain: "InjectedLegacyCommittedCleanupFailure",
                    code: 5
                )
            }
        ).applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        XCTAssertEqual(
            returned,
            try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        )
        XCTAssertTrue(
            try workbookCleanupArtifacts(in: root).contains {
                $0.lastPathComponent.contains(".workbook-cleanup-state-")
            }
        )
    }

    func testPreflightCleanupFailureBlocksWithoutCreatingWorkbookGeneration() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "preflight-cleanup-block"
        )
        paused.lock.release()
        defer { try? FileManager.default.removeItem(at: paused.root) }
        let before = try ONTGenotypeResultBundle.loadManifest(
            from: paused.fixture.bundleURL
        )
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                workbookAttestationRootURL: paused.attestationRoot,
                workbookCleanupFailureInjector: { checkpoint in
                    guard checkpoint
                        == "during-workbook-cleanup-traversal" else {
                        return
                    }
                    throw NSError(
                        domain: "InjectedPreflightCleanupFailure",
                        code: 5
                    )
                }
            ).applyHaplotypeOverridesWithOutcome(
                [],
                annotationSidecarURL: nil,
                into: paused.fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "The existing workbook is valid, but this new update was not applied because a prior retired generation could not be cleaned up safely."
                ),
                error.localizedDescription
            )
        }
        XCTAssertEqual(
            try ONTGenotypeResultBundle.loadManifest(
                from: paused.fixture.bundleURL
            ),
            before
        )
        XCTAssertEqual(
            try workbookCleanupArtifacts(in: paused.root).filter {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-cleanup-pending-"
                )
            }.count,
            1
        )
        try assertNoWorkbookUpdateStage(
            for: paused.fixture.bundleURL
        )
    }

    func testCleanupPendingWarningPersistenceFailureAfterCommitIsSuccessWarning()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "warning-persistence-failure"
        )

        let outcome = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "attestations",
                isDirectory: true
            ),
            workbookCleanupFailureInjector: { checkpoint in
                if checkpoint == "during-workbook-cleanup-traversal" {
                    throw NSError(
                        domain: "InjectedCommittedCleanupFailure",
                        code: 5
                    )
                }
                if checkpoint == "before-workbook-cleanup-warning-write" {
                    throw NSError(
                        domain: "InjectedWarningPersistenceFailure",
                        code: 17
                    )
                }
            }
        ).applyHaplotypeOverridesWithOutcome(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        XCTAssertEqual(
            outcome.cleanupPendingWarning,
            "Workbook updated; retired-generation cleanup pending."
        )
        XCTAssertEqual(
            outcome.manifest,
            try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        )
        XCTAssertTrue(
            try workbookCleanupArtifacts(in: root).contains {
                $0.lastPathComponent.contains(".workbook-cleanup-state-")
            }
        )
    }

    func testSchemaThreeCleanupPendingRecoveryFinishesThenPublishesLatestAssignments()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "schema-three-recovery"
        )
        paused.lock.release()
        defer { try? FileManager.default.removeItem(at: paused.root) }
        let stateURL = try workbookCleanupStateURL(in: paused.root)
        let stateObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(stateObject["schemaVersion"] as? Int, 3)

        let outcome = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: paused.attestationRoot
        ).applyHaplotypeOverridesWithOutcome(
            [
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: "MHC-DP",
                    haplotype1: "Recovered-Latest-DP-1",
                    haplotype2: "Recovered-Latest-DP-2",
                    status: "called",
                    notes: "latest after cleanup recovery"
                ),
            ],
            annotationSidecarURL: nil,
            into: paused.fixture.bundleURL
        )

        XCTAssertNil(outcome.cleanupPendingWarning)
        let inspection = try inspectMCMWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(
                for: paused.fixture.bundleURL
            )
        )
        XCTAssertEqual(
            inspection["abbreviatedDPHaplotype1"],
            "Recovered-Latest-DP-1"
        )
        XCTAssertEqual(
            inspection["abbreviatedDPHaplotype2"],
            "Recovered-Latest-DP-2"
        )
        XCTAssertTrue(
            try workbookRecoveryReceiptActions(in: paused.root).contains(
                "finished-committed-cleanup"
            )
        )
        try assertNoRetiredWorkbookGeneration(in: paused.root)
    }

    func testRecoveryConvergesBeforeNewGenerationAndAcquiresPublicationLockOnlyOnce()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "single-lock-recovery"
        )
        paused.lock.release()
        defer { try? FileManager.default.removeItem(at: paused.root) }
        let acquisitions = WorkbookPublicationLockAcquisitionCounter()

        let outcome = try GenotypeWorkbookRevisionService(
            testingWorkbookPublicationLockAcquirer: { bundleURL in
                acquisitions.increment()
                return try ONTGenotypeBundlePublicationLock.acquire(
                    for: bundleURL
                )
            },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: paused.attestationRoot
        ).applyHaplotypeOverridesWithOutcome(
            [],
            annotationSidecarURL: nil,
            into: paused.fixture.bundleURL
        )

        XCTAssertNil(outcome.cleanupPendingWarning)
        XCTAssertEqual(acquisitions.value, 1)
        XCTAssertTrue(
            try workbookRecoveryReceiptActions(in: paused.root).contains(
                "finished-committed-cleanup"
            )
        )
        try assertNoRetiredWorkbookGeneration(in: paused.root)
    }

    func testExplicitWorkbookUpdateAcceptsWriterShapedSchemaV4UnnameableIdentity() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "schema-v4-update")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 4)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let beforeScientificArtifacts = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let evidenceURL = ONTGenotypeResultBundle.resolvedURL(
            for: beforeScientificArtifacts.primaryWorkbookPath,
            in: fixture.bundleURL
        )
        let evidenceReference = ONTMHCArtifactReference(
            path: beforeScientificArtifacts.primaryWorkbookPath,
            sha256: try ProvenanceFileHasher.sha256(of: evidenceURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: evidenceURL))
        )
        let alignmentArtifacts = ONTGenotypeAlignmentArtifactManifest(
            genotypingEvidence: ONTMHCBAMArtifactPair(
                bam: evidenceReference,
                bai: evidenceReference
            ),
            reciprocalEvidence: nil
        )
        let provisionalArtifacts = ONTGenotypeProvisionalExon2ArtifactManifest(
            schemaVersion: 1,
            catalogJSON: evidenceReference,
            sequencesFASTA: evidenceReference
        )
        try ONTGenotypeResultBundle.writeManifest(
            ONTGenotypeResultBundleManifest(
                schemaVersion: beforeScientificArtifacts.schemaVersion,
                kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
                workflowKind: .fullLengthONTMHCGenotype,
                workflowMode: .genotypeOnly,
                outputName: beforeScientificArtifacts.outputName,
                analysisName: beforeScientificArtifacts.analysisName,
                primaryWorkbookPath: beforeScientificArtifacts.primaryWorkbookPath,
                currentWorkbookPath: beforeScientificArtifacts.currentWorkbookPath,
                workbookRevisions: beforeScientificArtifacts.workbookRevisions,
                longSummaryCSVPath: beforeScientificArtifacts.longSummaryCSVPath,
                sampleSummaryCSVPath: beforeScientificArtifacts.sampleSummaryCSVPath,
                statsJSONPath: beforeScientificArtifacts.statsJSONPath,
                provenancePath: beforeScientificArtifacts.provenancePath,
                mhcCandidateArtifacts: beforeScientificArtifacts.mhcCandidateArtifacts,
                mhcReferenceVisualizations: beforeScientificArtifacts.mhcReferenceVisualizations,
                referenceRecordStore: beforeScientificArtifacts.referenceRecordStore,
                alignmentArtifacts: alignmentArtifacts,
                provisionalExon2Artifacts: provisionalArtifacts
            ),
            to: fixture.bundleURL
        )
        let installedManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let unnameableDocument = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(
                for: try XCTUnwrap(installedManifest.mhcCandidateArtifacts?.unnameableJSON?.path),
                in: fixture.bundleURL
            ))
        )
        XCTAssertEqual(unnameableDocument.clusters.first?.stableClusterID, "raw-cluster-u")
        XCTAssertEqual(unnameableDocument.clusters.first?.fastaRecordID, "canonical-cluster-u")

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_200) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        XCTAssertEqual(updatedManifest.workflowKind, .fullLengthONTMHCGenotype)
        XCTAssertEqual(updatedManifest.workflowMode, .genotypeOnly)

        XCTAssertNotNil(updatedManifest.mhcCandidateArtifacts?.candidateJSON)
        XCTAssertNotNil(updatedManifest.mhcCandidateArtifacts?.unnameableJSON)
        XCTAssertEqual(updatedManifest.alignmentArtifacts, alignmentArtifacts)
        XCTAssertEqual(updatedManifest.provisionalExon2Artifacts, provisionalArtifacts)
        XCTAssertFalse((updatedManifest.workbookRevisions ?? []).isEmpty)
        let inspection = try inspectTwoSheetCandidateWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        XCTAssertTrue(
            inspection["unmatchedIDs"]?.split(separator: "|").contains("raw-cluster-u") == true
        )
        XCTAssertEqual(inspection["unnameableSequence"], String(repeating: "N", count: 40))
    }

    func testExplicitWorkbookUpdateAcceptsCandidateArtifactManifestSchema2RawIdentityRefs() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "candidate-manifest-schema-2-update"
        )
        try installCandidateArtifacts(
            in: fixture.bundleURL,
            schemaVersion: 4,
            artifactManifestSchemaVersion: 2
        )
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let before = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let rawFASTA = try XCTUnwrap(before.mhcCandidateArtifacts?.rawUnmatchedFASTA)
        let sourceIdentityMap = try XCTUnwrap(before.mhcCandidateArtifacts?.sourceIdentityMap)

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_300) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertEqual(updated.mhcCandidateArtifacts?.schemaVersion, 2)
        XCTAssertEqual(updated.mhcCandidateArtifacts?.rawUnmatchedFASTA, rawFASTA)
        XCTAssertEqual(updated.mhcCandidateArtifacts?.sourceIdentityMap, sourceIdentityMap)
    }

    func testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "mamu-biological-order")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)

        var manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let candidateJSONURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(artifacts.candidateJSON).path,
            in: fixture.bundleURL
        )
        var candidateJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: candidateJSONURL)) as? [String: Any]
        )
        var candidates = try XCTUnwrap(candidateJSON["candidates"] as? [[String: Any]])
        let candidateNames: [String: (name: String, locus: String, reference: String)] = [
            "cluster-1": ("Mamu-B02ps*001_5nt_nov", "Mamu-B02ps", "Mamu-B02ps*001"),
            "cluster-2": ("Mamu-B02ps*001_5nt_nov", "Mamu-B02ps", "Mamu-B02ps*001"),
            "cluster-3": ("Mamu-K*002_ext", "Mamu-K", "Mamu-K*002"),
            "cluster-4": ("Mamu-A2*003_ext", "Mamu-A2", "Mamu-A2*003"),
        ]
        for index in candidates.indices {
            let stableID = try XCTUnwrap(candidates[index]["stable_cluster_id"] as? String)
            let replacement = try XCTUnwrap(candidateNames[stableID])
            candidates[index]["provisional_name"] = replacement.name
            candidates[index]["locus"] = replacement.locus
            candidates[index]["closest_reference_name"] = replacement.reference
        }
        candidateJSON["candidates"] = candidates
        try JSONSerialization.data(
            withJSONObject: candidateJSON,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: candidateJSONURL, options: .atomic)

        let knownNames: [(id: String, name: String)] = [
            ("raw-01", "Mamu-DRB*001"),
            ("raw-02", "Mamu-K*001"),
            ("raw-03", "Mamu-J*001"),
            ("raw-04", "Mamu-AG*001"),
            ("raw-05", "Mamu-G*001"),
            ("raw-06", "Mamu-F*001"),
            ("raw-07", "Mamu-I*001"),
            ("raw-08", "Mamu-B16*001"),
            ("raw-09", "Mamu-B*010"),
            ("raw-10", "Mamu-B*002"),
            ("raw-11", "Mamu-A10*001"),
            ("raw-12", "Mamu-A2*010"),
            ("raw-13", "Mamu-A1*001"),
            ("raw-14", "Mamu-B*001:01N"),
            ("raw-15", "Mamu-B*001:01_ext"),
        ]
        let referenceArtifacts = try XCTUnwrap(manifest.mhcReferenceVisualizations)
        let referenceJSONURL = ONTGenotypeResultBundle.resolvedURL(
            for: referenceArtifacts.recordsJSON.path,
            in: fixture.bundleURL
        )
        let referenceSequence = "ATGGCTTAA"
        let referenceRecords = knownNames.enumerated().map { index, item in
            ONTMHCReferenceVisualizationRecord(
                rawReferenceID: item.id,
                sourceOrdinal: index,
                alleleName: item.name,
                locus: String(item.name.prefix { $0 != "*" }).split(separator: "-").last.map(String.init),
                sequence: referenceSequence,
                sequenceSHA256: sha256Hex(referenceSequence),
                recordFields: ["feature.allele": [item.name]],
                features: [],
                annotatedTranslation: "MA",
                genBankText: "LOCUS \(item.id)",
                fastaText: ">\(item.id)\n\(referenceSequence)\n",
                roles: [.init(role: .exactKnownCall, candidateStableClusterIDs: [])]
            )
        }
        try JSONEncoder().encode(
            ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: referenceRecords)
        ).write(to: referenceJSONURL, options: .atomic)

        let longSummaryURL = ONTGenotypeResultBundle.resolvedURL(
            for: manifest.longSummaryCSVPath,
            in: fixture.bundleURL
        )
        let longRows = knownNames.enumerated().map { index, item in
            "sample-a,\(item.id),\(index + 1),\(index + 1),1000,100,10,1000,100,10"
        }
        try ([
            "sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent",
        ] + longRows).joined(separator: "\n").appending("\n").write(
            to: longSummaryURL,
            atomically: true,
            encoding: .utf8
        )

        let revisedCandidateArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: try artifactReference(candidateJSONURL, relativeTo: fixture.bundleURL),
            candidateFASTA: artifacts.candidateFASTA,
            candidateGenBank: artifacts.candidateGenBank,
            unnameableJSON: artifacts.unnameableJSON,
            unnameableFASTA: artifacts.unnameableFASTA,
            unnameableGenBank: artifacts.unnameableGenBank
        )
        let revisedReferenceArtifacts = ONTMHCReferenceVisualizationArtifacts(
            schemaVersion: referenceArtifacts.schemaVersion,
            recordCount: referenceRecords.count,
            recordsJSON: try artifactReference(referenceJSONURL, relativeTo: fixture.bundleURL),
            genBank: referenceArtifacts.genBank,
            fasta: referenceArtifacts.fasta
        )
        manifest = ONTGenotypeResultBundleManifest(
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
            mhcCandidateArtifacts: revisedCandidateArtifacts,
            mhcReferenceVisualizations: revisedReferenceArtifacts,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
if "Unified Genotype Pivot" in wb.sheetnames:
    del wb["Unified Genotype Pivot"]
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append(["Client ID", "", ""] + [""] * 9 + ["sample-a"])
ws.append(["MHC-A Haplotype 1", "", ""] + [""] * 9 + ["analyst-h1"])
ws.append(["Comments", "Subtotal", "# Obs."] + [""] * 9 + ["analyst-comment"])
ws.append([])
ws.append([
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
    "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
    "total_cluster_reads", "sample-a",
])
wb.save(path)
"""#, currentURL.path])

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_150) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectBiologicallyOrderedTwoSheetWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["analystHaplotype"], "analyst-h1")
        XCTAssertEqual(inspection["analystComment"], "analyst-comment")
        let swiftOrderedDisplayNames = (
            knownNames.map { $0.name } + candidateNames.values.map { $0.name }
        ).sorted(by: MHCAlleleDisplayOrder.lessThan)
        XCTAssertEqual(
            inspection["unifiedDisplayNames"],
            swiftOrderedDisplayNames.joined(separator: "|"),
            "Explicit workbook refresh and Swift viewport ordering must remain identical"
        )
        XCTAssertEqual(inspection["unifiedDisplayNames"], [
            "Mamu-A1*001",
            "Mamu-A2*003_ext",
            "Mamu-A2*010",
            "Mamu-A10*001",
            "Mamu-B*001:01_ext",
            "Mamu-B*001:01N",
            "Mamu-B*002",
            "Mamu-B*010",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-B16*001",
            "Mamu-I*001",
            "Mamu-F*001",
            "Mamu-G*001",
            "Mamu-AG*001",
            "Mamu-J*001",
            "Mamu-K*001",
            "Mamu-K*002_ext",
            "Mamu-DRB*001",
        ].joined(separator: "|"))
        XCTAssertEqual(inspection["unmatchedNames"], [
            "Mamu-A2*003_ext",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-K*002_ext",
            "",
        ].joined(separator: "|"))
        XCTAssertEqual(
            inspection["unmatchedIDs"],
            "cluster-4|cluster-1|cluster-2|cluster-3|cluster-u",
            "Duplicate provisional names and the blank un-nameable row must remain distinct"
        )
    }

    func testExplicitUpdateWritesTwoSheetContractFromEmbeddedUnifiedHeaderAndNormalizedUnmatchedRows() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-update")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
if "Unified Genotype Pivot" in wb.sheetnames:
    del wb["Unified Genotype Pivot"]
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append(["Client ID", "", ""] + [""] * 9 + ["sample-a", "sample-b"])
ws.append(["Mapped Read Count", "stale-total", "stale-average"] + [""] * 9 + ["1", "2"])
ws.append(["MHC-A Haplotype 1", "", ""] + [""] * 9 + ["analyst-h1", ""])
ws.append(["MHC-DQA Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dqa"])
ws.append(["MHC-DQB Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dqb"])
ws.append(["MHC-DPA Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dpa"])
ws.append(["MHC-DPB Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dpb"])
ws.append(["Comments", "Subtotal", "# Obs."] + [""] * 9 + ["analyst-comment", ""])
ws.append([])
ws.append([
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
    "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
    "total_cluster_reads", "sample-a", "sample-b",
])
ws.append(["known-allele", "NHP00001", "Mafa-A1*001:01", "", "", "known", "", "Mafa-A1*001:01", "exact", 1, 1, 9, 9, ""])
wb.create_sheet("Legacy Sheet")
wb.save(path)
"""#, currentURL.path])

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_100) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([
            .init(sample: "sample-a", locus: "MHC-DQ", haplotype1: "DQ-H1", haplotype2: "DQ-H2", status: "called", notes: ""),
            .init(sample: "sample-a", locus: "MHC-DP", haplotype1: "DP-H1", haplotype2: "DP-H2", status: "called", notes: ""),
        ], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["tableHeaderRow"], "22", "computed header and table are rebuilt from durable CSV inputs")
        XCTAssertEqual(inspection["analystHaplotype"], "analyst-h1")
        XCTAssertEqual(inspection["analystComment"], "analyst-comment")
        XCTAssertEqual(inspection["sampleADQAHaplotype1"], "DQ-H1")
        XCTAssertEqual(inspection["sampleADQBHaplotype1"], "DQ-H1")
        XCTAssertEqual(inspection["sampleADPAHaplotype1"], "DP-H1")
        XCTAssertEqual(inspection["sampleADPBHaplotype1"], "DP-H1")
        XCTAssertEqual(inspection["sampleBDQAHaplotype1"], "analyst-dqa")
        XCTAssertEqual(inspection["sampleBDPBHaplotype1"], "analyst-dpb")
        XCTAssertEqual(inspection["mappedTotal"], "303")
        XCTAssertEqual(inspection["mappedAverage"], "151.5")
        XCTAssertEqual(inspection["mappedTotalType"], "n")
        XCTAssertEqual(inspection["mappedAverageType"], "n")
        XCTAssertEqual(inspection["sampleAMappedType"], "n")
        XCTAssertEqual(inspection["sampleATotalReadType"], "n")
        XCTAssertEqual(inspection["sampleAUnmappedPercentType"], "n")
        XCTAssertEqual(inspection["knownDisplayName"], "Mafa-A1*001:01:01:01")
        XCTAssertEqual(inspection["knownClosestReference"], "Mafa-A1*001:01:01:01")
        XCTAssertEqual(inspection["knownSampleAReads"], "101")
        XCTAssertEqual(inspection["knownSampleBReads"], "202")
        XCTAssertEqual(inspection["knownTotalReads"], "303")
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4|cluster-u")
        XCTAssertEqual(inspection["candidateSequence"], String(repeating: "C", count: 33))
        XCTAssertEqual(inspection["legacySequenceColumns"], "false")
        XCTAssertEqual(inspection["candidateTranslation"], "AAAAAAAAAAA")
        XCTAssertEqual(inspection["candidateTranslationStatus"], "full-length")
        XCTAssertEqual(inspection["unnameableSequence"], String(repeating: "N", count: 40))
        XCTAssertEqual(inspection["unnameableTranslationStatus"], "incomplete/unresolved")

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(envelope.steps.first { $0.toolName.contains("python openpyxl") })
        XCTAssertTrue(pythonStep.inputs.contains { $0.path.hasSuffix("candidate-alleles.gb") })
        XCTAssertTrue(pythonStep.inputs.contains { $0.path.hasSuffix("unnameable-clusters.gb") })
    }

    func testTwoSheetCurrentWorkbookRetainsAndAppliesSemanticReviews() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-reviews")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "Mafa-A1",
                    genotype: "Mafa-A1*018:01:01:01_5nt_nov",
                    sample: "sample-a",
                    stableClusterID: "cluster-1"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_150) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["Unified Genotype Pivot"]
headers = {}
header_row = None
for row in range(1, ws.max_row + 1):
    values = {str(ws.cell(row, col).value): col for col in range(1, ws.max_column + 1) if ws.cell(row, col).value is not None}
    if "stable_cluster_id" in values:
        headers = values
        header_row = row
        break
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["sample-a"])
annotation_rows = []
if "Matrix Annotations" in wb.sheetnames:
    annotations = wb["Matrix Annotations"]
    annotation_rows = [
        "|".join("" if annotations.cell(row, col).value is None else str(annotations.cell(row, col).value)
                 for col in range(1, annotations.max_column + 1))
        for row in range(2, annotations.max_row + 1)
    ]
print(json.dumps({
    "sheet_names": wb.sheetnames,
    "value": str(cell.value),
    "italic": bool(cell.font.italic),
    "has_annotations": "Matrix Annotations" in wb.sheetnames,
    "has_audit": "Audit Log" in wb.sheetnames,
    "annotations": annotation_rows,
}))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        let diagnostic = String(describing: payload["annotations"])
        XCTAssertEqual(payload["value"] as? String, "[7]", diagnostic)
        XCTAssertEqual(payload["italic"] as? Bool, true, diagnostic)
        XCTAssertEqual(payload["has_annotations"] as? Bool, true)
        XCTAssertEqual(payload["has_audit"] as? Bool, true)
    }

    func testAnnotationOnlyUpdatePreservesAttestedProjectionWithUnrelatedLegacyCandidateLabel() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "annotation-only-legacy-candidate"
        )
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_160) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        var manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let candidateJSONURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(artifacts.candidateJSON).path,
            in: fixture.bundleURL
        )
        var candidateJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: candidateJSONURL)) as? [String: Any]
        )
        var candidates = try XCTUnwrap(candidateJSON["candidates"] as? [[String: Any]])
        let legacyIndex = try XCTUnwrap(
            candidates.firstIndex { $0["stable_cluster_id"] as? String == "cluster-4" }
        )
        candidates[legacyIndex]["classification"] = "novel"
        candidates[legacyIndex]["provisional_name"] = "Mafa-B*002:01_0nt_nov"
        candidates[legacyIndex]["closest_reference_class"] = "genomicDNA"
        candidates[legacyIndex]["snp_count"] = 0
        candidates[legacyIndex]["deleted_bases"] = 0
        candidates[legacyIndex]["long_gap_bases"] = 0
        candidateJSON["candidates"] = candidates
        try JSONSerialization.data(
            withJSONObject: candidateJSON,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: candidateJSONURL, options: .atomic)

        _ = try runPython(["-c", #"""
import re
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
for sheet_name in ("Unified Genotype Pivot", "Unmatched Alleles"):
    ws = wb[sheet_name]
    header_row = None
    headers = {}
    for row in range(1, ws.max_row + 1):
        candidate_headers = {
            re.sub(r"[^a-z0-9]+", "_", str(ws.cell(row, col).value).lower()).strip("_"): col
            for col in range(1, ws.max_column + 1)
            if ws.cell(row, col).value is not None
        }
        if "stable_cluster_id" in candidate_headers:
            header_row = row
            headers = candidate_headers
            break
    for row in range(header_row + 1, ws.max_row + 1):
        if ws.cell(row, headers["stable_cluster_id"]).value != "cluster-4":
            continue
        name_header = (
            "display_name"
            if "display_name" in headers
            else "provisional_allele_name"
        )
        classification_header = (
            "classification"
            if "classification" in headers
            else "classification_or_reason"
        )
        ws.cell(row, headers[name_header]).value = "Mafa-B*002:01_0nt_nov"
        ws.cell(row, headers[classification_header]).value = "novel"
wb.save(path)
"""#, currentURL.path])

        let revisedArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: try artifactReference(candidateJSONURL, relativeTo: fixture.bundleURL),
            candidateFASTA: artifacts.candidateFASTA,
            candidateGenBank: artifacts.candidateGenBank,
            unnameableJSON: artifacts.unnameableJSON,
            unnameableFASTA: artifacts.unnameableFASTA,
            unnameableGenBank: artifacts.unnameableGenBank,
            rawUnmatchedFASTA: artifacts.rawUnmatchedFASTA,
            sourceIdentityMap: artifacts.sourceIdentityMap
        )
        let currentPath = try XCTUnwrap(manifest.currentWorkbookPath)
        let currentSHA256 = try ProvenanceFileHasher.sha256(of: currentURL)
        let currentSizeBytes = Int64(try ProvenanceFileHasher.fileSize(of: currentURL))
        let revisedRevisions = manifest.workbookRevisions?.map { revision in
            guard revision.path == currentPath else { return revision }
            return ONTGenotypeWorkbookRevision(
                id: revision.id,
                role: revision.role,
                path: revision.path,
                label: revision.label,
                sourceFilename: revision.sourceFilename,
                createdAt: revision.createdAt,
                user: revision.user,
                predecessorID: revision.predecessorID,
                predecessorPath: revision.predecessorPath,
                sha256: currentSHA256,
                sizeBytes: currentSizeBytes,
                provenancePath: revision.provenancePath
            )
        }
        manifest = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: revisedRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: manifest.deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: manifest.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            presetID: manifest.presetID,
            presetVersion: manifest.presetVersion,
            createdAt: manifest.createdAt,
            activeHaplotypeAnalysisRevisionID: manifest.activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: manifest.haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: revisedArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)

        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "Mafa-A1",
                    genotype: "Mafa-A1*018:01:01:01_5nt_nov",
                    sample: "sample-a",
                    stableClusterID: "cluster-1"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            annotationOnly: true
        )

        let output = try runPython(["-c", #"""
import json
import re
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
payload = {}
for sheet_name in ("Unified Genotype Pivot", "Unmatched Alleles"):
    ws = wb[sheet_name]
    for row in range(1, ws.max_row + 1):
        headers = {
            re.sub(r"[^a-z0-9]+", "_", str(ws.cell(row, col).value).lower()).strip("_"): col
            for col in range(1, ws.max_column + 1)
            if ws.cell(row, col).value is not None
        }
        if "stable_cluster_id" not in headers:
            continue
        for data_row in range(row + 1, ws.max_row + 1):
            stable_id = ws.cell(data_row, headers["stable_cluster_id"]).value
            if stable_id == "cluster-1" and sheet_name == "Unified Genotype Pivot":
                cell = ws.cell(data_row, headers["sample_a"])
                payload["review_value"] = str(cell.value)
                payload["review_italic"] = bool(cell.font.italic)
            if stable_id == "cluster-4":
                name_header = (
                    "display_name"
                    if "display_name" in headers
                    else "provisional_allele_name"
                )
                payload[f"legacy_{sheet_name}"] = str(
                    ws.cell(data_row, headers[name_header]).value
                )
        break
payload["has_annotations"] = "Matrix Annotations" in wb.sheetnames
payload["has_audit"] = "Audit Log" in wb.sheetnames
payload["has_guide"] = "Interpretation Guide" in wb.sheetnames
print(json.dumps(payload))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["review_value"] as? String, "[7]")
        XCTAssertEqual(payload["review_italic"] as? Bool, true)
        XCTAssertEqual(
            payload["legacy_Unified Genotype Pivot"] as? String,
            "Mafa-B*002:01_0nt_nov"
        )
        XCTAssertEqual(
            payload["legacy_Unmatched Alleles"] as? String,
            "Mafa-B*002:01_0nt_nov"
        )
        XCTAssertEqual(payload["has_annotations"] as? Bool, true)
        XCTAssertEqual(payload["has_audit"] as? Bool, true)
        XCTAssertEqual(payload["has_guide"] as? Bool, false)

        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                [
                    .init(
                        sample: "sample-a",
                        locus: "MHC-A",
                        haplotype1: "A-H1",
                        haplotype2: "",
                        status: "called",
                        notes: ""
                    ),
                ],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "Candidate cluster-4 has a prohibited or non-authoritative novel label."
                )
            )
        }

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 7_161) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-stage-created" else { return }
                    var tamperedWorkbook = try Data(contentsOf: currentURL)
                    tamperedWorkbook.append(0)
                    try tamperedWorkbook.write(to: currentURL, options: .atomic)
                }
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL,
                annotationOnly: true
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "current.xlsx to match its manifest attestation"
                )
            )
        }
    }

    func testTwoSheetRebuildPreservesUnrelatedNativeCommentAndFormatting() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-native-content")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_175) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["sample-a"])
cell.comment = Comment("Analyst-owned native note", "analyst")
cell.fill = PatternFill(fill_type="solid", fgColor="FF123456")
cell.font = cell.font.copy(bold=True)
wb.save(path)
"""#, currentURL.path])

        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "Mafa-A1",
                    genotype: "Mafa-A1*018:01:01:01_5nt_nov",
                    sample: "sample-a",
                    stableClusterID: "cluster-1"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["sample-a"])
print(json.dumps({
    "comment": "" if cell.comment is None else cell.comment.text,
    "author": "" if cell.comment is None else cell.comment.author,
    "fill": str(getattr(cell.fill.fgColor, "rgb", ""))[-6:],
    "bold": bool(cell.font.bold),
    "italic": bool(cell.font.italic),
}))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["comment"] as? String, "Analyst-owned native note")
        XCTAssertEqual(payload["author"] as? String, "analyst")
        XCTAssertEqual(payload["fill"] as? String, "123456")
        XCTAssertEqual(payload["bold"] as? Bool, true)
        XCTAssertEqual(payload["italic"] as? Bool, true)
    }

    func testTwoSheetRepeatUpdateRetainsAuthoritativeCandidateTintAndOtherNativeStyle() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-repeat-tint")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_180) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let canonicalTint = try runPython(["-c", #"""
import sys
from copy import copy
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["display_name"])
canonical = str(getattr(cell.fill.fgColor, "rgb", ""))[-6:]
cell.fill = PatternFill(fill_type="solid", fgColor="FFABCDEF")
font = copy(cell.font)
font.bold = True
cell.font = font
cell.comment = Comment("Native label note", "analyst")
wb.save(path)
print(canonical)
"""#, currentURL.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(canonicalTint.isEmpty)
        XCTAssertNotEqual(canonicalTint, "ABCDEF")

        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["display_name"])
print(json.dumps({
    "fill": str(getattr(cell.fill.fgColor, "rgb", ""))[-6:],
    "bold": bool(cell.font.bold),
    "comment": "" if cell.comment is None else cell.comment.text,
}))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["fill"] as? String, canonicalTint)
        XCTAssertEqual(payload["bold"] as? Bool, true)
        XCTAssertEqual(payload["comment"] as? String, "Native label note")
    }

    func testExplicitUpdateRetainsAllCandidateCategoriesAndUnnameableEvidenceWithNameOnlyTints() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-workbook")
        XCTAssertEqual(
            try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL).mhcReferenceVisualizations,
            fixture.manifest.mhcReferenceVisualizations
        )
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let installedManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
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
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 7_000),
            increment: -1
        )
        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)
        let after = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertNotEqual(before, after, "Only the explicit update action may rewrite current.xlsx")
        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["candidateNameFills"], "FFFF0000|8000FF00|FF0000FF|40FFFF00")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4|cluster-u")
        XCTAssertEqual(updated.mhcCandidateArtifacts?.schemaVersion, 1)
        XCTAssertEqual(
            updated.mhcReferenceVisualizations,
            installedManifest.mhcReferenceVisualizations
        )
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
        let workflowWallTime = try XCTUnwrap(envelope.wallTimeSeconds)
        XCTAssertGreaterThanOrEqual(workflowWallTime, 0)
        XCTAssertLessThan(workflowWallTime, 30, "Injected and live clocks must never be mixed")
        let timedSteps = envelope.steps.filter {
            $0.startedAt != nil && $0.completedAt != nil && $0.wallTimeSeconds != nil
        }
        for step in timedSteps {
            let startedAt = try XCTUnwrap(step.startedAt)
            let completedAt = try XCTUnwrap(step.completedAt)
            let wallTime = try XCTUnwrap(step.wallTimeSeconds)
            XCTAssertGreaterThanOrEqual(wallTime, 0)
            XCTAssertEqual(
                wallTime,
                completedAt.timeIntervalSince(startedAt),
                accuracy: 0.000_001
            )
        }
        let timedStepTotal = timedSteps.compactMap(\.wallTimeSeconds).reduce(0, +)
        XCTAssertGreaterThanOrEqual(workflowWallTime, timedStepTotal)

    }

    func testCandidateUpdateRejectsMissingUnifiedPivotWithoutBundleMutation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "candidate-fallback")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testExplicitUpdateNormalizesCandidateOnlyArtifactTriplet() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "candidate-only")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try retainCandidateArtifactCategory(.candidate, in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
    }

    func testExplicitUpdateNormalizesUnnameableOnlyArtifactTriplet() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "unnameable-only")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try retainCandidateArtifactCategory(.unnameable, in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        XCTAssertEqual(inspection["candidateIDs"], "")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-u")
        XCTAssertEqual(inspection["unnameableTranslationStatus"], "incomplete/unresolved")
    }

    func testSchemaVersionTwoCandidateUpdateUsesCompactRowsAndHeaderNamedPivotColumns() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "candidate-v2")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append([
    "display_name", "sample-b", "classification", "stable_cluster_id", "call_type",
    "sample-a", "locus", "support_class", "closest_reference", "match_class",
    "occurrence_count", "sample_count", "total_cluster_reads", "call_id",
])
wb.save(path)
"""#, currentURL.path])

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4|cluster-u")
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

    func testDescriptorCloneRehydratesAppleDoubleMetadataWithoutCopyingCompanionBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "appledouble-clone")
        let rawDirectory = fixture.bundleURL.appendingPathComponent(
            "samples/CR1178/savont/strict-qv90-min3/raw",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let baseURL = rawDirectory.appendingPathComponent("final_asvs.fasta")
        let scientificBytes = Data(">cluster-1\nACGTACGT\n".utf8)
        try scientificBytes.write(to: baseURL)
        let attributeName = "com.lungfish.clone-test"
        let attributeValue = Data("required-metadata".utf8)
        let setStatus = attributeValue.withUnsafeBytes { bytes in
            Darwin.setxattr(
                baseURL.path,
                attributeName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(setStatus, 0)
        let appleDoubleURL = rawDirectory.appendingPathComponent("._final_asvs.fasta")
        try Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00, 0, 0, 0, 0]).write(
            to: appleDoubleURL
        )

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            forceBundleCloneFallback: true
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let copiedBaseURL = fixture.bundleURL.appendingPathComponent(
            "samples/CR1178/savont/strict-qv90-min3/raw/final_asvs.fasta"
        )
        XCTAssertEqual(try Data(contentsOf: copiedBaseURL), scientificBytes)
        let attributeSize = Darwin.getxattr(copiedBaseURL.path, attributeName, nil, 0, 0, 0)
        XCTAssertEqual(attributeSize, attributeValue.count)
        var copiedAttribute = [UInt8](repeating: 0, count: max(0, attributeSize))
        let readSize = copiedAttribute.withUnsafeMutableBytes { bytes in
            Darwin.getxattr(
                copiedBaseURL.path,
                attributeName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(readSize, attributeValue.count)
        XCTAssertEqual(Data(copiedAttribute), attributeValue)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent(
                "samples/CR1178/savont/strict-qv90-min3/raw/._final_asvs.fasta"
            ).path
        ))
    }

    func testUnsupportedDirectorySwapPublishesThroughCrashSafeRotation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "rename-rotation")
        let before = try ProvenanceFileHasher.sha256(
            of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            forceBundleCloneFallback: true,
            directorySwapPrimitive: { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertNotEqual(
            try ProvenanceFileHasher.sha256(
                of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
            ),
            before
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(manifest.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(
            envelope.steps.last?.toolName,
            "lungfish-internal ExFAT journaled three-rename workbook rotation v2"
        )
        XCTAssertEqual(
            envelope.steps.last?.argv.dropFirst().first,
            "exfat-journaled-three-rename-v2"
        )
    }

    func testRecoveryRestoresPriorGenerationAfterEveryInterruptedRotationStep() throws {
        for checkpoint in [
            "after-rotation-stage-to-temporary-hard-stop",
            "after-rotation-final-to-stage-hard-stop",
            "after-rotation-temporary-to-final-hard-stop",
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: "rotation-crash-\(checkpoint)"
            )
            let before = try bundleSnapshot(fixture.bundleURL)

            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    pythonExecutableURL: testPythonExecutableURL,
                    publicationFailureInjector: { observed in
                        guard observed == checkpoint else { return }
                        throw NSError(domain: "SimulatedRotationSIGKILL", code: 9)
                    },
                    forceBundleCloneFallback: true,
                    directorySwapPrimitive: { _, _, _, _, _ in
                        errno = ENOTSUP
                        return -1
                    }
                ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
            )

            _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

            XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before, checkpoint)
            try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
            try assertNoRetiredWorkbookGeneration(in: root)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
            ))
        }
    }

    func testImmutableMarkerCreateDoesNotDependOnRenameFlags() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "marker-rename-fallback")
        let before = try bundleSnapshot(fixture.bundleURL)
        let renameCalls = SendableFlagBox()

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "post-exchange" else { return }
                    throw NSError(domain: "InjectedPostExchangeFailure", code: 1)
                },
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                workbookAtomicRenamePrimitive: { source, destination, flags in
                    renameCalls.set((renameCalls.value ?? 0) + 1)
                    if flags != 0 {
                        errno = ENOTSUP
                        return -1
                    }
                    return Darwin.renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, 0)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertNil(
            renameCalls.value,
            "The ExFAT marker hint is created O_EXCL and never published by replacement rename"
        )
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
    }


    func testManualSaveToRetiredGenerationAfterManifestCommitRollsBackAndPreservesEdit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-after-manifest")
        let currentPath = try XCTUnwrap(fixture.manifest.currentWorkbookPath)
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    let marker = try XCTUnwrap(
                        try JSONSerialization.jsonObject(
                            with: Data(contentsOf: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                                for: fixture.bundleURL
                            ))
                        ) as? [String: Any]
                    )
                    let stagedOldURL = URL(
                        fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
                        isDirectory: true
                    ).appendingPathComponent(currentPath)
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z93"] = "manual-save-after-manifest-survives"
wb.save(path)
"""#, stagedOldURL.path], executableURL: pythonURL)
                },
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        let value = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z93"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            "manual-save-after-manifest-survives"
        )
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        try assertNoRetiredWorkbookGeneration(in: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
    }

    func testManualSaveDuringRotationIsDetectedAndPreservedAtBothOldGenerationBoundaries() throws {
        for (checkpoint, cell) in [
            ("after-rotation-stage-to-temporary-hard-stop", "Z96"),
            ("after-rotation-final-to-stage-hard-stop", "Z95"),
            ("after-rotation-temporary-to-final-hard-stop", "Z92"),
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-\(cell)")
            let currentPath = try XCTUnwrap(fixture.manifest.currentWorkbookPath)
            let currentURL = ONTGenotypeResultBundle.resolvedURL(
                for: currentPath,
                in: fixture.bundleURL
            )
            let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
            let manifestBefore = try Data(contentsOf: manifestURL)
            let pythonURL = testPythonExecutableURL
            let didEdit = SendableFlagBox()

            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    pythonExecutableURL: pythonURL,
                    publicationFailureInjector: { observed in
                        guard observed == checkpoint, didEdit.value == nil else { return }
                        didEdit.set(1)
                        let editURL: URL
                        if checkpoint != "after-rotation-stage-to-temporary-hard-stop" {
                            let marker = try XCTUnwrap(
                                try JSONSerialization.jsonObject(
                                    with: Data(contentsOf: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                                        for: fixture.bundleURL
                                    ))
                                ) as? [String: Any]
                            )
                            editURL = URL(
                                fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
                                isDirectory: true
                            ).appendingPathComponent(currentPath)
                        } else {
                            editURL = currentURL
                        }
                        _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path, cell = sys.argv[1], sys.argv[2]
wb = load_workbook(path)
wb[wb.sheetnames[0]][cell] = "manual-rotation-survives"
wb.save(path)
"""#, editURL.path, cell], executableURL: pythonURL)
                    },
                    forceBundleCloneFallback: true,
                    directorySwapPrimitive: { _, _, _, _, _ in
                        errno = ENOTSUP
                        return -1
                    }
                ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains("changed"),
                    "\(checkpoint): \(error.localizedDescription)"
                )
            }

            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
            let value = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]][sys.argv[2]].value or "")
"""#, currentURL.path, cell], executableURL: pythonURL)
            XCTAssertEqual(value.trimmingCharacters(in: .whitespacesAndNewlines), "manual-rotation-survives")
            try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        }
    }

    func testRecoveryKeepsCommittedGenerationAfterLaterManualWorkbookEdit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "committed-manual-edit")
        let priorRevisionCount = fixture.manifest.workbookRevisions?.count ?? 0
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                },
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let committedURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z94"] = "committed-manual-edit-survives"
wb.save(path)
"""#, committedURL.path], executableURL: pythonURL)

        let loaded = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertGreaterThan(loaded.manifest.workbookRevisions?.count ?? 0, priorRevisionCount)
        let value = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z94"].value or "")
"""#, committedURL.path], executableURL: pythonURL)
        XCTAssertEqual(value.trimmingCharacters(in: .whitespacesAndNewlines), "committed-manual-edit-survives")
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testRecoveryPreservesBothGenerationsWhenBothWorkbooksWereEdited() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "both-generations-edited")
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try markerObject(at: markerURL)
        let stagedOld = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        let finalCurrent = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let oldCurrent = stagedOld.appendingPathComponent(try XCTUnwrap(fixture.manifest.currentWorkbookPath))
        for (url, cell, value) in [
            (finalCurrent, "Z91", "edited-new-generation"),
            (oldCurrent, "Z90", "edited-old-generation"),
        ] {
            _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path, cell, value = sys.argv[1:4]
wb = load_workbook(path)
wb[wb.sheetnames[0]][cell] = value
wb.save(path)
"""#, url.path, cell, value], executableURL: pythonURL)
        }
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagedBefore = try bundleSnapshot(stagedOld)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("ambiguous"))
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagedOld), stagedBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testTornOrMissingMarkerRehydratesFromDetachedAttestation() throws {
        for markerMutation in ["torn", "missing"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: "attestation-rehydrate-\(markerMutation)")
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
            let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
            if markerMutation == "torn" {
                try Data("{".utf8).write(to: markerURL)
            } else {
                try FileManager.default.removeItem(at: markerURL)
            }

            _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

            XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        }
    }

    func testPartialMarkerWriteFailureRetainsWALAndPreparedGenerationForRecovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "partial-marker-write")
        let before = try bundleSnapshot(fixture.bundleURL)
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                workbookAttestationRootURL: attestationRoot,
                workbookMarkerWriteFailureInjector: { checkpoint in
                    guard checkpoint == "after-marker-open-before-write" else { return }
                    throw NSError(domain: "InjectedMarkerWriteFailure", code: 1)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertEqual(try Data(contentsOf: markerURL), Data())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: attestationRoot.path)
                .filter { $0.hasSuffix(".json") }.count,
            1
        )
        let marker = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: root.path).first {
                $0.hasPrefix(".\(fixture.bundleURL.lastPathComponent).workbook-update-")
                    && $0.hasSuffix(".staging")
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path))

        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: fixture.bundleURL,
            attestationRootURL: attestationRoot
        )

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testMultipleMarkerHintsAndMatchingAttestationsFailClosed() throws {
        for duplicateKind in ["marker", "attestation"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: "multiple-authority-\(duplicateKind)")
            let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    pythonExecutableURL: testPythonExecutableURL,
                    publicationFailureInjector: { checkpoint in
                        guard checkpoint == "after-transaction-marker-hard-stop" else { return }
                        throw NSError(domain: "SimulatedSIGKILL", code: 9)
                    },
                    workbookAttestationRootURL: attestationRoot
                ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
            )
            let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
            if duplicateKind == "marker" {
                let duplicate = root.appendingPathComponent(
                    ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction-\(UUID().uuidString).json"
                )
                try FileManager.default.copyItem(at: markerURL, to: duplicate)
            } else {
                let attestation = try XCTUnwrap(
                    try FileManager.default.contentsOfDirectory(at: attestationRoot, includingPropertiesForKeys: nil)
                        .first { $0.pathExtension == "json" }
                )
                try FileManager.default.copyItem(
                    at: attestation,
                    to: attestationRoot.appendingPathComponent("duplicate.json")
                )
            }
            let finalBefore = try bundleSnapshot(fixture.bundleURL)
            if duplicateKind == "marker" {
                let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL)
                try FileManager.default.removeItem(at: lockURL)
                XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)) {
                    error in
                    XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("multiple"))
                }
                XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
            }
            let lock = try ONTGenotypeBundlePublicationLock.acquire(
                for: fixture.bundleURL,
                blocking: true,
                createIfMissing: duplicateKind == "marker"
            )

            XCTAssertThrowsError(
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: fixture.bundleURL,
                    attestationRootURL: attestationRoot
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("multiple")
                    || error.localizedDescription.localizedCaseInsensitiveContains("matching"))
            }
            lock.release()
            XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        }
    }

    func testAutomaticFinalizationDetachesAndRemovesRetiredGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "retired-generation-cleanup")

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        XCTAssertTrue(try workbookCleanupArtifacts(in: root).isEmpty)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix(".lungfish-workbook-generation-archive-")
            }
        )
    }

    func testWorkbookCleanupRecoversAfterEveryDurabilityBoundary() throws {
        let branches = [
            "committed",
            "prepared-discard",
            "rollback",
            "manual-save-winner",
        ]
        let checkpoints = [
            "after-workbook-cleanup-detach-hard-stop",
            "after-workbook-cleanup-state-write-before-attestation-hard-stop",
            "after-workbook-cleanup-state-durable-hard-stop",
            "after-workbook-cleanup-marker-removal-hard-stop",
            "after-workbook-cleanup-attestation-removal-hard-stop",
        ]
        for branch in branches {
            for checkpoint in checkpoints {
                let root = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let fixture = try makeMCMWorkbookBundle(
                    in: root,
                    outputName: "cleanup-\(branch)-\(checkpoint)"
                )
                let attestationRoot = root.appendingPathComponent(
                    "attestations",
                    isDirectory: true
                )

                try interruptWorkbookCleanup(
                    branch: branch,
                    fixture: fixture,
                    attestationRoot: attestationRoot
                )

                XCTAssertNoThrow(
                    try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
                )
                XCTAssertFalse(
                    try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                        $0.hasPrefix(".lungfish-workbook-generation-archive-")
                    }
                )
                let lock = try ONTGenotypeBundlePublicationLock.acquire(
                    for: fixture.bundleURL,
                    blocking: true,
                    createIfMissing: false
                )
                defer { lock.release() }
                XCTAssertThrowsError(
                    try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                        for: fixture.bundleURL,
                        attestationRootURL: attestationRoot,
                        cleanupFailureInjector: { observed in
                            guard observed == checkpoint else { return }
                            throw NSError(
                                domain: "InjectedWorkbookCleanupCrash",
                                code: 9
                            )
                        }
                    ),
                    "\(branch) @ \(checkpoint)"
                )
                XCTAssertFalse(try workbookCleanupArtifacts(in: root).isEmpty)
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: fixture.bundleURL,
                    attestationRootURL: attestationRoot
                )

                XCTAssertNoThrow(
                    try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL),
                    "\(branch) @ \(checkpoint)"
                )
                XCTAssertTrue(try workbookCleanupArtifacts(in: root).isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                        for: fixture.bundleURL
                    ).path
                ))
                try assertNoRetiredWorkbookGeneration(in: root)
            }
        }
    }

    func testWorkbookCleanupTraversalFailurePreservesEveryDecisionWinnerAndRetries()
        throws
    {
        let cases = [
            (
                branch: "committed",
                decision: "committed",
                terminalAction: "finished-committed-cleanup"
            ),
            (
                branch: "prepared-discard",
                decision: "prepared-discard",
                terminalAction: "finished-prepared-discard-cleanup"
            ),
            (
                branch: "rollback",
                decision: "rollback",
                terminalAction: "finished-rollback-cleanup"
            ),
            (
                branch: "manual-save-winner",
                decision: "manual-save-winner",
                terminalAction: "finished-manual-save-winner-cleanup"
            ),
        ]

        for testCase in cases {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: "cleanup-traversal-\(testCase.branch)"
            )
            let attestationRoot = root.appendingPathComponent(
                "attestations",
                isDirectory: true
            )
            let initialWorkbook = try ONTGenotypeResultBundle
                .currentWorkbookURL(for: fixture.bundleURL)
            let initialWorkbookSHA = try ProvenanceFileHasher.sha256(
                of: initialWorkbook
            )

            try interruptWorkbookCleanup(
                branch: testCase.branch,
                fixture: fixture,
                attestationRoot: attestationRoot
            )

            let lock = try ONTGenotypeBundlePublicationLock.acquire(
                for: fixture.bundleURL,
                blocking: true,
                createIfMissing: false
            )
            defer { lock.release() }
            XCTAssertThrowsError(
                try ONTGenotypeWorkbookUpdateRecovery
                    .recoverIfNeededAssumingLock(
                        for: fixture.bundleURL,
                        attestationRootURL: attestationRoot,
                        cleanupFailureInjector: { checkpoint in
                            guard checkpoint
                                == "during-workbook-cleanup-traversal" else {
                                return
                            }
                            throw NSError(
                                domain:
                                    "InjectedWorkbookCleanupTraversalMatrix",
                                code: 5
                            )
                        }
                    ),
                testCase.branch
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("cleanup-pending"),
                    "\(testCase.branch): \(error.localizedDescription)"
                )
                XCTAssertTrue(
                    error.localizedDescription
                        .localizedCaseInsensitiveContains("retry"),
                    "\(testCase.branch): \(error.localizedDescription)"
                )
            }

            let pendingArtifacts = try workbookCleanupArtifacts(in: root)
            let quarantine = try XCTUnwrap(
                pendingArtifacts.first {
                    $0.lastPathComponent.hasPrefix(
                        ".lungfish-workbook-cleanup-pending-"
                    )
                },
                testCase.branch
            )
            let stateURL = try XCTUnwrap(
                pendingArtifacts.first {
                    $0.lastPathComponent.contains(
                        ".workbook-cleanup-state-"
                    )
                },
                testCase.branch
            )
            let warningURL = try XCTUnwrap(
                pendingArtifacts.first {
                    $0.lastPathComponent.contains(
                        ".workbook-cleanup-warning-"
                    )
                },
                testCase.branch
            )
            let warning = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: warningURL)
                ) as? [String: Any]
            )
            XCTAssertEqual(
                warning["decision"] as? String,
                testCase.decision,
                testCase.branch
            )
            XCTAssertEqual(
                warning["retryState"] as? String,
                "cleanup-pending",
                testCase.branch
            )
            XCTAssertEqual(
                (warning["quarantinePath"] as? String).map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                },
                quarantine.resolvingSymlinksInPath().path,
                testCase.branch
            )
            XCTAssertEqual(
                (warning["statePath"] as? String).map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                },
                stateURL.resolvingSymlinksInPath().path,
                testCase.branch
            )
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(
                    atPath: quarantine.path
                ).isEmpty,
                testCase.branch
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                        for: fixture.bundleURL
                    ).path
                ),
                testCase.branch
            )
            let pendingActions = try workbookRecoveryReceiptActions(in: root)
            XCTAssertTrue(
                pendingActions.contains("workbook-cleanup-authorized"),
                testCase.branch
            )
            XCTAssertFalse(
                pendingActions.contains(testCase.terminalAction),
                testCase.branch
            )

            let survivingWorkbook = try ONTGenotypeResultBundle
                .currentWorkbookURL(for: fixture.bundleURL)
            let survivingWorkbookSHA = try ProvenanceFileHasher.sha256(
                of: survivingWorkbook
            )
            switch testCase.branch {
            case "committed":
                XCTAssertNotEqual(
                    survivingWorkbookSHA,
                    initialWorkbookSHA,
                    testCase.branch
                )
            case "prepared-discard", "rollback":
                XCTAssertEqual(
                    survivingWorkbookSHA,
                    initialWorkbookSHA,
                    testCase.branch
                )
            case "manual-save-winner":
                XCTAssertEqual(
                    try runPython([
                        "-c",
                        #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z94"].value or "")
"""#,
                        survivingWorkbook.path,
                    ]).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    "manual-cleanup-winner",
                    testCase.branch
                )
            default:
                XCTFail("Unhandled cleanup decision \(testCase.branch)")
            }

            try ONTGenotypeWorkbookUpdateRecovery
                .recoverIfNeededAssumingLock(
                    for: fixture.bundleURL,
                    attestationRootURL: attestationRoot
                )

            XCTAssertNoThrow(
                try ONTGenotypeResultBundle.loadResult(
                    from: fixture.bundleURL
                ),
                testCase.branch
            )
            XCTAssertEqual(
                try ProvenanceFileHasher.sha256(
                    of: ONTGenotypeResultBundle.currentWorkbookURL(
                        for: fixture.bundleURL
                    )
                ),
                survivingWorkbookSHA,
                testCase.branch
            )
            let completedArtifacts = try workbookCleanupArtifacts(in: root)
            XCTAssertFalse(
                completedArtifacts.contains {
                    $0.lastPathComponent.hasPrefix(
                        ".lungfish-workbook-cleanup-pending-"
                    )
                        || $0.lastPathComponent.contains(
                            ".workbook-cleanup-state-"
                        )
                },
                testCase.branch
            )
            XCTAssertEqual(
                completedArtifacts.filter {
                    $0.lastPathComponent.contains(
                        ".workbook-cleanup-warning-"
                    )
                }.map(\.standardizedFileURL),
                [warningURL.standardizedFileURL],
                testCase.branch
            )
            XCTAssertTrue(
                try workbookRecoveryReceiptActions(in: root).contains(
                    testCase.terminalAction
                ),
                testCase.branch
            )
            try assertNoRetiredWorkbookGeneration(in: root)
        }
    }

    func testWorkbookCleanupTraversalFailureRecordsRetryWarning() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "cleanup-traversal")
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "during-workbook-cleanup-traversal" else { return }
                    throw NSError(domain: "InjectedWorkbookCleanupTraversal", code: 5)
                }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("cleanup-pending"))
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("retry"))
        }

        let artifacts = try workbookCleanupArtifacts(in: root)
        XCTAssertTrue(artifacts.contains { $0.lastPathComponent.contains("cleanup-state") })
        XCTAssertTrue(artifacts.contains { $0.lastPathComponent.contains("cleanup-warning") })
        let warningURL = try XCTUnwrap(
            artifacts.first { $0.lastPathComponent.contains("cleanup-warning") }
        )
        let warning = try JSONSerialization.jsonObject(
            with: Data(contentsOf: warningURL)
        ) as? [String: Any]
        XCTAssertEqual(warning?["retryState"] as? String, "cleanup-pending")
        XCTAssertTrue(
            (warning?["quarantinePath"] as? String)?.contains(
                ".lungfish-workbook-cleanup-pending-"
            ) == true
        )

        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: fixture.bundleURL,
            attestationRootURL: attestationRoot
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        XCTAssertFalse(
            try workbookCleanupArtifacts(in: root).contains {
                $0.lastPathComponent.contains("cleanup-state")
                    || $0.lastPathComponent.contains("cleanup-pending")
            }
        )
    }

    func testMarkerlessCleanupRetryRetainsQuarantineWhenSurvivorIsMissing() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-missing-survivor"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let held = paused.root.appendingPathComponent(
            "held-surviving-generation",
            isDirectory: true
        )
        let warningPathsBefore = Set(
            try workbookCleanupArtifacts(in: paused.root)
                .filter { $0.lastPathComponent.contains(".workbook-cleanup-warning-") }
                .map(\.lastPathComponent)
        )
        try FileManager.default.moveItem(at: paused.fixture.bundleURL, to: held)

        var reportedWarningURL: URL?
        var reportedQuarantinePath: String?
        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot
            )
        ) { error in
            guard case let ONTGenotypeWorkbookUpdateRecoveryError
                .cleanupPendingWarning(
                    quarantinePath,
                    retryState,
                    warningPath,
                    reason
                ) = error else {
                return XCTFail(
                    "Expected structured cleanup warning, got \(error.localizedDescription)"
                )
            }
            XCTAssertEqual(
                URL(fileURLWithPath: quarantinePath).resolvingSymlinksInPath(),
                paused.quarantine.resolvingSymlinksInPath()
            )
            XCTAssertEqual(retryState, "cleanup-pending")
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains(
                    "surviving workbook generation"
                )
            )
            reportedWarningURL = URL(fileURLWithPath: warningPath)
            reportedQuarantinePath = quarantinePath
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
        let warningURL = try XCTUnwrap(reportedWarningURL)
        let expectedWarningPrefix =
            ".\(paused.fixture.bundleURL.lastPathComponent).workbook-cleanup-warning-"
        XCTAssertTrue(warningURL.lastPathComponent.hasPrefix(expectedWarningPrefix))
        XCTAssertTrue(warningURL.lastPathComponent.hasSuffix(".json"))
        XCTAssertEqual(warningURL.deletingLastPathComponent(), paused.root)
        let warningPathsAfter = Set(
            try workbookCleanupArtifacts(in: paused.root)
                .filter { $0.lastPathComponent.contains(".workbook-cleanup-warning-") }
                .map(\.lastPathComponent)
        )
        XCTAssertEqual(
            warningPathsAfter.subtracting(warningPathsBefore),
            Set([warningURL.lastPathComponent])
        )
        let warning = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: warningURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(warning["schemaVersion"] as? Int, 1)
        XCTAssertEqual(warning["finalBundlePath"] as? String, paused.fixture.bundleURL.path)
        XCTAssertEqual(
            warning["quarantinePath"] as? String,
            try XCTUnwrap(reportedQuarantinePath)
        )
        XCTAssertEqual(warning["retryState"] as? String, "cleanup-pending")
        XCTAssertTrue(
            (warning["reason"] as? String)?.localizedCaseInsensitiveContains(
                "surviving workbook generation"
            ) == true
        )
    }

    func testMarkerlessCleanupRetryRetainsQuarantineWhenSurvivorIsSubstituted() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-substituted-survivor"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let held = paused.root.appendingPathComponent(
            "held-surviving-generation",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: paused.fixture.bundleURL, to: held)
        try FileManager.default.copyItem(at: held, to: paused.fixture.bundleURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "surviving workbook generation"
                )
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
        XCTAssertFalse(try workbookCleanupArtifacts(in: paused.root).isEmpty)
    }

    func testMarkerlessCleanupRetryRetainsQuarantineWhenSurvivorIntegrityIsCorrupt() throws {
        for target in ["manifest", "workbook"] {
            let paused = try pausedCommittedWorkbookCleanup(
                outputName: "cleanup-corrupt-\(target)"
            )
            defer {
                paused.lock.release()
                try? FileManager.default.removeItem(at: paused.root)
            }
            let targetURL: URL
            if target == "manifest" {
                targetURL = ONTGenotypeResultBundle.manifestURL(
                    in: paused.fixture.bundleURL
                )
            } else {
                targetURL = try ONTGenotypeResultBundle.currentWorkbookURL(
                    for: paused.fixture.bundleURL
                )
            }
            try Data("corrupt-survivor".utf8).write(to: targetURL, options: .atomic)

            XCTAssertThrowsError(
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: paused.fixture.bundleURL,
                    attestationRootURL: paused.attestationRoot
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains(
                        "surviving workbook generation"
                    )
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
            XCTAssertFalse(try workbookCleanupArtifacts(in: paused.root).isEmpty)
        }
    }

    func testWorkbookCleanupRetryNeverDeletesSubstitutedQuarantineInode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "cleanup-substitution")
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        let held = root.appendingPathComponent("held-retired-generation", isDirectory: true)
        let replacementSentinel = Data("replacement-must-survive".utf8)
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "during-workbook-cleanup-traversal" else { return }
                    let quarantine = try XCTUnwrap(
                        try FileManager.default.contentsOfDirectory(
                            at: root,
                            includingPropertiesForKeys: nil
                        ).first {
                            $0.lastPathComponent.hasPrefix(
                                ".lungfish-workbook-cleanup-pending-"
                            )
                        }
                    )
                    try FileManager.default.moveItem(at: quarantine, to: held)
                    try FileManager.default.createDirectory(
                        at: quarantine,
                        withIntermediateDirectories: false
                    )
                    try replacementSentinel.write(
                        to: quarantine.appendingPathComponent("replacement.txt")
                    )
                }
            )
        )

        let replacement = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-cleanup-pending-"
                )
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: replacement.appendingPathComponent("replacement.txt")),
            replacementSentinel
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL))

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: replacement.appendingPathComponent("replacement.txt")),
            replacementSentinel
        )
        XCTAssertFalse(try bundleSnapshot(held).isEmpty)
    }

    func testWorkbookCleanupNeverUnlinksSubstitutedRegularEntry() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-regular-entry-substitution"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let entry = paused.quarantine.appendingPathComponent("race-entry.txt")
        let held = paused.root.appendingPathComponent("held-original-entry.txt")
        let original = Data("original-retired-bytes".utf8)
        let replacement = Data("replacement-must-survive".utf8)
        try original.write(to: entry)
        let substituted = SendableFlagBox()

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint.hasPrefix(
                        "before-workbook-cleanup-nondirectory-detach:"
                    ), checkpoint.hasSuffix("/race-entry.txt") else {
                        return
                    }
                    try FileManager.default.moveItem(at: entry, to: held)
                    try replacement.write(to: entry)
                    substituted.set(1)
                }
            )
        )

        XCTAssertEqual(substituted.value, 1)
        XCTAssertEqual(try Data(contentsOf: held), original)
        XCTAssertEqual(try Data(contentsOf: entry), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
    }

    func testMarkerlessCleanupDiscoveryUsesIdentityBoundActualBundleCasing() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-case-discovery"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let alternateName = paused.fixture.bundleURL.lastPathComponent.uppercased()
        guard alternateName != paused.fixture.bundleURL.lastPathComponent else {
            throw XCTSkip("Fixture name has no alternate casing")
        }
        let alternateURL = paused.fixture.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(alternateName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: alternateURL.path) else {
            throw XCTSkip("Volume is case-sensitive")
        }

        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: alternateURL,
            attestationRootURL: paused.attestationRoot
        )

        XCTAssertNoThrow(
            try ONTGenotypeResultBundle.loadResult(from: paused.fixture.bundleURL)
        )
        XCTAssertFalse(
            try workbookCleanupArtifacts(in: paused.root).contains {
                $0.lastPathComponent.contains("cleanup-state")
                    || $0.lastPathComponent.contains("cleanup-pending")
            }
        )
    }

    func testCleanupReceiptsRemainPendingUntilQuarantineDeletionIsDurable() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-receipt-disposition"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        func receipts() throws -> [[String: Any]] {
            try FileManager.default.contentsOfDirectory(
                at: paused.root,
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.lastPathComponent.contains(".workbook-update-recovery-")
                    && $0.pathExtension == "json"
            }
            .map {
                try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: Data(contentsOf: $0)
                    ) as? [String: Any]
                )
            }
        }
        let pending = try receipts()
        XCTAssertTrue(pending.contains {
            $0["action"] as? String == "workbook-cleanup-authorized"
                && $0["exitStatus"] as? Int == 75
        })
        XCTAssertFalse(pending.contains {
            ($0["action"] as? String)?.hasPrefix("finished-") == true
                && $0["exitStatus"] as? Int == 0
        })

        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: paused.fixture.bundleURL,
            attestationRootURL: paused.attestationRoot
        )

        let completed = try receipts()
        XCTAssertTrue(completed.contains {
            $0["action"] as? String == "finished-committed-cleanup"
                && $0["exitStatus"] as? Int == 0
        })
        XCTAssertFalse(
            try workbookCleanupArtifacts(in: paused.root).contains {
                $0.lastPathComponent.contains("cleanup-state")
                    || $0.lastPathComponent.contains("cleanup-pending")
            }
        )
    }

    func testCleanupStateTransactionTamperingBeforeAttestationPreservesLiveAuthority()
        throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "cleanup-state-live-authority-tamper"
        )
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint
                        == "after-workbook-cleanup-state-write-before-attestation-hard-stop" else {
                        return
                    }
                    throw NSError(
                        domain: "InjectedCleanupStateBeforeReceiptCrash",
                        code: 9
                    )
                }
            )
        )
        let stateURL = try workbookCleanupStateURL(in: root)
        let quarantine = try XCTUnwrap(
            try workbookCleanupArtifacts(in: root).first {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-cleanup-pending-"
                )
            }
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(
            for: fixture.bundleURL
        )
        let attestationBefore = try Dictionary(
            uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
                at: attestationRoot,
                includingPropertiesForKeys: nil
            ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
        )
        XCTAssertFalse(
            attestationBefore.keys.contains {
                $0.hasSuffix(".workbook-cleanup.json")
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(
            try workbookRecoveryReceiptActions(in: root).contains(
                "workbook-cleanup-authorized"
            )
        )
        try mutateJSONObject(at: stateURL) { state in
            var transaction = try XCTUnwrap(
                state["transaction"] as? [String: Any]
            )
            transaction["toolVersion"] = "forged-cleanup-tool-version"
            state["transaction"] = transaction
        }
        let sentinelURL = quarantine.appendingPathComponent(
            "replacement-must-not-be-traversed.txt"
        )
        let sentinel = Data("unrelated replacement".utf8)
        try sentinel.write(to: sentinelURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "cleanup state"
                )
                    || error.localizedDescription
                        .localizedCaseInsensitiveContains("authority"),
                error.localizedDescription
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(
            try Dictionary(
                uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
                    at: attestationRoot,
                    includingPropertiesForKeys: nil
                ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
            ),
            attestationBefore
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertFalse(
            try workbookRecoveryReceiptActions(in: root).contains(
                "workbook-cleanup-authorized"
            )
        )
    }

    func testCleanupAttestationRehydrationRejectsMissingOriginalMarker()
        throws
    {
        let paused = try pausedBeforeCleanupAttestation(
            outputName: "cleanup-attestation-missing-original-marker"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let stateBefore = try Data(contentsOf: paused.stateURL)
        let attestationBefore = try Data(
            contentsOf: paused.transactionAttestationURL
        )
        try FileManager.default.removeItem(at: paused.markerURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot
            )
        )

        XCTAssertEqual(try? Data(contentsOf: paused.stateURL), stateBefore)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paused.quarantine.path)
        )
        XCTAssertEqual(
            try? Data(contentsOf: paused.transactionAttestationURL),
            attestationBefore
        )
        XCTAssertFalse(
            try workbookRecoveryReceiptActions(in: paused.root).contains(
                "workbook-cleanup-authorized"
            )
        )
    }

    func testCleanupAttestationRehydrationRejectsMalformedOriginalMarker()
        throws
    {
        let paused = try pausedBeforeCleanupAttestation(
            outputName: "cleanup-attestation-malformed-original-marker"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let stateBefore = try Data(contentsOf: paused.stateURL)
        let attestationBefore = try Data(
            contentsOf: paused.transactionAttestationURL
        )
        let malformedMarker = Data(#"{"transactionID":"truncated""#.utf8)
        try malformedMarker.write(to: paused.markerURL, options: .atomic)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot
            )
        )

        XCTAssertEqual(try? Data(contentsOf: paused.markerURL), malformedMarker)
        XCTAssertEqual(try? Data(contentsOf: paused.stateURL), stateBefore)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paused.quarantine.path)
        )
        XCTAssertEqual(
            try? Data(contentsOf: paused.transactionAttestationURL),
            attestationBefore
        )
        XCTAssertFalse(
            try workbookRecoveryReceiptActions(in: paused.root).contains(
                "workbook-cleanup-authorized"
            )
        )
    }

    func testPostReceiptCleanupStateRejectsEveryForgedDerivedAuthority() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-state-derived-authority-tamper"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let stateURL = try workbookCleanupStateURL(in: paused.root)
        let originalState = try Data(contentsOf: stateURL)
        typealias Mutation = (inout [String: Any]) throws -> Void
        let mutations: [(String, Mutation)] = [
            ("parent identity", { state in
                var identity = try XCTUnwrap(
                    state["parentIdentity"] as? [String: Any]
                )
                identity["inode"] = NSNumber(value: UInt64.max - 101)
                state["parentIdentity"] = identity
            }),
            ("source and quarantine identity", { state in
                let forged = NSNumber(value: UInt64.max - 102)
                var source = try XCTUnwrap(
                    state["sourceIdentity"] as? [String: Any]
                )
                var quarantine = try XCTUnwrap(
                    state["quarantineIdentity"] as? [String: Any]
                )
                source["inode"] = forged
                quarantine["inode"] = forged
                state["sourceIdentity"] = source
                state["quarantineIdentity"] = quarantine
            }),
            ("survivor identity", { state in
                var identity = try XCTUnwrap(
                    state["survivorIdentity"] as? [String: Any]
                )
                identity["device"] = NSNumber(value: UInt64.max - 103)
                state["survivorIdentity"] = identity
            }),
            ("survivor manifest descriptor", { state in
                var descriptor = try XCTUnwrap(
                    state["survivorManifest"] as? [String: Any]
                )
                descriptor["sha256"] = String(repeating: "a", count: 64)
                state["survivorManifest"] = descriptor
            }),
            ("survivor workbook descriptor", { state in
                var descriptor = try XCTUnwrap(
                    state["survivorCurrentWorkbook"] as? [String: Any]
                )
                descriptor["sizeBytes"] = NSNumber(value: -1)
                state["survivorCurrentWorkbook"] = descriptor
            }),
            ("terminal receipt disposition", { state in
                state["terminalReceiptAction"] = "forged-finished-cleanup"
                state["terminalReceiptDetail"] = "forged terminal detail"
            }),
        ]

        for (name, mutation) in mutations {
            try originalState.write(to: stateURL, options: .atomic)
            try mutateJSONObject(at: stateURL, mutation)
            XCTAssertThrowsError(
                try ONTGenotypeWorkbookUpdateRecovery.recoveryAuthorityExists(
                    for: paused.fixture.bundleURL
                ),
                name
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains(
                        "invalid workbook cleanup state"
                    ),
                    "\(name): \(error.localizedDescription)"
                )
            }
        }
        try originalState.write(to: stateURL, options: .atomic)
    }

    func testPostReceiptSemanticTamperingNeverTraversesCleanupQuarantine() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-state-semantic-traversal-tamper"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let stateURL = try workbookCleanupStateURL(in: paused.root)
        try mutateJSONObject(at: stateURL) { state in
            state["terminalReceiptAction"] = "forged-finished-cleanup"
        }
        let sentinelURL = paused.quarantine.appendingPathComponent(
            "replacement-must-not-be-traversed.txt"
        )
        let sentinel = Data("replacement survives semantic tamper".utf8)
        try sentinel.write(to: sentinelURL)
        let traversed = SendableFlagBox()

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "during-workbook-cleanup-traversal" else {
                        return
                    }
                    traversed.set(1)
                    throw NSError(
                        domain: "UnexpectedCleanupTraversal",
                        code: 1
                    )
                }
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "invalid workbook cleanup state"
                ),
                error.localizedDescription
            )
        }

        XCTAssertNil(traversed.value)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paused.quarantine.path)
        )
    }

    func testMarkerlessCleanupRejectsCoherentReplacementStateAfterAuthorityRetirement()
        throws
    {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-state-coherent-replacement"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let stateURL = try workbookCleanupStateURL(in: paused.root)
        let original = try Data(contentsOf: stateURL)
        var replacement = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        replacement["createdAt"] = "2036-01-02T03:04:05Z"
        try JSONSerialization.data(
            withJSONObject: replacement,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: stateURL, options: .atomic)
        let traversed = SendableFlagBox()

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    if checkpoint == "during-workbook-cleanup-traversal" {
                        traversed.set(1)
                    }
                }
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "cleanup attestation"
                ),
                error.localizedDescription
            )
        }
        XCTAssertNil(traversed.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
        XCTAssertEqual(
            try Data(contentsOf: stateURL),
            try JSONSerialization.data(
                withJSONObject: replacement,
                options: [.prettyPrinted, .sortedKeys]
            )
        )
    }

    func testMissingCleanupAttestationWithoutOriginalAuthorityFailsClosed()
        throws
    {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-attestation-missing-after-authority"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let cleanupAttestation = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: paused.attestationRoot,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasSuffix(
                    ".workbook-cleanup.json"
                )
            }
        )
        try FileManager.default.removeItem(at: cleanupAttestation)
        let traversed = SendableFlagBox()

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    if checkpoint == "during-workbook-cleanup-traversal" {
                        traversed.set(1)
                    }
                }
            )
        )

        XCTAssertNil(traversed.value)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paused.quarantine.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cleanupAttestation.path
            )
        )
    }

    func testWorkbookCleanupRetirementNeverUnlinksSubstitutedMarker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "cleanup-marker-retirement-substitution"
        )
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        let marker = ONTGenotypeWorkbookUpdateRecovery.markerURL(
            for: fixture.bundleURL
        )
        let held = root.appendingPathComponent("held-authenticated-marker.json")
        let replacement = Data(#"{"replacement":"marker-must-survive"}"#.utf8)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint.hasPrefix(
                        "before-workbook-cleanup-marker-detach:"
                    ) else { return }
                    try FileManager.default.moveItem(at: marker, to: held)
                    try replacement.write(to: marker)
                }
            )
        )

        XCTAssertEqual(try Data(contentsOf: marker), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertFalse(try workbookCleanupArtifacts(in: root).isEmpty)
    }

    func testWorkbookCleanupPostWitnessMarkerSubstitutionIsPreserved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "cleanup-marker-post-witness-substitution"
        )
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        let marker = ONTGenotypeWorkbookUpdateRecovery.markerURL(
            for: fixture.bundleURL
        )
        let authenticatedMarker = try Data(contentsOf: marker)
        let held = root.appendingPathComponent(
            "held-post-witness-authenticated-marker.json"
        )
        let replacement = Data(
            #"{"replacement":"post-witness-marker-must-survive"}"#.utf8
        )
        let substituted = SendableFlagBox()

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint.hasPrefix(
                        "after-workbook-retirement-witness:"
                    ), checkpoint.hasSuffix(marker.path) else {
                        return
                    }
                    let tombstones = try FileManager.default
                        .contentsOfDirectory(
                            at: root,
                            includingPropertiesForKeys: nil
                        )
                        .filter {
                            $0.lastPathComponent.hasPrefix(
                                ".lungfish-workbook-retiring-"
                            )
                        }
                    let tombstone = try XCTUnwrap(tombstones.first)
                    XCTAssertEqual(tombstones.count, 1)
                    try FileManager.default.moveItem(
                        at: tombstone,
                        to: held
                    )
                    try replacement.write(to: tombstone)
                    substituted.set(1)
                }
            )
        )

        XCTAssertEqual(substituted.value, 1)
        XCTAssertEqual(try Data(contentsOf: held), authenticatedMarker)
        let preservedTombstones = try FileManager.default
            .contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-retiring-"
                )
            }
        XCTAssertEqual(preservedTombstones.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(preservedTombstones.first)),
            replacement
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(try workbookCleanupArtifacts(in: root).isEmpty)
    }

    func testWorkbookCleanupRetirementNeverUnlinksSubstitutedAttestation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "cleanup-attestation-retirement-substitution"
        )
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        let held = root.appendingPathComponent("held-authenticated-attestation.json")
        let replacement = Data(#"{"replacement":"attestation-must-survive"}"#.utf8)
        let marker = ONTGenotypeWorkbookUpdateRecovery.markerURL(
            for: fixture.bundleURL
        )
        let markerJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: marker)
            ) as? [String: Any]
        )
        let attestation = attestationRoot.appendingPathComponent(
            "\(try XCTUnwrap(markerJSON["attestationID"] as? String)).json"
        )

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    let prefix =
                        "before-workbook-cleanup-attestation-detach:"
                    guard checkpoint.hasPrefix(prefix) else { return }
                    let url = URL(
                        fileURLWithPath: String(checkpoint.dropFirst(prefix.count))
                    )
                    XCTAssertEqual(url.standardizedFileURL, attestation.standardizedFileURL)
                    try FileManager.default.moveItem(at: url, to: held)
                    try replacement.write(to: url)
                }
            )
        )

        XCTAssertEqual(try Data(contentsOf: attestation), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertFalse(try workbookCleanupArtifacts(in: root).isEmpty)
    }

    func testWorkbookCleanupRetirementNeverRemovesSubstitutedQuarantineRoot() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-quarantine-retirement-substitution"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let held = paused.root.appendingPathComponent(
            "held-authenticated-quarantine",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint.hasPrefix(
                        "before-workbook-cleanup-quarantine-detach:"
                    ) else { return }
                    try FileManager.default.moveItem(
                        at: paused.quarantine,
                        to: held
                    )
                    try FileManager.default.createDirectory(
                        at: paused.quarantine,
                        withIntermediateDirectories: false
                    )
                }
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertNotNil(try? workbookCleanupStateURL(in: paused.root))
    }

    func testWorkbookCleanupRetirementNeverUnlinksSubstitutedCleanupState() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-state-retirement-substitution"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let state = try workbookCleanupStateURL(in: paused.root)
        let held = paused.root.appendingPathComponent(
            "held-authenticated-cleanup-state.json"
        )
        var replacementObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: state)
            ) as? [String: Any]
        )
        replacementObject["createdAt"] = "2037-02-03T04:05:06Z"
        let replacement = try JSONSerialization.data(
            withJSONObject: replacementObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint.hasPrefix(
                        "before-workbook-cleanup-state-detach:"
                    ) else { return }
                    try FileManager.default.moveItem(at: state, to: held)
                    try replacement.write(to: state)
                }
            )
        )

        XCTAssertEqual(try Data(contentsOf: state), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
    }

    func testCleanupWarningPersistenceFailurePreservesOriginalStructuredCause() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-warning-write-failure"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let held = paused.root.appendingPathComponent(
            "held-missing-survivor",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: paused.fixture.bundleURL, to: held)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "before-workbook-cleanup-warning-write" else {
                        return
                    }
                    throw NSError(
                        domain: "InjectedWorkbookCleanupWarningWrite",
                        code: 17,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "injected warning persistence failure",
                        ]
                    )
                }
            )
        ) { error in
            guard case let ONTGenotypeWorkbookUpdateRecoveryError
                .cleanupPendingWarningPersistenceFailure(
                    quarantinePath,
                    retryState,
                    reason,
                    warningFailure
                ) = error else {
                return XCTFail("Expected combined cleanup warning failure: \(error)")
            }
            XCTAssertEqual(retryState, "cleanup-pending")
            XCTAssertEqual(
                URL(fileURLWithPath: quarantinePath)
                    .resolvingSymlinksInPath().path,
                paused.quarantine.resolvingSymlinksInPath().path
            )
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains(
                    "surviving workbook generation"
                )
            )
            XCTAssertEqual(warningFailure, "injected warning persistence failure")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
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

    func testCandidateGenBankIdentityMismatchFailsBeforeWorkbookReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-genbank-identity")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let candidateGenBankURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(artifacts.candidateGenBank).path,
            in: fixture.bundleURL
        )
        var records = try GenBankReader(url: candidateGenBankURL).readAllSync()
        let first = try XCTUnwrap(records.first)
        records[0] = try normalizedCandidateGenBankRecord(
            stableID: "wrong-cluster-id",
            sequence: first.sequence.asString(),
            translation: "AAAAAAAAAAAAA",
            status: "full-length"
        )
        try GenBankWriter(url: candidateGenBankURL).write(records)
        let revisedArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: artifacts.candidateJSON,
            candidateFASTA: artifacts.candidateFASTA,
            candidateGenBank: try artifactReference(candidateGenBankURL, relativeTo: fixture.bundleURL),
            unnameableJSON: artifacts.unnameableJSON,
            unnameableFASTA: artifacts.unnameableFASTA,
            unnameableGenBank: artifacts.unnameableGenBank
        )
        let revisedManifest = ONTGenotypeResultBundleManifest(
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
            mhcCandidateArtifacts: revisedArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(revisedManifest, to: fixture.bundleURL)
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try serviceThatFailsIfStagingBegins()
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
            XCTAssertTrue(error.localizedDescription.contains("Invalid unmatched MHC artifact identity"))
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testAmbiguousManagedCandidateMarkersFailClosedWithoutBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "ambiguous-candidate-markers")
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb["Full Sequencing Results 1"].append(["LGE MHC Candidate Alleles [BEGIN]"])
wb.save(path)
"""#, currentURL.path])
        XCTAssertNoThrow(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
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
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
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
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        XCTAssertEqual(marker["schemaVersion"] as? Int, 5)
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
        XCTAssertNotNil(marker["finalParentIdentity"] as? [String: Any])

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
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
    }

    func testMarkerFallbackNeverOverwritesForeignConcurrentMarker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "foreign-marker-race")
        let before = try bundleSnapshot(fixture.bundleURL)
        let foreignBytes = Data("foreign-marker-must-survive".utf8)

        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-transaction-marker-source-conflict-check" else {
                        return
                    }
                    try foreignBytes.write(to: markerURL, options: .withoutOverwriting)
                },
                forceBundleCloneFallback: true
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertEqual(try Data(contentsOf: markerURL), foreignBytes)
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testRotationFallbackNeverOverwritesForeignConcurrentDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "foreign-rotation-race")
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                directoryMovePrimitive: { _, _, destinationParent, destinationName, flags in
                    guard flags == UInt32(RENAME_EXCL) else {
                        errno = EINVAL
                        return -1
                    }
                    _ = destinationName.withCString {
                        Darwin.mkdirat(destinationParent, $0, S_IRWXU)
                    }
                    let reservation = destinationName.withCString {
                        Darwin.openat(
                            destinationParent,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    if reservation >= 0 {
                        let sentinel = Darwin.openat(
                            reservation,
                            "foreign-sentinel.txt",
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            S_IRUSR | S_IWUSR
                        )
                        if sentinel >= 0 {
                            _ = Darwin.write(sentinel, "survive", 7)
                            Darwin.close(sentinel)
                        }
                        Darwin.close(reservation)
                    }
                    errno = ENOTSUP
                    return -1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        let marker = try markerObject(
            at: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        )
        let rotation = URL(
            fileURLWithPath: try XCTUnwrap(marker["rotationTemporaryPath"] as? String),
            isDirectory: true
        )
        XCTAssertEqual(
            try Data(contentsOf: rotation.appendingPathComponent("foreign-sentinel.txt")),
            Data("survive".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(marker["stagingBundlePath"] as? String)
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
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
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
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
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
        let rollbackTimestamp = Date(timeIntervalSince1970: 6_500)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { rollbackTimestamp },
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
        let receiptProvenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: receiptURL)
        ))
        XCTAssertEqual(receiptProvenance.createdAt, rollbackTimestamp)
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        XCTAssertEqual(marker["phase"] as? String, "prepared", "The authenticated transaction marker is immutable")
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
        try assertNoRetiredWorkbookGeneration(in: root)
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
        try assertNoRetiredWorkbookGeneration(in: root)
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

    func testWorkbookRevisionPreservesScientificArtifactManifestFields() throws {
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
        let unmatchedClustersPath = "artifacts/candidates/deduplicated-unmatched-clusters.fasta"
        let reviewableRowCatalog = ONTMHCArtifactReference(
            path: "artifacts/review/reviewable-row-catalog.json",
            sha256: String(repeating: "c", count: 64),
            sizeBytes: 314
        )
        let manifest = ONTGenotypeResultBundleManifest(
            schemaVersion: fixture.manifest.schemaVersion,
            kind: fixture.manifest.kind,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: fixture.manifest.outputName,
            analysisName: fixture.manifest.analysisName,
            primaryWorkbookPath: fixture.manifest.primaryWorkbookPath,
            currentWorkbookPath: fixture.manifest.currentWorkbookPath,
            workbookRevisions: fixture.manifest.workbookRevisions,
            longSummaryCSVPath: fixture.manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: fixture.manifest.sampleSummaryCSVPath,
            statsJSONPath: fixture.manifest.statsJSONPath,
            provenancePath: fixture.manifest.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: unmatchedClustersPath,
            mhcCandidateArtifacts: candidateArtifacts,
            referenceRecordStore: fixture.manifest.referenceRecordStore,
            reviewableRowCatalog: reviewableRowCatalog
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)
        let replacement = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: replacement)

        let updated = try GenotypeWorkbookRevisionService()
            .importRevisedWorkbook(from: replacement, into: fixture.bundleURL)

        XCTAssertEqual(updated.mhcCandidateArtifacts, candidateArtifacts)
        XCTAssertEqual(updated.reviewableRowCatalog, reviewableRowCatalog)
        XCTAssertEqual(updated.deduplicatedUnmatchedClustersFASTAPath, unmatchedClustersPath)
        XCTAssertEqual(updated.referenceRecordStore, fixture.manifest.referenceRecordStore)
        XCTAssertEqual(updated.workflowKind, .fullLengthONTMHCGenotype)
        XCTAssertEqual(updated.workflowMode, .genotypeOnly)
    }

    func testWorkbookRevisionPreservesMalformedWorkflowDeclarations() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(
            in: root,
            outputName: "malformed-workflow-preservation",
            includeCurrent: true
        )
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        object["workflowKind"] = ["future": "mhc-workflow"]
        object["workflowMode"] = NSNull()
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        let malformed = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let originalKind = malformed.workflowKindDeclaration.originalValue
        let originalMode = malformed.workflowModeDeclaration.originalValue
        XCTAssertNil(malformed.workflowKind)
        XCTAssertNil(malformed.workflowMode)
        XCTAssertNotNil(malformed.workflowKindDeclaration.issue)
        XCTAssertNotNil(malformed.workflowModeDeclaration.issue)

        let replacement = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: replacement)
        let updated = try GenotypeWorkbookRevisionService()
            .importRevisedWorkbook(from: replacement, into: fixture.bundleURL)

        XCTAssertEqual(updated.workflowKindDeclaration.originalValue, originalKind)
        XCTAssertEqual(updated.workflowModeDeclaration.originalValue, originalMode)
        XCTAssertNil(updated.workflowKind)
        XCTAssertNil(updated.workflowMode)
        XCTAssertNotNil(updated.workflowKindDeclaration.issue)
        XCTAssertNotNil(updated.workflowModeDeclaration.issue)
        let reencoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(updated)) as? [String: Any]
        )
        XCTAssertEqual(
            (reencoded["workflowKind"] as? [String: String])?["future"],
            "mhc-workflow"
        )
        XCTAssertTrue(reencoded["workflowMode"] is NSNull)
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

    func testApplyManualHaplotypeSnapshotWritesFourteenLiteralValuesAndSidecarRevisionProvenance()
        throws
    {
        XCTAssertTrue(
            pythonCanImportOpenpyxl(),
            "The managed test runtime must provide openpyxl"
        )
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "manual-fourteen",
            workflowKind: .fullLengthONTMHCGenotype
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.lastEditedAt = "2026-07-27T12:00:00Z"
        sidecar.lastEditor = "manual-curator"
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "DW472",
                locus: "MHC-A",
                slot: .h1,
                label: "=LITERAL_NOT_FORMULA",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: "manual workbook snapshot"
            ),
        ]
        let sidecarData = try sidecar.encoded()
        try sidecarData.write(to: annotationURL)
        let sidecarSHA256 = try ProvenanceFileHasher.sha256(
            of: annotationURL
        )
        let authoritativeCSVURLs = [
            ONTGenotypeResultBundle.resolvedURL(
                for: fixture.manifest.longSummaryCSVPath,
                in: fixture.bundleURL
            ),
            ONTGenotypeResultBundle.resolvedURL(
                for: fixture.manifest.sampleSummaryCSVPath,
                in: fixture.bundleURL
            ),
        ]
        let authoritativeCSVDescriptors = try authoritativeCSVURLs.map {
            (
                url: $0,
                sha256: try ProvenanceFileHasher.sha256(of: $0),
                size: try ProvenanceFileHasher.fileSize(of: $0)
            )
        }
        let calls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-A",
                haplotype1: "=LITERAL_NOT_FORMULA",
                haplotype2: "+PLUS_LITERAL",
                status: "called",
                notes: "manual workbook snapshot"
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-B",
                haplotype1: "-MINUS_LITERAL",
                haplotype2: "@AT_LITERAL",
                status: "called",
                notes: ""
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-DRB",
                haplotype1: "Manual-DRB-1",
                haplotype2: "Manual-DRB-2",
                status: "called",
                notes: ""
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-DQA",
                haplotype1: "Manual-DQA-1",
                haplotype2: "Manual-DQA-2",
                status: "called",
                notes: ""
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-DQB",
                haplotype1: "Manual-DQB-1",
                haplotype2: "Manual-DQB-2",
                status: "called",
                notes: ""
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-DPA",
                haplotype1: "Manual-DPA-1",
                haplotype2: "Manual-DPA-2",
                status: "called",
                notes: ""
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-DPB",
                haplotype1: "Manual-DPB-1",
                haplotype2: "Manual-DPB-2",
                status: "called",
                notes: ""
            ),
        ]

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_050) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "attestations"
            )
        ).applyHaplotypeOverrides(
            calls,
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            projectionMode: .manualGenotypeOnly
        )

        let inspection = try inspectMCMWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(
                for: fixture.bundleURL
            )
        )
        XCTAssertEqual(
            inspection["fullAHaplotype1"],
            "=LITERAL_NOT_FORMULA"
        )
        XCTAssertEqual(inspection["fullAHaplotype1Type"], "s")
        XCTAssertEqual(inspection["fullAHaplotype2"], "+PLUS_LITERAL")
        XCTAssertEqual(inspection["fullAHaplotype2Type"], "s")
        XCTAssertEqual(inspection["fullBHaplotype1"], "-MINUS_LITERAL")
        XCTAssertEqual(inspection["fullBHaplotype1Type"], "s")
        XCTAssertEqual(inspection["fullBHaplotype2"], "@AT_LITERAL")
        XCTAssertEqual(inspection["fullBHaplotype2Type"], "s")
        XCTAssertEqual(inspection["fullDRBHaplotype1"], "Manual-DRB-1")
        XCTAssertEqual(inspection["fullDRBHaplotype2"], "Manual-DRB-2")
        XCTAssertEqual(inspection["fullDQAHaplotype1"], "Manual-DQA-1")
        XCTAssertEqual(inspection["fullDQAHaplotype2"], "Manual-DQA-2")
        XCTAssertEqual(inspection["fullDQBHaplotype1"], "Manual-DQB-1")
        XCTAssertEqual(inspection["fullDQBHaplotype2"], "Manual-DQB-2")
        XCTAssertEqual(inspection["fullDPAHaplotype1"], "Manual-DPA-1")
        XCTAssertEqual(inspection["fullDPAHaplotype2"], "Manual-DPA-2")
        XCTAssertEqual(inspection["fullDPBHaplotype1"], "Manual-DPB-1")
        XCTAssertEqual(inspection["fullDPBHaplotype2"], "Manual-DPB-2")
        XCTAssertEqual(
            inspection["abbreviatedDQHaplotype1"],
            "MHC-DQA: Manual-DQA-1; MHC-DQB: Manual-DQB-1"
        )
        XCTAssertEqual(
            inspection["abbreviatedDQHaplotype2"],
            "MHC-DQA: Manual-DQA-2; MHC-DQB: Manual-DQB-2"
        )
        XCTAssertEqual(
            inspection["abbreviatedDPHaplotype1"],
            "MHC-DPA: Manual-DPA-1; MHC-DPB: Manual-DPB-1"
        )
        XCTAssertEqual(
            inspection["abbreviatedDPHaplotype2"],
            "MHC-DPA: Manual-DPA-2; MHC-DPB: Manual-DPB-2"
        )
        XCTAssertEqual(
            inspection["customDQHaplotype1"],
            "MHC-DQA: Manual-DQA-1; MHC-DQB: Manual-DQB-1"
        )
        XCTAssertEqual(
            inspection["customDPHaplotype1"],
            "MHC-DPA: Manual-DPA-1; MHC-DPB: Manual-DPB-1"
        )

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(
                updated.workbookRevisions?.last?.provenancePath
            ),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        XCTAssertEqual(
            pythonStep.resolvedOptions[
                "annotationSidecarRevisionSHA256"
            ],
            .string(sidecarSHA256)
        )
        XCTAssertEqual(
            pythonStep.resolvedOptions["haplotypeProjectionMode"],
            .string("manual-genotype-only")
        )
        XCTAssertTrue(
            pythonStep.inputs.contains {
                URL(fileURLWithPath: $0.path).lastPathComponent
                    == GenotypeAnnotationSidecar.filename
                    && $0.checksumSHA256 == sidecarSHA256
                    && $0.fileSize == UInt64(sidecarData.count)
                }
        )
        for expected in authoritativeCSVDescriptors {
            XCTAssertTrue(
                pythonStep.inputs.contains {
                    $0.path == expected.url.path
                        && $0.checksumSHA256 == expected.sha256
                        && $0.fileSize == expected.size
                },
                expected.url.lastPathComponent
            )
            XCTAssertTrue(
                envelope.files.contains {
                    $0.role == .input
                        && $0.path == expected.url.path
                        && $0.checksumSHA256 == expected.sha256
                        && $0.fileSize == expected.size
                },
                expected.url.lastPathComponent
            )
        }

        let twoSheetFixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "manual-fourteen-two-sheet",
            workflowKind: .fullLengthONTMHCGenotype
        )
        try installCandidateArtifacts(in: twoSheetFixture.bundleURL)
        try installMinimalUnifiedPivot(in: twoSheetFixture.bundleURL)
        let twoSheetCalls = calls.map {
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: $0.locus,
                haplotype1: $0.haplotype1,
                haplotype2: $0.haplotype2,
                status: $0.status,
                notes: $0.notes
            )
        } + GenotypeManualHaplotypeLocus.allCases.map {
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-b",
                locus: $0.rawValue,
                haplotype1: "",
                haplotype2: "",
                status: "called",
                notes: ""
            )
        }
        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_051) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "attestations"
            )
        ).applyHaplotypeOverrides(
            twoSheetCalls,
            annotationSidecarURL: nil,
            into: twoSheetFixture.bundleURL,
            projectionMode: .manualGenotypeOnly
        )
        let twoSheetInspection = try inspectTwoSheetCandidateWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(
                for: twoSheetFixture.bundleURL
            )
        )
        XCTAssertEqual(
            twoSheetInspection["analystHaplotype"],
            "=LITERAL_NOT_FORMULA"
        )
        XCTAssertEqual(twoSheetInspection["analystHaplotypeType"], "s")
        XCTAssertEqual(
            twoSheetInspection["analystHaplotype2"],
            "+PLUS_LITERAL"
        )
        XCTAssertEqual(twoSheetInspection["analystHaplotype2Type"], "s")
        XCTAssertEqual(
            twoSheetInspection["sampleABHaplotype1"],
            "-MINUS_LITERAL"
        )
        XCTAssertEqual(twoSheetInspection["sampleABHaplotype1Type"], "s")
        XCTAssertEqual(
            twoSheetInspection["sampleABHaplotype2"],
            "@AT_LITERAL"
        )
        XCTAssertEqual(twoSheetInspection["sampleABHaplotype2Type"], "s")
        XCTAssertEqual(
            twoSheetInspection["sampleADRBHaplotype1"],
            "Manual-DRB-1"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADRBHaplotype2"],
            "Manual-DRB-2"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADQAHaplotype1"],
            "Manual-DQA-1"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADQAHaplotype2"],
            "Manual-DQA-2"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADQBHaplotype1"],
            "Manual-DQB-1"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADQBHaplotype2"],
            "Manual-DQB-2"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADPAHaplotype1"],
            "Manual-DPA-1"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADPAHaplotype2"],
            "Manual-DPA-2"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADPBHaplotype1"],
            "Manual-DPB-1"
        )
        XCTAssertEqual(
            twoSheetInspection["sampleADPBHaplotype2"],
            "Manual-DPB-2"
        )
    }

    func testCompleteSevenLocusHaplotypedSnapshotIsNeverInferredAsManual()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "seven-locus-haplotyped"
        )
        let calls = [
            ("MHC-A", "HAP-A-1", "HAP-A-2"),
            ("MHC-B", "HAP-B-1", "HAP-B-2"),
            ("MHC-DRB", "HAP-DRB-1", "HAP-DRB-2"),
            ("MHC-DQA", "HAP-DQA-1", "HAP-DQA-2"),
            ("MHC-DQB", "HAP-DQB-1", "HAP-DQB-2"),
            ("MHC-DPA", "HAP-DPA-1", "HAP-DPA-2"),
            ("MHC-DPB", "HAP-DPB-1", "HAP-DPB-2"),
        ].map {
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: $0.0,
                haplotype1: $0.1,
                haplotype2: $0.2,
                status: "called",
                notes: ""
            )
        }

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_052) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "attestations"
            )
        ).applyHaplotypeOverrides(
            calls,
            annotationSidecarURL: nil,
            into: fixture.bundleURL,
            projectionMode: .haplotyped
        )

        let inspection = try inspectMCMWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(
                for: fixture.bundleURL
            )
        )
        XCTAssertEqual(inspection["fullAHaplotype1"], "HAP-A-1")
        // Haplotyped mode intentionally preserves the established canonical
        // DQ/DP projection: the last canonical call supplies both split rows.
        XCTAssertEqual(inspection["fullDQAHaplotype1"], "HAP-DQB-1")
        XCTAssertEqual(inspection["fullDQBHaplotype1"], "HAP-DQB-1")
        XCTAssertEqual(inspection["fullDPAHaplotype1"], "HAP-DPB-1")
        XCTAssertEqual(inspection["fullDPBHaplotype1"], "HAP-DPB-1")
        XCTAssertEqual(
            inspection["abbreviatedDQHaplotype1"],
            "HAP-DQB-1"
        )
        XCTAssertEqual(
            inspection["abbreviatedDPHaplotype1"],
            "HAP-DPB-1"
        )
    }

    func testHaplotypedDuplicateExactLocusPreservesEstablishedLastWinsBehavior()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "haplotyped-duplicate-last-wins"
        )
        let calls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-DQA",
                haplotype1: "First-DQ",
                haplotype2: "",
                status: "called",
                notes: ""
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: "MHC-DQA",
                haplotype1: "Last-DQ",
                haplotype2: "",
                status: "called",
                notes: ""
            ),
        ]

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_052.5) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "attestations"
            )
        ).applyHaplotypeOverrides(
            calls,
            annotationSidecarURL: nil,
            into: fixture.bundleURL,
            projectionMode: .haplotyped
        )

        let inspection = try inspectMCMWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(
                for: fixture.bundleURL
            )
        )
        XCTAssertEqual(inspection["fullDQAHaplotype1"], "Last-DQ")
        XCTAssertEqual(inspection["fullDQBHaplotype1"], "Last-DQ")
        XCTAssertEqual(
            inspection["abbreviatedDQHaplotype1"],
            "Last-DQ"
        )
    }

    func testTypedONTAndMiSeqGenotypeOnlyBundlesMaterializeManualSnapshots()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in GenotypeResultWorkflowKind.allCases {
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: "typed-\(kind.rawValue)",
                workflowKind: kind
            )
            let calls = GenotypeManualHaplotypeLocus.allCases.map {
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: $0.rawValue,
                    haplotype1:
                        $0 == .a ? "=typed-\(kind.rawValue)" : "",
                    haplotype2: "",
                    status: "called",
                    notes: ""
                )
            }
            let updated = try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 5_053) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                workbookAttestationRootURL: root.appendingPathComponent(
                    "attestations"
                )
            ).applyHaplotypeOverrides(
                calls,
                annotationSidecarURL: nil,
                into: fixture.bundleURL,
                projectionMode: .manualGenotypeOnly
            )
            let inspection = try inspectMCMWorkbook(
                try ONTGenotypeResultBundle.currentWorkbookURL(
                    for: fixture.bundleURL
                )
            )
            XCTAssertEqual(
                inspection["fullAHaplotype1"],
                "=typed-\(kind.rawValue)"
            )
            XCTAssertEqual(inspection["fullAHaplotype1Type"], "s")
            XCTAssertEqual(updated.workflowKind, kind)
            XCTAssertEqual(updated.workflowMode, .genotypeOnly)
        }
    }

    func testLegacyCombinedManualRowsComposeEmptySingleSameAndDistinctValues()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = [
            (
                name: "empty",
                first: "",
                second: "",
                expectedDQ: "",
                expectedDP: ""
            ),
            (
                name: "single",
                first: "Only",
                second: "",
                expectedDQ: "MHC-DQA: DQ-Only",
                expectedDP: "MHC-DPA: DP-Only"
            ),
            (
                name: "same",
                first: "Same",
                second: "Same",
                expectedDQ: "DQ-Same",
                expectedDP: "DP-Same"
            ),
            (
                name: "distinct",
                first: "First",
                second: "Second",
                expectedDQ:
                    "MHC-DQA: DQ-First; MHC-DQB: DQ-Second",
                expectedDP:
                    "MHC-DPA: DP-First; MHC-DPB: DP-Second"
            ),
        ]
        for item in cases {
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: "legacy-composition-\(item.name)",
                workflowKind: .fullLengthONTMHCGenotype
            )
            let calls = GenotypeManualHaplotypeLocus.allCases.map { locus in
                let value: String
                switch locus {
                case .dqa:
                    value =
                        item.first.isEmpty ? "" : "DQ-\(item.first)"
                case .dqb:
                    value =
                        item.second.isEmpty ? "" : "DQ-\(item.second)"
                case .dpa:
                    value =
                        item.first.isEmpty ? "" : "DP-\(item.first)"
                case .dpb:
                    value =
                        item.second.isEmpty ? "" : "DP-\(item.second)"
                default:
                    value = ""
                }
                return GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: locus.rawValue,
                    haplotype1: value,
                    haplotype2: "",
                    status: "called",
                    notes: ""
                )
            }
            _ = try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 5_055) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                workbookAttestationRootURL: root.appendingPathComponent(
                    "attestations"
                )
            ).applyHaplotypeOverrides(
                calls,
                annotationSidecarURL: nil,
                into: fixture.bundleURL,
                projectionMode: .manualGenotypeOnly
            )
            let inspection = try inspectMCMWorkbook(
                try ONTGenotypeResultBundle.currentWorkbookURL(
                    for: fixture.bundleURL
                )
            )
            for key in [
                "abbreviatedDQHaplotype1",
                "customDQHaplotype1",
            ] {
                XCTAssertEqual(inspection[key], item.expectedDQ, key)
            }
            for key in [
                "abbreviatedDPHaplotype1",
                "customDPHaplotype1",
            ] {
                XCTAssertEqual(inspection[key], item.expectedDP, key)
            }
            XCTAssertEqual(inspection["abbreviatedDQHaplotype2"], "")
            XCTAssertEqual(inspection["abbreviatedDPHaplotype2"], "")
        }

        let script = GenotypeWorkbookRevisionService(
            workbookAttestationRootURL: root.appendingPathComponent(
                "attestations"
            )
        ).workbookOverrideScript
        XCTAssertTrue(
            script.contains("manual_haplotype_legacy_combined_rows")
        )
        XCTAssertFalse(script.contains("MHC-DQA/B Haplotype"))
        XCTAssertFalse(script.contains("MHC-DPA/B Haplotype"))
    }

    func testRecognizedLegacyGenotypeOnlyKindsUseSharedManualAuthority()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in GenotypeResultWorkflowKind.allCases {
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: "recognized-legacy-\(kind.rawValue)",
                manifestKind: kind.rawValue
            )
            let calls = GenotypeManualHaplotypeLocus.allCases.map {
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: $0.rawValue,
                    haplotype1: $0 == .a ? "Legacy-Manual-A" : "",
                    haplotype2: "",
                    status: "called",
                    notes: ""
                )
            }
            _ = try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 5_056) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                workbookAttestationRootURL: root.appendingPathComponent(
                    "attestations"
                )
            ).applyHaplotypeOverrides(
                calls,
                annotationSidecarURL: nil,
                into: fixture.bundleURL,
                projectionMode: .manualGenotypeOnly
            )
            let inspection = try inspectMCMWorkbook(
                try ONTGenotypeResultBundle.currentWorkbookURL(
                    for: fixture.bundleURL
                )
            )
            XCTAssertEqual(
                inspection["fullAHaplotype1"],
                "Legacy-Manual-A"
            )
        }
    }

    func testManualProjectionRejectsUnauthorizedManifestBeforeWorkbookMutation()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = [
            try makeMCMWorkbookBundle(
                in: root,
                outputName: "ambiguous-legacy-manual"
            ),
            try makeMCMWorkbookBundle(
                in: root,
                outputName: "typed-haplotyped-manual",
                workflowKind: .fullLengthONTMHCGenotype,
                workflowMode: .haplotyped
            ),
            try makeMCMWorkbookBundle(
                in: root,
                outputName: "contradictory-kind-manual",
                manifestKind:
                    GenotypeResultWorkflowKind
                        .miSeqAmpliconMHCGenotype.rawValue,
                workflowKind: .fullLengthONTMHCGenotype
            ),
            try makeMCMWorkbookBundle(
                in: root,
                outputName: "contradictory-authority-manual",
                workflowKind: .fullLengthONTMHCGenotype,
                haplotypeAnalysisPath: "haplotypes/current.json"
            ),
        ]
        let calls = GenotypeManualHaplotypeLocus.allCases.map {
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: $0.rawValue,
                haplotype1: "Manual-\($0.rawValue)",
                haplotype2: "",
                status: "called",
                notes: ""
            )
        }

        for fixture in fixtures {
            let bundleBefore = try directorySnapshot(fixture.bundleURL)
            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    dateProvider: { Date(timeIntervalSince1970: 5_054) },
                    userProvider: { "tester" },
                    pythonExecutableURL: testPythonExecutableURL,
                    workbookAttestationRootURL: root.appendingPathComponent(
                        "attestations"
                    )
                ).applyHaplotypeOverrides(
                    calls,
                    annotationSidecarURL: nil,
                    into: fixture.bundleURL,
                    projectionMode: .manualGenotypeOnly
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains(
                        "not authorized"
                    )
                )
            }
            XCTAssertEqual(
                try directorySnapshot(fixture.bundleURL),
                bundleBefore
            )
        }
    }

    func testManualProjectionRequiresCompleteAuthoritativeSampleSetBeforeMutation()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let completeDW472 = GenotypeManualHaplotypeLocus.allCases.map {
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: $0.rawValue,
                haplotype1: "",
                haplotype2: "",
                status: "called",
                notes: ""
            )
        }
        let cases: [(String, [GenotypeWorkbookHaplotypeCall], Bool)] = [
            ("empty", [], false),
            ("incomplete", Array(completeDW472.prefix(6)), false),
            (
                "extra",
                completeDW472
                    + completeDW472.map {
                        GenotypeWorkbookHaplotypeCall(
                            sample: "Extra",
                            locus: $0.locus,
                            haplotype1: $0.haplotype1,
                            haplotype2: $0.haplotype2,
                            status: $0.status,
                            notes: $0.notes
                        )
                    },
                false
            ),
            ("omitted", completeDW472, true),
            (
                "noncanonical-loci",
                completeDW472.map {
                    GenotypeWorkbookHaplotypeCall(
                        sample: $0.sample,
                        locus: String($0.locus.dropFirst("MHC-".count)),
                        haplotype1: $0.haplotype1,
                        haplotype2: $0.haplotype2,
                        status: $0.status,
                        notes: $0.notes
                    )
                },
                false
            ),
        ]

        for (name, calls, addOmittedAuthoritativeSample) in cases {
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: "manual-authority-\(name)",
                workflowKind: .fullLengthONTMHCGenotype
            )
            if addOmittedAuthoritativeSample {
                let sampleURL = ONTGenotypeResultBundle.resolvedURL(
                    for: fixture.manifest.sampleSummaryCSVPath,
                    in: fixture.bundleURL
                )
                try """
                sample,passed_alignments,passed_unique_reads
                DW472,1,1
                Missing,0,0
                """.write(
                    to: sampleURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            let before = try directorySnapshot(fixture.bundleURL)
            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    dateProvider: { Date(timeIntervalSince1970: 5_057) },
                    userProvider: { "tester" },
                    pythonExecutableURL: testPythonExecutableURL,
                    workbookAttestationRootURL: root.appendingPathComponent(
                        "attestations"
                    )
                ).applyHaplotypeOverrides(
                    calls,
                    annotationSidecarURL: nil,
                    into: fixture.bundleURL,
                    projectionMode: .manualGenotypeOnly
                )
            )
            XCTAssertEqual(
                try directorySnapshot(fixture.bundleURL),
                before,
                name
            )
        }
    }

    func testManualAnnotationOnlyUsesCompleteSemanticFingerprintSnapshot()
        throws
    {
        XCTAssertTrue(pythonCanImportOpenpyxl())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "manual-annotation-only",
            workflowKind: .fullLengthONTMHCGenotype
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        ).encoded().write(to: annotationURL)
        let semanticCalls = GenotypeManualHaplotypeLocus.allCases.map {
            GenotypeWorkbookHaplotypeCall(
                sample: "DW472",
                locus: $0.rawValue,
                haplotype1: "",
                haplotype2: "",
                status: "called",
                notes: ""
            )
        }

        XCTAssertNoThrow(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 5_058) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                workbookAttestationRootURL: root.appendingPathComponent(
                    "attestations"
                )
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL,
                annotationOnly: true,
                fingerprintInputs: GenotypeWorkbookFingerprintInputs(
                    calls: semanticCalls,
                    includedLoci:
                        GenotypeManualHaplotypeLocus.allCases.map(\.rawValue),
                    haplotypeProjectionMode: .manualGenotypeOnly
                ),
                projectionMode: .manualGenotypeOnly
            )
        )
    }

    func testApplyHaplotypeOverridesAttestsInputFingerprintAndSyncIntentInPublishedRevision() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "attested-update")
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let catalogReference = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(samples: ["sample-a"], rows: []),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.lastEditor = "attestation-reviewer"
        try sidecar.encoded().write(to: annotationURL)
        let calls: [GenotypeWorkbookHaplotypeCall] = []
        let immutableRequestDirectory = fixture.bundleURL
            .appendingPathComponent("artifacts/workbooks/updates/request-inputs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: immutableRequestDirectory,
            withIntermediateDirectories: true
        )
        let outerCallsURL = immutableRequestDirectory
            .appendingPathComponent("displayed-haplotype-calls.json")
        try ProvenanceJSON.encoder.encode(calls).write(to: outerCallsURL)
        let includedLoci = ["MHC-A"]
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: calls,
            includedLoci: includedLoci,
            annotationSidecar: sidecar,
            candidateArtifacts: manifest.mhcCandidateArtifacts,
            reviewableRowCatalog: catalogReference,
            reviewableRowCatalogSchemaVersion: GenotypeReviewableRowCatalog.schemaVersion
        )

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_100) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides(
            calls,
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            includedLoci: includedLoci,
            provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                toolName: "lungfish-cli fastq update-current-workbook",
                toolKind: "cli",
                argv: [
                    "lungfish-cli", "fastq", "update-current-workbook",
                    fixture.bundleURL.path,
                    "--calls-json", outerCallsURL.path,
                    "--annotations", annotationURL.path,
                    "--input-fingerprint", fingerprint.sha256,
                    "--input-fingerprint-schema", String(fingerprint.schemaVersion),
                    "--sync-intent", GenotypeCurrentWorkbookSyncIntent.updateAndView.rawValue,
                ],
                cliInputDescriptors: [
                    try ProvenanceFileDescriptor.file(
                        url: outerCallsURL,
                        format: .json,
                        role: .input
                    ),
                    try ProvenanceFileDescriptor.file(
                        url: annotationURL,
                        format: .json,
                        role: .input
                    ),
                ],
                inputFingerprint: fingerprint,
                syncIntent: .updateAndView
            )
        )

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookInputFingerprint"],
            .string(fingerprint.sha256)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookInputFingerprintSchemaVersion"],
            .integer(fingerprint.schemaVersion)
        )
        XCTAssertEqual(
            envelope.options.explicit["reviewableRowCatalogPath"],
            .string(catalogReference.path)
        )
        XCTAssertEqual(
            envelope.options.explicit["reviewableRowCatalogSize"],
            .integer(Int(catalogReference.sizeBytes))
        )
        XCTAssertEqual(
            envelope.options.explicit["reviewableRowCatalogSHA256"],
            .string(catalogReference.sha256)
        )
        XCTAssertEqual(
            envelope.options.explicit["reviewableRowCatalogSchemaVersion"],
            .integer(GenotypeReviewableRowCatalog.schemaVersion)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookSyncIntent"],
            .string("update-and-view")
        )
        XCTAssertEqual(envelope.argv.filter { $0 == "--input-fingerprint" }.count, 1)
        XCTAssertEqual(envelope.argv.filter { $0 == "--input-fingerprint-schema" }.count, 1)
        XCTAssertEqual(envelope.argv.filter { $0 == "--sync-intent" }.count, 1)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        for flag in ["--calls-json", "--annotations"] {
            let flagIndex = try XCTUnwrap(envelope.argv.firstIndex(of: flag))
            let path = envelope.argv[envelope.argv.index(after: flagIndex)]
            let inputURL = URL(fileURLWithPath: path)
            let descriptor = try XCTUnwrap(
                envelope.files.first {
                    $0.path == inputURL.standardizedFileURL.path && $0.role == .input
                }
            )
            XCTAssertEqual(
                descriptor.fileSize,
                UInt64(try ProvenanceFileHasher.fileSize(of: inputURL))
            )
            XCTAssertEqual(
                descriptor.checksumSHA256,
                try ProvenanceFileHasher.sha256(of: inputURL)
            )
            let publicationStep = try XCTUnwrap(
                envelope.steps.first {
                    $0.toolName.contains("genotype workbook update-current-workbook")
                }
            )
            XCTAssertTrue(
                publicationStep.inputs.contains { $0 == descriptor },
                "\(flag) exact immutable input is absent from the publication step"
            )
        }
        XCTAssertNotNil(envelope.options.explicit["cliImmutableInputs"])
        XCTAssertNotNil(envelope.options.explicit["additionalInputs"])
        XCTAssertEqual(updated.reviewableRowCatalog, catalogReference)
        let retainedCatalog = try XCTUnwrap(
            envelope.files.first {
                $0.role == .input
                    && $0.path.contains("/artifacts/workbooks/updates/")
                    && $0.path.hasSuffix("/reviewable-row-catalog.json")
            }
        )
        let retainedCatalogURL = URL(fileURLWithPath: retainedCatalog.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedCatalogURL.path))
        XCTAssertEqual(
            retainedCatalog.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: retainedCatalogURL)
        )
        XCTAssertEqual(
            retainedCatalog.fileSize,
            UInt64(try ProvenanceFileHasher.fileSize(of: retainedCatalogURL))
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first { $0.toolName.contains("python openpyxl") }
        )
        XCTAssertTrue(pythonStep.inputs.contains { $0.path == retainedCatalog.path })
        XCTAssertTrue(pythonStep.durableReplayArgv?.contains(retainedCatalog.path) == true)
    }

    func testFalseNegativeWithoutAttestedReviewableRowCatalogFailsBeforeStagingOrMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "false-negative-missing-catalog"
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*001:01",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-26T00:01:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try serviceThatFailsIfStagingBegins().applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("reviewable-row catalog"),
                "Unexpected error: \(error)"
            )
        }

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testFalseNegativeWithInvalidReviewableRowCatalogFailsBeforeStagingOrMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "false-negative-invalid-catalog"
        )
        _ = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(samples: ["AR3628"], rows: []),
            in: fixture.bundleURL
        )
        let catalogURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/review/reviewable-row-catalog.json"
        )
        var corrupted = try Data(contentsOf: catalogURL)
        corrupted.append(0x20)
        try corrupted.write(to: catalogURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*001:01",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-26T00:01:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try serviceThatFailsIfStagingBegins().applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("checksum or size"),
                "Unexpected error: \(error)"
            )
        }

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testReviewableRowCatalogParentSwapCannotSubstituteOutsideBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "reviewable-row-catalog-parent-swap"
        )
        _ = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(samples: ["inside"], rows: []),
            in: fixture.bundleURL
        )
        let reviewDirectory = fixture.bundleURL.appendingPathComponent(
            "artifacts/review",
            isDirectory: true
        )
        let displacedReviewDirectory = fixture.bundleURL.appendingPathComponent(
            "artifacts/displaced-review",
            isDirectory: true
        )
        let outsideReviewDirectory = root.appendingPathComponent(
            "outside-review",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideReviewDirectory,
            withIntermediateDirectories: true
        )
        let outsideCatalogURL = outsideReviewDirectory.appendingPathComponent(
            "reviewable-row-catalog.json"
        )
        try GenotypeReviewableRowCatalog(samples: ["outside"], rows: [])
            .validated()
            .encoded()
            .write(to: outsideCatalogURL, options: .atomic)
        let outsideReference = try artifactReference(
            outsideCatalogURL,
            relativeTo: root
        )
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        try mutateJSONObject(at: manifestURL) { object in
            object["reviewableRowCatalog"] = [
                "path": "artifacts/review/reviewable-row-catalog.json",
                "sha256": outsideReference.sha256,
                "size_bytes": outsideReference.sizeBytes,
            ]
        }
        let workbookURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        let workbookBefore = try Data(contentsOf: workbookURL)
        let reachedStaging = SendableFlagBox()

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    switch checkpoint {
                    case "after-reviewable-row-catalog-validation-before-read":
                        try FileManager.default.moveItem(
                            at: reviewDirectory,
                            to: displacedReviewDirectory
                        )
                        try FileManager.default.createSymbolicLink(
                            at: reviewDirectory,
                            withDestinationURL: outsideReviewDirectory
                        )
                    case "after-stage-created":
                        reachedStaging.set(1)
                        throw NSError(
                            domain: "UnexpectedWorkbookUpdateStaging",
                            code: 1
                        )
                    default:
                        break
                    }
                }
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("checksum or size"),
                "Unexpected error: \(error)"
            )
        }

        XCTAssertNil(reachedStaging.value)
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testApplyHaplotypeOverridesRejectsSameSizeCallsInputMutationBeforePublication() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "mutated-cli-input"
        )
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-24T00:00:00Z"
        )
        try sidecar.encoded().write(to: annotationURL)
        let admittedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: "review"
            ),
        ]
        let changedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-b",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: "review"
            ),
        ]
        let retainedDirectory = root.appendingPathComponent(
            "retained-cli-inputs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: retainedDirectory,
            withIntermediateDirectories: true
        )
        let callsURL = retainedDirectory.appendingPathComponent(
            "displayed-haplotype-calls.json"
        )
        let admittedData = try ProvenanceJSON.encoder.encode(admittedCalls)
        let changedData = try ProvenanceJSON.encoder.encode(changedCalls)
        XCTAssertEqual(admittedData.count, changedData.count)
        try admittedData.write(to: callsURL)
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let mutationCheckpoint = SendableFlagBox()
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_125) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            publicationFailureInjector: { checkpoint in
                guard checkpoint == "after-python-before-source-conflict-check" else {
                    return
                }
                mutationCheckpoint.set(1)
                let handle = try FileHandle(forWritingTo: callsURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: changedData)
                try handle.synchronize()
            }
        )
        let argv = [
            "lungfish-cli", "fastq", "update-current-workbook",
            fixture.bundleURL.path,
            "--calls-json", callsURL.path,
            "--annotations", annotationURL.path,
        ]

        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                admittedCalls,
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL,
                provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                    toolName: "lungfish-cli fastq update-current-workbook",
                    toolKind: "cli",
                    argv: argv,
                    cliInputDescriptors: [
                        try ProvenanceFileDescriptor.file(
                            url: callsURL,
                            format: .json,
                            role: .input
                        ),
                        try ProvenanceFileDescriptor.file(
                            url: annotationURL,
                            format: .json,
                            role: .input
                        ),
                    ]
                )
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("CLI provenance descriptor"),
                "Unexpected error: \(error)"
            )
        }

        XCTAssertEqual(mutationCheckpoint.value, 1)
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
        XCTAssertEqual(try Data(contentsOf: callsURL), changedData)
    }

    func testApplyHaplotypeOverridesRejectsMismatchedInputFingerprintWithoutBundleMutation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "mismatched-attestation")
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.lastEditor = "immutable-reviewer"
        try sidecar.encoded().write(to: annotationURL)
        let calls: [GenotypeWorkbookHaplotypeCall] = []
        let includedLoci = ["MHC-A"]
        let manifestBefore = try Data(
            contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let currentBefore = try Data(contentsOf: currentURL)
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let mismatchedFingerprint = try GenotypeCurrentWorkbookInputFingerprint(
            schemaVersion: GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
            sha256: String(repeating: "d", count: 64)
        )

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 5_150) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                calls,
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL,
                includedLoci: includedLoci,
                provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                    toolName: "lungfish-cli fastq update-current-workbook",
                    toolKind: "cli",
                    argv: ["lungfish-cli", "fastq", "update-current-workbook"],
                    inputFingerprint: mismatchedFingerprint,
                    syncIntent: .automaticIdle
                )
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("input fingerprint"),
                "Unexpected error: \(error)"
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)),
            manifestBefore
        )
        XCTAssertEqual(try Data(contentsOf: currentURL), currentBefore)
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
    }

    func testFullUpdateRejectsSemanticFingerprintOverrideWithoutBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "full-update-semantic-override"
        )
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let divergentCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-B",
                haplotype1: "B-H1",
                haplotype2: "B-H2",
                status: "called",
                notes: ""
            ),
        ]

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService().applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL,
                fingerprintInputs: GenotypeWorkbookFingerprintInputs(
                    calls: divergentCalls,
                    includedLoci: ["MHC-B"]
                )
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("only valid for annotation-only"),
                "Unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
    }

    func testAttestedAnnotationOnlyRejectsMissingSemanticInputsWithoutBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "annotation-only-missing-semantic-inputs"
        )
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint(
            schemaVersion: GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
            sha256: String(repeating: "e", count: 64)
        )

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService().applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL,
                annotationOnly: true,
                provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                    toolName: "test",
                    toolKind: "test",
                    argv: ["test"],
                    inputFingerprint: fingerprint,
                    syncIntent: .automaticIdle
                )
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).lowercased().contains(
                    "requires complete semantic fingerprint inputs"
                ),
                "Unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
    }

    func testAnnotationOnlyUpdateAttestsFullSemanticCallsAndRetainsTheirProvenance() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "annotation-only-semantic-attestation"
        )
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_175) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let scientificBefore = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertNotNil(scientificBefore["candidateIDs"])
        let displayedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: "displayed effective call"
            ),
        ]
        let displayedLoci = ["MHC-A"]
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.lastEditor = "annotation-only-reviewer"
        try sidecar.encoded().write(to: annotationURL)
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let expectedFingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: displayedCalls,
            includedLoci: displayedLoci,
            annotationSidecar: sidecar,
            candidateArtifacts: manifest.mhcCandidateArtifacts
        )
        let emptyCallsFingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: displayedLoci,
            annotationSidecar: sidecar,
            candidateArtifacts: manifest.mhcCandidateArtifacts
        )
        XCTAssertNotEqual(expectedFingerprint, emptyCallsFingerprint)

        let updated = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            annotationOnly: true,
            fingerprintInputs: GenotypeWorkbookFingerprintInputs(
                calls: displayedCalls,
                includedLoci: displayedLoci
            ),
            provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                toolName: "lungfish-cli fastq update-current-workbook",
                toolKind: "cli",
                argv: [
                    "lungfish-cli", "fastq", "update-current-workbook",
                    fixture.bundleURL.path,
                    "--calls-json", "/displayed/calls.json",
                    "--included-locus", "MHC-A",
                    "--annotation-only",
                ],
                inputFingerprint: expectedFingerprint,
                syncIntent: .automaticIdle
            )
        )

        let scientificAfter = try inspectTwoSheetCandidateWorkbook(currentURL)
        for key in [
            "candidateIDs",
            "candidateSequence",
            "unmatchedIDs",
            "sampleADPBHaplotype1",
            "sampleBDQAHaplotype1",
        ] {
            XCTAssertEqual(scientificAfter[key], scientificBefore[key], key)
        }
        XCTAssertEqual(
            try GenotypeCurrentWorkbookInputFingerprint.recorded(
                in: updated,
                bundleURL: fixture.bundleURL
            ),
            expectedFingerprint
        )
        XCTAssertNotEqual(
            try GenotypeCurrentWorkbookInputFingerprint.recorded(
                in: updated,
                bundleURL: fixture.bundleURL
            ),
            emptyCallsFingerprint
        )
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookInputFingerprint"],
            .string(expectedFingerprint.sha256)
        )
        let semanticCallsInput = try XCTUnwrap(
            envelope.files.first { $0.path.hasSuffix("fingerprint-haplotype-calls.json") }
        )
        let semanticCallsURL = URL(fileURLWithPath: semanticCallsInput.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: semanticCallsURL.path))
        XCTAssertEqual(
            semanticCallsInput.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: semanticCallsURL)
        )
        XCTAssertEqual(
            semanticCallsInput.fileSize,
            UInt64(try ProvenanceFileHasher.fileSize(of: semanticCallsURL))
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [GenotypeWorkbookHaplotypeCall].self,
                from: Data(contentsOf: semanticCallsURL)
            ),
            displayedCalls
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first { $0.toolName.contains("python openpyxl") }
        )
        XCTAssertFalse(
            pythonStep.inputs.contains { $0.path.hasSuffix("fingerprint-haplotype-calls.json") }
        )
        XCTAssertFalse(
            pythonStep.argv.contains { $0.hasSuffix("fingerprint-haplotype-calls.json") }
        )
    }

    func testApplyHaplotypeOverridesLegacyProvenanceOmitsWorkbookAttestationOptions() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "legacy-update")

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_200) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertNil(envelope.options.explicit["currentWorkbookInputFingerprint"])
        XCTAssertNil(envelope.options.explicit["currentWorkbookInputFingerprintSchemaVersion"])
        XCTAssertNil(envelope.options.explicit["currentWorkbookSyncIntent"])
    }

    func testAbsentZeroSupportFalseNegativeUsesExactPortablePresentation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "missing-false-negative-row"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
wb["Unified Genotype Pivot"].auto_filter.ref = "A1:P1"
wb.save(path)
"""#, currentURL.path])
        let catalogReference = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(
                samples: ["Sample-A", "Sample-B"],
                rows: [
                    .init(
                        kind: .reference,
                        callID: "reference:MHC-A:Mamu-A1*001:01",
                        displayName: "Mamu-A1*001:01",
                        locus: "MHC-A",
                        stableID: nil,
                        section: "reference",
                        sortKey: "MHC-A|Mamu-A1*001:01",
                        supportBySample: ["Sample-A": 0, "Sample-B": 0]
                    ),
                ]
            ),
            in: fixture.bundleURL
        )

        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = ["Sample-A", "Sample-B"].enumerated().map {
            index, sample in
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*001:01",
                    sample: sample
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T00:0\(index):00Z"
            )
        }
        try sidecar.encoded().write(to: annotationURL)
        let callsURL = root.appendingPathComponent("displayed-calls.json")
        try Data("[]".utf8).write(to: callsURL)
        let cliArgv = [
            "lungfish-cli", "fastq", "update-current-workbook",
            fixture.bundleURL.path,
            "--calls-json", callsURL.path,
            "--annotations", annotationURL.path,
        ]
        let cliProvenanceContext = GenotypeWorkbookRevisionProvenanceContext(
            toolName: "lungfish-cli fastq update-current-workbook",
            toolKind: "cli",
            argv: cliArgv,
            cliInputDescriptors: [
                try ProvenanceFileDescriptor.file(url: callsURL, role: .input),
                try ProvenanceFileDescriptor.file(url: annotationURL, role: .input),
            ]
        )

        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_100),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "workbook-attestations",
                isDirectory: true
            )
        )
        let updated = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            provenanceContext: cliProvenanceContext
        )

        let inspection = try inspectAnnotationOnlyReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["adapter"], "unified")
        XCTAssertEqual(inspection["markerRows"], "1")
        XCTAssertEqual(inspection["syntheticRows"], "1")
        XCTAssertEqual(inspection["syntheticCallType"], "analyst-annotation-only")
        XCTAssertEqual(
            inspection["syntheticCallID"],
            "reference:MHC-A:Mamu-A1*001:01"
        )
        XCTAssertEqual(inspection["syntheticDisplayName"], "Mamu-A1*001:01")
        XCTAssertEqual(inspection["syntheticStableID"], "")
        XCTAssertEqual(inspection["syntheticLocus"], "MHC-A")
        XCTAssertEqual(
            inspection["syntheticClassification"],
            "analyst-annotation-only"
        )
        XCTAssertEqual(inspection["syntheticOccurrenceCount"], "0")
        XCTAssertEqual(inspection["syntheticOccurrenceCountType"], "n")
        XCTAssertEqual(inspection["syntheticSampleCount"], "0")
        XCTAssertEqual(inspection["syntheticSampleCountType"], "n")
        XCTAssertEqual(inspection["syntheticTotalReads"], "0")
        XCTAssertEqual(inspection["syntheticTotalReadsType"], "n")
        XCTAssertEqual(inspection["sampleAValue"], "FN")
        XCTAssertEqual(inspection["sampleBValue"], "FN")
        XCTAssertEqual(
            inspection["sampleABorders"],
            "mediumDashed|mediumDashed|mediumDashed|mediumDashed"
        )
        XCTAssertEqual(
            inspection["sampleBBorders"],
            "mediumDashed|mediumDashed|mediumDashed|mediumDashed"
        )
        XCTAssertEqual(
            inspection["sampleABorderColors"],
            "FFC65911|FFC65911|FFC65911|FFC65911"
        )
        XCTAssertEqual(
            inspection["sampleBBorderColors"],
            "FFC65911|FFC65911|FFC65911|FFC65911"
        )
        XCTAssertEqual(inspection["sampleAFill"], "solid|FFFFF2CC")
        XCTAssertEqual(inspection["sampleBFill"], "solid|FFFFF2CC")
        XCTAssertEqual(inspection["sampleAFont"], "true|FF7F6000")
        XCTAssertEqual(inspection["sampleBFont"], "true|FF7F6000")
        XCTAssertEqual(inspection["tableRef"], "A1:N3")
        XCTAssertEqual(inspection["tableAutoFilterRef"], "A1:N3")
        XCTAssertEqual(inspection["autoFilterRef"], "A1:P3")
        XCTAssertEqual(inspection["freezePanes"], "A2")
        XCTAssertEqual(inspection["mergedRanges"], "O1:P1")
        XCTAssertEqual(inspection["formula"], "=1+1")
        XCTAssertEqual(inspection["formulaFont"], "true|FFFF0000")
        XCTAssertEqual(inspection["formulaFill"], "FFFFFF00")
        XCTAssertEqual(inspection["formulaBorders"], "thin|thin|thin|thin")
        XCTAssertEqual(inspection["formulaNumberFormat"], "0.00")
        XCTAssertEqual(inspection["managedSyntheticStateRows"], "2")
        let ooxml = try inspectPortableFalseNegativeOOXML(currentURL)
        XCTAssertEqual(ooxml["hasLiteralFN"], "true")
        XCTAssertEqual(ooxml["hasDashedBorder"], "true")
        XCTAssertEqual(ooxml["hasBorderColor"], "true")
        XCTAssertEqual(ooxml["hasFillColor"], "true")
        XCTAssertEqual(ooxml["hasFontColor"], "true")

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(
            envelope.toolName,
            "lungfish-cli fastq update-current-workbook"
        )
        XCTAssertEqual(envelope.argv, cliArgv)
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        XCTAssertEqual(
            pythonStep.resolvedOptions["annotationSidecarRevisionSHA256"],
            .string(try ProvenanceFileHasher.sha256(of: annotationURL))
        )
        XCTAssertEqual(
            pythonStep.resolvedOptions["workbookMatrixAdapterVersion"],
            .string("lge-workbook-matrix-adapter-v1")
        )
        let catalogDescriptor = try XCTUnwrap(
            pythonStep.resolvedOptions["reviewableRowCatalogDescriptor"]?
                .dictionaryValue
        )
        XCTAssertEqual(catalogDescriptor["path"], .string(catalogReference.path))
        XCTAssertEqual(
            catalogDescriptor["sizeBytes"],
            .integer(Int(catalogReference.sizeBytes))
        )
        XCTAssertEqual(
            catalogDescriptor["sha256"],
            .string(catalogReference.sha256)
        )
        XCTAssertEqual(
            catalogDescriptor["schemaVersion"],
            .integer(GenotypeReviewableRowCatalog.schemaVersion)
        )
        let adapterDecisions = try XCTUnwrap(
            pythonStep.resolvedOptions["workbookAdapterDecisions"]?.arrayValue
        )
        XCTAssertEqual(adapterDecisions.count, 1)
        XCTAssertEqual(
            adapterDecisions.first?.dictionaryValue?["adapter"],
            .string("unified")
        )
        let synthesisDecisions = try XCTUnwrap(
            pythonStep.resolvedOptions["falseNegativeSynthesisDecisions"]?
                .arrayValue
        )
        XCTAssertEqual(synthesisDecisions.count, 1)
        XCTAssertEqual(
            synthesisDecisions.first?.dictionaryValue?["identity"],
            .dictionary([
                "kind": .string("reference"),
                "callID": .string("reference:MHC-A:Mamu-A1*001:01"),
                "displayName": .string("Mamu-A1*001:01"),
                "locus": .string("MHC-A"),
                "stableID": .null,
            ])
        )
        XCTAssertEqual(
            synthesisDecisions.first?.dictionaryValue?["cells"],
            .array([.string("M3"), .string("N3")])
        )
        let targetDecisions = try XCTUnwrap(
            pythonStep.resolvedOptions["falseNegativeTargetCellDecisions"]?
                .arrayValue
        )
        XCTAssertEqual(targetDecisions.count, 2)
        XCTAssertEqual(
            Set(targetDecisions.compactMap {
                $0.dictionaryValue?["cell"]?.stringValue
            }),
            ["M3", "N3"]
        )
        XCTAssertTrue(targetDecisions.allSatisfy {
            $0.dictionaryValue?["presentationPrecedence"]
                == .string("false-negative-over-viewport-style")
        })
        XCTAssertEqual(
            Set(targetDecisions.compactMap {
                $0.dictionaryValue?["target"]?.dictionaryValue?["sample"]?
                    .stringValue
            }),
            ["Sample-A", "Sample-B"]
        )
        XCTAssertEqual(
            pythonStep.resolvedOptions["managedReviewRestorationDecisions"],
            .array([.dictionary([
                "action": .string("none"),
                "reason": .string("no-managed-review-state"),
            ])])
        )
        let sidecarInput = try XCTUnwrap(
            pythonStep.inputs.first { $0.path == annotationURL.path }
        )
        XCTAssertEqual(
            sidecarInput.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: annotationURL)
        )
        let workbookOutput = try XCTUnwrap(
            pythonStep.outputs.first { $0.path == currentURL.path }
        )
        XCTAssertEqual(
            workbookOutput.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: currentURL)
        )
        XCTAssertEqual(pythonStep.exitStatus, 0)
        XCTAssertEqual(pythonStep.stderr, "")
        XCTAssertNotNil(pythonStep.wallTimeSeconds)
        XCTAssertFalse(pythonStep.argv.isEmpty)
        XCTAssertEqual(pythonStep.runtimeIdentity?.condaEnvironment, "openpyxl")

        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        let cleared = try inspectAnnotationOnlyReviewWorkbook(currentURL)
        XCTAssertEqual(cleared["markerRows"], "0")
        XCTAssertEqual(cleared["syntheticRows"], "0")
        XCTAssertEqual(cleared["tableRef"], "A1:N1")
        XCTAssertEqual(cleared["tableAutoFilterRef"], "A1:N1")
        XCTAssertEqual(cleared["autoFilterRef"], "A1:P1")
        XCTAssertEqual(cleared["formula"], "=1+1")
        XCTAssertEqual(cleared["formulaFont"], "true|FFFF0000")
        XCTAssertEqual(cleared["formulaFill"], "FFFFFF00")
        XCTAssertEqual(cleared["formulaBorders"], "thin|thin|thin|thin")
        XCTAssertEqual(cleared["formulaNumberFormat"], "0.00")
    }

    func testGenericAnnotationOnlyRowIsIdempotentAndClearsSafely() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "generic-false-negative-lifecycle"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_125),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )

        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        var inspection = try inspectAnnotationOnlyGenericWorkbook(currentURL)
        XCTAssertEqual(inspection["markerRows"], "1")
        XCTAssertEqual(inspection["syntheticRows"], "1")
        XCTAssertEqual(inspection["syntheticTotal"], "0")
        XCTAssertEqual(inspection["syntheticObserved"], "0")
        XCTAssertEqual(inspection["syntheticEvidence"], "FN")
        XCTAssertEqual(inspection["tableRef"], "A6:D9")
        XCTAssertEqual(inspection["tableAutoFilterRef"], "A6:D9")
        XCTAssertEqual(inspection["autoFilterRef"], "A6:D9")
        XCTAssertEqual(inspection["formula"], "=SUM(B7:B9)")
        XCTAssertEqual(inspection["freezePanes"], "D7")

        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        inspection = try inspectAnnotationOnlyGenericWorkbook(currentURL)
        XCTAssertEqual(inspection["markerRows"], "0")
        XCTAssertEqual(inspection["syntheticRows"], "0")
        XCTAssertEqual(inspection["tableRef"], "A6:D7")
        XCTAssertEqual(inspection["tableAutoFilterRef"], "A6:D7")
        XCTAssertEqual(inspection["autoFilterRef"], "A6:D7")
        XCTAssertEqual(inspection["existingRow"], "Mamu-A1*existing|5|1|5")
        XCTAssertEqual(inspection["formula"], "=SUM(B7:B9)")
        XCTAssertEqual(inspection["hasManagedReviewState"], "false")
    }

    func testTablelessGenericClearCompactsCompleteCatalogRosterWithLaterRealRow() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "tableless-generic-owned-clear"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
del ws.tables["GenericGenotypeTable"]
ws["E6"] = "AR9999"
ws.auto_filter.ref = "A6:E7"
ws["G8"] = "outside-marker-row"
ws["H9"] = "outside-synthetic-row"
wb.save(path)
"""#, currentURL.path])
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628", "AR9999"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:05:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_126) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
ws.append(["Mamu-A1*later-real", 9, 1, None, 9])
ws.auto_filter.ref = "A6:E10"
wb.save(path)
"""#, currentURL.path])
        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["matrix"]
text = lambda value: "" if value is None else str(value)
print(json.dumps({
    "markerRows": str(sum(
        1 for row in range(7, ws.max_row + 1)
        if text(ws.cell(row, 1).value) == "Analyst annotation-only rows"
    )),
    "syntheticRows": str(sum(
        1 for row in range(7, ws.max_row + 1)
        if text(ws.cell(row, 1).value) == "Mamu-A1*missing"
    )),
    "existingRow": "|".join(text(ws.cell(7, col).value) for col in range(1, 6)),
    "realRow": "|".join(text(ws.cell(8, col).value) for col in range(1, 6)),
    "outsideMarker": text(ws["G8"].value),
    "outsideSynthetic": text(ws["H9"].value),
    "autoFilterRef": text(ws.auto_filter.ref),
    "tableCount": str(len(ws.tables)),
    "hasManagedReviewState": str(
        "_LGE Matrix Review State" in wb.sheetnames
    ).lower(),
}))
"""#, currentURL.path])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        let inspection = try XCTUnwrap(object as? [String: String])
        XCTAssertEqual(inspection["markerRows"], "0")
        XCTAssertEqual(inspection["syntheticRows"], "0")
        XCTAssertEqual(inspection["existingRow"], "Mamu-A1*existing|5|1|5|")
        XCTAssertEqual(inspection["realRow"], "Mamu-A1*later-real|9|1||9")
        XCTAssertEqual(inspection["outsideMarker"], "outside-marker-row")
        XCTAssertEqual(inspection["outsideSynthetic"], "outside-synthetic-row")
        XCTAssertEqual(inspection["autoFilterRef"], "A6:E8")
        XCTAssertEqual(inspection["tableCount"], "0")
        XCTAssertEqual(inspection["hasManagedReviewState"], "false")
    }

    func testTablelessClearFailsClosedForDuplicateUnannotatedCatalogSample() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "tableless-duplicate-unannotated-sample"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
del ws.tables["GenericGenotypeTable"]
ws["E6"] = "AR9999"
ws.auto_filter.ref = "A6:E7"
wb.save(path)
"""#, currentURL.path])
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628", "AR9999"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:05:30Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_126.5) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
wb["matrix"]["F6"] = "AR9999"
wb.save(path)
"""#, currentURL.path])
        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "AR9999"
                )
            )
        }
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testGenericClearIgnoresUnrelatedTableSpanningManagedRows() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "generic-unrelated-table-clear"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
from openpyxl.worksheet.table import Table

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
for row, values in {
    6: ("External A", "External B", "External C"),
    7: ("external-7a", "external-7b", "external-7c"),
    8: ("external-8a", "external-8b", "external-8c"),
    9: ("external-9a", "external-9b", "external-9c"),
    10: ("external-10a", "external-10b", "external-10c"),
}.items():
    for offset, value in enumerate(values, start=6):
        ws.cell(row, offset).value = value
ws.add_table(Table(displayName="UnrelatedTable", ref="F6:H10"))
wb.save(path)
"""#, currentURL.path])
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:06:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_127) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["matrix"]
text = lambda value: "" if value is None else str(value)
print(json.dumps({
    "matrixTableRef": text(ws.tables["GenericGenotypeTable"].ref),
    "matrixTableFilterRef": text(ws.tables["GenericGenotypeTable"].autoFilter.ref),
    "unrelatedTableRef": text(ws.tables["UnrelatedTable"].ref),
    "unrelatedRows": "|".join(
        text(ws.cell(row, col).value)
        for row in range(6, 11)
        for col in range(6, 9)
    ),
    "markerRows": str(sum(
        1 for row in range(7, ws.max_row + 1)
        if text(ws.cell(row, 1).value) == "Analyst annotation-only rows"
    )),
    "syntheticRows": str(sum(
        1 for row in range(7, ws.max_row + 1)
        if text(ws.cell(row, 1).value) == "Mamu-A1*missing"
    )),
    "autoFilterRef": text(ws.auto_filter.ref),
}))
"""#, currentURL.path])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        let inspection = try XCTUnwrap(object as? [String: String])
        XCTAssertEqual(inspection["matrixTableRef"], "A6:D7")
        XCTAssertEqual(inspection["matrixTableFilterRef"], "A6:D7")
        XCTAssertEqual(inspection["unrelatedTableRef"], "F6:H10")
        XCTAssertEqual(
            inspection["unrelatedRows"],
            [
                "External A", "External B", "External C",
                "external-7a", "external-7b", "external-7c",
                "external-8a", "external-8b", "external-8c",
                "external-9a", "external-9b", "external-9c",
                "external-10a", "external-10b", "external-10c",
            ].joined(separator: "|")
        )
        XCTAssertEqual(inspection["markerRows"], "0")
        XCTAssertEqual(inspection["syntheticRows"], "0")
        XCTAssertEqual(inspection["autoFilterRef"], "A6:D7")
    }

    func testUserEditedSyntheticRowIsRetainedUnmanagedWithValidationWarning() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "edited-false-negative-row"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_150) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
from openpyxl.comments import Comment

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
row = next(
    row for row in range(7, ws.max_row + 1)
    if ws.cell(row, 1).value == "Mamu-A1*missing"
)
ws.cell(row, 2).comment = Comment("Analyst retained note", "analyst")
wb.save(path)
"""#, currentURL.path])

        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        var inspection = try inspectAnnotationOnlyGenericWorkbook(currentURL)
        XCTAssertEqual(inspection["syntheticRows"], "1")
        XCTAssertEqual(inspection["markerRows"], "0")
        XCTAssertEqual(inspection["retainedMarkerRows"], "1")
        XCTAssertEqual(inspection["analystComment"], "Analyst retained note")
        XCTAssertEqual(inspection["managedSyntheticRows"], "0")
        XCTAssertTrue(
            inspection["reviewWarning"]?.contains("user-edited") == true
        )

        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        inspection = try inspectAnnotationOnlyGenericWorkbook(currentURL)
        XCTAssertEqual(inspection["syntheticRows"], "1")
        XCTAssertEqual(inspection["analystComment"], "Analyst retained note")
        XCTAssertEqual(inspection["hasManagedReviewState"], "false")
    }

    func testRetainedSyntheticBlockMarkerIsNeverReadoptedForNewManagedRows() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "retained-marker-ownership"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        let rows = ["Mamu-A1*missing", "Mamu-A1*second"].map { displayName in
            GenotypeReviewableRowCatalog.Row(
                kind: .reference,
                callID: "reference:MHC-A:\(displayName)",
                displayName: displayName,
                locus: "MHC-A",
                stableID: nil,
                section: "reference",
                sortKey: "MHC-A|\(displayName)",
                supportBySample: ["AR3628": 0]
            )
        }
        _ = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(samples: ["AR3628"], rows: rows),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        func review(
            _ displayName: String,
            minute: Int
        ) -> GenotypeAnnotationSidecar.MatrixReviewAnnotation {
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: displayName,
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:\(String(format: "%02d", minute)):00Z"
            )
        }
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [review("Mamu-A1*missing", minute: 0)]
        try sidecar.encoded().write(to: annotationURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_175),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
from openpyxl.comments import Comment

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
row = next(
    row for row in range(7, ws.max_row + 1)
    if ws.cell(row, 1).value == "Mamu-A1*missing"
)
ws.cell(row, 2).comment = Comment("Retained analyst edit", "analyst")
wb.save(path)
"""#, currentURL.path])
        sidecar.matrixReviews = [
            review("Mamu-A1*missing", minute: 1),
            review("Mamu-A1*second", minute: 2),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let beforeRejectedUpdate = try ProvenanceFileHasher.sha256(of: currentURL)
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(
            try ProvenanceFileHasher.sha256(of: currentURL),
            beforeRejectedUpdate
        )

        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        let inspection = try inspectAnnotationOnlyGenericWorkbook(currentURL)
        XCTAssertEqual(inspection["syntheticRows"], "1")
        XCTAssertEqual(inspection["analystComment"], "Retained analyst edit")
        XCTAssertEqual(inspection["markerRows"], "0")
        XCTAssertEqual(inspection["retainedMarkerRows"], "1")
        XCTAssertEqual(inspection["hasManagedReviewState"], "false")
    }

    func testMarkerOnlyAnalystEditRetainsTheEntireSyntheticBlockOnClear() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "retained-marker-only-edit"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_200),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
from openpyxl.comments import Comment

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
row = next(
    row for row in range(7, ws.max_row + 1)
    if ws.cell(row, 1).value == "Analyst annotation-only rows"
)
ws.cell(row, 1).comment = Comment("Marker-only analyst edit", "analyst")
wb.save(path)
"""#, currentURL.path])
        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectAnnotationOnlyGenericWorkbook(currentURL)
        XCTAssertEqual(inspection["markerRows"], "0")
        XCTAssertEqual(inspection["retainedMarkerRows"], "1")
        XCTAssertEqual(
            inspection["retainedMarkerComment"],
            "Marker-only analyst edit"
        )
        XCTAssertEqual(inspection["syntheticRows"], "1")
        XCTAssertEqual(inspection["tableRef"], "A6:D9")
        XCTAssertEqual(inspection["tableAutoFilterRef"], "A6:D9")
        XCTAssertEqual(inspection["hasManagedReviewState"], "false")
    }

    func testForeignManagedStateSheetNameCollisionFailsClosedWithoutMutation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "foreign-managed-state-collision"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb.create_sheet("_LGE Matrix Review State")
ws["A1"] = "Unrelated analyst worksheet"
ws["A2"] = "This content is not Lungfish-managed state."
wb.save(path)
"""#, currentURL.path])
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        ).encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_300) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testExactShapeForeignManagedStateMimicFailsClosedWithoutMutation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "exact-shape-foreign-managed-state"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
state = wb.create_sheet("_LGE Matrix Review State")
state.append([
    "Sheet", "Target Kind", "Locus", "Genotype", "Sample",
    "Stable Cluster ID", "Coordinate", "Disposition", "Original Value",
    "Original Font", "Original Fill", "Original Border",
    "Expected Managed Value", "Expected Managed Font",
    "Expected Managed Fill", "Expected Managed Border", "Synthetic Row",
    "Adapter", "Synthetic Row Index", "Expected Synthetic Row",
    "Marker Row Index", "Expected Marker Row",
    "org.lungfish.matrix-review-state", 3,
    "foreign-unbound-authority",
    "a" * 64,
])
state.append([
    "matrix", "cell", "", "Mamu-A1*existing", "AR3628",
    "", "D7", "falsePositive", '{"type":"int","value":5}',
])
state.sheet_state = "veryHidden"
wb.save(path)
"""#, currentURL.path])
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        ).encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_310) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testExactLegacyManagedStateSchemaRestoresAndMigratesSafely() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "legacy-managed-state"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from copy import copy
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
matrix = wb["matrix"]
original_font = copy(matrix["D7"].font)
original_border = copy(matrix["D7"].border)
matrix["D7"] = "[5]"
managed_font = copy(matrix["D7"].font)
managed_font.italic = True
managed_font.color = "FF767676"
matrix["D7"].font = managed_font

state = wb.create_sheet("_LGE Matrix Review State")
state.append([
    "Sheet", "Target Kind", "Locus", "Genotype", "Sample",
    "Stable Cluster ID", "Coordinate", "Disposition", "Original Value",
    "Original Font", "Original Border",
])
state.append([
    "matrix", "cell", "", "Mamu-A1*existing", "AR3628",
    "", "D7", "falsePositive", 5,
])
state.cell(2, 10).font = original_font
state.cell(2, 11).border = original_border
state.sheet_state = "veryHidden"
wb.save(path)
"""#, currentURL.path])
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        ).encoded().write(to: annotationURL)

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_325) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "workbook-attestations",
                isDirectory: true
            )
        ).applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectAnnotationOnlyGenericWorkbook(currentURL)
        XCTAssertEqual(inspection["existingRow"], "Mamu-A1*existing|5|1|5")
        XCTAssertEqual(inspection["hasManagedReviewState"], "false")
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        let decisions = try XCTUnwrap(
            pythonStep.resolvedOptions["managedReviewRestorationDecisions"]?
                .arrayValue
        )
        let legacy = try XCTUnwrap(
            decisions.first {
                $0.dictionaryValue?["cell"] == .string("D7")
            }?.dictionaryValue
        )
        XCTAssertEqual(legacy["action"], .string("restore-legacy-cell"))
        XCTAssertEqual(
            legacy["properties"]?.dictionaryValue?["value"],
            .string("restored")
        )
        XCTAssertEqual(
            legacy["properties"]?.dictionaryValue?["font.italic"],
            .string("restored")
        )
    }

    func testUnreleasedUnversionedTask4ManagedStateFailsClosed() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "unversioned-task4-state"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_350),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
state = wb["_LGE Matrix Review State"]
state.delete_cols(23, 2)
wb.save(path)
"""#, currentURL.path])

        let before = try ProvenanceFileHasher.sha256(of: currentURL)
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testManagedFalseNegativeStateDigestBindsExpectedBold() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "managed-fn-bold-integrity"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installSemanticReviewMatrix(in: currentURL)
        try installSemanticReviewableRowCatalog(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Zero",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_360),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "workbook-attestations",
                isDirectory: true
            )
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from copy import copy
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
state = wb["_LGE Matrix Review State"]
font = copy(state.cell(2, 14).font)
font.bold = False
state.cell(2, 14).font = font
wb.save(path)
"""#, currentURL.path])
        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testVersion3ManagedFalseNegativeStateRestoresAndMigratesSafely() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "managed-fn-v3-migration"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installSemanticReviewMatrix(in: currentURL)
        try installSemanticReviewableRowCatalog(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Zero",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_365),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "workbook-attestations",
                isDirectory: true
            )
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import hashlib
import json
import sys
from copy import copy
from openpyxl import load_workbook
from openpyxl.styles import Side

def clean(value):
    return "" if value is None else str(value).strip()

def serialized(value):
    if value is None:
        payload = {"type": "none", "value": None}
    elif isinstance(value, bool):
        payload = {"type": "bool", "value": value}
    elif isinstance(value, int):
        payload = {"type": "int", "value": value}
    elif isinstance(value, float):
        payload = {"type": "float", "value": value}
    else:
        payload = {"type": "string", "value": str(value)}
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))

def color_payload(color):
    if color is None:
        return None
    color_type = clean(color.type)
    if color_type == "rgb":
        value = clean(color.rgb).upper()
    elif color_type == "indexed":
        value = color.indexed
    elif color_type == "theme":
        value = color.theme
    elif color_type == "auto":
        value = bool(color.auto)
    else:
        value = None
    return {"type": color_type, "value": value}

def side_payload(side):
    if side is None:
        return None
    return {
        "style": clean(side.style),
        "color": color_payload(side.color),
    }

path = sys.argv[1]
wb = load_workbook(path)
matrix = wb["matrix"]
state = wb["_LGE Matrix Review State"]
row = 2
cell = matrix["E7"]
cell.value = json.loads(state.cell(row, 9).value)["value"]
cell.font = copy(state.cell(row, 10).font)
cell.fill = copy(state.cell(row, 11).fill)
border = copy(state.cell(row, 12).border)
managed_side = Side(style="thick", color="FF000000")
for side_name in ("left", "right", "top", "bottom"):
    setattr(border, side_name, copy(managed_side))
cell.border = border
state.cell(row, 13).value = state.cell(row, 9).value
state.cell(row, 14).font = copy(state.cell(row, 10).font)
state.cell(row, 15).fill = copy(state.cell(row, 11).fill)
state.cell(row, 16).border = copy(cell.border)
state.cell(1, 24).value = 3

rows = []
for state_row in range(2, state.max_row + 1):
    cells = []
    for col in range(1, 23):
        state_cell = state.cell(state_row, col)
        payload = {"value": serialized(state_cell.value)}
        if col in (10, 14):
            payload["font"] = {
                "italic": bool(state_cell.font.i),
                "color": color_payload(state_cell.font.color),
            }
        elif col in (11, 15):
            payload["fill"] = {
                "type": clean(state_cell.fill.fill_type),
                "foreground": color_payload(state_cell.fill.fgColor),
                "background": color_payload(state_cell.fill.bgColor),
            }
        elif col in (12, 16):
            payload["border"] = {
                name: side_payload(getattr(state_cell.border, name))
                for name in ("left", "right", "top", "bottom", "diagonal")
            }
        cells.append(payload)
    rows.append(cells)
authority = state.cell(1, 25).value
digest_payload = json.dumps(
    {"authority": authority, "rows": rows},
    sort_keys=True,
    separators=(",", ":"),
)
state.cell(1, 26).value = hashlib.sha256(
    digest_payload.encode("utf-8")
).hexdigest()
wb.save(path)
"""#, currentURL.path])

        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        let updated = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["explicitZeroValue"], "0")
        XCTAssertEqual(inspection["explicitZeroBorders"], "|||")
        XCTAssertEqual(inspection["hasManagedReviewStateSheet"], "false")
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        let decisions = try XCTUnwrap(
            pythonStep.resolvedOptions["managedReviewRestorationDecisions"]?
                .arrayValue
        )
        XCTAssertEqual(
            decisions.first {
                $0.dictionaryValue?["cell"] == .string("E7")
            }?.dictionaryValue?["action"],
            .string("restore-version-3-cell")
        )
    }

    func testLegacyManagedStateRequiresExactRecordedCoordinateAndManagedPresentation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        for defect in [
            "coordinate",
            "presentation",
            "display-value",
            "display-whitespace",
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeGenericMatrixWorkbookBundle(
                in: root,
                outputName: "invalid-legacy-\(defect)"
            )
            let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
                for: fixture.bundleURL
            )
            try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
            _ = try runPython(["-c", #"""
import sys
from copy import copy
from openpyxl import load_workbook

path, defect = sys.argv[1:3]
wb = load_workbook(path)
matrix = wb["matrix"]
original_font = copy(matrix["D7"].font)
original_border = copy(matrix["D7"].border)
if defect == "display-value":
    matrix["D7"] = "[999]"
elif defect == "display-whitespace":
    matrix["D7"] = " [5] "
else:
    matrix["D7"] = "[5]"
managed_font = copy(matrix["D7"].font)
managed_font.italic = defect != "presentation"
managed_font.color = "FF767676"
matrix["D7"].font = managed_font

state = wb.create_sheet("_LGE Matrix Review State")
state.append([
    "Sheet", "Target Kind", "Locus", "Genotype", "Sample",
    "Stable Cluster ID", "Coordinate", "Disposition", "Original Value",
    "Original Font", "Original Border",
])
state.append([
    "matrix", "cell", "", "Mamu-A1*existing", "AR3628",
    "", "Z999" if defect == "coordinate" else "D7",
    "falsePositive", 5,
])
state.cell(2, 10).font = original_font
state.cell(2, 11).border = original_border
state.sheet_state = "veryHidden"
wb.save(path)
"""#, currentURL.path, defect])
            let annotationURL = fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
            try GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-27T00:00:00Z"
            ).encoded().write(to: annotationURL)
            let before = try ProvenanceFileHasher.sha256(of: currentURL)

            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    dateProvider: { Date(timeIntervalSince1970: 8_375) },
                    userProvider: { "tester" },
                    pythonExecutableURL: testPythonExecutableURL
                ).applyHaplotypeOverrides(
                    [],
                    annotationSidecarURL: annotationURL,
                    into: fixture.bundleURL
                ),
                "Legacy defect \(defect) must fail closed"
            )
            XCTAssertEqual(
                try ProvenanceFileHasher.sha256(of: currentURL),
                before,
                "Legacy defect \(defect) must not mutate current.xlsx"
            )
        }
    }

    func testIdenticalManagedReviewPublicationIsANoOp() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "identical-managed-review"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["AR3628"],
                displayName: "Mamu-A1*missing"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*missing",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_400) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        let first = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        let firstHash = try ProvenanceFileHasher.sha256(of: currentURL)
        let firstRevisionCount = first.workbookRevisions?.count ?? 0
        let updatesURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/updates",
            isDirectory: true
        )
        let firstUpdateNames = try FileManager.default.contentsOfDirectory(
            atPath: updatesURL.path
        ).sorted()

        let second = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), firstHash)
        XCTAssertEqual(second.workbookRevisions?.count ?? 0, firstRevisionCount)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: updatesURL.path).sorted(),
            firstUpdateNames
        )
    }

    func testLaterRealWorkbookRowSupersedesManagedSyntheticRow() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "real-row-supersession"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["Sample-A", "Sample-B"],
                displayName: "Mamu-A1*001:01"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*001:01",
                    sample: "Sample-A"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T02:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_175) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
ws.append([
    "known-allele",
    "reference:MHC-A:Mamu-A1*001:01",
    "Mamu-A1*001:01",
    None,
    "MHC-A",
    "known",
    None,
    "Mamu-A1*001:01",
    "exact",
    0,
    0,
    0,
    None,
    None,
])
ws.tables["UnifiedGenotypeTable"].ref = "A1:N4"
ws.auto_filter.ref = "A1:N4"
wb.save(path)
"""#, currentURL.path])

        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectAnnotationOnlyReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["markerRows"], "0")
        XCTAssertEqual(inspection["syntheticRows"], "0")
        XCTAssertEqual(inspection["realRows"], "1")
        XCTAssertEqual(
            inspection["realSampleABorders"],
            "mediumDashed|mediumDashed|mediumDashed|mediumDashed"
        )
        XCTAssertEqual(inspection["tableRef"], "A1:N2")
        XCTAssertEqual(inspection["autoFilterRef"], "A1:N2")
        XCTAssertEqual(inspection["managedSyntheticStateRows"], "0")
    }

    func testAbsentAnnotationOnlyRowsUseCanonicalCatalogSortOrder() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "sorted-false-negative-rows"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        let names = ["Mamu-B*010:01", "Mamu-A1*002:01"]
        _ = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(
                samples: ["Sample-A", "Sample-B"],
                rows: [
                    .init(
                        kind: .reference,
                        callID: "reference:MHC-B:\(names[0])",
                        displayName: names[0],
                        locus: "MHC-B",
                        stableID: nil,
                        section: "reference",
                        sortKey: "02|MHC-B|\(names[0])",
                        supportBySample: ["Sample-A": 0, "Sample-B": 0]
                    ),
                    .init(
                        kind: .reference,
                        callID: "reference:MHC-A:\(names[1])",
                        displayName: names[1],
                        locus: "MHC-A",
                        stableID: nil,
                        section: "reference",
                        sortKey: "01|MHC-A|\(names[1])",
                        supportBySample: ["Sample-A": 0, "Sample-B": 0]
                    ),
                ]
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            ("MHC-B", names[0]),
            ("MHC-A", names[1]),
        ].enumerated().map { index, identity in
            .init(
                target: .cell(
                    locus: identity.0,
                    genotype: identity.1,
                    sample: "Sample-A"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T03:0\(index):00Z"
            )
        }
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_200) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectAnnotationOnlyReviewWorkbook(currentURL)
        XCTAssertEqual(
            inspection["syntheticDisplayNames"],
            "Mamu-A1*002:01|Mamu-B*010:01"
        )
        XCTAssertEqual(inspection["markerRows"], "1")
        XCTAssertEqual(inspection["syntheticRows"], "2")
        XCTAssertEqual(inspection["tableRef"], "A1:N4")
        XCTAssertEqual(inspection["tableAutoFilterRef"], "A1:N4")
        XCTAssertEqual(inspection["autoFilterRef"], "A1:N4")
    }

    func testAmbiguousExistingRowsFailClosedBeforeAnnotationOnlySynthesis() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "ambiguous-existing-rows"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        let displayName = "Mamu-A1*ambiguous"
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path, display_name = sys.argv[1:3]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
for row in (2, 3):
    values = [
        "known-allele",
        "reference:MHC-A:" + display_name,
        display_name,
        None,
        "MHC-A",
        "known",
        None,
        display_name,
        "exact",
        0,
        0,
        0,
        None,
        None,
    ]
    for column, value in enumerate(values, start=1):
        ws.cell(row, column).value = value
ws.tables["UnifiedGenotypeTable"].ref = "A1:N3"
ws.tables["UnifiedGenotypeTable"].autoFilter.ref = "A1:N3"
ws.auto_filter.ref = "A1:N3"
wb.save(path)
"""#, currentURL.path, displayName])
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["Sample-A", "Sample-B"],
                displayName: displayName
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: displayName,
                    sample: "Sample-A"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T03:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_220) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "ambiguous"
                )
            )
        }
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testReferenceTargetFailsClosedWhenWorkbookRequiresStableIdentity() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "reference-target-stable-collision"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        let displayName = "Mamu-A1*stable-collision"
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path, display_name = sys.argv[1:3]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
values = [
    "candidate",
    "cluster-existing",
    display_name,
    "cluster-existing",
    "MHC-A",
    "candidate",
    "zero-support",
    None,
    "candidate",
    0,
    0,
    0,
    None,
    None,
]
for column, value in enumerate(values, start=1):
    ws.cell(2, column).value = value
ws.tables["UnifiedGenotypeTable"].ref = "A1:N2"
ws.tables["UnifiedGenotypeTable"].autoFilter.ref = "A1:N2"
ws.auto_filter.ref = "A1:N2"
wb.save(path)
"""#, currentURL.path, displayName])
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["Sample-A", "Sample-B"],
                displayName: displayName
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: displayName,
                    sample: "Sample-A"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T03:05:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_221) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "stable cluster id"
                )
            )
        }
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testDuplicateStableWorkbookIdentityFailsClosedBeforeFormatting() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "duplicate-stable-workbook-identity"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        let displayName = "Mamu-A1*duplicate-stable"
        let stableID = "cluster-duplicate"
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path, display_name, stable_id = sys.argv[1:4]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
for row in (2, 3):
    values = [
        "candidate",
        stable_id,
        display_name,
        stable_id,
        "MHC-A",
        "candidate",
        "zero-support",
        None,
        "candidate",
        0,
        0,
        0,
        None,
        None,
    ]
    for column, value in enumerate(values, start=1):
        ws.cell(row, column).value = value
ws.tables["UnifiedGenotypeTable"].ref = "A1:N3"
ws.tables["UnifiedGenotypeTable"].autoFilter.ref = "A1:N3"
ws.auto_filter.ref = "A1:N3"
wb.save(path)
"""#, currentURL.path, displayName, stableID])
        _ = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(
                samples: ["Sample-A", "Sample-B"],
                rows: [
                    .init(
                        kind: .candidate,
                        callID: stableID,
                        displayName: displayName,
                        locus: "MHC-A",
                        stableID: stableID,
                        section: "candidate",
                        sortKey: "MHC-A|\(displayName)|\(stableID)",
                        supportBySample: ["Sample-A": 0, "Sample-B": 0]
                    ),
                ]
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: displayName,
                    sample: "Sample-A",
                    stableClusterID: stableID
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T03:06:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_222) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "ambiguous"
                )
            )
        }
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testAnnotationOnlySynthesisFailsClosedWhenNextOwnedRowIsOccupied() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "occupied-owned-row"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
ws["A2"] = "Unrelated analyst content in the next matrix-owned row"
wb.save(path)
"""#, currentURL.path])
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["Sample-A", "Sample-B"],
                displayName: "Mamu-A1*blocked"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*blocked",
                    sample: "Sample-A"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T03:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_230) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testAnnotationOnlyCachingScalesWithUniqueSheetsAndRows() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "annotation-only-cache-scale"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        let displayNames = (1...6).map {
            "Mamu-A1*cache-\(String(format: "%02d", $0))"
        }
        let rows = displayNames.map { displayName in
            GenotypeReviewableRowCatalog.Row(
                kind: .reference,
                callID: "reference:MHC-A:\(displayName)",
                displayName: displayName,
                locus: "MHC-A",
                stableID: nil,
                section: "reference",
                sortKey: "MHC-A|\(displayName)",
                supportBySample: ["Sample-A": 0, "Sample-B": 0]
            )
        }
        _ = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(
                samples: ["Sample-A", "Sample-B"],
                rows: rows
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = displayNames.flatMap { displayName in
            ["Sample-A", "Sample-B"].map { sample in
                .init(
                    target: .cell(
                        locus: "MHC-A",
                        genotype: displayName,
                        sample: sample
                    ),
                    disposition: .falseNegative,
                    author: "reviewer",
                    timestamp: "2026-07-27T01:00:00Z"
                )
            }
        }
        try sidecar.encoded().write(to: annotationURL)

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_275) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        XCTAssertEqual(
            pythonStep.resolvedOptions["matrixDescriptorScanCount"],
            .integer(2)
        )
        XCTAssertEqual(
            pythonStep.resolvedOptions["matrixRowSignatureCount"],
            .integer(7)
        )
    }

    func testGenericDuplicateAliasesAndUnsupportedLayoutsFailClosed() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for scenario in ["duplicate-alias", "unsupported-layout"] {
            let fixture = try makeGenericMatrixWorkbookBundle(
                in: root,
                outputName: scenario
            )
            let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
                for: fixture.bundleURL
            )
            try installAnnotationOnlyGenericReviewMatrix(in: currentURL)
            let catalog: GenotypeReviewableRowCatalog
            if scenario == "duplicate-alias" {
                catalog = GenotypeReviewableRowCatalog(
                    samples: ["AR3628"],
                    rows: [
                        .init(
                            kind: .reference,
                            callID: "reference:MHC-A:Mamu-X*same",
                            displayName: "Mamu-X*same",
                            locus: "MHC-A",
                            stableID: nil,
                            section: "reference",
                            sortKey: "MHC-A|Mamu-X*same",
                            supportBySample: ["AR3628": 0]
                        ),
                        .init(
                            kind: .reference,
                            callID: "reference:MHC-B:Mamu-X*same",
                            displayName: "Mamu-X*same",
                            locus: "MHC-B",
                            stableID: nil,
                            section: "reference",
                            sortKey: "MHC-B|Mamu-X*same",
                            supportBySample: ["AR3628": 0]
                        ),
                    ]
                )
            } else {
                catalog = annotationOnlyReferenceCatalog(
                    samples: ["AR3628"],
                    displayName: "Mamu-A1*missing"
                )
                _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
ws["B6"] = "Amount"
ws.tables["GenericGenotypeTable"].ref = "A6:D7"
wb.save(path)
"""#, currentURL.path])
            }
            _ = try installReviewableRowCatalog(catalog, in: fixture.bundleURL)
            let targetName = scenario == "duplicate-alias"
                ? "Mamu-X*same"
                : "Mamu-A1*missing"
            let annotationURL = fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-27T00:00:00Z"
            )
            sidecar.matrixReviews = [
                .init(
                    target: .cell(
                        locus: "MHC-A",
                        genotype: targetName,
                        sample: "AR3628"
                    ),
                    disposition: .falseNegative,
                    author: "reviewer",
                    timestamp: "2026-07-27T04:00:00Z"
                ),
            ]
            try sidecar.encoded().write(to: annotationURL)
            let before = try ProvenanceFileHasher.sha256(of: currentURL)

            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    dateProvider: { Date(timeIntervalSince1970: 8_225) },
                    userProvider: { "tester" },
                    pythonExecutableURL: testPythonExecutableURL
                ).applyHaplotypeOverrides(
                    [],
                    annotationSidecarURL: annotationURL,
                    into: fixture.bundleURL
                )
            ) { error in
                let message = error.localizedDescription.lowercased()
                if scenario == "duplicate-alias" {
                    XCTAssertTrue(message.contains("duplicate genotype aliases"))
                } else {
                    XCTAssertTrue(message.contains("unsupported workbook matrix layout"))
                }
            }
            XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
        }
    }

    func testUnifiedDuplicateSampleHeadersFailClosedWithoutWorkbookMutation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "duplicate-unified-samples"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
ws["N1"] = "Sample-A"
wb.save(path)
"""#, currentURL.path])
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["Sample-A"],
                displayName: "Mamu-A1*duplicate"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*duplicate",
                    sample: "Sample-A"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_225) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testDuplicateUnifiedSampleIntroducedAfterManagedApplyMakesClearFailClosed() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "duplicate-unified-sample-on-clear"
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(
            for: fixture.bundleURL
        )
        try installAnnotationOnlyUnifiedReviewMatrix(in: currentURL)
        _ = try installReviewableRowCatalog(
            annotationOnlyReferenceCatalog(
                samples: ["Sample-A", "Sample-B"],
                displayName: "Mamu-A1*managed"
            ),
            in: fixture.bundleURL
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*managed",
                    sample: "Sample-A"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 8_250),
            increment: 1
        )
        let service = GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
ws["N1"] = "Sample-A"
wb.save(path)
"""#, currentURL.path])
        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
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
        XCTAssertEqual(
            inspection["matrixAnnotationStyleRow"],
            [
                "style", "cell", "MHC-B", "Mamu-I*expected", "AR3628", "", "",
                "not-applicable", "", "#FFF2CC", "#C00000", "#666666", "true", "true",
                "curator", "2026-06-30T12:00:00Z", "",
            ].joined(separator: "|")
        )
        XCTAssertEqual(
            inspection["matrixAnnotationCommentRow"],
            [
                "comment", "cell", "MHC-B", "Mamu-I*expected", "AR3628", "", "",
                "not-applicable", "", "", "", "", "", "", "curator",
                "2026-06-30T12:00:00Z", "Expected genotype missing from reads.",
            ].joined(separator: "|")
        )
        XCTAssertEqual(inspection["cellFillSuffix"], "FFF2CC")
        XCTAssertEqual(inspection["cellTextColorSuffix"], "C00000")
        XCTAssertEqual(inspection["cellBorderSuffix"], "666666")
        XCTAssertEqual(inspection["cellBold"], "true")
        XCTAssertEqual(inspection["cellItalic"], "true")
        XCTAssertTrue(inspection["cellComment"]?.contains("Expected genotype missing from reads.") == true)
        XCTAssertEqual(inspection["guideMatrixStyles"], "1")
        XCTAssertEqual(inspection["guideMatrixComments"], "1")
    }

    func testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "semantic-reviews")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        try installSemanticReviewableRowCatalog(in: fixture.bundleURL)

        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Zero",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-24T10:01:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Absent",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-24T10:02:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-c"
                ),
                disposition: .falseNegative,
                author: "imported-reviewer",
                timestamp: "2026-07-24T10:03:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Zero",
                    stableClusterID: "cluster-a"
                ),
                body: "Analyst expects support in this sample.",
                author: "reviewer",
                timestamp: "2026-07-24T10:04:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_000) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "workbook-attestations",
                isDirectory: true
            )
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["falsePositiveValue"], "[42]")
        XCTAssertEqual(inspection["falsePositiveItalic"], "true")
        XCTAssertEqual(inspection["falsePositiveColor"], "767676")
        XCTAssertEqual(inspection["explicitZeroValue"], "FN")
        XCTAssertEqual(inspection["explicitZeroType"], "s")
        XCTAssertEqual(
            inspection["explicitZeroBorders"],
            "mediumDashed|mediumDashed|mediumDashed|mediumDashed"
        )
        XCTAssertEqual(inspection["explicitZeroFill"], "solid|FFF2CC")
        XCTAssertEqual(inspection["explicitZeroBold"], "true")
        XCTAssertEqual(inspection["explicitZeroColor"], "7F6000")
        XCTAssertTrue(
            inspection["explicitZeroComment"]?.contains(
                "Analyst expects support in this sample."
            ) == true
        )
        XCTAssertEqual(inspection["absentValue"], "FN")
        XCTAssertEqual(inspection["absentType"], "s")
        XCTAssertEqual(
            inspection["absentBorders"],
            "mediumDashed|mediumDashed|mediumDashed|mediumDashed"
        )
        XCTAssertEqual(inspection["otherLocusValue"], "42", "The colliding genotype at another locus must not be formatted")
        XCTAssertEqual(inspection["otherStableIDValue"], "42", "The colliding genotype at another stable ID must not be formatted")
        XCTAssertEqual(inspection["invalidReviewValue"], "42", "An ineligible false-negative import must not be formatted")
        XCTAssertEqual(inspection["invalidReviewBorders"], "|||")
        XCTAssertTrue(inspection["validReviewRow"]?.contains("|cluster-a|falsePositive|valid|") == true)
        XCTAssertTrue(inspection["invalidReviewRow"]?.contains("|cluster-c|falseNegative|invalid|") == true)
        XCTAssertTrue(inspection["invalidAuditRow"]?.contains("validateMatrixReview") == true)
        XCTAssertTrue(inspection["invalidAuditRow"]?.contains("|cluster-c|falseNegative|invalid|") == true)
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        let targetDecisions = try XCTUnwrap(
            pythonStep.resolvedOptions["falseNegativeTargetCellDecisions"]?
                .arrayValue
        )
        XCTAssertEqual(targetDecisions.count, 3)
        let invalidDecision = try XCTUnwrap(
            targetDecisions.first {
                $0.dictionaryValue?["status"] == .string("invalid")
            }?.dictionaryValue
        )
        XCTAssertEqual(invalidDecision["cell"], .null)
        XCTAssertEqual(
            invalidDecision["target"]?.dictionaryValue?["stableClusterID"],
            .string("cluster-c")
        )
        XCTAssertEqual(
            invalidDecision["presentationPrecedence"],
            .string("not-applied")
        )
        XCTAssertTrue(
            invalidDecision["reason"]?.stringValue?.contains(
                "authoritative sample support of zero"
            ) == true
        )
    }

    func testClearingMatrixReviewsRestoresManagedPresentationAndRemovesStaleSheets() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "review-clear")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        try installSemanticReviewableRowCatalog(in: fixture.bundleURL)
        let originalInspection = try inspectSemanticReviewWorkbook(currentURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Zero",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-24T10:01:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Absent",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-24T10:02:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_025) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "workbook-attestations",
                isDirectory: true
            )
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        XCTAssertEqual(try inspectSemanticReviewWorkbook(currentURL)["falsePositiveValue"], "[42]")
        let applied = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(applied["explicitZeroValue"], "FN")
        XCTAssertEqual(applied["explicitZeroFill"], "solid|FFF2CC")
        XCTAssertEqual(applied["explicitZeroBold"], "true")
        XCTAssertEqual(applied["explicitZeroColor"], "7F6000")
        XCTAssertEqual(applied["absentValue"], "FN")
        _ = try runPython(["-c", #"""
import sys
from copy import copy
from openpyxl import load_workbook
from openpyxl.styles import Side

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
font = copy(ws["D7"].font)
font.bold = True
font.italic = False
ws["D7"].font = font
border = copy(ws["E7"].border)
border.left = Side(style="thin", color="FF123456")
ws["E7"].border = border
wb.save(path)
"""#, currentURL.path])

        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        let cleared = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["falsePositiveValue"], "42")
        XCTAssertEqual(inspection["falsePositiveItalic"], "false")
        XCTAssertEqual(inspection["falsePositiveColor"], originalInspection["falsePositiveColor"])
        XCTAssertEqual(inspection["falsePositiveBold"], "true")
        XCTAssertEqual(inspection["explicitZeroValue"], "0")
        XCTAssertEqual(inspection["explicitZeroType"], "n")
        XCTAssertEqual(
            inspection["explicitZeroFill"],
            originalInspection["explicitZeroFill"]
        )
        XCTAssertEqual(
            inspection["explicitZeroFillBackground"],
            originalInspection["explicitZeroFillBackground"]
        )
        XCTAssertEqual(
            inspection["explicitZeroDiagonalBorder"],
            originalInspection["explicitZeroDiagonalBorder"]
        )
        XCTAssertEqual(
            inspection["explicitZeroDiagonalUp"],
            originalInspection["explicitZeroDiagonalUp"]
        )
        XCTAssertEqual(
            inspection["explicitZeroBold"],
            originalInspection["explicitZeroBold"]
        )
        XCTAssertEqual(
            inspection["explicitZeroColor"],
            originalInspection["explicitZeroColor"]
        )
        XCTAssertEqual(inspection["explicitZeroBorders"], "thin|||")
        XCTAssertEqual(inspection["absentValue"], "")
        XCTAssertEqual(inspection["absentType"], "n")
        XCTAssertEqual(inspection["hasMatrixAnnotationsSheet"], "false")
        XCTAssertEqual(inspection["hasManagedReviewStateSheet"], "false")
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(cleared.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        let restorationDecisions = try XCTUnwrap(
            pythonStep.resolvedOptions["managedReviewRestorationDecisions"]?
                .arrayValue
        )
        let zeroRestoration = try XCTUnwrap(
            restorationDecisions.first {
                $0.dictionaryValue?["cell"] == .string("E7")
            }?.dictionaryValue
        )
        XCTAssertEqual(
            zeroRestoration["target"]?.dictionaryValue?["sample"],
            .string("Sample-Zero")
        )
        let zeroProperties = try XCTUnwrap(
            zeroRestoration["properties"]?.dictionaryValue
        )
        XCTAssertEqual(zeroProperties["value"], .string("restored"))
        XCTAssertEqual(zeroProperties["font.bold"], .string("restored"))
        XCTAssertEqual(zeroProperties["font.color"], .string("restored"))
        XCTAssertEqual(zeroProperties["fill.patternType"], .string("restored"))
        XCTAssertEqual(zeroProperties["fill.fgColor"], .string("restored"))
        XCTAssertEqual(zeroProperties["border.left"], .string("preserved"))
        XCTAssertEqual(zeroProperties["border.right"], .string("restored"))
        let blankRestoration = try XCTUnwrap(
            restorationDecisions.first {
                $0.dictionaryValue?["cell"] == .string("F7")
            }?.dictionaryValue
        )
        XCTAssertEqual(
            blankRestoration["properties"]?.dictionaryValue?["value"],
            .string("restored")
        )
    }

    func testDuplicateExactReviewTargetsFailClosedInEitherOrder() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            sample: "Sample-FP",
            stableClusterID: "cluster-a"
        )
        for (index, dispositions) in [
            [
                GenotypeAnnotationSidecar.MatrixReviewDisposition.falseNegative,
                .falsePositive,
            ],
            [
                GenotypeAnnotationSidecar.MatrixReviewDisposition.falsePositive,
                .falseNegative,
            ],
        ].enumerated() {
            let fixture = try makeGenericMatrixWorkbookBundle(
                in: root,
                outputName: "duplicate-review-order-\(index)"
            )
            let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
            try installSemanticReviewMatrix(in: currentURL)
            try installSemanticReviewableRowCatalog(in: fixture.bundleURL)
            let original = try inspectSemanticReviewWorkbook(currentURL)
            let annotationURL = fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-24T00:00:00Z"
            )
            sidecar.matrixReviews = dispositions.enumerated().map { offset, disposition in
                .init(
                    target: target,
                    disposition: disposition,
                    author: "import-\(offset)",
                    timestamp: offset == 0
                        ? "2026-07-24T10:00:00"
                        : "2026-07-24T10:01:00Z"
                )
            }
            try sidecar.encoded().write(to: annotationURL)

            _ = try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_035) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )

            let inspection = try inspectSemanticReviewWorkbook(currentURL)
            XCTAssertEqual(inspection["falsePositiveValue"], "42")
            XCTAssertEqual(inspection["falsePositiveItalic"], "false")
            XCTAssertEqual(inspection["falsePositiveColor"], original["falsePositiveColor"])
            XCTAssertEqual(
                inspection["falsePositiveBorders"],
                original["falsePositiveBorders"]
            )
            XCTAssertEqual(inspection["conflictingReviewRows"], "2")
            XCTAssertEqual(inspection["conflictingAuditRows"], "2")
            XCTAssertTrue(
                inspection["conflictingReviewReasons"]?.contains(
                    "Conflicting duplicate review records target the same projection cell."
                ) == true
            )
        }
    }

    func testReviewBecomingInvalidRestoresPriorManagedPresentation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "review-valid-invalid")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        try installSemanticReviewableRowCatalog(in: fixture.bundleURL)
        let originalInspection = try inspectSemanticReviewWorkbook(currentURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            sample: "Sample-FP",
            stableClusterID: "cluster-a"
        )
        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_050) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falseNegative,
                author: "imported-reviewer",
                timestamp: "2026-07-24T10:01:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["falsePositiveValue"], "42")
        XCTAssertEqual(inspection["falsePositiveItalic"], "false")
        XCTAssertEqual(inspection["falsePositiveColor"], originalInspection["falsePositiveColor"])
        XCTAssertEqual(inspection["invalidReviewBorders"], "|||")
        XCTAssertTrue(inspection["invalidReviewRow"]?.contains("|cluster-a|falseNegative|invalid|") == true)
        XCTAssertEqual(inspection["hasManagedReviewStateSheet"], "false")
    }

    func testApplyHaplotypeOverridesComposesResolvedNativeNotesByScope() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "semantic-notes")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL, withUnrelatedComments: true)

        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            stableClusterID: "cluster-a"
        )
        let columnTarget = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Sample-FP")
        let cellTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            sample: "Sample-FP",
            stableClusterID: "cluster-a"
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: cellTarget,
                body: "Superseded cell note.",
                author: "older",
                timestamp: "2026-07-24T09:00:00Z"
            ),
            .init(
                target: rowTarget,
                body: "Allele-level note.",
                author: "row-author",
                timestamp: "2026-07-24T10:00:00Z"
            ),
            .init(
                target: columnTarget,
                body: "Sample-level note.",
                author: "column-author",
                timestamp: "2026-07-24T10:01:00Z"
            ),
            .init(
                target: cellTarget,
                body: "Current cell note.",
                author: "cell-author",
                timestamp: "2026-07-24T10:02:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_100) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        let rowComment = try XCTUnwrap(inspection["rowComment"])
        let columnComment = try XCTUnwrap(inspection["columnComment"])
        let cellComment = try XCTUnwrap(inspection["cellComment"])
        XCTAssertTrue(rowComment.contains("Existing row note"))
        XCTAssertTrue(rowComment.contains("Allele Row"))
        XCTAssertTrue(rowComment.contains("Body: Allele-level note."))
        XCTAssertTrue(rowComment.contains("Author: row-author"))
        XCTAssertTrue(rowComment.contains("Timestamp: 2026-07-24T10:00:00Z"))
        XCTAssertTrue(columnComment.contains("Sample Column"))
        XCTAssertTrue(columnComment.contains("Body: Sample-level note."))
        XCTAssertTrue(cellComment.contains("Existing cell note"))
        XCTAssertFalse(cellComment.contains("Superseded cell note."))
        XCTAssertTrue(cellComment.contains("Current cell note."))
        let rowRange = try XCTUnwrap(cellComment.range(of: "Allele Row"))
        let columnRange = try XCTUnwrap(cellComment.range(of: "Sample Column"))
        let cellRange = try XCTUnwrap(cellComment.range(of: "\nCell\n"))
        XCTAssertLessThan(rowRange.lowerBound, columnRange.lowerBound)
        XCTAssertLessThan(columnRange.lowerBound, cellRange.lowerBound)
        XCTAssertEqual(inspection["resolvedCellCommentRows"], "1")
        XCTAssertTrue(inspection["commentIdentityRow"]?.contains("|cell|MHC-A|Mamu-I*collision|Sample-FP|cluster-a|") == true)
    }

    func testApplyHaplotypeOverridesProvenanceNamesFinalStoredSidecarAndWorkbook() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "semantic-provenance")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_200) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(envelope.steps.first { $0.toolName.contains("python openpyxl") })
        let sidecarInput = try XCTUnwrap(pythonStep.inputs.first { $0.path == annotationURL.path })
        XCTAssertEqual(sidecarInput.checksumSHA256, try ProvenanceFileHasher.sha256(of: annotationURL))
        XCTAssertEqual(sidecarInput.fileSize, UInt64(try ProvenanceFileHasher.fileSize(of: annotationURL)))
        let workbookOutput = try XCTUnwrap(pythonStep.outputs.first { $0.path == currentURL.path })
        XCTAssertEqual(workbookOutput.checksumSHA256, try ProvenanceFileHasher.sha256(of: currentURL))
        XCTAssertEqual(workbookOutput.fileSize, UInt64(try ProvenanceFileHasher.fileSize(of: currentURL)))
        let durableReplayArgv = try XCTUnwrap(pythonStep.durableReplayArgv)
        XCTAssertTrue(durableReplayArgv.contains(annotationURL.path))
        XCTAssertTrue(durableReplayArgv.contains(currentURL.path))
        XCTAssertTrue(pythonStep.reproducibleCommand.contains(annotationURL.path))
        XCTAssertTrue(pythonStep.reproducibleCommand.contains(currentURL.path))
    }

    func testConcurrentAnnotationPublicationDuringWorkbookUpdateFailsClosedAndPreservesExactPair() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "annotation-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        let workbookBefore = try Data(contentsOf: currentURL)
        let manifestBefore = try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL))
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let annotationProvenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        var initial = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        initial.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "initial",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try initial.encoded().write(to: annotationURL)
        let initialProvenance = Data("initial-provenance".utf8)
        try initialProvenance.write(to: annotationProvenanceURL)

        var concurrent = initial
        concurrent.matrixReviews = []
        concurrent.matrixComments = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                body: "Concurrent annotation edit",
                author: "other-writer",
                timestamp: "2026-07-24T10:01:00Z"
            )
        ]
        let concurrentData = try concurrent.encoded()
        let concurrentProvenance = Data("concurrent-provenance".utf8)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_250) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-python-before-source-conflict-check" else { return }
                    try concurrentData.write(to: annotationURL, options: .atomic)
                    try concurrentProvenance.write(to: annotationProvenanceURL, options: .atomic)
                }
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )

        XCTAssertEqual(try Data(contentsOf: annotationURL), concurrentData)
        XCTAssertEqual(try Data(contentsOf: annotationProvenanceURL), concurrentProvenance)
        XCTAssertEqual(try Data(contentsOf: currentURL), workbookBefore)
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)),
            manifestBefore
        )
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
        XCTAssertEqual(updatedManifest.referenceRecordStore, fixture.manifest.referenceRecordStore)

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
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent,
            referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo(
                databasePath: "reference/records.sqlite",
                recordCount: 2,
                fieldCount: 4,
                sha256: String(repeating: "b", count: 64),
                sizeBytes: 512
            )
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func writeMinimalNativeArtifacts(
        in bundleURL: URL,
        outputName: String,
        sample: String = "SampleA"
    ) throws -> (genotypeCSV: URL, sampleCSV: URL, statsJSON: URL, provenance: URL) {
        let genotypeCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        \(sample),allele1,1,1
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        \(sample),1,1
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
        outputName: String,
        manifestKind: String? = nil,
        workflowKind: GenotypeResultWorkflowKind? = nil,
        workflowMode: GenotypeResultWorkflowMode? = nil,
        haplotypeAnalysisPath: String? = nil
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
        let artifacts = try writeMinimalNativeArtifacts(
            in: bundleURL,
            outputName: outputName,
            sample: "DW472"
        )
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
        let referenceDirectoryURL = bundleURL.appendingPathComponent("artifacts/reference", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceDirectoryURL, withIntermediateDirectories: true)
        let referenceVisualizationJSONURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-visualizations.json")
        let referenceGenBankURL = referenceDirectoryURL.appendingPathComponent("mhc-reference-records.gb")
        let referenceFASTAURL = referenceDirectoryURL.appendingPathComponent("mhc-reference-records.fasta")
        let referenceVisualizationDocument = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: []
        )
        let referenceEncoder = JSONEncoder()
        referenceEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try referenceEncoder.encode(referenceVisualizationDocument).write(to: referenceVisualizationJSONURL)
        try Data().write(to: referenceGenBankURL)
        try Data().write(to: referenceFASTAURL)
        let manifest = ONTGenotypeResultBundleManifest(
            kind:
                manifestKind
                    ?? workflowKind?.rawValue
                    ?? "ont-barcode-genotype",
            workflowKind: workflowKind,
            workflowMode:
                workflowKind == nil
                    ? nil
                    : (workflowMode ?? .genotypeOnly),
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [currentRevision],
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifacts(
                schemaVersion: 1,
                recordCount: 0,
                recordsJSON: try artifactReference(referenceVisualizationJSONURL, relativeTo: bundleURL),
                genBank: try artifactReference(referenceGenBankURL, relativeTo: bundleURL),
                fasta: try artifactReference(referenceFASTAURL, relativeTo: bundleURL)
            )
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func makeGenericMatrixWorkbookBundle(
        in root: URL,
        outputName: String,
        workflowKind: GenotypeResultWorkflowKind? = nil
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
        let artifacts = try writeMinimalNativeArtifacts(
            in: bundleURL,
            outputName: outputName,
            sample: "sample-a"
        )
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
            kind: workflowKind?.rawValue ?? "ont-barcode-genotype",
            workflowKind: workflowKind,
            workflowMode: workflowKind == nil ? nil : .genotypeOnly,
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

    private func installSemanticReviewMatrix(
        in url: URL,
        withUnrelatedComments: Bool = false
    ) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.styles import Border, PatternFill, Side

path = sys.argv[1]
with_comments = sys.argv[2] == "true"
wb = Workbook()
ws = wb.active
ws.title = "matrix"
ws.append(["Animal ID", None, None, "Sample-FP", "Sample-Zero", "Sample-Absent"])
ws.append(["GS ID", "Total", "Average", "Sample-FP", "Sample-Zero", "Sample-Absent"])
ws.append(["Filtered exact-match read count", None, None, 84, 0, 0])
ws.append([])
ws.append(["Comments", "Subtotal", "# Obs.", None, None, None])
ws.append(["Genotype", "Locus", "Stable Cluster ID", "Sample-FP", "Sample-Zero", "Sample-Absent"])
ws.append(["Mamu-I*collision", "MHC-A", "cluster-a", 42, 0, None])
ws.append(["Mamu-I*collision", "MHC-B", "cluster-b", 42, None, None])
ws.append(["Mamu-I*collision", "MHC-A", "cluster-c", 42, None, None])
ws["E7"].fill = PatternFill(
    fill_type="solid",
    fgColor="FFABCDEF",
    bgColor="FF112233",
)
ws["E7"].border = Border(
    diagonal=Side(style="dashDot", color="FF345678"),
    diagonalUp=True,
)
if with_comments:
    ws["A7"].comment = Comment("Existing row note", "existing-author")
    ws["D7"].comment = Comment("Existing cell note", "existing-author")
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path, withUnrelatedComments ? "true" : "false"])
    }

    private func installAnnotationOnlyUnifiedReviewMatrix(in url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import Border, Font, PatternFill, Side
from openpyxl.worksheet.table import Table, TableStyleInfo

path = sys.argv[1]
wb = Workbook()
ws = wb.active
ws.title = "Unified Genotype Pivot"
headers = [
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus",
    "classification", "support_class", "closest_reference", "match_class",
    "occurrence_count", "sample_count", "total_cluster_reads",
    "Sample-A", "Sample-B",
]
ws.append(headers)
ws.freeze_panes = "A2"
ws.merge_cells("O1:P1")
ws["O1"] = "Preserved merged heading"
ws["P2"] = "=1+1"
ws["P2"].font = Font(bold=True, color="FFFF0000")
ws["P2"].fill = PatternFill(fill_type="solid", fgColor="FFFFFF00")
formula_side = Side(style="thin", color="FF0000FF")
ws["P2"].border = Border(
    left=formula_side,
    right=formula_side,
    top=formula_side,
    bottom=formula_side,
)
ws["P2"].number_format = "0.00"
table = Table(displayName="UnifiedGenotypeTable", ref="A1:N1")
table.tableStyleInfo = TableStyleInfo(
    name="TableStyleMedium2",
    showFirstColumn=False,
    showLastColumn=False,
    showRowStripes=True,
    showColumnStripes=False,
)
ws.add_table(table)
ws.auto_filter.ref = "A1:N1"
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func annotationOnlyReferenceCatalog(
        samples: [String],
        displayName: String
    ) -> GenotypeReviewableRowCatalog {
        GenotypeReviewableRowCatalog(
            samples: samples,
            rows: [
                .init(
                    kind: .reference,
                    callID: "reference:MHC-A:\(displayName)",
                    displayName: displayName,
                    locus: "MHC-A",
                    stableID: nil,
                    section: "reference",
                    sortKey: "MHC-A|\(displayName)",
                    supportBySample: Dictionary(
                        uniqueKeysWithValues: samples.map { ($0, 0) }
                    )
                ),
            ]
        )
    }

    private func installAnnotationOnlyGenericReviewMatrix(in url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.worksheet.table import Table, TableStyleInfo

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
ws.append(["Mamu-A1*existing", 5, 1, 5])
ws["F2"] = "=SUM(B7:B9)"
ws.freeze_panes = "D7"
table = Table(displayName="GenericGenotypeTable", ref="A6:D7")
table.tableStyleInfo = TableStyleInfo(
    name="TableStyleMedium2",
    showFirstColumn=False,
    showLastColumn=False,
    showRowStripes=True,
    showColumnStripes=False,
)
ws.add_table(table)
ws.auto_filter.ref = "A6:D7"
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func inspectAnnotationOnlyGenericWorkbook(
        _ url: URL
    ) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["matrix"]

def text(value):
    return "" if value is None else str(value)

marker_rows = [
    row for row in range(7, ws.max_row + 1)
    if text(ws.cell(row, 1).value) == "Analyst annotation-only rows"
]
retained_marker_rows = [
    row for row in range(7, ws.max_row + 1)
    if text(ws.cell(row, 1).value)
        == "Analyst annotation-only rows (contains retained analyst edits)"
]
synthetic_rows = [
    row for row in range(7, ws.max_row + 1)
    if text(ws.cell(row, 1).value) == "Mamu-A1*missing"
]
synthetic = synthetic_rows[0] if synthetic_rows else 0
state = wb["_LGE Matrix Review State"] if "_LGE Matrix Review State" in wb.sheetnames else None
annotations = wb["Matrix Annotations"] if "Matrix Annotations" in wb.sheetnames else None
review_warning = ""
if annotations is not None:
    for row in range(2, annotations.max_row + 1):
        if (
            text(annotations.cell(row, 1).value) == "review"
            and text(annotations.cell(row, 4).value) == "Mamu-A1*missing"
        ):
            review_warning = text(annotations.cell(row, 9).value)
payload = {
    "markerRows": str(len(marker_rows)),
    "retainedMarkerRows": str(len(retained_marker_rows)),
    "retainedMarkerComment": (
        "" if not retained_marker_rows
        or ws.cell(retained_marker_rows[0], 1).comment is None
        else ws.cell(retained_marker_rows[0], 1).comment.text
    ),
    "syntheticRows": str(len(synthetic_rows)),
    "syntheticTotal": "" if not synthetic else text(ws.cell(synthetic, 2).value),
    "syntheticObserved": "" if not synthetic else text(ws.cell(synthetic, 3).value),
    "syntheticEvidence": "" if not synthetic else text(ws.cell(synthetic, 4).value),
    "tableRef": text(ws.tables["GenericGenotypeTable"].ref),
    "tableAutoFilterRef": text(
        getattr(ws.tables["GenericGenotypeTable"].autoFilter, "ref", None)
    ),
    "autoFilterRef": text(ws.auto_filter.ref),
    "existingRow": "|".join(text(ws.cell(7, col).value) for col in range(1, 5)),
    "formula": text(ws["F2"].value),
    "freezePanes": text(ws.freeze_panes),
    "analystComment": (
        "" if not synthetic or ws.cell(synthetic, 2).comment is None
        else ws.cell(synthetic, 2).comment.text
    ),
    "managedSyntheticRows": str(
        0 if state is None else sum(
            1 for row in range(2, state.max_row + 1)
            if text(state.cell(row, 17).value) == "true"
        )
    ),
    "reviewWarning": review_warning,
    "hasManagedReviewState": str(
        "_LGE Matrix Review State" in wb.sheetnames
    ).lower(),
    "stateSchemaID": "" if state is None else text(state.cell(1, 23).value),
    "stateSchemaVersion": "" if state is None else text(state.cell(1, 24).value),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        return try XCTUnwrap(object as? [String: String])
    }

    private func inspectAnnotationOnlyReviewWorkbook(
        _ url: URL
    ) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["Unified Genotype Pivot"]
headers = {
    str(ws.cell(1, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(1, col).value is not None
}

def text(value):
    return "" if value is None else str(value)

def borders(cell):
    return "|".join(
        text(getattr(getattr(cell.border, side), "style", None))
        for side in ("left", "right", "top", "bottom")
    )

def border_colors(cell):
    return "|".join(
        text(getattr(getattr(getattr(cell.border, side), "color", None), "rgb", None))
        for side in ("left", "right", "top", "bottom")
    )

def fill(cell):
    return "|".join([
        text(cell.fill.fill_type),
        text(getattr(cell.fill.fgColor, "rgb", None)),
    ])

def font(cell):
    return "|".join([
        str(bool(cell.font.bold)).lower(),
        text(getattr(cell.font.color, "rgb", None)),
    ])

marker_rows = [
    row for row in range(2, ws.max_row + 1)
    if text(ws.cell(row, headers["call_type"]).value)
        == "analyst-annotation-only-block"
]
synthetic_rows = [
    row for row in range(2, ws.max_row + 1)
    if text(ws.cell(row, headers["call_type"]).value)
        == "analyst-annotation-only"
]
synthetic_row = synthetic_rows[0] if synthetic_rows else 0
real_rows = [
    row for row in range(2, ws.max_row + 1)
    if text(ws.cell(row, headers["call_type"]).value) == "known-allele"
    and text(ws.cell(row, headers["display_name"]).value) == "Mamu-A1*001:01"
]
real_row = real_rows[0] if real_rows else 0
state = wb["_LGE Matrix Review State"] if "_LGE Matrix Review State" in wb.sheetnames else None

def synthetic_value(header):
    return "" if not synthetic_row else text(ws.cell(synthetic_row, headers[header]).value)

def synthetic_type(header):
    return "" if not synthetic_row else text(ws.cell(synthetic_row, headers[header]).data_type)

payload = {
    "adapter": "" if state is None or state.max_row < 2 else text(state.cell(2, 18).value),
    "markerRows": str(len(marker_rows)),
    "syntheticRows": str(len(synthetic_rows)),
    "syntheticDisplayNames": "|".join(
        text(ws.cell(row, headers["display_name"]).value)
        for row in synthetic_rows
    ),
    "realRows": str(len(real_rows)),
    "syntheticCallType": synthetic_value("call_type"),
    "syntheticCallID": synthetic_value("call_id"),
    "syntheticDisplayName": synthetic_value("display_name"),
    "syntheticStableID": synthetic_value("stable_cluster_id"),
    "syntheticLocus": synthetic_value("locus"),
    "syntheticClassification": synthetic_value("classification"),
    "syntheticOccurrenceCount": synthetic_value("occurrence_count"),
    "syntheticOccurrenceCountType": synthetic_type("occurrence_count"),
    "syntheticSampleCount": synthetic_value("sample_count"),
    "syntheticSampleCountType": synthetic_type("sample_count"),
    "syntheticTotalReads": synthetic_value("total_cluster_reads"),
    "syntheticTotalReadsType": synthetic_type("total_cluster_reads"),
    "sampleAValue": synthetic_value("Sample-A"),
    "sampleBValue": synthetic_value("Sample-B"),
    "sampleABorders": "" if not synthetic_row else borders(
        ws.cell(synthetic_row, headers["Sample-A"])
    ),
    "sampleBBorders": "" if not synthetic_row else borders(
        ws.cell(synthetic_row, headers["Sample-B"])
    ),
    "sampleABorderColors": "" if not synthetic_row else border_colors(
        ws.cell(synthetic_row, headers["Sample-A"])
    ),
    "sampleBBorderColors": "" if not synthetic_row else border_colors(
        ws.cell(synthetic_row, headers["Sample-B"])
    ),
    "sampleAFill": "" if not synthetic_row else fill(
        ws.cell(synthetic_row, headers["Sample-A"])
    ),
    "sampleBFill": "" if not synthetic_row else fill(
        ws.cell(synthetic_row, headers["Sample-B"])
    ),
    "sampleAFont": "" if not synthetic_row else font(
        ws.cell(synthetic_row, headers["Sample-A"])
    ),
    "sampleBFont": "" if not synthetic_row else font(
        ws.cell(synthetic_row, headers["Sample-B"])
    ),
    "realSampleABorders": "" if not real_row else borders(
        ws.cell(real_row, headers["Sample-A"])
    ),
    "tableRef": text(ws.tables["UnifiedGenotypeTable"].ref),
    "tableAutoFilterRef": text(
        getattr(ws.tables["UnifiedGenotypeTable"].autoFilter, "ref", None)
    ),
    "autoFilterRef": text(ws.auto_filter.ref),
    "freezePanes": text(ws.freeze_panes),
    "mergedRanges": "|".join(sorted(str(item) for item in ws.merged_cells.ranges)),
    "formula": text(ws["P2"].value),
    "formulaFont": (
        f"{str(bool(ws['P2'].font.bold)).lower()}|"
        f"{text(getattr(ws['P2'].font.color, 'rgb', None))}"
    ),
    "formulaFill": text(getattr(ws["P2"].fill.fgColor, "rgb", None)),
    "formulaBorders": borders(ws["P2"]),
    "formulaNumberFormat": text(ws["P2"].number_format),
    "managedSyntheticStateRows": str(
        0 if state is None else sum(
            1 for row in range(2, state.max_row + 1)
            if text(state.cell(row, 17).value) == "true"
        )
    ),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        return try XCTUnwrap(object as? [String: String])
    }

    private func inspectPortableFalseNegativeOOXML(
        _ url: URL
    ) throws -> [String: String] {
        let code = #"""
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    styles = archive.read("xl/styles.xml").decode("utf-8")
    cell_xml = "\n".join(
        archive.read(name).decode("utf-8")
        for name in archive.namelist()
        if name.startswith("xl/worksheets/sheet") and name.endswith(".xml")
    )
    if "xl/sharedStrings.xml" in archive.namelist():
        cell_xml += archive.read("xl/sharedStrings.xml").decode("utf-8")

payload = {
    "hasLiteralFN": str(">FN<" in cell_xml).lower(),
    "hasDashedBorder": str('style="mediumDashed"' in styles).lower(),
    "hasBorderColor": str('rgb="FFC65911"' in styles).lower(),
    "hasFillColor": str('rgb="FFFFF2CC"' in styles).lower(),
    "hasFontColor": str('rgb="FF7F6000"' in styles).lower(),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        return try XCTUnwrap(object as? [String: String])
    }

    private func installSemanticReviewableRowCatalog(
        in bundleURL: URL
    ) throws {
        let samples = ["Sample-FP", "Sample-Zero", "Sample-Absent"]
        let rows = [
            GenotypeReviewableRowCatalog.Row(
                kind: .candidate,
                callID: "cluster-a",
                displayName: "Mamu-I*collision",
                locus: "MHC-A",
                stableID: "cluster-a",
                section: "candidate",
                sortKey: "MHC-A|Mamu-I*collision|cluster-a",
                supportBySample: [
                    "Sample-FP": 42,
                    "Sample-Zero": 0,
                    "Sample-Absent": 0,
                ]
            ),
            GenotypeReviewableRowCatalog.Row(
                kind: .candidate,
                callID: "cluster-c",
                displayName: "Mamu-I*collision",
                locus: "MHC-A",
                stableID: "cluster-c",
                section: "candidate",
                sortKey: "MHC-A|Mamu-I*collision|cluster-c",
                supportBySample: [
                    "Sample-FP": 42,
                    "Sample-Zero": 0,
                    "Sample-Absent": 0,
                ]
            ),
        ]
        _ = try installReviewableRowCatalog(
            GenotypeReviewableRowCatalog(samples: samples, rows: rows),
            in: bundleURL
        )
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
    "abbreviatedDQHaplotype1": text(abbr.cell(abbr_row, abbr_headers["MHC-DQA/B Haplotype 1"]).value),
    "abbreviatedDQHaplotype2": text(abbr.cell(abbr_row, abbr_headers["MHC-DQA/B Haplotype 2"]).value),
    "abbreviatedDRBHaplotype1": text(abbr.cell(abbr_row, abbr_headers["MHC-DRB Haplotype 1"]).value),
    "abbreviatedDRBHaplotype2": text(abbr.cell(abbr_row, abbr_headers["MHC-DRB Haplotype 2"]).value),
    "abbreviatedComments": text(abbr.cell(abbr_row, abbr_headers["Comments"]).value),
    "customDPHaplotype1": text(custom.cell(custom_row, custom_headers["MHC-DPA/B Haplotype 1"]).value),
    "customDQHaplotype1": text(custom.cell(custom_row, custom_headers["MHC-DQA/B Haplotype 1"]).value),
    "fullAHaplotype1": text(full.cell(row_for(full, "MHC-A Haplotype 1"), full_col).value),
    "fullAHaplotype1Type": text(full.cell(row_for(full, "MHC-A Haplotype 1"), full_col).data_type),
    "fullAHaplotype2": text(full.cell(row_for(full, "MHC-A Haplotype 2"), full_col).value),
    "fullAHaplotype2Type": text(full.cell(row_for(full, "MHC-A Haplotype 2"), full_col).data_type),
    "fullBHaplotype1": text(full.cell(row_for(full, "MHC-B Haplotype 1"), full_col).value),
    "fullBHaplotype1Type": text(full.cell(row_for(full, "MHC-B Haplotype 1"), full_col).data_type),
    "fullBHaplotype2": text(full.cell(row_for(full, "MHC-B Haplotype 2"), full_col).value),
    "fullBHaplotype2Type": text(full.cell(row_for(full, "MHC-B Haplotype 2"), full_col).data_type),
    "fullDQAHaplotype1": text(full.cell(row_for(full, "MHC-DQA Haplotype 1"), full_col).value),
    "fullDQAHaplotype2": text(full.cell(row_for(full, "MHC-DQA Haplotype 2"), full_col).value),
    "fullDQBHaplotype1": text(full.cell(row_for(full, "MHC-DQB Haplotype 1"), full_col).value),
    "fullDQBHaplotype2": text(full.cell(row_for(full, "MHC-DQB Haplotype 2"), full_col).value),
    "fullDPAHaplotype1": text(full.cell(row_for(full, "MHC-DPA Haplotype 1"), full_col).value),
    "fullDPAHaplotype2": text(full.cell(row_for(full, "MHC-DPA Haplotype 2"), full_col).value),
    "fullDPBHaplotype1": text(full.cell(row_for(full, "MHC-DPB Haplotype 1"), full_col).value),
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

    private func inspectSemanticReviewWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["matrix"]

def text(value):
    return "" if value is None else str(value)

def color_suffix(color):
    value = getattr(color, "rgb", None)
    return "" if not value else str(value)[-6:]

def borders(cell):
    return "|".join(text(getattr(getattr(cell.border, side), "style", None)) for side in ("left", "right", "top", "bottom"))

def fill(cell):
    return "|".join([
        text(cell.fill.fill_type),
        color_suffix(cell.fill.fgColor),
    ])

def table_rows(name):
    if name not in wb.sheetnames:
        return []
    sheet = wb[name]
    return [[text(sheet.cell(row, col).value) for col in range(1, sheet.max_column + 1)] for row in range(2, sheet.max_row + 1)]

annotations = table_rows("Matrix Annotations")
audits = table_rows("Audit Log")
valid_review = next(("|".join(row) for row in annotations if "cluster-a" in row and "falsePositive" in row), "")
invalid_review = next((
    "|".join(row) for row in annotations
    if "falseNegative" in row and "invalid" in row
), "")
invalid_audit = next(("|".join(row) for row in audits if "cluster-c" in row and "invalid" in row), "")
comment_identity = next(("|".join(row) for row in annotations if row and row[0] == "comment" and "cluster-a" in row), "")
resolved_cell_comments = sum(1 for row in annotations if row and row[0] == "comment" and "cluster-a" in row and "Sample-FP" in row)
def has_duplicate_review_conflict(row):
    return any(
        "Conflicting duplicate review records" in value
        for value in row
    )

payload = {
    "falsePositiveValue": text(ws["D7"].value),
    "falsePositiveItalic": str(bool(ws["D7"].font.italic)).lower(),
    "falsePositiveBold": str(bool(ws["D7"].font.bold)).lower(),
    "falsePositiveColor": color_suffix(ws["D7"].font.color),
    "falsePositiveBorders": borders(ws["D7"]),
    "explicitZeroValue": text(ws["E7"].value),
    "explicitZeroType": text(ws["E7"].data_type),
    "explicitZeroBorders": borders(ws["E7"]),
    "explicitZeroFill": fill(ws["E7"]),
    "explicitZeroFillBackground": color_suffix(ws["E7"].fill.bgColor),
    "explicitZeroDiagonalBorder": "|".join([
        text(getattr(ws["E7"].border.diagonal, "style", None)),
        color_suffix(getattr(ws["E7"].border.diagonal, "color", None)),
    ]),
    "explicitZeroDiagonalUp": str(bool(ws["E7"].border.diagonalUp)).lower(),
    "explicitZeroBold": str(bool(ws["E7"].font.bold)).lower(),
    "explicitZeroColor": color_suffix(ws["E7"].font.color),
    "explicitZeroComment": (
        "" if ws["E7"].comment is None else ws["E7"].comment.text
    ),
    "absentValue": text(ws["F7"].value),
    "absentType": text(ws["F7"].data_type),
    "absentBorders": borders(ws["F7"]),
    "otherLocusValue": text(ws["D8"].value),
    "otherStableIDValue": text(ws["D9"].value),
    "invalidReviewValue": text(ws["D9"].value),
    "invalidReviewBorders": borders(ws["D9"]),
    "rowComment": "" if ws["A7"].comment is None else ws["A7"].comment.text,
    "columnComment": "" if ws["D1"].comment is None else ws["D1"].comment.text,
    "cellComment": "" if ws["D7"].comment is None else ws["D7"].comment.text,
    "validReviewRow": valid_review,
    "invalidReviewRow": invalid_review,
    "invalidAuditRow": invalid_audit,
    "commentIdentityRow": comment_identity,
    "resolvedCellCommentRows": str(resolved_cell_comments),
    "conflictingReviewRows": str(sum(
        1 for row in annotations
        if "cluster-a" in row and "invalid" in row
        and has_duplicate_review_conflict(row)
    )),
    "conflictingAuditRows": str(sum(
        1 for row in audits
        if "cluster-a" in row and "invalid" in row
        and has_duplicate_review_conflict(row)
    )),
    "conflictingReviewReasons": "||".join(
        "|".join(row) for row in annotations
        if "cluster-a" in row and "invalid" in row
        and has_duplicate_review_conflict(row)
    ),
    "hasMatrixAnnotationsSheet": str("Matrix Annotations" in wb.sheetnames).lower(),
    "hasManagedReviewStateSheet": str("_LGE Matrix Review State" in wb.sheetnames).lower(),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
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
    "matrixAnnotationStyleRow": row_values("Matrix Annotations", 2, 17),
    "matrixAnnotationCommentRow": row_values("Matrix Annotations", 3, 17),
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

    private enum RetainedCandidateArtifactCategory: Equatable {
        case candidate
        case unnameable
    }

    private func retainCandidateArtifactCategory(
        _ category: RetainedCandidateArtifactCategory,
        in bundleURL: URL
    ) throws {
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let revisedArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: category == .candidate ? artifacts.candidateJSON : nil,
            candidateFASTA: category == .candidate ? artifacts.candidateFASTA : nil,
            candidateGenBank: category == .candidate ? artifacts.candidateGenBank : nil,
            unnameableJSON: category == .unnameable ? artifacts.unnameableJSON : nil,
            unnameableFASTA: category == .unnameable ? artifacts.unnameableFASTA : nil,
            unnameableGenBank: category == .unnameable ? artifacts.unnameableGenBank : nil
        )
        let revisedManifest = ONTGenotypeResultBundleManifest(
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
            mhcCandidateArtifacts: revisedArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(revisedManifest, to: bundleURL)
    }

    private func installMinimalUnifiedPivot(in bundleURL: URL) throws {
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append([
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
    "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
    "total_cluster_reads", "sample-a", "sample-b",
])
wb.save(path)
"""#, currentURL.path])
    }

    private func installCandidateArtifacts(
        in bundleURL: URL,
        schemaVersion: Int = 1,
        artifactManifestSchemaVersion: Int = 1
    ) throws {
        let directory = bundleURL.appendingPathComponent("artifacts/mhc-candidates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidateFASTAURL = directory.appendingPathComponent("candidate-alleles.fasta")
        let unnameableFASTAURL = directory.appendingPathComponent("unnameable-clusters.fasta")
        let bases = Array("ACGT")
        let candidateSequences = Dictionary(uniqueKeysWithValues: (1...4).map {
            ("cluster-\($0)", String(
                repeating: bases[$0 % 4],
                count: schemaVersion >= 4 ? 33 : 39
            ))
        })
        let unnameableRawStableID = schemaVersion >= 4 ? "raw-cluster-u" : "cluster-u"
        let unnameableCanonicalFASTAID = schemaVersion >= 4 ? "canonical-cluster-u" : "cluster-u"
        let unnameableSequence = String(repeating: "N", count: 40)
        try candidateSequences.keys.sorted().map { ">\($0)\n" + candidateSequences[$0]! }
            .joined(separator: "\n").appending("\n")
            .write(to: candidateFASTAURL, atomically: true, encoding: .utf8)
        try ">\(unnameableCanonicalFASTAID)\n".appending(unnameableSequence).appending("\n")
            .write(to: unnameableFASTAURL, atomically: true, encoding: .utf8)
        let candidateFASTA = try artifactReference(candidateFASTAURL, relativeTo: bundleURL)
        let unnameableFASTA = try artifactReference(unnameableFASTAURL, relativeTo: bundleURL)
        let candidateGenBankURL = directory.appendingPathComponent("candidate-alleles.gb")
        let unnameableGenBankURL = directory.appendingPathComponent("unnameable-clusters.gb")
        try GenBankWriter(url: candidateGenBankURL).write(
            try candidateSequences.keys.sorted().map { stableID in
                let fullSequence = candidateSequences[stableID]!
                let isCroppedFixture = schemaVersion < 4 && stableID == "cluster-1"
                return try normalizedCandidateGenBankRecord(
                    stableID: stableID,
                    sequence: isCroppedFixture
                        ? String(fullSequence.dropFirst(3).dropLast(3))
                        : fullSequence,
                    translation: String(repeating: "A", count: isCroppedFixture ? 11 : 13),
                    status: "full-length",
                    fullSequence: isCroppedFixture ? fullSequence : nil,
                    trimStart: isCroppedFixture ? 4 : nil,
                    trimEnd: isCroppedFixture ? 36 : nil
                )
            }
        )
        try GenBankWriter(url: unnameableGenBankURL).write([
            try normalizedCandidateGenBankRecord(
                stableID: unnameableCanonicalFASTAID,
                sourceStableID: unnameableRawStableID,
                sequence: unnameableSequence,
                translation: nil,
                status: "incomplete/unresolved"
            ),
        ])
        let candidateGenBank = try artifactReference(candidateGenBankURL, relativeTo: bundleURL)
        let unnameableGenBank = try artifactReference(unnameableGenBankURL, relativeTo: bundleURL)
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
        let candidates = try specs.map { id, name, classification, support, snps in
            let selectedEvidence = ONTMHCEvidenceLocator(
                bamPath: selected.bamPath,
                queryName: id,
                referenceName: selected.referenceName,
                readGroupID: nil,
                referenceStart: selected.referenceStart,
                cigar: selected.cigar
            )
            let reciprocalSummary = try ONTMHCReciprocalQueryHitSummary(
                bamPath: selected.bamPath,
                queryName: id,
                alignmentCount: 3,
                targetAlignmentCounts: [selected.referenceName: 3],
                exactMatchTargetNames: [],
                closestMatchTargetNames: [selected.referenceName]
            )
            return ONTMHCCandidateRecord(
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
                sequenceSHA256: sha256Hex(candidateSequences[id]!),
                reciprocalHitSummary: reciprocalSummary,
                selectedEvidence: selectedEvidence
            )
        }
        var observations: [ONTMHCCandidateObservation] = []
        for candidate in candidates {
            observations.append(candidateObservation(candidate.stableClusterID, sample: "sample-a", reads: candidate.stableClusterID == "cluster-1" ? 7 : 4, schemaVersion: schemaVersion))
            if candidate.supportClass == .shared {
                observations.append(candidateObservation(candidate.stableClusterID, sample: "sample-b", reads: candidate.stableClusterID == "cluster-1" ? 3 : 2, schemaVersion: schemaVersion))
            }
        }
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: schemaVersion,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: candidateFASTA,
            candidates: candidates.reversed(),
            observations: observations.reversed()
        )
        let unnameable: ONTMHCUnnameableRecord
        if schemaVersion >= 2 {
            unnameable = ONTMHCUnnameableRecord(
                stableClusterID: unnameableRawStableID,
                reason: .unresolvedLocus,
                failedMetrics: ["identity": 0.7],
                supportClass: .singleton,
                independentSampleCount: 1,
                occurrenceCount: 1,
                totalClusterReads: 4,
                supportingSampleIDs: ["sample-a"],
                fastaRecordID: unnameableCanonicalFASTAID,
                sequenceSHA256: sha256Hex(unnameableSequence),
                reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                    bamPath: "artifacts/alignments/reciprocal.bam",
                    queryName: unnameableRawStableID,
                    alignmentCount: 3,
                    targetAlignmentCounts: ["ref-b": 1, "ref-a": 2],
                    exactMatchTargetNames: ["ref-a"],
                    closestMatchTargetNames: ["ref-a", "ref-b"]
                ),
                selectedEvidence: .init(
                    bamPath: "artifacts/alignments/reciprocal.bam",
                    queryName: unnameableRawStableID,
                    referenceName: "ref-a",
                    readGroupID: "sample-a",
                    referenceStart: 10,
                    cigar: "800M"
                )
            )
        } else {
            unnameable = ONTMHCUnnameableRecord(
                stableClusterID: "cluster-u",
                reason: .unresolvedLocus,
                failedMetrics: ["identity": 0.7],
                supportClass: .singleton,
                independentSampleCount: 1,
                occurrenceCount: 1,
                totalClusterReads: 4,
                supportingSampleIDs: ["sample-a"],
                fastaRecordID: "cluster-u",
                sequenceSHA256: sha256Hex(unnameableSequence),
                evidence: [
                    .init(bamPath: "artifacts/alignments/z.bam", queryName: "cluster-u-z", referenceName: "ref-z", readGroupID: "sample-z", referenceStart: 90, cigar: "900M"),
                    .init(bamPath: "artifacts/alignments/a.bam", queryName: "cluster-u-a", referenceName: "ref-a", readGroupID: "sample-a", referenceStart: 10, cigar: "800M"),
                ]
            )
        }
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: schemaVersion,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: unnameableFASTA,
            clusters: [unnameable],
            observations: [
                candidateObservation(
                    unnameableRawStableID,
                    sample: "sample-a",
                    reads: 4,
                    schemaVersion: schemaVersion
                ),
            ]
        )
        let candidateJSONURL = directory.appendingPathComponent("candidate-alleles.json")
        let unnameableJSONURL = directory.appendingPathComponent("unnameable-clusters.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(candidateDocument).write(to: candidateJSONURL, options: .atomic)
        try encoder.encode(unnameableDocument).write(to: unnameableJSONURL, options: .atomic)
        let rawUnmatchedFASTA: ONTMHCArtifactReference?
        let sourceIdentityMap: ONTMHCArtifactReference?
        if artifactManifestSchemaVersion >= 2 {
            let rawUnmatchedFASTAURL = directory.appendingPathComponent("raw-unmatched.fasta")
            try ">raw-cluster\nACGT\n".write(
                to: rawUnmatchedFASTAURL,
                atomically: true,
                encoding: .utf8
            )
            let sourceIdentityMapURL = directory.appendingPathComponent("source-identity.json")
            try Data(#"{"schema_version":1,"records":[]}"#.utf8).write(
                to: sourceIdentityMapURL,
                options: .atomic
            )
            rawUnmatchedFASTA = try artifactReference(
                rawUnmatchedFASTAURL,
                relativeTo: bundleURL
            )
            sourceIdentityMap = try artifactReference(
                sourceIdentityMapURL,
                relativeTo: bundleURL
            )
        } else {
            rawUnmatchedFASTA = nil
            sourceIdentityMap = nil
        }
        let artifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifactManifestSchemaVersion,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: try artifactReference(candidateJSONURL, relativeTo: bundleURL),
            candidateFASTA: candidateFASTA,
            candidateGenBank: candidateGenBank,
            unnameableJSON: try artifactReference(unnameableJSONURL, relativeTo: bundleURL),
            unnameableFASTA: unnameableFASTA,
            unnameableGenBank: unnameableGenBank,
            rawUnmatchedFASTA: rawUnmatchedFASTA,
            sourceIdentityMap: sourceIdentityMap
        )
        let referenceDirectory = bundleURL.appendingPathComponent("artifacts/mhc-reference", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)
        let referenceSequence = "ATGGCTTAA"
        let referenceRecord = ONTMHCReferenceVisualizationRecord(
            rawReferenceID: "NHP00001",
            sourceOrdinal: 0,
            alleleName: "Mafa-A1*001:01:01:01",
            locus: "Mafa-A1",
            sequence: referenceSequence,
            sequenceSHA256: sha256Hex(referenceSequence),
            recordFields: ["feature.allele": ["Mafa-A1*001:01:01:01"]],
            features: [],
            annotatedTranslation: "MA",
            genBankText: "LOCUS NHP00001",
            fastaText: ">NHP00001\n\(referenceSequence)\n",
            roles: [.init(role: .exactKnownCall, candidateStableClusterIDs: [])]
        )
        let referenceJSONURL = referenceDirectory.appendingPathComponent("records.json")
        try JSONEncoder().encode(
            ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: [referenceRecord])
        ).write(to: referenceJSONURL, options: .atomic)
        let referenceGenBankURL = referenceDirectory.appendingPathComponent("records.gb")
        try Data("LOCUS NHP00001\n//\n".utf8).write(to: referenceGenBankURL)
        let referenceFASTAURL = referenceDirectory.appendingPathComponent("records.fasta")
        try Data(referenceRecord.fastaText.utf8).write(to: referenceFASTAURL)
        let referenceVisualizations = ONTMHCReferenceVisualizationArtifacts(
            schemaVersion: 1,
            recordCount: 1,
            recordsJSON: try artifactReference(referenceJSONURL, relativeTo: bundleURL),
            genBank: try artifactReference(referenceGenBankURL, relativeTo: bundleURL),
            fasta: try artifactReference(referenceFASTAURL, relativeTo: bundleURL)
        )
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        sample-a,NHP00001,101,101,1000,101,10.1,3000,303,10.1
        sample-b,NHP00001,202,202,2000,202,10.1,3000,303,10.1
        """.write(
            to: ONTGenotypeResultBundle.resolvedURL(for: manifest.longSummaryCSVPath, in: bundleURL),
            atomically: true,
            encoding: .utf8
        )
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent
        sample-a,101,101,1000,101,10.1
        sample-b,202,202,2000,202,10.1
        """.write(
            to: ONTGenotypeResultBundle.resolvedURL(for: manifest.sampleSummaryCSVPath, in: bundleURL),
            atomically: true,
            encoding: .utf8
        )
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
            mhcCandidateArtifacts: artifacts,
            mhcReferenceVisualizations: referenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundleURL)
    }

    private func installReviewableRowCatalog(
        _ catalog: GenotypeReviewableRowCatalog,
        in bundleURL: URL
    ) throws -> ONTMHCArtifactReference {
        let validated = try catalog.validated()
        let catalogURL = bundleURL.appendingPathComponent(
            "artifacts/review/reviewable-row-catalog.json"
        )
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try validated.encoded().write(to: catalogURL, options: .atomic)
        let reference = try artifactReference(catalogURL, relativeTo: bundleURL)
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        let updated = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            workflowKind: manifest.workflowKind,
            workflowMode: manifest.workflowMode,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath:
                manifest.deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: manifest.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            presetID: manifest.presetID,
            presetVersion: manifest.presetVersion,
            createdAt: manifest.createdAt,
            activeHaplotypeAnalysisRevisionID:
                manifest.activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: manifest.haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: manifest.mhcCandidateArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore,
            alignmentArtifacts: manifest.alignmentArtifacts,
            provisionalExon2Artifacts: manifest.provisionalExon2Artifacts,
            reviewableRowCatalog: reference
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundleURL)
        return reference
    }

    private func artifactReference(_ url: URL, relativeTo bundleURL: URL) throws -> ONTMHCArtifactReference {
        ONTMHCArtifactReference(
            path: String(url.standardizedFileURL.path.dropFirst(bundleURL.standardizedFileURL.path.count + 1)),
            sha256: try ProvenanceFileHasher.sha256(of: url),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
        )
    }

    private func normalizedCandidateGenBankRecord(
        stableID: String,
        sourceStableID: String? = nil,
        sequence: String,
        translation: String?,
        status: String,
        fullSequence: String? = nil,
        trimStart: Int? = nil,
        trimEnd: Int? = nil
    ) throws -> GenBankRecord {
        var sourceQualifiers: [String: AnnotationQualifier] = [
            "stable_cluster_id": .init(sourceStableID ?? stableID),
            "sequence_sha256": .init(sha256Hex(fullSequence ?? sequence)),
            "translation_status": .init(status),
        ]
        if let fullSequence, let trimStart, let trimEnd {
            sourceQualifiers["original_sequence_length"] = .init(String(fullSequence.count))
            sourceQualifiers["trim_start"] = .init(String(trimStart))
            sourceQualifiers["trim_end"] = .init(String(trimEnd))
            sourceQualifiers["genbank_sequence_sha256"] = .init(sha256Hex(sequence))
            sourceQualifiers["trim_status"] = .init("trimmed-to-outer-lifted-CDS")
            sourceQualifiers["reference_readiness_status"] = .init("reference-ready")
        }
        var annotations = [
            SequenceAnnotation(
                type: .source,
                name: stableID,
                start: 0,
                end: sequence.count,
                strand: .forward,
                qualifiers: sourceQualifiers
            ),
        ]
        if let translation {
            annotations.append(SequenceAnnotation(
                type: .cds,
                name: stableID,
                start: 0,
                end: sequence.count,
                strand: .forward,
                qualifiers: ["translation": .init(translation)]
            ))
        }
        return GenBankRecord(
            sequence: try Sequence(name: stableID, alphabet: .dna, bases: sequence),
            annotations: annotations,
            locus: .init(name: stableID, length: sequence.count, moleculeType: .dna, topology: .linear),
            accession: stableID
        )
    }

    private func sha256Hex(_ sequence: String) -> String {
        SHA256.hash(data: Data(sequence.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func candidateObservation(
        _ cluster: String,
        sample: String,
        reads: Int,
        schemaVersion: Int = 1
    ) -> ONTMHCCandidateObservation {
        if schemaVersion == 2 {
            return ONTMHCCandidateObservation(
                stableClusterID: cluster,
                sampleID: sample,
                readGroupID: sample,
                sourceClusterIDs: ["source-\(cluster)-\(sample)"],
                sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
                aggregatedSampleReadCount: reads,
                genotypingHitSummaries: []
            )
        }
        return ONTMHCCandidateObservation(
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
candidate_headers = {text(cell.value): cell.column for cell in candidate[1] if text(cell.value)}
unnameable_headers = {text(cell.value): cell.column for cell in unnameable[1] if text(cell.value)}
candidate_ids = [text(candidate.cell(row, 1).value) for row in range(2, candidate.max_row + 1)]
candidate_names = [text(candidate.cell(row, 2).value) for row in range(2, candidate.max_row + 1)]
unnameable_query_col = unnameable_headers.get("Selected Evidence Query Name") or unnameable_headers.get("Evidence Query Name")
payload = {
    "candidateIDs": "|".join(candidate_ids),
    "candidateNames": "|".join(candidate_names),
    "candidateNameFills": "|".join(argb(candidate.cell(row, 2)) for row in range(2, candidate.max_row + 1)),
    "candidateIDFills": "|".join(argb(candidate.cell(row, 1)) for row in range(2, candidate.max_row + 1)),
    "unnameableIDs": "|".join(text(unnameable.cell(row, 1).value) for row in range(2, unnameable.max_row + 1)),
    "unnameableQueries": "|".join(text(unnameable.cell(row, unnameable_query_col).value) for row in range(2, unnameable.max_row + 1)) if unnameable_query_col else "",
    "unnameableReciprocalAlignmentCounts": "|".join(text(unnameable.cell(row, unnameable_headers["Reciprocal Alignment Count"]).value) for row in range(2, unnameable.max_row + 1)) if "Reciprocal Alignment Count" in unnameable_headers else "",
    "unnameableExactTargets": "|".join(text(unnameable.cell(row, unnameable_headers["Exact Match Target Names"]).value) for row in range(2, unnameable.max_row + 1)) if "Exact Match Target Names" in unnameable_headers else "",
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
    headers = {text(cell.value): cell.column for cell in ws[1] if text(cell.value)}
    call_type_col = headers.get("call_type", 1)
    stable_id_col = headers.get("stable_cluster_id", 4)
    rows = [row for row in range(2, ws.max_row + 1) if text(ws.cell(row, call_type_col).value).startswith("candidate-")]
    payload["unifiedCandidateCount"] = str(len(rows))
    payload["unifiedCandidateIDs"] = "|".join(text(ws.cell(row, stable_id_col).value) for row in rows)
    payload["unifiedSampleAReads"] = "|".join(text(ws.cell(row, headers["Sample Reads: sample-a"]).value) for row in rows) if "Sample Reads: sample-a" in headers else ""
    payload["unifiedSampleBReads"] = "|".join(text(ws.cell(row, headers["Sample Reads: sample-b"]).value) for row in rows) if "Sample Reads: sample-b" in headers else ""
else:
    payload["unifiedCandidateCount"] = "0"
    payload["unifiedCandidateIDs"] = ""
    payload["unifiedSampleAReads"] = ""
    payload["unifiedSampleBReads"] = ""
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

    private func inspectTwoSheetCandidateWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def text(value):
    return "" if value is None else str(value)

unified = wb["Unified Genotype Pivot"]
def row_for_label(label):
    return next((row for row in range(1, unified.max_row + 1) if text(unified.cell(row, 1).value) == label), None)

sample_a_col = next((column for column in range(1, unified.max_column + 1) if text(unified.cell(1, column).value) == "sample-a"), None)
sample_b_col = next((column for column in range(1, unified.max_column + 1) if text(unified.cell(1, column).value) == "sample-b"), None)
table_header_row = next(
    row for row in range(1, unified.max_row + 1)
    if any(text(unified.cell(row, column).value) == "call_type" for column in range(1, unified.max_column + 1))
)
headers = {
    text(unified.cell(table_header_row, column).value): column
    for column in range(1, unified.max_column + 1)
    if text(unified.cell(table_header_row, column).value)
}
candidate_rows = [
    row for row in range(table_header_row + 1, unified.max_row + 1)
    if text(unified.cell(row, headers["call_type"]).value).startswith("candidate-")
]
def argb(cell):
    value = getattr(cell.fill.fgColor, "rgb", None)
    return text(value) or "00000000"
unmatched = wb["Unmatched Alleles"]
unmatched_headers = {
    text(cell.value): cell.column for cell in unmatched[1] if text(cell.value)
}
unmatched_rows = {
    text(unmatched.cell(row, unmatched_headers["Stable Cluster ID"]).value): row
    for row in range(2, unmatched.max_row + 1)
}
candidate_row = unmatched_rows.get("cluster-1")
unnameable_row = unmatched_rows.get("raw-cluster-u") or unmatched_rows.get("cluster-u")
payload = {
    "sheetNames": "|".join(wb.sheetnames),
    "tableHeaderRow": str(table_header_row),
    "analystHaplotype": text(unified.cell(row_for_label("MHC-A Haplotype 1"), sample_a_col).value) if row_for_label("MHC-A Haplotype 1") and sample_a_col else "",
    "analystHaplotypeType": text(unified.cell(row_for_label("MHC-A Haplotype 1"), sample_a_col).data_type) if row_for_label("MHC-A Haplotype 1") and sample_a_col else "",
    "analystHaplotype2": text(unified.cell(row_for_label("MHC-A Haplotype 2"), sample_a_col).value) if row_for_label("MHC-A Haplotype 2") and sample_a_col else "",
    "analystHaplotype2Type": text(unified.cell(row_for_label("MHC-A Haplotype 2"), sample_a_col).data_type) if row_for_label("MHC-A Haplotype 2") and sample_a_col else "",
    "analystComment": text(unified.cell(row_for_label("Comments"), sample_a_col).value) if row_for_label("Comments") and sample_a_col else "",
    "mappedTotal": text(unified.cell(row_for_label("Mapped Read Count"), 2).value) if row_for_label("Mapped Read Count") else "",
    "mappedAverage": text(unified.cell(row_for_label("Mapped Read Count"), 3).value) if row_for_label("Mapped Read Count") else "",
    "mappedTotalType": text(unified.cell(row_for_label("Mapped Read Count"), 2).data_type) if row_for_label("Mapped Read Count") else "",
    "mappedAverageType": text(unified.cell(row_for_label("Mapped Read Count"), 3).data_type) if row_for_label("Mapped Read Count") else "",
    "sampleAMappedType": text(unified.cell(row_for_label("Mapped Read Count"), sample_a_col).data_type) if row_for_label("Mapped Read Count") and sample_a_col else "",
    "sampleATotalReadType": text(unified.cell(row_for_label("total_read_count"), sample_a_col).data_type) if row_for_label("total_read_count") and sample_a_col else "",
    "sampleAUnmappedPercentType": text(unified.cell(row_for_label("percent_reads_unmapped"), sample_a_col).data_type) if row_for_label("percent_reads_unmapped") and sample_a_col else "",
    "sampleADQAHaplotype1": text(unified.cell(row_for_label("MHC-DQA Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DQA Haplotype 1") and sample_a_col else "",
    "sampleADQAHaplotype2": text(unified.cell(row_for_label("MHC-DQA Haplotype 2"), sample_a_col).value) if row_for_label("MHC-DQA Haplotype 2") and sample_a_col else "",
    "sampleADRBHaplotype1": text(unified.cell(row_for_label("MHC-DRB Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DRB Haplotype 1") and sample_a_col else "",
    "sampleADRBHaplotype2": text(unified.cell(row_for_label("MHC-DRB Haplotype 2"), sample_a_col).value) if row_for_label("MHC-DRB Haplotype 2") and sample_a_col else "",
    "sampleADQBHaplotype1": text(unified.cell(row_for_label("MHC-DQB Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DQB Haplotype 1") and sample_a_col else "",
    "sampleADQBHaplotype2": text(unified.cell(row_for_label("MHC-DQB Haplotype 2"), sample_a_col).value) if row_for_label("MHC-DQB Haplotype 2") and sample_a_col else "",
    "sampleADPAHaplotype1": text(unified.cell(row_for_label("MHC-DPA Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DPA Haplotype 1") and sample_a_col else "",
    "sampleADPAHaplotype2": text(unified.cell(row_for_label("MHC-DPA Haplotype 2"), sample_a_col).value) if row_for_label("MHC-DPA Haplotype 2") and sample_a_col else "",
    "sampleADPBHaplotype1": text(unified.cell(row_for_label("MHC-DPB Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DPB Haplotype 1") and sample_a_col else "",
    "sampleADPBHaplotype2": text(unified.cell(row_for_label("MHC-DPB Haplotype 2"), sample_a_col).value) if row_for_label("MHC-DPB Haplotype 2") and sample_a_col else "",
    "sampleABHaplotype1": text(unified.cell(row_for_label("MHC-B Haplotype 1"), sample_a_col).value) if row_for_label("MHC-B Haplotype 1") and sample_a_col else "",
    "sampleABHaplotype1Type": text(unified.cell(row_for_label("MHC-B Haplotype 1"), sample_a_col).data_type) if row_for_label("MHC-B Haplotype 1") and sample_a_col else "",
    "sampleABHaplotype2": text(unified.cell(row_for_label("MHC-B Haplotype 2"), sample_a_col).value) if row_for_label("MHC-B Haplotype 2") and sample_a_col else "",
    "sampleABHaplotype2Type": text(unified.cell(row_for_label("MHC-B Haplotype 2"), sample_a_col).data_type) if row_for_label("MHC-B Haplotype 2") and sample_a_col else "",
    "sampleBDQAHaplotype1": text(unified.cell(row_for_label("MHC-DQA Haplotype 1"), sample_b_col).value) if row_for_label("MHC-DQA Haplotype 1") and sample_b_col else "",
    "sampleBDPBHaplotype1": text(unified.cell(row_for_label("MHC-DPB Haplotype 1"), sample_b_col).value) if row_for_label("MHC-DPB Haplotype 1") and sample_b_col else "",
    "knownDisplayName": text(unified.cell(table_header_row + 1, headers["display_name"]).value),
    "knownClosestReference": text(unified.cell(table_header_row + 1, headers["closest_reference"]).value),
    "knownSampleAReads": text(unified.cell(table_header_row + 1, headers["sample-a"]).value) if "sample-a" in headers else "",
    "knownSampleBReads": text(unified.cell(table_header_row + 1, headers["sample-b"]).value) if "sample-b" in headers else "",
    "knownTotalReads": text(unified.cell(table_header_row + 1, headers["total_cluster_reads"]).value),
    "candidateIDs": "|".join(text(unified.cell(row, headers["stable_cluster_id"]).value) for row in candidate_rows),
    "candidateNameFills": "|".join(argb(unified.cell(row, headers["display_name"])) for row in candidate_rows),
    "unmatchedIDs": "|".join(text(unmatched.cell(row, unmatched_headers["Stable Cluster ID"]).value) for row in range(2, unmatched.max_row + 1)),
    "candidateSequence": text(unmatched.cell(candidate_row, unmatched_headers["Nucleotide Sequence"]).value) if candidate_row else "",
    "legacySequenceColumns": str(
        "Full-Length FASTA Sequence" in unmatched_headers
        or "UTR-Trimmed FASTA Sequence" in unmatched_headers
    ).lower(),
    "candidateTranslation": text(unmatched.cell(candidate_row, unmatched_headers["Putative Amino Acid Translation"]).value) if candidate_row else "",
    "candidateTranslationStatus": text(unmatched.cell(candidate_row, unmatched_headers["Translation Status"]).value) if candidate_row else "",
    "unnameableSequence": text(unmatched.cell(unnameable_row, unmatched_headers["Nucleotide Sequence"]).value) if unnameable_row else "",
    "unnameableTranslationStatus": text(unmatched.cell(unnameable_row, unmatched_headers["Translation Status"]).value) if unnameable_row else "",
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    private func inspectBiologicallyOrderedTwoSheetWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def text(value):
    return "" if value is None else str(value)

unified = wb["Unified Genotype Pivot"]
table_header_row = next(
    row for row in range(1, unified.max_row + 1)
    if any(text(unified.cell(row, column).value) == "call_type" for column in range(1, unified.max_column + 1))
)
headers = {
    text(unified.cell(table_header_row, column).value): column
    for column in range(1, unified.max_column + 1)
    if text(unified.cell(table_header_row, column).value)
}
data_rows = range(table_header_row + 1, unified.max_row + 1)
sample_a_col = next(
    column for column in range(1, unified.max_column + 1)
    if text(unified.cell(1, column).value) == "sample-a"
)
def row_for_label(label):
    return next(row for row in range(1, unified.max_row + 1) if text(unified.cell(row, 1).value) == label)

unmatched = wb["Unmatched Alleles"]
unmatched_headers = {text(cell.value): cell.column for cell in unmatched[1] if text(cell.value)}
payload = {
    "sheetNames": "|".join(wb.sheetnames),
    "analystHaplotype": text(unified.cell(row_for_label("MHC-A Haplotype 1"), sample_a_col).value),
    "analystComment": text(unified.cell(row_for_label("Comments"), sample_a_col).value),
    "unifiedDisplayNames": "|".join(text(unified.cell(row, headers["display_name"]).value) for row in data_rows),
    "unmatchedNames": "|".join(
        text(unmatched.cell(row, unmatched_headers["Provisional Allele Name"]).value)
        for row in range(2, unmatched.max_row + 1)
    ),
    "unmatchedIDs": "|".join(
        text(unmatched.cell(row, unmatched_headers["Stable Cluster ID"]).value)
        for row in range(2, unmatched.max_row + 1)
    ),
}
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
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
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

    private func workbookCleanupArtifacts(in parent: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(".lungfish-workbook-cleanup-pending-")
                || name.contains(".workbook-cleanup-state-")
                || name.contains(".workbook-cleanup-warning-")
        }
    }

    private func workbookCleanupStateURL(in parent: URL) throws -> URL {
        try XCTUnwrap(
            try workbookCleanupArtifacts(in: parent).first {
                $0.lastPathComponent.contains(".workbook-cleanup-state-")
            }
        )
    }

    private func workbookRecoveryReceiptActions(in parent: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains(".workbook-update-recovery-")
                && $0.pathExtension == "json"
        }.compactMap {
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: $0)
            ) as? [String: Any]
            return object?["action"] as? String
        }
    }

    private func mutateJSONObject(
        at url: URL,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        try mutation(&object)
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url, options: .atomic)
    }

    private func assertNoRetiredWorkbookGeneration(in parent: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertFalse(
            names.contains {
                $0.hasPrefix(".lungfish-workbook-generation-archive-")
                    || $0.hasPrefix(".lungfish-workbook-cleanup-pending-")
                    || $0.contains(".workbook-cleanup-state-")
            }
        )
    }

    private func interruptCommittedWorkbookCleanup(
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        attestationRoot: URL
    ) throws {
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else {
                        return
                    }
                    throw NSError(domain: "SimulatedCommittedWorkbookCrash", code: 9)
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL
            )
        )
    }

    private func interruptWorkbookCleanup(
        branch: String,
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        attestationRoot: URL
    ) throws {
        let checkpoint: String
        switch branch {
        case "committed":
            checkpoint = "after-revision-manifest-hard-stop"
        case "prepared-discard":
            checkpoint = "after-transaction-marker-hard-stop"
        case "rollback":
            checkpoint = "after-exchange-hard-stop"
        case "manual-save-winner":
            checkpoint = "after-revision-manifest-hard-stop"
        default:
            XCTFail("Unknown workbook cleanup branch \(branch)")
            return
        }
        let currentPath = try XCTUnwrap(fixture.manifest.currentWorkbookPath)
        let pythonURL = testPythonExecutableURL
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { observed in
                    guard observed == checkpoint else { return }
                    if branch == "manual-save-winner" {
                        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(
                            for: fixture.bundleURL
                        )
                        let marker = try XCTUnwrap(
                            try JSONSerialization.jsonObject(
                                with: Data(contentsOf: markerURL)
                            ) as? [String: Any]
                        )
                        let staging = URL(
                            fileURLWithPath: try XCTUnwrap(
                                marker["stagingBundlePath"] as? String
                            ),
                            isDirectory: true
                        )
                        let workbook = staging.appendingPathComponent(currentPath)
                        _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z94"] = "manual-cleanup-winner"
wb.save(path)
"""#, workbook.path], executableURL: pythonURL)
                    }
                    throw NSError(
                        domain: "SimulatedWorkbookBranchCrash",
                        code: 9
                    )
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL
            )
        )
    }

    private func pausedCommittedWorkbookCleanup(
        outputName: String
    ) throws -> (
        root: URL,
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        attestationRoot: URL,
        quarantine: URL,
        lock: ONTGenotypeBundlePublicationLock
    ) {
        let root = try temporaryDirectory()
        do {
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: outputName)
            let attestationRoot = root.appendingPathComponent(
                "attestations",
                isDirectory: true
            )
            try interruptCommittedWorkbookCleanup(
                fixture: fixture,
                attestationRoot: attestationRoot
            )
            let lock = try ONTGenotypeBundlePublicationLock.acquire(
                for: fixture.bundleURL,
                blocking: true,
                createIfMissing: false
            )
            do {
                XCTAssertThrowsError(
                    try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                        for: fixture.bundleURL,
                        attestationRootURL: attestationRoot,
                        cleanupFailureInjector: { checkpoint in
                            guard checkpoint == "during-workbook-cleanup-traversal" else {
                                return
                            }
                            throw NSError(
                                domain: "InjectedWorkbookCleanupTraversal",
                                code: 5
                            )
                        }
                    )
                )
                let quarantine = try XCTUnwrap(
                    try FileManager.default.contentsOfDirectory(
                        at: root,
                        includingPropertiesForKeys: nil
                    ).first {
                        $0.lastPathComponent.hasPrefix(
                            ".lungfish-workbook-cleanup-pending-"
                        )
                    }
                )
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                        for: fixture.bundleURL
                    ).path
                ))
                return (root, fixture, attestationRoot, quarantine, lock)
            } catch {
                lock.release()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func pausedBeforeCleanupAttestation(
        outputName: String
    ) throws -> (
        root: URL,
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        attestationRoot: URL,
        stateURL: URL,
        quarantine: URL,
        markerURL: URL,
        transactionAttestationURL: URL,
        lock: ONTGenotypeBundlePublicationLock
    ) {
        let root = try temporaryDirectory()
        do {
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: outputName
            )
            let attestationRoot = root.appendingPathComponent(
                "attestations",
                isDirectory: true
            )
            try interruptCommittedWorkbookCleanup(
                fixture: fixture,
                attestationRoot: attestationRoot
            )
            let lock = try ONTGenotypeBundlePublicationLock.acquire(
                for: fixture.bundleURL,
                blocking: true,
                createIfMissing: false
            )
            do {
                XCTAssertThrowsError(
                    try ONTGenotypeWorkbookUpdateRecovery
                        .recoverIfNeededAssumingLock(
                            for: fixture.bundleURL,
                            attestationRootURL: attestationRoot,
                            cleanupFailureInjector: { checkpoint in
                                guard checkpoint
                                    == "after-workbook-cleanup-state-write-before-attestation-hard-stop" else {
                                    return
                                }
                                throw NSError(
                                    domain:
                                        "InjectedCleanupAttestationPublicationCrash",
                                    code: 9
                                )
                            }
                        )
                )
                let stateURL = try workbookCleanupStateURL(in: root)
                let quarantine = try XCTUnwrap(
                    try workbookCleanupArtifacts(in: root).first {
                        $0.lastPathComponent.hasPrefix(
                            ".lungfish-workbook-cleanup-pending-"
                        )
                    }
                )
                let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(
                    for: fixture.bundleURL
                )
                let attestations = try FileManager.default
                    .contentsOfDirectory(
                        at: attestationRoot,
                        includingPropertiesForKeys: nil
                    )
                    .filter {
                        $0.pathExtension == "json"
                            && !$0.lastPathComponent.hasSuffix(
                                ".workbook-cleanup.json"
                            )
                    }
                let transactionAttestationURL = try XCTUnwrap(
                    attestations.first
                )
                XCTAssertEqual(attestations.count, 1)
                return (
                    root,
                    fixture,
                    attestationRoot,
                    stateURL,
                    quarantine,
                    markerURL,
                    transactionAttestationURL,
                    lock
                )
            } catch {
                lock.release()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
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

private final class WorkbookPublicationLockAcquisitionCounter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

private final class IncrementingDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var nextDate: Date
    private let increment: TimeInterval

    init(start: Date, increment: TimeInterval) {
        self.nextDate = start
        self.increment = increment
    }

    func now() -> Date {
        lock.withLock {
            defer { nextDate = nextDate.addingTimeInterval(increment) }
            return nextDate
        }
    }
}
