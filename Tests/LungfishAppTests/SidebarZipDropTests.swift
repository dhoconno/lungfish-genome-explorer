// SidebarZipDropTests.swift - A ZIP dropped on the sidebar, from the drop to the project it lands in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane ZIP (OBS-W8 and OBS-W9 of the packaged walk of 2026-10-24, rows 88 and W2c). Every test drops a
// ZIP that the test builds with /usr/bin/zip on the sidebar of a window that holds a fresh project, through the
// handler of the `sidebarFileDropped` notification. The drop copies a read bundle through the route's own argv,
// which the test parses with `ProjectCopyItemSubcommand` and runs in the test process, so no `lungfish-cli` starts.

import AppKit
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class SidebarZipDropTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var controller: MainSplitViewController!
    private let fm = FileManager.default

    /// The drop extracts the ZIP with a subprocess, so 30 s leaves room for the parallel unit tier. Every wait here
    /// ends as soon as its condition holds.
    private let budget = WaitBudget.standard.raised(to: .seconds(30))

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "sidebar-zip-drop")
        project = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        controller = MainSplitViewController()
        _ = controller.view
        controller.sidebarController.openProject(at: project)
    }

    override func tearDown() async throws {
        controller.sidebarController.closeProject()
        TestTempDirectory.cleanup(root)
    }

    // MARK: - OBS-W8

    /// A bundle in a dropped ZIP is copied into the project and the batch then deletes its extraction folder. The
    /// copy went into that folder before the fix, so the row read Completed and the reads were gone.
    func testZipDropBundleSurvivesCleanup() async throws {
        let zip = try makeReadBundleZip(name: "SRR12486983", reads: 3)
        let log = DropLog(observing: controller)

        drop(zip.archive, log: log)
        await waitUntil(budget: budget) { !log.entries.isEmpty }
        await waitUntil(budget: budget) { self.extractionFolders().isEmpty }

        let landed = project.appendingPathComponent("Imports/SRR12486983.lungfishfastq", isDirectory: true)
        XCTAssertEqual(log.entries.map(\.success), [true], "the drop ends once, as a success: \(log.entries)")
        XCTAssertTrue(fm.fileExists(atPath: landed.path), "the bundle must land in Imports once the cleanup has run")
        XCTAssertEqual(
            try? fastqRecordCount(landed.appendingPathComponent("reads.fastq")), zip.reads,
            "the copy keeps every read of the archive's bundle"
        )
        XCTAssertEqual(extractionFolders(), [], "no sidebar-zip-import folder remains")
        XCTAssertTrue(fm.fileExists(atPath: zip.archive.path), "the user's ZIP stays where it was")
    }

    // MARK: - The drop

    /// Posts the drop of `archive` on the sidebar of the open project with no destination item, with the copy run
    /// in this process.
    private func drop(_ archive: URL, log: DropLog) {
        CrossProjectCopyRoute.LaunchSeam.$launch.withValue(Self.copyInProcess) {
            controller.handleSidebarFileDropped(Notification(
                name: .sidebarFileDropped,
                object: controller.sidebarController,
                userInfo: [
                    "urls": [archive],
                    "requestID": UUID().uuidString,
                    NotificationUserInfoKey.windowStateScope: controller.windowStateScope,
                ]
            ))
        }
    }

    /// The drop's copy, run as `lungfish-cli project copy-item` runs it. The command parses the route's argv and
    /// copies through `copyItem`, which is the whole body of the command after its argument checks.
    private static let copyInProcess: CrossProjectCopyRoute.Launch = { arguments, _ in
        let command = try ProjectCopyItemSubcommand.parse(Array(arguments.dropFirst(2)))
        let outcome = try command.copyItem(events: CLIEventEmitter(enabled: false, emit: { _ in }))
        return CrossProjectCopyRoute.Run(outputs: [outcome.destinationURL.path], message: nil)
    }

    private func extractionFolders() -> [String] {
        let temp = project.appendingPathComponent(".tmp", isDirectory: true)
        return ((try? fm.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("sidebar-zip-import-") }
    }

    // MARK: - Fixtures

    /// A ZIP of one read bundle with `reads` FASTQ records.
    private func makeReadBundleZip(name: String, reads: Int) throws -> (archive: URL, reads: Int) {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let bundle = source.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = (1...reads).map { "@read\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try fastq.write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("\(name).zip")
        try runZip(workingDirectory: source, archiveURL: archive, entries: [bundle.lastPathComponent])
        return (archive, reads)
    }

    private func fastqRecordCount(_ url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).count / 4
    }

    private func runZip(workingDirectory: URL, archiveURL: URL, entries: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workingDirectory
        process.arguments = ["-qry", archiveURL.path] + entries
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// The `sidebarFileDropCompleted` notifications of one window, in the order the drop posted them. The drop posts
/// on the main thread, and the lock keeps a read from the test apart from a write.
final class DropLog: @unchecked Sendable {
    struct Entry: CustomStringConvertible {
        let url: URL
        let success: Bool
        let error: String?

        var description: String { "\(url.lastPathComponent) success=\(success) error=\(error ?? "none")" }
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []
    private var token: NSObjectProtocol?

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(observing window: AnyObject) {
        token = NotificationCenter.default.addObserver(
            forName: .sidebarFileDropCompleted, object: window, queue: nil
        ) { [weak self] notification in
            let info = notification.userInfo
            let entry = Entry(
                url: info?["url"] as? URL ?? URL(fileURLWithPath: "/"),
                success: info?["success"] as? Bool ?? false,
                error: info?["error"] as? String
            )
            self?.lock.lock()
            self?.recorded.append(entry)
            self?.lock.unlock()
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
