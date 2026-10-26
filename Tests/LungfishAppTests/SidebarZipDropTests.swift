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

        drop([zip.archive])
        await waitUntil(budget: budget) { !log.entries.isEmpty }
        await waitUntil(budget: budget) { self.extractionFolders().isEmpty }
        XCTAssertEqual(presenter.messages, [], "an import that works shows no refusal")

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

    // MARK: - OBS-W9

    /// A ZIP whose bundle holds a link to a file outside the archive is refused and the person is told so, in a
    /// sheet that names the archive. The drop showed no words before the fix and left an empty `.tmp` folder in
    /// the project, though it followed no link and imported nothing.
    func testRefusedZipDropPresentsFailureNamingArchive() async throws {
        let zip = try makeReadBundleZip(name: "SRR12486983-abslink", reads: 3, absoluteLinkTo: "/etc/hosts")
        let before = try projectListing()
        let log = DropLog(observing: controller)

        drop([zip.archive])
        await waitUntil(budget: budget) { !log.entries.isEmpty }

        XCTAssertEqual(log.entries.map(\.success), [false], "the drop ends once, as a failure: \(log.entries)")
        XCTAssertEqual(presenter.messages, [
            RecordingZipFailurePresenter.Message(
                title: "Could not import SRR12486983-abslink.zip",
                text: "It holds a link to a file outside the archive, so Lungfish did not import it."
            ),
        ])
        XCTAssertEqual(try projectListing(), before, "the drop leaves the project as it was, with no bundle and no .tmp folder")
        XCTAssertTrue(fm.fileExists(atPath: zip.archive.path), "the user's ZIP stays where it was")
    }

    /// Two refused archives in one drop share one sheet, which names each archive with its reason.
    func testTwoRefusedArchivesShareOneSheetThatNamesEach() async throws {
        let linked = try makeReadBundleZip(name: "Linked", reads: 1, absoluteLinkTo: "/etc/hosts")
        let plain = try makePlainZip(name: "Plain")
        let before = try projectListing()
        let log = DropLog(observing: controller)

        drop([linked.archive, plain])
        await waitUntil(budget: budget) { log.entries.count >= 2 }

        XCTAssertEqual(presenter.messages.count, 1, "one sheet for the drop: \(presenter.messages)")
        let message = try XCTUnwrap(presenter.messages.first)
        XCTAssertEqual(message.title, "Could not import 2 items")
        XCTAssertTrue(message.text.contains("Linked.zip"), message.text)
        XCTAssertTrue(message.text.contains("Plain.zip"), message.text)
        XCTAssertTrue(
            message.text.contains("It holds a link to a file outside the archive, so Lungfish did not import it."),
            message.text
        )
        XCTAssertTrue(message.text.contains("Lungfish bundle"), "the ZIP with no bundle says so: \(message.text)")
        XCTAssertEqual(try projectListing(), before)
    }

    /// The error the resolver throws, here a project folder that takes no new entry, shows the same sheet.
    func testZipDropThatCannotMakeItsWorkingFolderPresentsOneSheetNamingTheArchive() async throws {
        try XCTSkipIf(getuid() == 0, "root writes into a folder that has no write permission")
        let zip = try makeReadBundleZip(name: "SRR12486983", reads: 3)
        let before = try projectListing()
        let log = DropLog(observing: controller)
        // The sidebar can still read the folder, but the drop cannot make its .tmp folder in it.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path) }

        drop([zip.archive])
        await waitUntil(budget: budget) { !log.entries.isEmpty }

        XCTAssertEqual(log.entries.map(\.success), [false], "the drop ends once, as a failure: \(log.entries)")
        XCTAssertEqual(presenter.messages.count, 1, "one sheet for the drop: \(presenter.messages)")
        XCTAssertEqual(presenter.messages.first?.title, "Could not import SRR12486983.zip")
        XCTAssertTrue(presenter.messages.first?.text.contains("working folder") == true, "\(presenter.messages)")
        XCTAssertEqual(try projectListing(), before)
    }

    // MARK: - The drop

    /// The sheets the drop presents, which the live presenter would put on a window.
    private let presenter = RecordingZipFailurePresenter()

    /// Posts the drop of `archives` on the sidebar of the open project with no destination item, with the copy run
    /// in this process and the refusal sheet recorded.
    private func drop(_ archives: [URL]) {
        CrossProjectCopyRoute.LaunchSeam.$launch.withValue(Self.copyInProcess) {
            LGEZipImportFailureSeam.$presenter.withValue(presenter) {
                controller.handleSidebarFileDropped(Notification(
                    name: .sidebarFileDropped,
                    object: controller.sidebarController,
                    userInfo: [
                        "urls": archives,
                        "requestID": UUID().uuidString,
                        NotificationUserInfoKey.windowStateScope: controller.windowStateScope,
                    ]
                ))
            }
        }
    }

    /// Every path under the project, relative to it and sorted, so a folder the drop made and left shows. The
    /// sidebar writes its search index into a project when it opens one, at a time the drop does not choose, so the
    /// index files stay out of the listing.
    private func projectListing() throws -> [String] {
        try fm.subpathsOfDirectory(atPath: project.path)
            .filter { !$0.hasPrefix(".universal-search.db") }
            .sorted()
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

    /// A ZIP of one read bundle with `reads` FASTQ records, and with a link to `absoluteLinkTo` inside the bundle
    /// when that is given. `zip -y` stores the link as a link and does not follow it.
    private func makeReadBundleZip(
        name: String, reads: Int, absoluteLinkTo: String? = nil
    ) throws -> (archive: URL, reads: Int) {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let bundle = source.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = (1...reads).map { "@read\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try fastq.write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        if let absoluteLinkTo {
            try fm.createSymbolicLink(atPath: bundle.appendingPathComponent("link").path, withDestinationPath: absoluteLinkTo)
        }
        let archive = root.appendingPathComponent("\(name).zip")
        try runZip(workingDirectory: source, archiveURL: archive, entries: [bundle.lastPathComponent])
        return (archive, reads)
    }

    /// A ZIP that holds a text file and no Lungfish bundle.
    private func makePlainZip(name: String) throws -> URL {
        let source = root.appendingPathComponent("source-\(name)", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "not a Lungfish bundle\n".write(to: source.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("\(name).zip")
        try runZip(workingDirectory: source, archiveURL: archive, entries: ["README.txt"])
        return archive
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

/// Records what the refusal of a dropped archive hands to its presenter. The drop presents on the main actor, so
/// the tests read the messages there too.
final class RecordingZipFailurePresenter: LGEZipImportFailurePresenting, @unchecked Sendable {
    struct Message: Equatable, CustomStringConvertible {
        let title: String
        let text: String

        var description: String { "[\(title)] \(text)" }
    }

    private(set) var messages: [Message] = []

    @MainActor func present(title: String, message: String, on window: NSWindow?) {
        messages.append(Message(title: title, text: message))
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
