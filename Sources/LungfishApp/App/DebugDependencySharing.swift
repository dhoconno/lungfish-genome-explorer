// DebugDependencySharing.swift - Reuse compatible installed Preview dependencies at Debug launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishWorkflow

@MainActor
public enum DebugDependencySharing {
    private static var lastBootstrapStatus: Status?
    private static let markerKey = "LUNGFISH_SHARED_PREVIEW_ROOT"
    private static let legacyStorageKey = "DatabaseStorageLocation"
    private static let manifestRelativePath = "ManagedTools/third-party-tools-lock.json"

    public struct Status: Codable, Equatable, Sendable {
        public var appBundlePath: String?
        public var appVersion: String?
        public var previewApplicationPath: String?
        public var processIdentifier: Int32?
        public var recordedAt: String?
        public var enabled: Bool
        public var reason: String
        public var sharedRootPath: String?
        public var effectiveStorageRootPath: String?
        public var effectiveCondaRootPath: String?
        public var effectiveDatabaseRootPath: String?
        public var localManifestHash: String?
        public var previewManifestHash: String?
    }

    /// Runs before AppDelegate or managed-tool services are initialized. This
    /// selects only a process-local default; explicit Debug settings remain authoritative.
    public static func bootstrap() -> Status {
        let identity = LungfishAppIdentity.current
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Revalidate inherited sharing hints against this executable's resources.
        // A stale hint must not survive a failed compatibility check.
        unsetenv(markerKey)
        let previewApplication = identity.isDebug && !identity.isFork
            ? preferredPreviewApplication(
                homeDirectory: home,
                applicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true),
                workspaceCandidate: NSWorkspace.shared.urlForApplication(withBundleIdentifier: LungfishAppIdentity.preview.bundleIdentifier)
            )
            : nil
        var status = evaluate(
            identity: identity,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: home,
            debugLegacyStoragePath: defaults.persistentDomain(forName: LungfishAppIdentity.debug.bundleIdentifier)?[legacyStorageKey] as? String,
            previewLegacyStoragePath: defaults.persistentDomain(forName: LungfishAppIdentity.preview.bundleIdentifier)?[legacyStorageKey] as? String,
            localManifestURL: RuntimeResourceLocator.path(manifestRelativePath, in: .workflow),
            previewApplicationURL: previewApplication
        )
        status.appBundlePath = Bundle.main.bundleURL.path
        status.appVersion = LungfishAppVersion.short
        status.previewApplicationPath = previewApplication?.path
        status.processIdentifier = ProcessInfo.processInfo.processIdentifier
        status.recordedAt = ISO8601DateFormatter().string(from: Date())
        if let root = status.sharedRootPath, status.enabled,
           setenv(markerKey, root, 1) != 0 {
            status.enabled = false
            status.reason = "environment-setup-failed"
            status.sharedRootPath = nil
        }
        let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: identity)
        let location = store.currentLocation()
        status.effectiveStorageRootPath = location.rootURL.path
        status.effectiveCondaRootPath = store.currentCondaRootURL().path
        status.effectiveDatabaseRootPath = location.databaseRootURL.path
        if identity.isDebug && !identity.isFork {
            NSLog("DebugDependencySharing: %@ (%@); storage root %@",
                  status.enabled ? "sharing Preview dependencies" : "keeping Debug storage",
                  status.reason, location.rootURL.path)
        }
        lastBootstrapStatus = status
        do { _ = try writeDecision(status, identity: identity, homeDirectory: home) }
        catch { NSLog("DebugDependencySharing: unable to record launch decision: %@", error.localizedDescription) }
        return status
    }

    /// Uses the result of the real bootstrap, rather than a simulated diagnostic path.
    public static func diagnosticOutput(arguments: [String], status: Status) -> String? {
        guard Array(arguments.dropFirst()) == ["--debug-dependency-sharing-status"] else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(status) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func preferredPreviewApplication(homeDirectory: URL, applicationsDirectory: URL, workspaceCandidate: URL?) -> URL? {
        let preferred = [
            applicationsDirectory.appendingPathComponent("Lungfish Preview.app"),
            homeDirectory.appendingPathComponent("Applications/Lungfish Preview.app"),
        ]
        return (preferred + [workspaceCandidate].compactMap { $0 }).first { candidate in
            guard let info = Bundle(url: candidate)?.infoDictionary,
                  let identity = try? LungfishAppIdentity.from(infoDictionary: info) else { return false }
            return identity.isPreview && !identity.isFork
                && identity.bundleIdentifier == LungfishAppIdentity.preview.bundleIdentifier
        }
    }

    static func writeDecision(_ status: Status, identity: LungfishAppIdentity, homeDirectory: URL) throws -> URL? {
        guard identity.isDebug, !identity.isFork else { return nil }
        let directory = homeDirectory.appendingPathComponent("Library/Logs").appendingPathComponent(identity.logDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("debug-dependency-sharing.json")
        try diagnosticEncoder().encode(status).write(to: url, options: .atomic)
        return url
    }

    struct PlanStatus: Codable, Equatable {
        let bootstrap: Status?
        let processIdentifier: Int32
        let recordedAt: String
        let storageRootPath: String
        let condaRootPath: String
        let requiredInstallCount: Int
        let requiredReinstallCount: Int
        let estimatedDownloadBytes: Int64
        let plan: ReconciliationPlan?
        let error: String?

        init(bootstrap: Status?, storageRoot: URL, condaRoot: URL, plan: ReconciliationPlan?, error: String?) {
            self.bootstrap = bootstrap
            processIdentifier = ProcessInfo.processInfo.processIdentifier
            recordedAt = ISO8601DateFormatter().string(from: Date())
            storageRootPath = storageRoot.path
            condaRootPath = condaRoot.path
            requiredInstallCount = plan?.installEnvironments.filter(\.isRequired).count ?? 0
            requiredReinstallCount = plan?.reinstallEnvironments.filter(\.isRequired).count ?? 0
            estimatedDownloadBytes = plan?.estimatedDownloadBytes ?? 0
            self.plan = plan
            self.error = error
        }
    }

    static func probePlan(
        bootstrapStatus: Status,
        loadSettings: () -> Void,
        storageRoot: () -> URL,
        condaRoot: () -> URL,
        readPlan: (URL) async throws -> ReconciliationPlan
    ) async -> PlanStatus {
        loadSettings()
        let root = storageRoot()
        let managerRoot = condaRoot()
        do {
            let plan = try await readPlan(root)
            return PlanStatus(bootstrap: bootstrapStatus, storageRoot: root, condaRoot: managerRoot, plan: plan, error: nil)
        } catch {
            return PlanStatus(bootstrap: bootstrapStatus, storageRoot: root, condaRoot: managerRoot, plan: nil, error: error.localizedDescription)
        }
    }

    public static func planDiagnosticOutput(bootstrapStatus: Status) async -> String {
        let report = await probePlan(
            bootstrapStatus: bootstrapStatus,
            loadSettings: { AppSettings.load() },
            storageRoot: { DependencyReconciliationFactory.storageRoot },
            condaRoot: { CondaManager.shared.rootPrefix },
            readPlan: { root in try await DependencyReconciliationFactory.makeReconciler(storageRoot: root).currentPlan() }
        )
        recordPlanReport(report)
        guard let data = try? diagnosticEncoder().encode(report),
              let output = String(data: data, encoding: .utf8) else { return "{\"error\":\"unable-to-encode-plan\"}" }
        return output
    }

    static func recordLaunchPlan(_ plan: ReconciliationPlan, storageRoot: URL) {
        guard LungfishAppIdentity.current.isDebug, !LungfishAppIdentity.current.isFork else { return }
        recordPlanReport(PlanStatus(
            bootstrap: lastBootstrapStatus,
            storageRoot: storageRoot,
            condaRoot: CondaManager.shared.rootPrefix,
            plan: plan,
            error: nil
        ))
    }

    private static func diagnosticEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static func recordPlanReport(_ report: PlanStatus) {
        let identity = LungfishAppIdentity.current
        guard identity.isDebug, !identity.isFork else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs").appendingPathComponent(identity.logDirectoryName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try diagnosticEncoder().encode(report).write(to: directory.appendingPathComponent("debug-dependency-plan.json"), options: .atomic)
        } catch {
            NSLog("DebugDependencySharing: unable to record dependency plan: %@", error.localizedDescription)
        }
    }

    static func evaluate(
        identity: LungfishAppIdentity,
        environment: [String: String],
        homeDirectory: URL,
        debugLegacyStoragePath: String?,
        previewLegacyStoragePath: String?,
        localManifestURL: URL?,
        previewApplicationURL: URL?
    ) -> Status {
        var status = Status(enabled: false, reason: "not-upstream-debug")
        guard identity.isDebug, !identity.isFork else { return status }

        let debugConfig = homeDirectory.appendingPathComponent(".config/lungfish-debug/storage-location.json")
        guard !hasValue(environment["LUNGFISH_STORAGE_ROOT"]),
              !hasValue(environment["LUNGFISH_CONDA_ROOT"]),
              !hasValue(debugLegacyStoragePath),
              !FileManager.default.fileExists(atPath: debugConfig.path) else {
            status.reason = "explicit-storage"
            return status
        }
        guard let localManifestURL else {
            status.reason = "missing-local-manifest"
            return status
        }
        guard let previewApplicationURL,
              let info = Bundle(url: previewApplicationURL)?.infoDictionary,
              let previewIdentity = try? LungfishAppIdentity.from(infoDictionary: info),
              previewIdentity.isPreview, !previewIdentity.isFork,
              previewIdentity.bundleIdentifier == LungfishAppIdentity.preview.bundleIdentifier,
              let previewManifestURL = previewManifest(in: previewApplicationURL) else {
            status.reason = "missing-preview-manifest"
            return status
        }

        var compatibleManifestData: [Data] = []
        do {
            let localData = try Data(contentsOf: localManifestURL)
            let previewData = try Data(contentsOf: previewManifestURL)
            // Decoding validates the known dependency schema and source identities.
            let local = try JSONDecoder().decode(ManagedToolLock.self, from: localData)
            let preview = try JSONDecoder().decode(ManagedToolLock.self, from: previewData)
            status.localManifestHash = local.manifestHash
            status.previewManifestHash = preview.manifestHash
            // Compare actual resource JSON, preserving unknown fields that a typed
            // round trip would discard. Only presentation/set-label metadata is ignored.
            guard try dependencyContent(localData) == dependencyContent(previewData) else {
                status.reason = "dependency-manifests-differ"
                return status
            }
            compatibleManifestData = [localData, previewData]
        } catch {
            status.reason = "invalid-manifest"
            return status
        }

        let previewConfig = homeDirectory.appendingPathComponent(".config/lungfish/storage-location.json")
        let root: URL
        if FileManager.default.fileExists(atPath: previewConfig.path) {
            guard let data = try? Data(contentsOf: previewConfig),
                  let config = try? JSONDecoder().decode(ManagedStorageBootstrapConfig.self, from: data),
                  hasValue(config.activeRootPath),
                  config.migrationState != .pending else {
                status.reason = "invalid-preview-storage"
                return status
            }
            root = URL(fileURLWithPath: config.activeRootPath, isDirectory: true)
        } else if let previewLegacyStoragePath, hasValue(previewLegacyStoragePath) {
            root = URL(fileURLWithPath: previewLegacyStoragePath, isDirectory: true)
        } else {
            root = homeDirectory.appendingPathComponent(".lungfish", isDirectory: true)
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              case .valid = ManagedStorageLocation.validateSelection(canonicalRoot) else {
            status.reason = "invalid-preview-storage"
            return status
        }
        guard let receipt = try? DependencyReceiptStore(storageRoot: canonicalRoot).load(),
              !receipt.synthesized,
              let receiptHash = receipt.manifestHash else {
            status.reason = "receipt-does-not-match"
            return status
        }
        let matchesCurrentManifest = receiptHash == status.localManifestHash || receiptHash == status.previewManifestHash
        let matchesInstalledVersion = compatibleManifestData.contains { data in
            receiptVersionAdjustedHash(data, version: receipt.appVersion) == receiptHash
        }
        guard matchesCurrentManifest || matchesInstalledVersion else {
            status.reason = "receipt-does-not-match"
            return status
        }
        status.enabled = true
        status.reason = "compatible-preview-dependencies"
        status.sharedRootPath = canonicalRoot.path
        return status
    }

    /// A version-only app update must not invalidate unchanged installations.
    /// Reconstruct the complete typed manifest hash with only the recorded app
    /// version replaced; every pin and all remaining metadata stay covered.
    private static func receiptVersionAdjustedHash(_ data: Data, version: String?) -> String? {
        guard let version, version.utf8.count <= 128,
              version.range(of: "^[0-9]+(?:\\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?$", options: .regularExpression) != nil,
              version == version.trimmingCharacters(in: .whitespacesAndNewlines),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        object["version"] = version
        guard let adjustedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let adjustedManifest = try? JSONDecoder().decode(ManagedToolLock.self, from: adjustedData) else { return nil }
        return adjustedManifest.manifestHash
    }

    private static func hasValue(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func dependencyContent(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        for key in ["version", "displayName", "dependencySet", "dependencySetDate"] {
            object.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func previewManifest(in appURL: URL) -> URL? {
        let appRoot = appURL.resolvingSymlinksInPath().standardizedFileURL
        let resources = appRoot.appendingPathComponent("Contents/Resources", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard resources.path.hasPrefix(appRoot.path + "/") else { return nil }
        let bundles = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        let workflowBundles = bundles.filter {
            $0.pathExtension == "bundle" && $0.lastPathComponent.contains("LungfishWorkflow")
        }.sorted { $0.path < $1.path }
        let candidates = [resources.appendingPathComponent(manifestRelativePath)] + workflowBundles.flatMap {
            [$0.appendingPathComponent(manifestRelativePath), $0.appendingPathComponent("Contents/Resources").appendingPathComponent(manifestRelativePath)]
        }
        return candidates.first { candidate in
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
            return canonical.path.hasPrefix(resources.path + "/") && FileManager.default.fileExists(atPath: canonical.path)
        }
    }
}
