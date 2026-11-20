// PluginPack+SingleCell.swift - The single-cell pack's four packages
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation

extension PluginPack {
    /// The tools of `lungfish-cli rnaseq cell-map compute` (5.5 C9). Scanpy, python-igraph, leidenalg and umap-learn
    /// share the one `sc-embed` environment. The installer runs one requirement after another and a reinstall deletes
    /// the environment first, so the lock gives each of the four an `explicitLocks` row that names the one bundled lock.
    /// The smoke tests read each distribution's metadata and start no scientific code.
    static var singleCellPack: PluginPack {
        PluginPack(
            id: "single-cell",
            name: "Single-Cell Analysis",
            description: "Computes a two-dimensional cell map and clusters from single-cell RNA-seq results",
            sfSymbol: "circle.grid.3x3",
            packages: ["scanpy", "python-igraph", "leidenalg", "umap-learn"],
            category: "Single Cell",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "single-cell",
                    id: "scanpy",
                    displayName: "Scanpy",
                    executables: ["python"],
                    smokeTest: .command(
                        executable: "python",
                        arguments: ["-c", "from importlib.metadata import version;print(version('scanpy'))"],
                        timeoutSeconds: 30,
                        acceptedExitCodes: [0],
                        requiredOutputSubstring: ManagedToolLock.bundled.packTool(packID: "single-cell", id: "scanpy")?.version ?? ""
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "single-cell",
                    id: "python-igraph",
                    displayName: "python-igraph",
                    executables: ["python"],
                    smokeTest: .command(
                        executable: "python",
                        arguments: ["-c", "from importlib.metadata import version;print(version('igraph'))"],
                        timeoutSeconds: 30,
                        acceptedExitCodes: [0],
                        requiredOutputSubstring: ManagedToolLock.bundled.packTool(packID: "single-cell", id: "python-igraph")?.version ?? ""
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "single-cell",
                    id: "leidenalg",
                    displayName: "leidenalg",
                    executables: ["python"],
                    smokeTest: .command(
                        executable: "python",
                        arguments: ["-c", "from importlib.metadata import version;print(version('leidenalg'))"],
                        timeoutSeconds: 30,
                        acceptedExitCodes: [0],
                        requiredOutputSubstring: ManagedToolLock.bundled.packTool(packID: "single-cell", id: "leidenalg")?.version ?? ""
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "single-cell",
                    id: "umap-learn",
                    displayName: "umap-learn",
                    executables: ["python"],
                    smokeTest: .command(
                        executable: "python",
                        arguments: ["-c", "from importlib.metadata import version;print(version('umap-learn'))"],
                        timeoutSeconds: 30,
                        acceptedExitCodes: [0],
                        requiredOutputSubstring: ManagedToolLock.bundled.packTool(packID: "single-cell", id: "umap-learn")?.version ?? ""
                    )
                ),
            ],
            estimatedSizeMB: 800
        )
    }
}
