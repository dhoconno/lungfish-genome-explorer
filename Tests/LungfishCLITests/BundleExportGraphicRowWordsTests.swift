// BundleExportGraphicRowWordsTests.swift - What the export-graphic leaf says while it runs (Phase 2.13 lane 13.30 fixes)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// UX review of lane 13.30, Fixes 1 and 2. A degraded fact reads as one plain sentence on standard error and in the event
// stream. A fact that leaves data out of the image is a warning and one that repeats a choice the viewer makes too is a
// note, so a routine export ends Completed and not Completed with Warnings. The record holds every fact either way. The
// helpers here also serve `BundleExportGraphicDegradedFactTests`.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class BundleExportGraphicRowWordsTests: XCTestCase {
    private var scratch: URL!
    private var folder: URL!
    private var bundle: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "BundleExportGraphicRowWords")
        // Four levels below the scratch folder, so the provenance lookup never lists the user temp folder (QA review Fix 3).
        folder = scratch.appendingPathComponent("levels/deep/run/case", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bundle = try BundleExportGraphicCommandTests.makeBundle(in: folder)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - Helpers, shared with BundleExportGraphicDegradedFactTests

    /// The leaf parsed from `arguments`, as the command line parses it.
    static func command(_ arguments: [String]) throws -> BundleExportGraphicSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(["bundle", "export-graphic"] + arguments)
        return try XCTUnwrap(parsed as? BundleExportGraphicSubcommand)
    }

    /// One log event of the leaf's stream.
    struct LogLine: Equatable {
        let level: String
        let message: String
    }

    /// What one export said, in its event stream and on standard error.
    struct Said {
        var logs: [LogLine] = []
        var progress: [String] = []
        /// The lines of standard error that start `Warning: ` or `Note: `.
        var standardError: [String] = []
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func add(_ line: String) {
            lock.lock()
            stored.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Runs the leaf in process with an enabled event emitter and file descriptor 2 pointed at a file in `folder`, so
    /// the lines it wrote to standard error can be read back.
    static func said(_ arguments: [String], in folder: URL) async throws -> Said {
        let lines = Lines()
        let leaf = try command(arguments)
        let errorFile = folder.appendingPathComponent("stderr-\(UUID().uuidString).txt")
        let descriptor = open(errorFile.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let saved = dup(STDERR_FILENO)
        dup2(descriptor, STDERR_FILENO)
        close(descriptor)
        do {
            _ = try await leaf.export(events: CLIEventEmitter(enabled: true) { lines.add($0) })
        } catch {
            dup2(saved, STDERR_FILENO)
            close(saved)
            throw error
        }
        dup2(saved, STDERR_FILENO)
        close(saved)
        var said = Said()
        for line in lines.all {
            let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
            switch event["event"] as? String {
            case "log":
                said.logs.append(LogLine(level: event["level"] as? String ?? "", message: event["message"] as? String ?? ""))
            case "progress":
                said.progress.append(event["message"] as? String ?? "")
            default:
                break
            }
        }
        said.standardError = try String(contentsOf: errorFile, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("Warning: ") || $0.hasPrefix("Note: ") }
        return said
    }

    /// The `resolved.degraded` entries of the record beside `output`.
    static func degraded(of output: URL) throws -> [[String: ParameterValue]] {
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        guard case .array(let facts)? = record.options.resolvedDefaults["degraded"] else {
            XCTFail("the record holds no degraded list")
            return []
        }
        return facts.compactMap { fact in
            if case .dictionary(let entry) = fact { return entry }
            return nil
        }
    }

    // MARK: - Tests

    /// UX review Fix 2. A label that does not fit repeats what the viewer does, so it is a note and the row stays
    /// Completed. A track the figure cannot draw leaves its data out, so it is a warning. Both read as plain sentences.
    func testExportGraphicWarnsOnlyForFactsThatLeaveDataOut() async throws {
        let routine = folder.appendingPathComponent("routine.png")
        let note = try await Self.said(
            [bundle.path, "--region", "chr1:1-3000", "--width", "300", "--track", "genes", "--output-format", "png",
             "-o", routine.path],
            in: folder
        )
        XCTAssertEqual(note.logs.map(\.level), ["info"], "\(note)")
        let message = try XCTUnwrap(note.logs.first?.message)
        XCTAssertTrue(message.hasPrefix("The genes track left out labels (narrower than 72 points or more than 12 rows, "), message)
        XCTAssertTrue(message.hasSuffix(" left out)."), message)
        XCTAssertEqual(note.standardError, ["Note: " + message])
        XCTAssertEqual(try Self.degraded(of: routine).map { $0["kind"] }, [.string("labelsOmitted")], "the record keeps the fact")

        let partial = folder.appendingPathComponent("partial.png")
        let warning = try await Self.said(
            [bundle.path, "--region", "chr1:1101-1300", "--width", "2000", "--track", "genes", "--track", "signal",
             "--output-format", "png", "-o", partial.path],
            in: folder
        )
        let sentence = "The signal track was not drawn in full (no figure builder)."
        XCTAssertEqual(warning.logs, [LogLine(level: "warning", message: sentence)])
        XCTAssertEqual(warning.standardError, ["Warning: " + sentence])
        XCTAssertEqual(try Self.degraded(of: partial).count, 1)

        XCTAssertEqual(
            BundleExportGraphicRecord.warning(ViewerFigureOmission(
                trackID: "annotations", kind: .labelsOmitted, reason: "narrower than 72 points or more than 12 rows", count: 7
            )),
            "The annotations track left out labels (narrower than 72 points or more than 12 rows, 7 left out)."
        )
    }

    /// The level of each kind of fact, a sentence that names no enum case, and the image name the bulk form puts first.
    func testOnlyTheFactsThatLeaveDataOutAreWarnings() {
        let notes: [ViewerFigureOmissionKind] = [.labelsOmitted, .scaleMode, .fontFallback]
        let warnings: [ViewerFigureOmissionKind] = [.annotationLimit, .readRowCap, .readSample, .trackNotDrawn]
        XCTAssertEqual(Set(notes + warnings), Set(ViewerFigureOmissionKind.allCases), "every kind has a level")
        for kind in notes + warnings {
            let fact = ViewerFigureOmission(trackID: "annotations", kind: kind, reason: "a reason", count: 3)
            XCTAssertEqual(BundleExportGraphicRecord.warns(fact), warnings.contains(kind), "\(kind)")
            let sentence = BundleExportGraphicRecord.warning(fact)
            XCTAssertTrue(sentence.hasPrefix("The annotations track "), sentence)
            XCTAssertTrue(sentence.hasSuffix("(a reason, 3 left out)."), sentence)
            XCTAssertFalse(sentence.contains(kind.rawValue), "a sentence names no enum case: \(sentence)")
        }
        let font = ViewerFigureOmission(
            trackID: "figure", kind: .fontFallback, reason: "Menlo fell back to Courier at 9 points", count: nil
        )
        XCTAssertEqual(
            BundleExportGraphicRecord.warning(font, image: "first.png"),
            "In first.png, the figure used another font (Menlo fell back to Courier at 9 points)."
        )
    }
}
