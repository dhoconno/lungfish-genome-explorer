// SRAWindowDownloadSourceTests.swift - The window's "Download source" setting reaches every SRA download
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Owner request of 2026-10-05: the SRA search window has an advanced
/// "Download source" setting, Prefer ENA (the default) or Prefer NCBI. It is
/// stored in UserDefaults, every download the window starts reads it, and the
/// run's provenance records it with the source that served the run. The
/// mirror is scripted and the toolkit writes recorded fasterq-dump output, so
/// no test reaches the network or spawns a tool.
final class SRAWindowDownloadSourceTests: XCTestCase {

    private static let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
    private var root: URL!
    private var recorded: SRAToolkitRecordedRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-window-download-source")
        recorded = SRAToolkitRecordedRunner(testFile: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The setting

    @MainActor
    func testThePopupStoresTheChoiceWhereTheDownloadReadsIt() throws {
        let suite = "sra-window-download-source-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = SRADownloadSourcePicker.storage(in: defaults)
        XCTAssertEqual(storage.wrappedValue, .ena, "Prefer ENA is the default")
        storage.wrappedValue = .ncbi
        XCTAssertEqual(SRADownloadSourcePreference.stored(in: defaults), .ncbi)
        XCTAssertEqual(SRADownloadSourcePicker.storage(in: defaults).wrappedValue, .ncbi, "the choice persists")
    }

    /// VoiceOver read "Download source, Download source" in the orchestrator's
    /// GUI walk. The popup carries the label once, and the visible caption
    /// above it is not a second element saying the same thing.
    @MainActor
    func testVoiceOverReadsThePopupLabelOnce() throws {
        let suite = "sra-window-download-source-ax-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        NSApplication.shared.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let host = NSHostingView(rootView: SRADownloadSourcePicker(store: defaults))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        func all(_ element: NSObject) -> [NSObject] {
            let modern = ((element as AnyObject).accessibilityChildren?() ?? nil) ?? []
            let children = modern.isEmpty
                ? ((element.accessibilityAttributeValue(.children) as? [Any]) ?? [])
                : modern
            return [element] + children.compactMap { $0 as? NSObject }.flatMap(all)
        }
        func identifier(_ element: NSObject) -> String? { (element as AnyObject).accessibilityIdentifier?() ?? nil }
        func labels(_ element: NSObject) -> [String] {
            [((element as AnyObject).accessibilityLabel?() ?? nil),
             element.accessibilityAttributeValue(.description) as? String,
             element.accessibilityAttributeValue(.title) as? String].compactMap { $0 }.filter { !$0.isEmpty }
        }

        let deadline = Date().addingTimeInterval(5)
        var popup: NSObject?
        while popup == nil, Date() < deadline {
            popup = all(window).first { identifier($0) == SRADownloadSourcePicker.accessibilityIdentifier }
            if popup == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        let element = try XCTUnwrap(popup, "the popup must be in the AX tree")
        let popupLabels = labels(element)
        XCTAssertFalse(popupLabels.isEmpty, "the popup must be labelled")
        for label in popupLabels {
            XCTAssertEqual(label, SRADownloadSourcePicker.title, "the label is read once, got \(popupLabels)")
        }
        let echoes = all(window).filter { $0 !== element && labels($0).contains(SRADownloadSourcePicker.title) }
        XCTAssertTrue(echoes.isEmpty, "no other element repeats the popup's label, got \(echoes.map(labels))")
    }

    func testThePopupNamesItsChoicesAndTheTradeOff() {
        XCTAssertEqual(SRADownloadSourcePreference.allCases.map(\.menuTitle), ["Prefer ENA", "Prefer NCBI"])
        XCTAssertEqual(SRADownloadSourcePicker.title, "Download source")
        XCTAssertTrue(SRADownloadSourcePreference.tradeOff.contains("ENA serves ready FASTQ files"))
        XCTAssertTrue(SRADownloadSourcePreference.tradeOff.contains("faster when ENA is slow"))
    }

    // MARK: - The download

    func testPreferENAKeepsTheMirrorFirst() async throws {
        let toolkitCalls = Counter()
        let staged = try await stage(preference: .ena, mirror: .serves, toolkit: .recorded, toolkitCalls: toolkitCalls)
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .ena)
        XCTAssertEqual(staged.download.preference, .ena)
        XCTAssertEqual(toolkitCalls.value, 0)
    }

    func testPreferNCBIFetchesWithTheToolkitAndNeverTouchesTheMirror() async throws {
        let toolkitCalls = Counter()
        let staged = try await stage(preference: .ncbi, mirror: .failsTest, toolkit: .recorded, toolkitCalls: toolkitCalls)
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .sraToolkit)
        XCTAssertEqual(staged.download.preference, .ncbi)
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["\(Self.run)_1.fastq", "\(Self.run)_2.fastq", "\(Self.run).fastq"])
        XCTAssertEqual(toolkitCalls.value, 1)
    }

    func testPreferNCBIFallsBackToTheMirrorWhenTheToolkitFailsAndLogsWhy() async throws {
        let toolkitCalls = Counter()
        let lines = Lines()
        let staged = try await stage(
            preference: .ncbi, mirror: .serves, toolkit: .failsAfterWritingAMate, toolkitCalls: toolkitCalls, lines: lines
        )
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .enaAfterFailedToolkit)
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staged.folder.path).sorted(),
            ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"],
            "nothing the toolkit wrote is left beside ENA's files"
        )
        XCTAssertTrue(lines.values.contains { $0.contains("SRA Toolkit failed") && $0.contains("ENA") }, "\(lines.values)")
    }

    func testPreferNCBIFallsBackToTheMirrorWhenTheToolkitIsMissing() async throws {
        let staged = try await stage(preference: .ncbi, mirror: .serves, toolkit: .missing, toolkitCalls: Counter())
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .enaAfterMissingToolkit)
    }

    func testPreferNCBIFailsWithBothReasonsWhenTheMirrorFailsToo() async throws {
        do {
            let staged = try await stage(preference: .ncbi, mirror: .answersHTML, toolkit: .missing, toolkitCalls: Counter())
            staged.removeFolder()
            XCTFail("both sources failed, so the run must fail")
        } catch let error as SRAError {
            XCTAssertTrue(error.localizedDescription.contains("Toolkit"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("batch/\(Self.run)").path))
    }

    func testTheProvenanceRecordsThePreferenceAndTheSourceUsed() async throws {
        let staged = try await stage(preference: .ncbi, mirror: .serves, toolkit: .missing, toolkitCalls: Counter())
        defer { staged.removeFolder() }
        let bundle = root.appendingPathComponent("\(Self.run).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: fastq)
        let arguments = ["import", "fastq"] + staged.reads.files.map(\.path)

        try writeGUISRAFASTQImportProvenance(
            accession: Self.run,
            readRecord: nil,
            downloadSource: staged.download.source.rawValue,
            preferredSource: staged.download.preference,
            enaDownloadSteps: staged.download.enaSteps,
            toolkitDownloadTraces: [],
            cliArguments: arguments,
            cliStartedAt: Date(timeIntervalSince1970: 0),
            cliCompletedAt: Date(timeIntervalSince1970: 1),
            stagedFASTQFiles: staged.reads.files,
            finalFASTQURL: fastq,
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast",
            // Never `swift build --show-bin-path`, which waits on the build
            // lock `swift test` holds.
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") }
        )

        let run = try XCTUnwrap(ProvenanceRecorder.load(from: bundle))
        XCTAssertEqual(run.steps.last?.command.first, "/injected/lungfish-cli", "the import step names the injected CLI")
        XCTAssertEqual(run.parameters["preferredSource"], .string("ncbi"))
        XCTAssertEqual(run.parameters["downloadSource"], .string("ENA (SRA Toolkit not installed)"))
        XCTAssertEqual(run.parameters["condaEnvironment"], .string("none"))
    }

    // MARK: - The window's download path

    /// The window's own download path reads the setting from the defaults
    /// it was given, so Prefer NCBI reaches the run's download.
    func testTheWindowDownloadPathReadsTheStoredSetting() async throws {
        let suite = "sra-window-download-path-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SRADownloadSourcePreference.ncbi.store(in: defaults)
        let viewModel = await MainActor.run {
            DatabaseBrowserViewModel(source: .ena, sraDownloadSuiteName: suite)
        }

        let statuses = Statuses()
        let runner = recorded.runner
        let staged = try await viewModel.stageSRARun(
            accession: Self.run,
            ncbiRun: nil,
            in: root.appendingPathComponent("batch", isDirectory: true),
            lookUpRoute: { .enaMirror(try Self.pairedRecord()) },
            mirrorFile: { _, _, _, _ in
                XCTFail("Prefer NCBI with a working toolkit fetches nothing from ENA's mirror")
                return Self.gzipStream
            },
            toolkit: { status, folder in
                statuses.append(status)
                return try await SRAService(toolkitRunner: runner).downloadFASTQ(accession: Self.run, outputDir: folder)
            },
            log: { _ in }
        )
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.preference, .ncbi)
        XCTAssertEqual(staged.download.source, .sraToolkit)
        XCTAssertEqual(statuses.values.map(\.level), [.info], "the chosen route is logged as information, not a warning")
    }

    /// Review nit: the popup writes the same defaults the window's downloads
    /// read, so a view model built with a suite never reads another store.
    @MainActor
    func testThePopupAndTheDownloadShareTheWindowsDefaults() throws {
        let suite = "sra-window-shared-defaults-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let viewModel = DatabaseBrowserViewModel(source: .ena, sraDownloadSuiteName: suite)
        XCTAssertEqual(viewModel.sraDownloadPreference(), .ena)
        let storage = SRADownloadSourcePicker.storage(in: viewModel.sraDownloadDefaults)
        storage.wrappedValue = .ncbi
        XCTAssertEqual(viewModel.sraDownloadPreference(), .ncbi)
        XCTAssertEqual(SRADownloadSourcePreference.stored(in: try XCTUnwrap(UserDefaults(suiteName: suite))), .ncbi)
    }

    /// ENA can be slow, so under Prefer NCBI the toolkit starts while ENA's
    /// lookup is still running, and the bundle still gets ENA's record.
    func testPreferNCBIStartsTheToolkitBeforeASlowENALookupAnswers() async throws {
        let events = Lines()
        let runner = recorded.runner
        let toolkitStarted = Flag()
        let staged = try await SRAWindowRunDownload.stage(
            accession: Self.run,
            preference: .ncbi,
            in: root.appendingPathComponent("batch", isDirectory: true),
            lookUpRoute: {
                // Answers only once the toolkit has started, with a ceiling,
                // so a regression fails here instead of hanging the suite.
                guard await waitUntil(timeout: .seconds(30), { toolkitStarted.isSet }) else {
                    throw CeilingExceeded()
                }
                events.append("lookup answered")
                return .enaMirror(try Self.pairedRecord())
            },
            enaRecordWait: .seconds(30),
            mirrorFile: { _, _, _ in Self.gzipStream },
            toolkit: { _, folder in
                events.append("toolkit started")
                toolkitStarted.set()
                return try await SRAService(toolkitRunner: runner).downloadFASTQ(accession: Self.run, outputDir: folder)
            }
        )
        defer { staged.removeFolder() }
        XCTAssertEqual(events.values, ["toolkit started", "lookup answered"])
        XCTAssertEqual(staged.download.source, .sraToolkit)
        XCTAssertEqual(staged.download.enaRecord?.instrumentPlatform, "ILLUMINA", "ENA's record reaches the bundle's metadata")
        XCTAssertNotNil(staged.reads.r2, "the run imports as pairs")
    }

    /// Orchestrator ruling on lane S2: when ENA's record is missing and NCBI
    /// lists the run as paired but only mate 1 arrived, the run still imports
    /// as single-end reads, as before, and the row and the provenance name
    /// the mismatch. Whether to refuse such runs is sub-phase 2.1's call.
    func testALoneMateOneOfARunNCBIListsAsPairedImportsAsSingleEndWithAWarning() async throws {
        let lines = Lines()
        let ncbiRun = try JSONDecoder().decode(SRARunInfo.self, from: Data("""
        {"accession": "\(Self.run)", "platform": "ILLUMINA", "libraryLayout": "PAIRED"}
        """.utf8))
        let staged = try await SRAWindowRunDownload.stage(
            accession: Self.run,
            preference: .ncbi,
            ncbiRun: ncbiRun,
            in: root.appendingPathComponent("batch", isDirectory: true),
            lookUpRoute: { throw URLError(.cannotFindHost) },
            mirrorFile: { _, _, _ in Self.gzipStream },
            toolkit: { _, folder in
                let mate1 = folder.appendingPathComponent("\(Self.run)_1.fastq")
                try Data("@r1\nAC\n+\nII\n".utf8).write(to: mate1)
                return [mate1]
            },
            log: { lines.append($0) }
        )
        defer { staged.removeFolder() }
        XCTAssertNil(staged.reads.r2, "the run imports as single-end reads, as before")
        let expected = "NCBI lists \(Self.run) as paired but only one read file arrived; imported as single-end reads"
        XCTAssertEqual(staged.layoutWarning, expected)
        XCTAssertTrue(lines.values.contains(expected), "\(lines.values)")

        let bundle = root.appendingPathComponent("\(Self.run).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: fastq)
        try writeGUISRAFASTQImportProvenance(
            accession: Self.run,
            readRecord: nil,
            downloadSource: staged.download.source.rawValue,
            preferredSource: staged.download.preference,
            layoutWarning: staged.layoutWarning,
            enaDownloadSteps: [],
            toolkitDownloadTraces: [],
            cliArguments: ["import", "fastq"],
            cliStartedAt: Date(timeIntervalSince1970: 0),
            cliCompletedAt: Date(timeIntervalSince1970: 1),
            stagedFASTQFiles: staged.reads.files,
            finalFASTQURL: fastq,
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast",
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") }
        )
        let run = try XCTUnwrap(ProvenanceRecorder.load(from: bundle))
        XCTAssertEqual(run.parameters["layoutWarning"], .string(expected))
    }

    /// When ENA never answers, the import waits a bounded time, then NCBI's
    /// record from the search gives the run's metadata, and the
    /// row says so.
    func testPreferNCBIFallsBackToNCBIsRecordWhenENANeverAnswers() async throws {
        let lines = Lines()
        let runner = recorded.runner
        let ncbiRun = try JSONDecoder().decode(SRARunInfo.self, from: Data("""
        {"accession": "\(Self.run)", "platform": "ILLUMINA", "libraryLayout": "PAIRED"}
        """.utf8))
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        let staged = try await withinCeiling {
            try await SRAWindowRunDownload.stage(
                accession: Self.run,
                preference: .ncbi,
                ncbiRun: ncbiRun,
                in: batch,
                lookUpRoute: {
                    try await Task.sleep(for: .seconds(600))
                    return .enaMirror(try Self.pairedRecord())
                },
                enaRecordWait: .milliseconds(200),
                mirrorFile: { _, _, _ in Self.gzipStream },
                toolkit: { _, folder in
                    try await SRAService(toolkitRunner: runner).downloadFASTQ(accession: Self.run, outputDir: folder)
                },
                log: { lines.append($0) }
            )
        }
        defer { staged.removeFolder() }
        XCTAssertNil(staged.download.enaRecord)
        XCTAssertEqual(staged.ncbiRun?.platform, "ILLUMINA", "NCBI's record reaches the bundle's metadata")
        XCTAssertNotNil(staged.reads.r2, "both mates arrived, so the run imports as pairs")
        XCTAssertTrue(lines.values.contains { $0.contains("NCBI's record gives the run's metadata") }, "\(lines.values)")
    }

    /// When the toolkit fails, the download waits for ENA's lookup and the
    /// mirror serves the run.
    func testPreferNCBIWaitsForTheLookupWhenTheToolkitFails() async throws {
        let staged = try await SRAWindowRunDownload.stage(
            accession: Self.run,
            preference: .ncbi,
            in: root.appendingPathComponent("batch", isDirectory: true),
            lookUpRoute: {
                try await Task.sleep(for: .milliseconds(100))
                return .enaMirror(try Self.pairedRecord())
            },
            mirrorFile: { _, _, _ in Self.gzipStream },
            toolkit: { _, _ in throw SRAError.toolkitNotFound }
        )
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .enaAfterMissingToolkit)
        XCTAssertNotNil(staged.download.enaRecord)
    }

    // MARK: - Cancellation (review finding S3-2)

    /// A cancel while the toolkit has failed and the download waits on ENA's
    /// lookup reaches the lookup, so the run stops at once with no import.
    func testACancelWhileWaitingOnTheLookupAfterAToolkitFailureEndsPromptly() async throws {
        let lookupStarted = Flag()
        let toolkitFailed = Flag()
        let lookupCancelled = Flag()
        let outcome = try await cancelStage(once: { lookupStarted.isSet && toolkitFailed.isSet }, lookUpRoute: {
            lookupStarted.set()
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                lookupCancelled.set()
                throw error
            }
            return .enaMirror(try Self.pairedRecord())
        }, toolkit: { _, _ in
            toolkitFailed.set()
            throw SRAError.toolkitNotFound
        })
        XCTAssertTrue(outcome.cancelled, "the run stops with a cancellation, got \(outcome.result)")
        XCTAssertTrue(lookupCancelled.isSet, "the cancel reaches ENA's lookup")
    }

    /// A cancel during the wait for ENA's record after the toolkit finished
    /// stops the run. It must not read as "ENA did not answer" and import.
    func testACancelDuringTheWaitForENAsRecordEndsPromptlyWithNoImport() async throws {
        let runner = recorded.runner
        let toolkitDone = Flag()
        let lines = Lines()
        let outcome = try await cancelStage(once: { toolkitDone.isSet }, lookUpRoute: {
            try await Task.sleep(for: .seconds(600))
            return .enaMirror(try Self.pairedRecord())
        }, toolkit: { _, folder in
            let files = try await SRAService(toolkitRunner: runner).downloadFASTQ(accession: Self.run, outputDir: folder)
            toolkitDone.set()
            return files
        }, lines: lines)
        XCTAssertTrue(outcome.cancelled, "the run stops with a cancellation, got \(outcome.result)")
        XCTAssertFalse(lines.values.contains { $0.contains("missing") }, "a cancel is not ENA failing to answer: \(lines.values)")
    }

    /// A cancelled toolkit stops the run and cancels ENA's lookup.
    func testACancelledToolkitEndsPromptlyAndCancelsTheLookup() async throws {
        let lookupCancelled = Flag()
        let toolkitStarted = Flag()
        let outcome = try await cancelStage(once: { toolkitStarted.isSet }, lookUpRoute: {
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                lookupCancelled.set()
                throw error
            }
            return .enaMirror(try Self.pairedRecord())
        }, toolkit: { _, _ in
            toolkitStarted.set()
            try await Task.sleep(for: .seconds(600))
            return []
        })
        XCTAssertTrue(outcome.cancelled, "the run stops with a cancellation, got \(outcome.result)")
        let reached = await waitUntil(timeout: .seconds(10), { lookupCancelled.isSet })
        XCTAssertTrue(reached, "the cancel reaches ENA's lookup")
    }

    /// Review nit: the window names both failures when the toolkit fails and
    /// ENA cannot serve the run, with ENA's own one-line reason, and the row
    /// says the toolkit failed before the download waits on ENA.
    func testPreferNCBIFailsWithBothReasonsWhenENAListsNoFiles() async throws {
        let lines = Lines()
        do {
            let staged = try await SRAWindowRunDownload.stage(
                accession: Self.run,
                preference: .ncbi,
                in: root.appendingPathComponent("batch", isDirectory: true),
                lookUpRoute: { .sraToolkit(enaRecord: nil, reason: "ENA lists no FASTQ files for \(Self.run)") },
                mirrorFile: { _, _, _ in
                    XCTFail("ENA lists no files, so the mirror is not asked")
                    return Self.gzipStream
                },
                toolkit: { _, _ in throw SRAError.toolkitNotFound },
                log: { lines.append($0) }
            )
            staged.removeFolder()
            XCTFail("both sources failed, so the run must fail")
        } catch let error as SRAError {
            guard case .downloadFailed(let message) = error else {
                return XCTFail("expected downloadFailed, got \(error)")
            }
            XCTAssertTrue(message.hasPrefix("Toolkit: "), message)
            XCTAssertTrue(message.hasSuffix("ENA: ENA lists no FASTQ files for \(Self.run)"), message)
        }
        XCTAssertTrue(lines.values.contains { $0.contains("not installed") }, "\(lines.values)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("batch/\(Self.run)").path))
    }

    /// Review nit: a mirror transfer that fails after a toolkit failure names
    /// ENA's own one-line reason, as Core does.
    func testPreferNCBIBothFailedUsesENAsOwnReason() async throws {
        do {
            let staged = try await SRAWindowRunDownload.stage(
                accession: Self.run,
                preference: .ncbi,
                in: root.appendingPathComponent("batch", isDirectory: true),
                lookUpRoute: { .enaMirror(try Self.pairedRecord()) },
                mirrorFile: { _, _, _ in
                    throw ENAFASTQDownloadFailure(fallbackSource: .sraToolkitAfterFailedTransfer, message: "mirror said 503")
                },
                toolkit: { _, _ in throw SRAError.toolkitNotFound }
            )
            staged.removeFolder()
            XCTFail("both sources failed, so the run must fail")
        } catch let error as SRAError {
            guard case .downloadFailed(let message) = error else {
                return XCTFail("expected downloadFailed, got \(error)")
            }
            XCTAssertTrue(message.hasSuffix("ENA: mirror said 503"), message)
        }
    }

    private struct CancelOutcome {
        let result: String
        let cancelled: Bool
    }

    /// Stages the run under Prefer NCBI in a task, cancels it once `once`
    /// holds, and reports how it ended. Each wait has a ceiling, so a
    /// regression fails instead of hanging.
    private func cancelStage(
        once: @escaping @Sendable () -> Bool,
        lookUpRoute: @escaping @Sendable () async throws -> SRAFASTQDownloadRoute,
        toolkit: @escaping @Sendable (SRAWindowToolkitStatus, URL) async throws -> [URL],
        lines: Lines = Lines()
    ) async throws -> CancelOutcome {
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        let finished = Flag()
        let task = Task { () -> String in
            defer { finished.set() }
            do {
                let staged = try await SRAWindowRunDownload.stage(
                    accession: Self.run, preference: .ncbi, in: batch,
                    lookUpRoute: lookUpRoute, enaRecordWait: .seconds(600),
                    mirrorFile: { _, _, _ in Self.gzipStream },
                    toolkit: toolkit, log: { lines.append($0) }
                )
                staged.removeFolder()
                return "staged"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "failed: \(error)"
            }
        }
        let reached = await waitUntil(timeout: .seconds(30), { once() })
        task.cancel()
        XCTAssertTrue(reached, "the run reached the point to cancel at")
        let ended = await waitUntil(timeout: .seconds(10), { finished.isSet })
        XCTAssertTrue(ended, "the run ends promptly after a cancel")
        guard ended else { return CancelOutcome(result: "still running", cancelled: false) }
        let result = await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent(Self.run).path), "no staged files are left")
        return CancelOutcome(result: result, cancelled: result == "cancelled")
    }

    /// Runs `body`, failing with `CeilingExceeded` after `ceiling`.
    private func withinCeiling<T: Sendable>(
        _ ceiling: Duration = .seconds(30),
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: ceiling)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw CeilingExceeded()
            }
            return value
        }
    }

    private static func pairedRecord() throws -> ENAReadRecord {
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/094/\(run)"
        let size = gzipStream.count
        let json = """
        {"run_accession": "\(run)", "library_layout": "PAIRED", "instrument_platform": "ILLUMINA",
         "fastq_ftp": "\(folder)/\(run)_1.fastq.gz;\(folder)/\(run)_2.fastq.gz",
         "fastq_bytes": "\(size);\(size)"}
        """
        return try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
    }

    // MARK: - Helpers

    private enum Mirror {
        case serves
        case answersHTML
        case failsTest
    }

    private enum Toolkit {
        case recorded
        case missing
        case failsAfterWritingAMate
    }

    /// An empty gzip stream, which passes ENA's download check.
    private static let gzipStream = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    private func stage(
        preference: SRADownloadSourcePreference,
        mirror: Mirror,
        toolkit: Toolkit,
        toolkitCalls: Counter,
        lines: Lines = Lines()
    ) async throws -> SRAWindowStagedRun {
        let run = Self.run
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/094/\(run)"
        let size = Self.gzipStream.count
        let json = """
        {"run_accession": "\(run)", "library_layout": "PAIRED",
         "fastq_ftp": "\(folder)/\(run)_1.fastq.gz;\(folder)/\(run)_2.fastq.gz",
         "fastq_bytes": "\(size);\(size)"}
        """
        let record = try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
        let emptyHome = root.appendingPathComponent("home", isDirectory: true)
        let service: SRAService
        switch toolkit {
        case .recorded:
            service = SRAService(toolkitRunner: recorded.runner)
        case .missing:
            service = SRAService(homeDirectoryProvider: { emptyHome })
        case .failsAfterWritingAMate:
            let fasterq = URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
            service = SRAService(toolkitRunner: SRAToolkitRunner(
                prefetch: URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch"), fasterqDump: fasterq
            ) { executable, arguments in
                guard executable == fasterq, let index = arguments.firstIndex(of: "-O") else {
                    return SRAToolkitRunner.Result(exitCode: 0)
                }
                try Data("@\(run).1\nAC".utf8).write(
                    to: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("\(run)_1.fastq")
                )
                return SRAToolkitRunner.Result(exitCode: 3, stderr: "disk full")
            })
        }
        return try await SRAWindowRunDownload.stage(
            accession: run,
            route: .enaMirror(record),
            preference: preference,
            in: root.appendingPathComponent("batch", isDirectory: true),
            mirrorFile: { _, _, _ in
                switch mirror {
                case .serves: return Self.gzipStream
                case .answersHTML: return Data("<html>Index of</html>".utf8)
                case .failsTest:
                    XCTFail("Prefer NCBI with a working toolkit fetches nothing from ENA's mirror")
                    return Self.gzipStream
                }
            },
            toolkit: { _, folder in
                toolkitCalls.increment()
                return try await service.downloadFASTQ(accession: run, outputDir: folder)
            },
            log: { lines.append($0) }
        )
    }
}

private struct CeilingExceeded: Error {}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

private final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SRAWindowToolkitStatus] = []
    var values: [SRAWindowToolkitStatus] { lock.withLock { stored } }
    func append(_ status: SRAWindowToolkitStatus) { lock.withLock { stored.append(status) } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
