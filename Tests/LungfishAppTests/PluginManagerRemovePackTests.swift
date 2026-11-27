// PluginManagerRemovePackTests.swift - What Remove All removes on a pack card
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Remove All removes the conda environments the pack installs into. That is the
// list the installer runs (`PluginPack.toolRequirements`, filled from the
// lock). GATK Core installs `gatk4` into `gatk-core`, Variant Phasing installs
// `whatshap` into `phasing`, and Single-Cell installs four tools into
// `sc-embed`. Every test runs on a temporary conda root and never reads or
// writes ~/.lungfish.

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor PackRemovalStatusProvider: PluginPackStatusProviding {
    func visibleStatuses() async -> [PluginPackStatus] { [] }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}

@MainActor
final class PluginManagerRemovePackTests: XCTestCase {
    func testRemoveAllRemovesTheGATKCoreEnvironment() async throws {
        try await assertRemoveAllRemoves(packID: "gatk-core", environments: ["gatk-core"])
    }

    func testRemoveAllRemovesTheVariantPhasingEnvironment() async throws {
        try await assertRemoveAllRemoves(packID: "phasing", environments: ["phasing"])
    }

    func testRemoveAllRemovesTheOneEnvironmentOfTheFourSingleCellTools() async throws {
        try await assertRemoveAllRemoves(packID: "single-cell", environments: ["sc-embed"])
    }

    /// Packs whose tools install into environments named like them keep working.
    func testRemoveAllStillRemovesTheEnvironmentsNamedLikeThePackages() async throws {
        try await assertRemoveAllRemoves(
            packID: "read-mapping",
            environments: ["minimap2", "bwa-mem2", "bowtie2"]
        )
    }

    /// Puts `environments` and one environment of another pack into a temporary
    /// conda root, clicks Remove All, and expects exactly `environments` gone.
    private func assertRemoveAllRemoves(
        packID: String,
        environments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: packID), file: file, line: line)
        let bystander = "samtools"
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("remove-all-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let condaRoot = sandbox.appendingPathComponent("conda", isDirectory: true)
        for name in environments + [bystander] {
            try FileManager.default.createDirectory(
                at: condaRoot.appendingPathComponent("envs/\(name)/conda-meta", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // removeEnvironment asks the root's micromamba for its version first.
        let bin = condaRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let micromamba = bin.appendingPathComponent("micromamba")
        try "#!/bin/sh\necho 2.0.5\n".write(to: micromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        let manager = CondaManager(
            rootPrefix: condaRoot,
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )
        let viewModel = PluginManagerViewModel(
            packStatusProvider: PackRemovalStatusProvider(),
            notificationCenter: NotificationCenter(),
            automaticallyRefresh: false,
            condaManager: manager
        )
        let installed = try await manager.listEnvironments()
        viewModel.applyInstalledEnvironments(installed)
        XCTAssertEqual(
            viewModel.installedEnvironmentNames,
            Set(environments + [bystander]),
            "The temporary conda root lists the environments the test put there",
            file: file, line: line
        )

        viewModel.removePack(pack)
        await waitUntil(file: file, line: line) { !viewModel.installingPacks.contains(pack.id) }

        for name in environments {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: condaRoot.appendingPathComponent("envs/\(name)").path),
                "Remove All on \(pack.name) left the environment \(name)",
                file: file, line: line
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: condaRoot.appendingPathComponent("envs/\(bystander)").path),
            "Remove All on \(pack.name) removed the environment of another pack",
            file: file, line: line
        )
    }
}
