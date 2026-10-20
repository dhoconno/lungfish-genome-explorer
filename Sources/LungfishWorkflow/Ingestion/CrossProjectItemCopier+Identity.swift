// CrossProjectItemCopier+Identity.swift - The command a cross-project copy's records name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 (BIO rulings on `caller`, F3 and F4). The copier writes
// two kinds of record. A read bundle goes through `FASTQBundleCopyImportWorkflow`,
// whose envelope names a command, and every other kind gets the receipt of
// `NativeProjectCopyImportService`. The identity says which command both name,
// the `lungfish project copy-item` run that made the copy. The earlier `.appLegacy`
// identity, which named the app's own `fastq import-ont` and `Lungfish.app
// import-native` records for the hidden key `CrossProjectCopyRoute`, went with the
// key in Phase 2.13. Records of that kind still replay
// (`CrossProjectCopyLegacyRecordReplayTests`).

import Foundation
import LungfishCore

/// The command a cross-project copy's records name. One case is left, since only a CLI run copies a project item.
package enum ProjectCopyRecordIdentity: Sendable, Equatable {
    /// A run of a CLI command, which both branches of the copier name.
    case command(ProjectCopyCommandIdentity)
}

/// One CLI run's identity, as the records of the copy it made name it.
package struct ProjectCopyCommandIdentity: Sendable, Equatable {
    /// The workflow and tool name, such as `lungfish project copy-item`.
    package let name: String
    /// The command's words, which are also its durable replay words.
    package let argv: [String]
    package let explicitOptions: [String: ParameterValue]
    package let defaultOptions: [String: ParameterValue]
    /// The resolved options, `caller` among them. The copier adds `destination`, and for a read bundle the
    /// `sourceKind` and `copyMode` of the bundle copy.
    package let resolvedOptions: [String: ParameterValue]

    package init(
        name: String,
        argv: [String],
        explicitOptions: [String: ParameterValue],
        defaultOptions: [String: ParameterValue],
        resolvedOptions: [String: ParameterValue]
    ) {
        self.name = name
        self.argv = argv
        self.explicitOptions = explicitOptions
        self.defaultOptions = defaultOptions
        self.resolvedOptions = resolvedOptions
    }

    /// The context of a read bundle's copy through `FASTQBundleCopyImportWorkflow`.
    func fastqContext(destination: URL) -> FASTQBundleCopyImportWorkflow.CommandContext {
        var resolved = resolvedOptions
        resolved["destination"] = .file(destination)
        resolved["sourceKind"] = .string("existing-fastq-bundle")
        resolved["copyMode"] = .string("atomic-bundle-copy")
        return FASTQBundleCopyImportWorkflow.CommandContext(
            workflowName: name,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: name,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            explicitOptions: explicitOptions,
            defaultOptions: defaultOptions,
            resolvedOptions: resolved,
            runtimeIdentity: ProvenanceRuntimeIdentity()
        )
    }

    /// The receipt of a native copy, to which the service adds its own resolved facts.
    var nativeReceipt: NativeCopyReceiptIdentity {
        NativeCopyReceiptIdentity(
            workflowName: name,
            toolName: name,
            argv: argv,
            durableReplayArgv: argv,
            explicitOptions: explicitOptions,
            defaultOptions: defaultOptions,
            resolvedOptions: resolvedOptions
        )
    }
}
