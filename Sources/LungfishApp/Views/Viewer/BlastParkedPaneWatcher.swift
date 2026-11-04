// BlastParkedPaneWatcher.swift - Brings a parked search back to a pane that is on no row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

/// Hears the news of every search for one parked search, and moves its pane when the search moves (BIO SF2).
///
/// A viewer on a row asks the disk about that row when news comes. FASTA's pane is on no row, so without this it would keep
/// `the result comes back here` after the monitor had collected the result. It ends once the result lands, or once the
/// pane has moved on to something else, so that it never writes over a later search.
@MainActor
final class BlastParkedPaneWatcher: NSObject {
    private enum Found: Sendable {
        case record(result: BlastVerificationResult, url: URL)
        case search(BlastLiveSearch)
        case nothing
    }

    private let output: URL
    private weak var drawer: BlastResultsDrawerTab?
    private let land: @MainActor (BlastVerificationResult, URL) -> Void
    private var keptAlive: BlastParkedPaneWatcher?

    private init(output: URL, drawer: BlastResultsDrawerTab, land: @escaping @MainActor (BlastVerificationResult, URL) -> Void) {
        self.output = output
        self.drawer = drawer
        self.land = land
    }

    static func watch(output: URL, drawer: BlastResultsDrawerTab, land: @escaping @MainActor (BlastVerificationResult, URL) -> Void) {
        let watcher = BlastParkedPaneWatcher(output: output, drawer: drawer, land: land)
        watcher.keptAlive = watcher
        NotificationCenter.default.addObserver(watcher, selector: #selector(searchChanged), name: BlastSearchNews.changed, object: nil)
    }

    private var paneIsOnThisSearch: Bool {
        guard case .waiting(let state)? = drawer?.displayState else { return false }
        return state.folder.standardizedFileURL.path == output.standardizedFileURL.path
    }

    private func stop() {
        NotificationCenter.default.removeObserver(self)
        keptAlive = nil
    }

    @objc private func searchChanged() {
        guard paneIsOnThisSearch else { return stop() }
        let output = self.output
        Task { [weak self] in
            let found = await Self.read(output)
            self?.apply(found)
        }
    }

    private func apply(_ found: Found) {
        guard paneIsOnThisSearch else { return stop() }
        switch found {
        case .record(let result, let url):
            land(result, url)
            stop()
        case .search(let search):
            drawer?.showWaiting(search)
        case .nothing:
            break
        }
    }

    /// A project's folder can be slow, so this never reads on the main actor.
    @concurrent nonisolated private static func read(_ output: URL) async -> Found {
        let url = output.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        if let record = try? BlastSubmissionRecord.load(url) { return .record(result: record.result, url: url) }
        if let search = BlastLiveSearch.read(folder: output) { return .search(search) }
        return .nothing
    }
}
