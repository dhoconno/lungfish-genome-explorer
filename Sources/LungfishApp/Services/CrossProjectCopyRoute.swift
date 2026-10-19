// CrossProjectCopyRoute.swift - The sidebar's cross-project copy, run as lungfish-cli project copy-item
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The route of a project item dropped from another project onto the sidebar (Phase 2.12 lane 12.18, gap id
/// `cross-project-copy`).
///
/// The default runs `lungfish-cli project copy-item` on `CLIBundleBuildRunner` for the app's Operations row.
/// The command builds the copy in the target project's `.tmp` folder, rewrites its links there, writes its
/// records and publishes it with one rename, and the app writes nothing after it exits. The row records the
/// command. Cancel goes through the transport, so the command gets SIGTERM and the runner's grace to stop
/// before it publishes, and the row ends Cancelled.
///
/// Side A against side C of `CrossProjectCopyParityReplayTests` declares the command and the `caller` the
/// records name (BIO rulings on `caller`, answer 2, and on F4, section 2), so the in-process copy stays behind
/// the hidden key `CrossProjectCopyRoute` for one release (decision C4 of 2.10, R-A1 and U-R1 of 2.12). Phase
/// 2.13 (lane 13.03) deletes the key with the `legacy` code.
enum CrossProjectCopyRoute: String, Sendable, Equatable, CaseIterable {
    /// `CrossProjectItemCopier.copy` in this process, the route before Phase 2.12. Its row records no command,
    /// and its records name `fastq import-ont` or `Lungfish.app import-native`.
    case legacy
    /// `lungfish-cli project copy-item` on `CLIBundleBuildRunner`, the default.
    case cli

    /// What a run of the command gives back to the row, the item it published and its `complete` message.
    struct Run: Sendable {
        let outputs: [String]
        let message: String?
    }

    /// Runs `arguments`, the argv after `lungfish-cli`, for the row `operationID`.
    typealias Launch = @MainActor (_ arguments: [String], _ operationID: UUID) async throws -> Run

    /// Where a copy landed, with its record of the source items the target project lacks.
    struct Landed: Sendable {
        let destinationURL: URL
        let record: ProjectItemCopyRecord?
    }

    struct RouteError: LocalizedError {
        var errorDescription: String? { "The copy command did not name the copied item." }
    }

    /// The argv after `lungfish-cli` that copies `itemURL` into `projectURL`, in the words the command records.
    /// An item inside a project is named by its path inside that project with `--source-project`, and a folder
    /// the person dropped onto by its path inside `projectURL`. A Finder item in no project keeps its absolute
    /// path, and so does a folder outside `projectURL`, which the command refuses.
    static func arguments(itemURL: URL, projectURL: URL, requestedFolder: URL?) -> [String] {
        let item = itemURL.standardizedFileURL
        let target = projectURL.standardizedFileURL
        var arguments = ["project", "copy-item"]
        if let holder = ProjectTempDirectory.findProjectRoot(item.deletingLastPathComponent())?.standardizedFileURL,
           let relative = ProjectItemLinkRewriter.descendantPath(of: item, in: holder) {
            arguments += [relative, "--source-project", holder.path]
        } else {
            arguments.append(item.path)
        }
        arguments += ["--project", target.path]
        if let requestedFolder {
            let folder = requestedFolder.standardizedFileURL
            let relative = folder.path == target.path
                ? "."
                : ProjectItemLinkRewriter.descendantPath(of: folder, in: target)
            arguments += ["--folder", relative ?? folder.path]
        }
        return arguments + ["--format", "json"]
    }

    /// The command the row records for the copy.
    static func command(itemURL: URL, projectURL: URL, requestedFolder: URL?) -> String {
        let arguments = Self.arguments(itemURL: itemURL, projectURL: projectURL, requestedFolder: requestedFolder)
        return OperationCenter.buildCLICommand(subcommand: "project copy-item", args: Array(arguments.dropFirst(2)))
    }

    /// The command on `CLIBundleBuildRunner`, whose Cancel goes through the transport.
    static let launchCommand: Launch = { arguments, operationID in
        let result = try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: operationID)
        return Run(outputs: result.outputs, message: result.message)
    }

    /// Copies the item with the command for the row `operationID` and returns where it landed, throwing
    /// `CancellationError` once a cancel is acknowledged on the row. The command logs each source item the
    /// project lacks on the row, and the record is read, never written, after it exits.
    @MainActor
    static func copy(
        itemURL: URL,
        projectURL: URL,
        requestedFolder: URL?,
        operationID: UUID,
        launch: Launch = CrossProjectCopyRoute.launchCommand
    ) async throws -> Landed {
        let arguments = Self.arguments(itemURL: itemURL, projectURL: projectURL, requestedFolder: requestedFolder)
        let run = try await launch(arguments, operationID)
        guard let path = run.outputs.first else { throw RouteError() }
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        // project-copy.json lists every source file of the item, so it is read off the main actor.
        let record = await Task.detached(priority: .userInitiated) { ProjectItemCopyRecord.load(from: destination) }.value
        return Landed(destinationURL: destination, record: record)
    }

    /// The `legacy` route, the copier in this process off the main actor, as the sidebar ran it before 2.12.
    static func copyInProcess(itemURL: URL, projectURL: URL, requestedFolder: URL?) async throws -> Landed {
        let outcome = try await Task.detached(priority: .userInitiated) {
            try CrossProjectItemCopier.copy(itemAt: itemURL, intoProject: projectURL, requestedFolder: requestedFolder)
        }.value
        return Landed(destinationURL: outcome.destinationURL, record: outcome.record)
    }
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never touches the
/// user's defaults.
struct CrossProjectCopyRouteSettings {
    /// The hidden key, a new name under U-R1. It holds `cli` or `legacy`, or a Boolean that is true for the CLI
    /// route, for example `defaults write com.lungfish.browser.preview CrossProjectCopyRoute legacy`.
    static let defaultsKey = "CrossProjectCopyRoute"
    /// The route of a key that is unset or holds a value this reader does not know.
    static let defaultRoute: CrossProjectCopyRoute = .cli

    let defaults: UserDefaults

    var route: CrossProjectCopyRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return CrossProjectCopyRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }

    /// The route a project item dropped from another project takes now, read from the app's defaults.
    static var currentRoute: CrossProjectCopyRoute {
        CrossProjectCopyRouteSettings(defaults: .standard).route
    }
}
