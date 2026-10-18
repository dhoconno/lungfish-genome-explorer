// ViewerExportInvocation.swift - The one builder of a viewer export leaf's argv
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A viewer export leaf's invocation, which writes the argv the runner runs, the Operations row records and the leaf
/// records (Phase 2.12, ARCH ruling G2-3, ARCH 2).
///
/// The begin helper builds it from the view and passes ``arguments()`` to `CLIViewerExportRunner` and to
/// `OperationCenter.buildCLICommand(subcommand:args:)`. The leaf rebuilds it from its parsed groups and records
/// ``canonicalArgv()``. So row and record name one command.
public struct ViewerExportInvocation: Sendable, Equatable {
    /// The leaf's path under the root, such as `["esviritu", "export", "detections"]`.
    public var commandPath: [String]
    /// The absolute path of the input the leaf reads, such as the result folder.
    public var input: String
    /// Flags only this leaf takes, spelled by its family's builder.
    public var leafArguments: [String]
    public var state: ViewerTableExportState
    public var tab: String?
    public var outputFormat: String?
    /// The absolute path of a selection file (ARCH ruling 1.3).
    public var selection: String?
    /// The absolute path of the output file.
    public var output: String
    public var force: Bool
    /// True when the leaf prints events, which adds `--format json`.
    public var emitsEvents: Bool

    public init(
        commandPath: [String],
        input: String,
        leafArguments: [String] = [],
        state: ViewerTableExportState = ViewerTableExportState(),
        tab: String? = nil,
        outputFormat: String? = nil,
        selection: String? = nil,
        output: String,
        force: Bool = false,
        emitsEvents: Bool = true
    ) {
        self.commandPath = commandPath
        self.input = input
        self.leafArguments = leafArguments
        self.state = state
        self.tab = tab
        self.outputFormat = outputFormat
        self.selection = selection
        self.output = output
        self.force = force
        self.emitsEvents = emitsEvents
    }

    /// The argv without the executable, in one fixed order. The command path, the input, the leaf's own arguments,
    /// the state's options, `--tab`, `--output-format`, `--selection`, `--output`, `--force` when set and
    /// `--format json` when the leaf prints events.
    public func arguments() -> [String] {
        var arguments = commandPath + [input] + leafArguments + state.cliArguments()
        if let tab {
            arguments += [ViewerExportOption.tab.flag, tab]
        }
        if let outputFormat {
            arguments += [ViewerExportOption.outputFormat.flag, outputFormat]
        }
        if let selection {
            arguments += [ViewerExportOption.selection.flag, selection]
        }
        arguments += [ViewerExportOption.output.flag, output]
        if force {
            arguments.append(ViewerExportOption.force.flag)
        }
        if emitsEvents {
            arguments += ["--format", "json"]
        }
        return arguments
    }

    /// The argv the leaf records, which starts with ``CLICommandIdentity/executableName``.
    public func canonicalArgv() -> [String] {
        [CLICommandIdentity.executableName] + arguments()
    }
}
