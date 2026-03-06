// main.swift - Lungfish Genome Explorer application entry point
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishApp

if let helperExitCode = VCFImportHelper.runIfRequested(arguments: CommandLine.arguments) {
    exit(helperExitCode)
}

// Launch AppKit on the main thread using a single event loop.
// Avoid nested/dual run-loop patterns (e.g. app.run + dispatchMain) which can
// cause delayed menu-bar activation and unstable full-screen behavior.
let app = NSApplication.shared

// Set the application icon (SPM doesn't process Info.plist CFBundleIconFile)
if let icnsURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
   let icon = NSImage(contentsOf: icnsURL) {
    app.applicationIconImage = icon
}

let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
