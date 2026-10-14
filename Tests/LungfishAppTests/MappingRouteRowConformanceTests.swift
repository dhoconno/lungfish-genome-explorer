// MappingRouteRowConformanceTests.swift - What the Map Reads row shows on the mapping golden's fixture
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M2, ruling 1 of the M1 review (UX 3). The row of today's in-process Map Reads
// route is frozen here, each bar and detail it shows in order, each line it logs and its end, on
// the mapping golden's fixture with its plain FASTA and once more with that FASTA in a `.lungfishref`
// bundle, so that the reference viewer's words appear. M3's parity class plays the transcripts of
// `lungfish-cli map --format json` through the bridge and holds the CLI route's row to these files.
// The scratch folder of a run reads `/work`. Set LUNGFISH_RECAPTURE_MAPPING_ROW=1 to write the files
// instead of comparing, and review the diff.
//
// The real tools run, so the name holds Conformance and the class never runs in the unit tier:
//
//     LUNGFISH_STORAGE_ROOT=/Users/Shared/lungfish-golden/storage LUNGFISH_REQUIRE_TOOLS=1 \
//         swift test --skip-update --filter MappingRouteRowConformanceTests

import Combine
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class MappingRouteRowConformanceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "mapping-route-row")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheInProcessRowOnThePlainFASTA() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let fixture = try MappingRouteGolden.Fixture(in: scratch)
        let row = try await MappingRouteRow.recordInProcess(fixture.windowRequest())
        try MappingRouteRow.assertFrozen(row, name: "plain-fasta", scratch: scratch)
    }

    func testTheInProcessRowOnALungfishrefShowsTheViewersWords() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let fixture = try MappingRouteGolden.Fixture(in: scratch)
        let bundle = try MappingRouteRow.referenceBundle(from: fixture.reference, in: fixture.project)
        let request = fixture.windowRequest(referenceFASTA: bundle.appendingPathComponent("genome/sequence.fa"))
        let row = try await MappingRouteRow.recordInProcess(request)
        XCTAssertTrue(row.shown.contains("Validating alignment file..."), row.text)
        try MappingRouteRow.assertFrozen(row, name: "lungfishref", scratch: scratch)
    }

    /// Fix 2 of the whole-lane review of lane A46. With a `.lungfishref` the CLI route's `map` publishes
    /// the reference viewer, so its row shows the viewer's steps, and the file the in-process route froze
    /// holds them too. The details, the lines logged and the end are the frozen ones. The CLI row's bar
    /// is held (decision W2), so both bars read through `heldBar` and the viewer's step back to 0.9300
    /// and climb to 1.0000 after the first 1.0000 are left to the in-process row. The route finds its CLI through
    /// LUNGFISH_CLI_PATH, which names the built one here, since the lookup through SwiftPM waits on the
    /// lock that the running `swift test` holds.
    func testTheCLIRowOnALungfishrefShowsTheInProcessWords() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so the CLI route cannot run"
        )
        let saved = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        defer {
            if let saved { setenv("LUNGFISH_CLI_PATH", saved, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        let fixture = try MappingRouteGolden.Fixture(in: scratch)
        let bundle = try MappingRouteRow.referenceBundle(from: fixture.reference, in: fixture.project)
        let request = fixture.windowRequest(referenceFASTA: bundle.appendingPathComponent("genome/sequence.fa"))
        let row = try await MappingRouteRow.recordInProcess(request) { appDelegate, plan in
            let keys = TestDefaultsSuite(prefix: "MappingRouteRowConformanceTests")
            defer { keys.tearDown() }
            keys.defaults.set(ReadsLaunchRoute.cli.rawValue, forKey: ReadsLaunchPath.mapping.defaultsKey)
            appDelegate.runManagedMapping(plan: plan, routeSettings: ReadsLaunchRouteSettings(defaults: keys.defaults))
        }
        XCTAssertTrue(row.shown.contains("Validating alignment file..."), row.text)
        // The in-process row steps back after 1.0000, so a bar that only rises shows the CLI route ran.
        XCTAssertEqual(row.bar, MappingRouteRow.heldBar(row.bar), "the CLI route holds the bar")
        try MappingRouteRow.assertFrozen(
            row, name: "lungfishref", scratch: scratch, recapturing: false, bar: MappingRouteRow.heldBar
        )
    }
}

/// The row of one Map Reads run as the Operations panel shows it. The details and the bar are kept
/// apart, since a row update sets them one after the other and a route may set them in either order.
struct MappingRouteRow: Equatable {
    /// Each detail the row showed, in order, a repeat left out.
    var shown: [String] = []
    /// Each position of the bar, in order, as a fraction with four places, a repeat left out.
    var bar: [String] = []
    /// Each line the row logged, as `<level> <message>`.
    var logged: [String] = []
    /// The row's end, as `<state> <detail>`.
    var end = ""

    /// The frozen form: four sections, one line each.
    var text: String {
        (["# shown"] + shown + ["# bar"] + bar + ["# logged"] + logged + ["# end", end])
            .joined(separator: "\n") + "\n"
    }

    /// The bar as the parity and freeze checks compare it (QA's ruling D9 on lane A46 M3). After the
    /// bar reached 1, the viewer's step back to 0.93 and up to 1 reaches the panel on one run and not
    /// the next, on either route, so a last `0.9300, 1.0000` that follows `1.0000` is dropped, and
    /// nothing else.
    static func comparableBar(_ bar: [String]) -> [String] {
        guard bar.suffix(3) == ["1.0000", "0.9300", "1.0000"] else { return bar }
        return Array(bar.dropLast(2))
    }

    /// The bar as the CLI route's row shows it (decision W2, `OperationCenterCLIBridge`). The row holds
    /// the bar and moves it only to a higher fraction, so a step below the highest one so far is left
    /// out. The viewer's step back to 0.93 and up to 1 that the in-process row froze after the bar
    /// reached 1 never reaches it, and a bar that only rises reads as itself.
    static func heldBar(_ bar: [String]) -> [String] {
        var highest = -Double.infinity
        return bar.filter { step in
            guard let value = Double(step), value > highest else { return false }
            highest = value
            return true
        }
    }

    /// `text`, a row in its frozen form, with its bar read through `read`, ``comparableBar(_:)`` unless
    /// a case names another.
    static func comparableText(_ text: String, bar read: ([String]) -> [String] = comparableBar) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "# bar"), let end = lines.firstIndex(of: "# logged"), start < end else {
            return text
        }
        lines.replaceSubrange((start + 1)..<end, with: read(Array(lines[(start + 1)..<end])))
        return lines.joined(separator: "\n")
    }

    static var frozenFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MappingRouteRow", isDirectory: true)
    }

    /// Runs `request` alone through `runManagedMapping` and records its row until it ends. The
    /// freeze holds the in-process route, which stays one release behind the Map Reads key (2.7
    /// E14), so the default `run` reads a key set to `legacy` now that the key defaults to `cli`.
    @MainActor
    static func recordInProcess(
        _ request: MappingRunRequest,
        run: (AppDelegate, MappingRunPlan) -> Void = { appDelegate, plan in
            let keys = TestDefaultsSuite(prefix: "MappingRouteRowConformanceTests")
            defer { keys.tearDown() }
            keys.defaults.set(ReadsLaunchRoute.legacy.rawValue, forKey: ReadsLaunchPath.mapping.defaultsKey)
            appDelegate.runManagedMapping(plan: plan, routeSettings: ReadsLaunchRouteSettings(defaults: keys.defaults))
        }
    ) async throws -> MappingRouteRow {
        let recorder = Recorder(title: "Map Reads (\(request.tool.displayName)): \(request.sampleName)")
        let subscription = OperationCenter.shared.$items.sink { items in recorder.take(items) }
        defer { subscription.cancel() }
        let appDelegate = AppDelegate()
        run(appDelegate, MappingRunPlan(requests: [request], mode: .perBundle, warning: nil))
        // A real mapping run, so the wait is long, and it returns once the row ends.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, recorder.ended == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        withExtendedLifetime(appDelegate) {}
        let item = try XCTUnwrap(recorder.ended, "the row never ended:\n\(recorder.row.text)")
        var row = recorder.row
        row.logged = item.logEntries.map { "\($0.level) \($0.message)" }
        row.end = "\(item.state) \(item.detail)"
        return row
    }

    /// Holds `row` to its frozen file, with `scratch` read as `/work` and both bars read through `read`.
    /// LUNGFISH_RECAPTURE_MAPPING_ROW writes the file from `row` only when `recapturing`, which a case
    /// that holds the CLI route's row to the in-process file leaves off, since the file is that route's.
    static func assertFrozen(
        _ row: MappingRouteRow, name: String, scratch: URL,
        recapturing: Bool = true, bar read: ([String]) -> [String] = comparableBar,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var text = row.text
        for root in [scratch.resolvingSymlinksInPath().path, scratch.path] {
            text = text.replacingOccurrences(of: root, with: "/work")
        }
        let url = frozenFolder.appendingPathComponent("\(name).txt")
        if recapturing, ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_MAPPING_ROW"] == "1" {
            try FileManager.default.createDirectory(at: frozenFolder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(
            comparableText(text, bar: read), comparableText(try String(contentsOf: url, encoding: .utf8), bar: read),
            "the row differs from \(name).txt", file: file, line: line
        )
    }

    /// A `.lungfishref` bundle in `project` that holds the sequence of `fasta`, one record on one line.
    static func referenceBundle(from fasta: URL, in project: URL) throws -> URL {
        let lines = try String(contentsOf: fasta, encoding: .utf8).split(separator: "\n").map(String.init)
        let name = String(lines[0].dropFirst().split(separator: " ")[0])
        let sequence = lines.dropFirst().joined()
        let made = try MappingRoutingFixture.makeReferenceBundle(
            name: "sarscov2",
            chromosomes: [.init(name: name, length: sequence.count)]
        )
        try ">\(name)\n\(sequence)\n".write(to: made.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        let folder = project.appendingPathComponent("Reference Sequences", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = folder.appendingPathComponent(made.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: made, to: bundle)
        try? FileManager.default.removeItem(at: made.deletingLastPathComponent())
        return bundle
    }

    /// Takes each state of the row whose title it is given, from the panel's published items.
    @MainActor
    final class Recorder {
        private let title: String
        private let before: Set<UUID>
        private var rowID: UUID?
        private(set) var row = MappingRouteRow()
        private(set) var ended: OperationCenter.Item?

        init(title: String) {
            self.title = title
            before = Set(OperationCenter.shared.items.map(\.id))
        }

        func take(_ items: [OperationCenter.Item]) {
            let item = items.first { candidate in
                rowID.map { candidate.id == $0 } ?? (!before.contains(candidate.id) && candidate.title == title)
            }
            guard let item, ended == nil else { return }
            rowID = item.id
            if row.shown.last != item.detail { row.shown.append(item.detail) }
            let bar = String(format: "%.4f", item.progress)
            if row.bar.last != bar { row.bar.append(bar) }
            if item.finishedAt != nil { ended = item }
        }
    }
}
