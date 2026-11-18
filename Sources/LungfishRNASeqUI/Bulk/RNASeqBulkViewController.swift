// RNASeqBulkViewController.swift - The view of a bulk RNA-seq result (stub for the views of 5.4 wave 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// Where the count table and the quality view of a bulk result go. RS-BULK-VIEW-M2 owns this file after RS-UI-KIND.
/// Until then it holds the loaded result and shows nothing of its own.
@MainActor
public final class RNASeqBulkViewController: NSViewController {
    public static let accessibilityID = "rnaseq-bulk-view"

    public private(set) var result: RNASeqResult?
    public private(set) var bundleURL: URL?

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier(Self.accessibilityID)
        view = root
    }

    public func configure(result: RNASeqResult, bundleURL: URL) {
        self.result = result
        self.bundleURL = bundleURL
    }
}
