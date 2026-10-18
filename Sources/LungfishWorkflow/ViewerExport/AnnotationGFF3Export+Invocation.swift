// AnnotationGFF3Export+Invocation.swift - The argv of bundle export-gff3 in its bundle and selection forms
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension AnnotationGFF3Export {
    /// The leaf's invocation, which writes the argv the runner runs, the Operations row records and the leaf records
    /// (ARCH 2). `ViewerExportInvocation` always writes an input, and this leaf takes a bundle or `--selection`,
    /// exactly one (ARCH ruling on 12.39 R2 item 3), so it keeps its own type with the same order and spellings.
    public struct Invocation: Sendable, Equatable {
        /// The absolute path of the reference bundle, nil in the selection form.
        public var bundle: String?
        /// The absolute path of the selection file, nil in the bundle form.
        public var selection: String?
        /// The absolute path of the output file.
        public var output: String
        public var force: Bool
        /// True when the leaf prints events, which adds `--format json`.
        public var emitsEvents: Bool

        public init(bundle: String?, selection: String?, output: String, force: Bool, emitsEvents: Bool = true) {
            self.bundle = bundle
            self.selection = selection
            self.output = output
            self.force = force
            self.emitsEvents = emitsEvents
        }

        /// The argv without the executable. The command path, the bundle or `--selection`, `--output`, `--force`
        /// when set and `--format json` when the leaf prints events.
        public func arguments() -> [String] {
            var arguments = AnnotationGFF3Export.commandPath
            if let bundle {
                arguments.append(bundle)
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

    /// The bundle form, for a reference bundle in the sidebar, with absolute standardized paths.
    public static func invocation(bundleURL: URL, outputURL: URL, force: Bool, emitsEvents: Bool = true) -> Invocation {
        Invocation(
            bundle: bundleURL.standardizedFileURL.path,
            selection: nil,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The selection form, for an open document's annotations, with absolute standardized paths.
    public static func invocation(selectionURL: URL, outputURL: URL, force: Bool, emitsEvents: Bool = true) -> Invocation {
        Invocation(
            bundle: nil,
            selection: selectionURL.standardizedFileURL.path,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }
}
