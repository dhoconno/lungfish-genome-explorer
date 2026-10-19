// TreeSubtreeExport.swift - The subtree export the tree viewer and `tree export subtree` share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The subtree export of a `.lungfishtree` bundle (Phase 2.12 lane 12.35, ARCH ruling 1.1 row A15).
public enum TreeSubtreeExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row A15).
    public static let commandPath = ["tree", "export", "subtree"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish tree export subtree"

    /// The leaf's invocation, with absolute standardized paths, `tree export subtree <bundle> --node <id> |
    /// --label <label> --output-format <format> --output <file> [--force] [--format json]`. The begin helper passes
    /// its `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        bundleURL: URL,
        nodeID: String?,
        label: String? = nil,
        outputFormat: String = "newick",
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        var leafArguments: [String] = []
        if let nodeID {
            leafArguments += ["--node", nodeID]
        }
        if let label {
            leafArguments += ["--label", label]
        }
        return ViewerExportInvocation(
            commandPath: commandPath,
            input: bundleURL.standardizedFileURL.path,
            leafArguments: leafArguments,
            outputFormat: outputFormat,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The bundle files a subtree export reads, which are the two files `PhylogeneticTreeBundle.load` decodes. The
    /// load checks that the bundle's other files exist but reads none of them, so a record names these two with
    /// their digests and never the bundle folder (BIO-12.31-G3).
    public static func inputURLs(bundleURL: URL) -> [URL] {
        ["manifest.json", "tree/primary.normalized.json"].map {
            bundleURL.appendingPathComponent($0).standardizedFileURL
        }
    }
}
