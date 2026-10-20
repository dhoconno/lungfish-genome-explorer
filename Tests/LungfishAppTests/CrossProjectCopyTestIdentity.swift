// CrossProjectCopyTestIdentity.swift - The identity the cross-project copier's tests pass
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.03 (review N1 item 1 of lane 12.18). `CrossProjectItemCopier.copy` took a default
// identity, `.appLegacy`, which about 30 test calls used without naming it. The copier takes no default once
// that identity goes, so these tests pass one neutral run of `project copy-item`. They check where an item
// lands, what its copy record holds and that a cancel leaves nothing behind, not which command a record names.
// A test of what a record names builds the identity it needs.

import Foundation
import LungfishCore
@testable import LungfishWorkflow

extension ProjectCopyRecordIdentity {
    /// A plain `lungfish project copy-item` run with the caller `cli`, the shape the command gives its own copies.
    static let neutral = ProjectCopyRecordIdentity.command(ProjectCopyCommandIdentity(
        name: "lungfish project copy-item",
        argv: [CLICommandIdentity.executableName, "project", "copy-item"],
        explicitOptions: [:],
        defaultOptions: [:],
        resolvedOptions: ["caller": .string("cli")]
    ))
}
