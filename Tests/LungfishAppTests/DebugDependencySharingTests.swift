// DebugDependencySharingTests.swift - Compatibility and explicit-storage boundaries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishWorkflow

@MainActor
final class DebugDependencySharingTests: XCTestCase {
    private var directory: URL!
    private var localManifestURL: URL!
    private var previewApplicationURL: URL!
    private var previewManifestURL: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent(".lungfish")
        localManifestURL = directory.appendingPathComponent("local.json")
        previewApplicationURL = directory.appendingPathComponent("Preview.app")
        previewManifestURL = previewApplicationURL.appendingPathComponent("Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/ManagedTools/third-party-tools-lock.json")
        try FileManager.default.createDirectory(at: previewManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": LungfishAppIdentity.preview.bundleIdentifier, "CFBundleName": LungfishAppIdentity.preview.shortName, "CFBundleDisplayName": LungfishAppIdentity.preview.fullName, "LungfishReleaseChannel": "preview", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: previewApplicationURL.appendingPathComponent("Contents/Info.plist"))
        try writeManifest(to: localManifestURL, version: "2026.9.10")
        try writeManifest(to: previewManifestURL, version: "2026.9.9")
        try writeReceipt()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func writeManifest(to url: URL, version: String, additions: [String: Any] = [:]) throws {
        var object: [String: Any] = ["packID": "lungfish-tools", "displayName": "Third-Party Tools", "version": version, "dependencySet": "set", "dependencySetDate": "2026-08-18", "tools": [["id": "mafft", "environment": "mafft", "packageSpec": "bioconda::mafft=7.526", "executables": ["mafft"]]], "managedData": []]
        object.merge(additions) { _, replacement in replacement }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func writeReceipt(hash: String? = nil, synthesized: Bool = false, at destination: URL? = nil) throws {
        let manifest = try JSONDecoder().decode(ManagedToolLock.self, from: Data(contentsOf: previewManifestURL))
        var receipt = DependencyReceipt.empty()
        receipt.appVersion = manifest.version
        receipt.manifestHash = hash ?? manifest.manifestHash
        receipt.synthesized = synthesized
        _ = try DependencyReceiptStore(storageRoot: destination ?? root).save(receipt)
    }

    private func evaluate(identity: LungfishAppIdentity = .debug, environment: [String: String] = [:], debugPreference: String? = nil, previewPreference: String? = nil) -> DebugDependencySharing.Status {
        DebugDependencySharing.evaluate(identity: identity, environment: environment, homeDirectory: directory, debugLegacyStoragePath: debugPreference, previewLegacyStoragePath: previewPreference, localManifestURL: localManifestURL, previewApplicationURL: previewApplicationURL)
    }

    func testMetadataOnlyVersionDifferenceSharesExistingPreviewRoot() {
        let status = evaluate()
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.sharedRootPath, root.path)
        XCTAssertNotEqual(status.localManifestHash, status.previewManifestHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".config/lungfish-debug/storage-location.json").path))
    }

    func testUnknownDependencyFieldsCannotDisappearThroughTypedDecoding() throws {
        try writeManifest(to: localManifestURL, version: "2026.9.10", additions: ["futureDependencyPolicy": ["requiredRevision": "new"]])
        XCTAssertEqual(evaluate().reason, "dependency-manifests-differ")
        XCTAssertFalse(evaluate().enabled)
    }

    func testToolAndRetirementChangesDisableSharing() throws {
        try writeManifest(to: localManifestURL, version: "2026.9.10", additions: ["retiredEnvironments": ["mafft"]])
        XCTAssertEqual(evaluate().reason, "dependency-manifests-differ")
        try writeManifest(to: localManifestURL, version: "2026.9.10", additions: ["tools": []])
        XCTAssertFalse(evaluate().enabled)
    }

    func testInvalidManifestsFailValidationEvenWhenBothRawFilesMatch() throws {
        try Data("{\"tools\":[]}".utf8).write(to: localManifestURL)
        try Data("{\"tools\":[]}".utf8).write(to: previewManifestURL)
        XCTAssertEqual(evaluate().reason, "invalid-manifest")
    }

    func testReceiptMustBeNonsynthesizedAndMatchEitherFullManifest() throws {
        try writeReceipt(hash: "unrelated")
        XCTAssertEqual(evaluate().reason, "receipt-does-not-match")
        try writeReceipt(synthesized: true)
        XCTAssertEqual(evaluate().reason, "receipt-does-not-match")
        let local = try JSONDecoder().decode(ManagedToolLock.self, from: Data(contentsOf: localManifestURL))
        try writeReceipt(hash: local.manifestHash)
        XCTAssertTrue(evaluate().enabled)
        try FileManager.default.removeItem(at: root.appendingPathComponent("dependency-receipt.json"))
        XCTAssertEqual(evaluate().reason, "receipt-does-not-match")
    }

    func testExplicitDebugStorageAlwaysWinsIncludingMalformedBootstrap() throws {
        XCTAssertEqual(evaluate(environment: ["LUNGFISH_STORAGE_ROOT": "/explicit"]).reason, "explicit-storage")
        XCTAssertEqual(evaluate(environment: ["LUNGFISH_CONDA_ROOT": "/explicit"]).reason, "explicit-storage")
        XCTAssertEqual(evaluate(debugPreference: "/explicit").reason, "explicit-storage")
        let config = directory.appendingPathComponent(".config/lungfish-debug/storage-location.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("malformed".utf8).write(to: config)
        XCTAssertEqual(evaluate().reason, "explicit-storage")
    }

    func testPreviewBootstrapTakesPrecedenceOverLegacyPreferences() throws {
        let configured = directory.appendingPathComponent("preview-storage")
        try writeReceipt(at: configured)
        let config = directory.appendingPathComponent(".config/lungfish/storage-location.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ManagedStorageBootstrapConfig(activeRootPath: configured.path)).write(to: config)
        XCTAssertEqual(evaluate(previewPreference: "/ignored").sharedRootPath, configured.path)
        try Data("malformed".utf8).write(to: config)
        XCTAssertEqual(evaluate().reason, "invalid-preview-storage")
    }

    func testPreviewLegacyPreferenceIsUsedBeforeDefaultRoot() throws {
        let legacy = directory.appendingPathComponent("legacy-preview")
        try writeReceipt(at: legacy)
        XCTAssertEqual(evaluate(previewPreference: legacy.path).sharedRootPath, legacy.path)
        XCTAssertFalse(evaluate(previewPreference: directory.appendingPathComponent("missing").path).enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing").path))
    }

    func testSharingIsLimitedToUpstreamDebugIdentity() throws {
        XCTAssertEqual(evaluate(identity: .preview).reason, "not-upstream-debug")
        XCTAssertEqual(evaluate(identity: .stable).reason, "not-upstream-debug")
        let fork = try LungfishAppIdentity.from(infoDictionary: ["CFBundleDisplayName": "Fork Debug", "CFBundleName": "Fork", "CFBundleIdentifier": "org.example.fork.debug", "LungfishReleaseChannel": "debug", "LungfishIdentitySchemaVersion": 1, "LungfishRuntimeNamespace": "org.example.fork"])
        XCTAssertEqual(evaluate(identity: fork).reason, "not-upstream-debug")
    }

    func testAllFourPresentationMetadataKeysAreExcluded() throws {
        try writeManifest(to: localManifestURL, version: "future", additions: ["displayName": "Updated Title", "dependencySet": "future-label", "dependencySetDate": "2099-01-01"])
        XCTAssertTrue(evaluate().enabled)
    }
    func testDiagnosticSerializesTheActualBootstrapPaths() throws {
        var status = evaluate()
        status.effectiveStorageRootPath = root.path
        status.effectiveCondaRootPath = root.appendingPathComponent("conda").path
        status.effectiveDatabaseRootPath = root.appendingPathComponent("databases").path
        let output = try XCTUnwrap(DebugDependencySharing.diagnosticOutput(arguments: ["Lungfish", "--debug-dependency-sharing-status"], status: status))
        let decoded = try JSONDecoder().decode(DebugDependencySharing.Status.self, from: Data(output.utf8))
        XCTAssertEqual(decoded, status)
        XCTAssertNil(DebugDependencySharing.diagnosticOutput(arguments: ["Lungfish"], status: status))
    }

    func testOlderReceiptRemainsValidAfterBothAppsUpgradeWithoutChangingPins() throws {
        // The fixture receipt was installed by 2026.9.9. Neither current app
        // still has that complete manifest hash after its version-only update.
        try writeManifest(to: localManifestURL, version: "2026.9.11", additions: ["displayName": "Debug Tools"])
        try writeManifest(to: previewManifestURL, version: "2026.9.11")
        XCTAssertTrue(evaluate().enabled)
        XCTAssertEqual(evaluate().sharedRootPath, root.path)
    }

    func testOlderReceiptDoesNotAuthorizeChangedPinsDespiteSameDependencySet() throws {
        try writeManifest(to: localManifestURL, version: "2026.9.11", additions: ["tools": []])
        try writeManifest(to: previewManifestURL, version: "2026.9.11", additions: ["tools": []])
        XCTAssertEqual(evaluate().reason, "receipt-does-not-match")
    }

    func testReceiptVersionReconstructionRejectsMissingOrInvalidVersions() throws {
        try writeManifest(to: localManifestURL, version: "2026.9.11")
        try writeManifest(to: previewManifestURL, version: "2026.9.11")
        let store = DependencyReceiptStore(storageRoot: root)
        for version: String? in [nil, "", "   ", "2026.9.9\n", "not-a-version"] {
            var receipt = try XCTUnwrap(store.load())
            receipt.appVersion = version
            _ = try store.save(receipt)
            XCTAssertFalse(evaluate().enabled, "Invalid receipt version must not authorize sharing: \(String(describing: version))")
        }
    }

    func testInstalledPreviewWinsOverCompetingWorkspaceBuildCandidate() throws {
        let applications = directory.appendingPathComponent("Applications")
        let installed = applications.appendingPathComponent("Lungfish Preview.app")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: previewApplicationURL, to: installed)
        let selected = DebugDependencySharing.preferredPreviewApplication(homeDirectory: directory, applicationsDirectory: applications, workspaceCandidate: previewApplicationURL)
        XCTAssertEqual(selected?.path, installed.path)
    }

    func testLaunchDecisionIsDurableAndContainsOnlyExplicitDiagnosticFields() throws {
        var status = evaluate()
        status.appBundlePath = "/Applications/Lungfish Debug.app"
        status.appVersion = "2026.9.11"
        status.previewApplicationPath = previewApplicationURL.path
        let url = try XCTUnwrap(DebugDependencySharing.writeDecision(status, identity: .debug, homeDirectory: directory))
        XCTAssertEqual(url.path, directory.appendingPathComponent("Library/Logs/Lungfish Debug/debug-dependency-sharing.json").path)
        let persisted = try JSONDecoder().decode(DebugDependencySharing.Status.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted, status)
        XCTAssertNil(try DebugDependencySharing.writeDecision(status, identity: .preview, homeDirectory: directory))
    }

    func testPlanProbeLoadsSettingsBeforeReadingGUIRootsAndPlansWithoutApplying() async {
        var loaded = false
        var plannedRoot: URL?
        let plan = ReconciliationPlan(installEnvironments: [], reinstallEnvironments: [], removeEnvironments: [], databaseUpdates: [], pipelinePrefetch: [], bootstrapUpdate: nil, targetDependencySet: "test", estimatedDownloadBytes: 0)
        let result = await DebugDependencySharing.probePlan(
            bootstrapStatus: evaluate(),
            loadSettings: { loaded = true },
            storageRoot: { XCTAssertTrue(loaded); return self.root },
            condaRoot: { self.root.appendingPathComponent("conda") },
            readPlan: { plannedRoot = $0; return plan }
        )
        XCTAssertEqual(plannedRoot, root)
        XCTAssertEqual(result.plan, plan)
        XCTAssertEqual(result.condaRootPath, root.appendingPathComponent("conda").path)
        XCTAssertNil(result.error)
    }

}
