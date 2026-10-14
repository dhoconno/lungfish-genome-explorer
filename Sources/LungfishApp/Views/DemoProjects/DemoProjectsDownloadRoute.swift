// DemoProjectsDownloadRoute.swift - The Demo Projects window's download, in process or one lungfish-cli demo fetch child
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow
import os

/// The route the Demo Projects window's download takes (Phase 2.10 lane A45 M4, panel decision C4).
enum DemoProjectsDownloadRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane A45, kept for one release as the escape the hidden key names (C4). The window
    /// downloads, verifies, unpacks and installs in the app process with `DemoProjectInstaller`, and its
    /// Cancel cancels that task. It goes in 2.11 with the key.
    case legacy
    /// One `lungfish-cli demo fetch <id> --dest <folder> [--force] --format json` child, which downloads,
    /// verifies, unpacks and installs in its own process. The window shows its `progress` lines as the bar,
    /// opens the project its `complete` line names, and cancels it with SIGTERM.
    case cli
}

/// Reads the route of the window's download from the defaults it is given, so a test passes its own suite
/// and never touches the user's defaults.
struct DemoProjectsDownloadRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route, for example
    /// `defaults write <app id> DemoProjectsDownloadRoute legacy`.
    static let defaultsKey = "DemoProjectsDownloadRoute"
    /// The route of a key that is unset or holds a value this reader does not know.
    static let defaultRoute: DemoProjectsDownloadRoute = .legacy

    let defaults: UserDefaults

    var route: DemoProjectsDownloadRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return DemoProjectsDownloadRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }
}

/// Reads a `progress` line of `demo fetch` back into the phase the window shows. The command writes the
/// download as the share of the bytes received from 0 to ``downloadShare`` of the bar and each later phase
/// at a number of its own (`DemoFetchReporter`), so a line names its phase by where it sits, and the bytes
/// received follow from the archive's size in the project list.
enum DemoProjectCLIProgress {
    /// These four numbers are the command's (`DemoFetchReporter`), and `DemoProjectsDownloadRouteTests`
    /// keeps the two copies equal.
    static let downloadShare = 0.9
    static let verifyingFraction = 0.91
    static let extractingFraction = 0.93
    static let installingFraction = 0.98

    static func phase(forFraction fraction: Double, totalBytes: Int64) -> DemoProjectInstallPhase {
        if fraction >= installingFraction { return .installing }
        if fraction >= extractingFraction { return .extracting }
        if fraction >= verifyingFraction { return .verifying }
        let share = min(1, max(0, fraction / downloadShare))
        return .downloading(bytesReceived: Int64((share * Double(totalBytes)).rounded()), totalBytes: totalBytes)
    }
}

/// A flag the window sets when its Cancel is pressed, which the transport reads to tell a cancel from a failure.
final class DemoDownloadCancelFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// One project through `lungfish-cli demo fetch <id> --dest <folder> [--force] --format json`, the command the
/// row records without the format (Phase 2.10 lane A45 M4). The child downloads the archive, checks its size
/// and SHA-256, unpacks it into a hidden staging folder and moves the project into place in its own process,
/// and the old copy of a replace goes to the Trash once the new one has verified. SIGTERM and the launcher's
/// grace stop it, so it removes its staging folder and exits 125.
struct DemoProjectCLIFetch: Sendable {
    let projectID: String
    let directory: URL
    let replaceExisting: Bool
    /// The archive's size in the project list, which the bar's fraction is read against.
    let totalBytes: Int64
    /// The CLI to launch, nil for the app's own.
    var cliURLOverride: URL?

    /// The arguments of the child. The row's command without `lungfish-cli`, with `--format json`.
    var arguments: [String] {
        var arguments = ["demo", "fetch", projectID, "--dest", directory.path]
        if replaceExisting { arguments.append("--force") }
        return arguments + ["--format", "json"]
    }

    func makeTransport() -> CLISubprocessTransport {
        CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Runs the child and returns the project folder its `complete` line names.
    ///
    /// - Parameters:
    ///   - isCancelled: True once the window's Cancel was pressed.
    ///   - onPhase: Called for each `progress` line, as the phase the window shows.
    ///   - onLog: Called for each `log` line, such as the notice of a replaced copy.
    func run(
        transport: CLISubprocessTransport,
        isCancelled: @escaping @Sendable () -> Bool,
        onPhase: @escaping @Sendable (DemoProjectInstallPhase) -> Void,
        onLog: @escaping @Sendable (CLIEvent) -> Void
    ) async throws -> URL {
        let totalBytes = totalBytes
        let result = try await transport.run(
            arguments: arguments,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain,
            isCancelled: { isCancelled() },
            onEvent: { event in
                switch event {
                case let .progress(fraction, _):
                    onPhase(DemoProjectCLIProgress.phase(forFraction: fraction, totalBytes: totalBytes))
                case .log:
                    onLog(event)
                case .start, .output, .complete, .failed:
                    break
                }
            }
        )
        guard let path = result.outputs.first, !path.isEmpty else {
            throw CLISubprocessTransport.RunError.missingCompletion
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
