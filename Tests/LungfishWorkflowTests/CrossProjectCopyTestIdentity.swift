// CrossProjectCopyTestIdentity.swift - The identity the cross-project copier's stage tests pass
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 (DEL-REST, review N1 item 1 of lane 12.18). The same neutral identity as the one in
// `Tests/LungfishAppTests/CrossProjectCopyTestIdentity.swift`, since each test target is its own module. The
// copier takes no default identity once `.appLegacy` goes, and these tests check the stage, the cancel gates and
// the digests of a copy, not which command a record names.

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
