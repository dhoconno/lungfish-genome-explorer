// main.swift - Lungfish Genome Explorer application entry point
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishApp
import Sparkle

@MainActor
private final class SparkleUpdaterBridge {
    private let updaterController: SPUStandardUpdaterController?

    init(delegate: AppDelegate) {
        guard Self.hasRequiredConfiguration else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller

        delegate.checkForUpdatesHandler = { [weak controller] sender in
            controller?.checkForUpdates(sender)
        }
        delegate.canCheckForUpdatesHandler = { [weak controller] in
            controller?.updater.canCheckForUpdates ?? false
        }
    }

    private static var hasRequiredConfiguration: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

if let helperExitCode = VCFImportHelper.runIfRequested(arguments: CommandLine.arguments) {
    exit(helperExitCode)
}
if let helperExitCode = BAMImportHelper.runIfRequested(arguments: CommandLine.arguments) {
    exit(helperExitCode)
}
if let helperExitCode = ReferenceImportHelper.runIfRequested(arguments: CommandLine.arguments) {
    exit(helperExitCode)
}
if let helperExitCode = MetagenomicsImportHelper.runIfRequested(arguments: CommandLine.arguments) {
    exit(helperExitCode)
}

// Launch AppKit on the main thread using a single event loop.
// Avoid nested/dual run-loop patterns (e.g. app.run + dispatchMain) which can
// cause delayed menu-bar activation and unstable full-screen behavior.
let app = NSApplication.shared

// Set the application icon from LungfishApp's bundled resources
app.applicationIconImage = AppIcon.image

let delegate = AppDelegate()
private let updaterBridge = SparkleUpdaterBridge(delegate: delegate)
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

_ = updaterBridge
