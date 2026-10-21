// ManagedToolLeafFixtures.swift - Stand-ins for the managed tools and packs leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishWorkflow
@testable import LungfishCLI
import LungfishTestSupport

/// Stand-ins for `tools update`, `conda install --pack` and `conda db update` (Phase 2.10 lane A52),
/// whose real runs drive micromamba and gigabyte downloads. The leaf tests and the transcript
/// captures share them, so the transcripts are runs of the same fixtures the tests check.
enum ManagedToolLeafFixtures {
    final class Lines: Sendable {
        private let state = Mutex<[String]>([])
        func append(_ line: String) { state.withLock { $0.append(line) } }
        var all: [String] { state.withLock { $0 } }
        var events: [CLIEvent] {
            let decoder = CLIEventLineDecoder()
            return all.compactMap { try? decoder.decodeLine($0)?.event }
        }
    }

    /// Becomes true once a stand-in is at work, so a test sends SIGTERM while the leaf listens.
    final class AtWork: Sendable {
        private let state = Mutex(false)
        func mark() { state.withLock { $0 = true } }
        var isSet: Bool { state.withLock { $0 } }
    }

    /// A pack service that records what it was asked and either finishes, fails or waits for a cancel.
    actor PackService: PluginPackStatusProviding {
        enum Behaviour: Sendable { case succeed, fail, stall, failAfterOneFinished, failAfterFinishing(String) }
        private let behaviour: Behaviour
        private let atWork: AtWork
        private(set) var requests: [(packID: String, reinstall: Bool)] = []

        init(_ behaviour: Behaviour, atWork: AtWork = AtWork()) {
            self.behaviour = behaviour
            self.atWork = atWork
        }

        func visibleStatuses() async -> [PluginPackStatus] { [] }
        func status(for pack: PluginPack) async -> PluginPackStatus {
            PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: [], failureMessage: nil)
        }
        func invalidateVisibleStatusesCache() async {}

        func install(
            pack: PluginPack,
            reinstall: Bool,
            progress: (@Sendable (PluginPackInstallProgress) -> Void)?
        ) async throws {
            requests.append((pack.id, reinstall))
            progress?(PluginPackInstallProgress(
                requirementID: "first-tool", requirementDisplayName: "First tool",
                overallFraction: 0.25, itemFraction: 0.5, message: "Creating first-tool"
            ))
            atWork.mark()
            switch behaviour {
            case .succeed:
                progress?(PluginPackInstallProgress(
                    requirementID: "second-tool", requirementDisplayName: "Second tool",
                    overallFraction: 0.75, itemFraction: 1, message: "Creating second-tool"
                ))
            case .fail:
                throw PluginPackStatusServiceError.verificationFailed(requirementID: "second-tool", reason: "second-tool does not run")
            case .failAfterOneFinished:
                // A requirement reached its end, and then the run failed on another one.
                progress?(PluginPackInstallProgress(
                    requirementID: "done-tool", requirementDisplayName: "Done tool",
                    overallFraction: 0.5, itemFraction: 1, message: "Created done-tool"
                ))
                throw PluginPackStatusServiceError.verificationFailed(requirementID: "second-tool", reason: "second-tool does not run")
            case .failAfterFinishing(let requirementID):
                // The named requirement reached its end, and then the run failed on another one.
                progress?(PluginPackInstallProgress(
                    requirementID: requirementID, requirementDisplayName: requirementID,
                    overallFraction: 0.5, itemFraction: 1, message: "Finished \(requirementID)"
                ))
                throw PluginPackStatusServiceError.verificationFailed(requirementID: "second-tool", reason: "second-tool does not run")
            case .stall:
                try await Task.sleep(for: .seconds(60))
            }
        }
    }

    static func pack() throws -> PluginPack {
        try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
    }

    // MARK: tools update

    static func manifest() -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: [.init(
                id: "samtools", environment: "samtools",
                packageSpec: "bioconda::samtools=1.24=h36b3a25_1",
                executables: ["samtools"], version: "1.24"
            )],
            managedData: [], dependencySet: "2026.2",
            pipelines: [], databases: [],
            bootstrap: BootstrapSpec(micromamba: .init(version: "2.9.0-0", sha256: nil))
        )
    }

    /// Services that create nothing. The environment creation either returns, fails or waits for a cancel.
    static func services(behaviour: PackService.Behaviour, atWork: AtWork = AtWork()) -> ReconcilerServices {
        var services = ReconcilerServices.live(condaManager: .shared, storageRoot: FileManager.default.temporaryDirectory)
        services.installBootstrap = { _ in }
        services.createEnvironment = { _, _, report in
            report(0.5, "Solving samtools")
            atWork.mark()
            switch behaviour {
            case .succeed: report(1, "samtools created")
            case .fail, .failAfterOneFinished, .failAfterFinishing:
                throw NSError(domain: "stand-in", code: 1, userInfo: [NSLocalizedDescriptionKey: "samtools does not solve"])
            case .stall: try await Task.sleep(for: .seconds(60))
            }
        }
        services.removeEnvironment = { _ in }
        services.smokeTest = { _ in }
        services.installRegistryDatabase = { _, _ in URL(fileURLWithPath: "/x") }
        services.updateMetagenomicsDatabase = { _, _ in }
        services.prefetchPipeline = { _, _ in }
        services.listEnvironments = { [:] }
        services.installedPackIDs = { [] }
        services.registryDatabaseVersions = { [:] }
        services.metagenomicsDatabaseVersions = { [:] }
        services.installedMicromambaVersion = { "2.9.0" }
        return services
    }

    // MARK: conda db update

    static let payloadFiles = ["hash.k2d", "opts.k2d", "taxo.k2d"]

    static func writePayload(at directory: URL, marker: String) throws {
        for name in payloadFiles {
            try marker.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    static func markers(of directory: URL) -> [String] {
        payloadFiles.map { (try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) ?? "missing" }
    }

    /// A registry under `base` holding one installed Viral database whose three files read "old", with an
    /// archive installer that stages a "new" copy, or stalls until a cancel after it signals `atWork`.
    static func registry(in base: URL, stalling: Bool, atWork: AtWork = AtWork()) async throws -> MetagenomicsDatabaseRegistry {
        let installed = base.appendingPathComponent("kraken2/viral", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()
        try writePayload(at: installed, marker: "old")
        _ = try await registry.seedRowThroughManifest(at: installed, name: "Viral")
        await registry.setArchiveInstallerForTesting { _, destination, progress in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try writePayload(at: destination, marker: "new")
            progress(0.5, "Downloading Viral")
            atWork.mark()
            if stalling { try await Task.sleep(for: .seconds(60)) }
            return nil
        }
        return registry
    }

    /// The status of the one record file in `folder` under `storageRoot`, nil when there is none.
    static func recordStatus(storageRoot: URL, folder: String) throws -> String? {
        let directory = ManagedToolLeaf.recordDirectory(storageRoot: storageRoot, folder: folder)
        let names = ManagedToolLeaf.recordNames(storageRoot: storageRoot, folder: folder).sorted()
        guard let name = names.last else { return nil }
        return try ProvenanceEnvelopeReader.load(fromSidecar: directory.appendingPathComponent(name))?.status.rawValue
    }
}
