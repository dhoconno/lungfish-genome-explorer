// CLIEventLegacyNamesTests.swift - The dated table that reads the private event names of older CLIs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Decision V13 of Phase 2.6. The streams that `import msa`, `import tree`, `import geneious` and
/// `import application-export` printed before the version 2 envelope are checked in under
/// `Tests/Fixtures/cli-events/legacy`. The version 2 decoder reads each of them through
/// `CLIEventLegacyNames` to the outcome and outputs that the app runners read from the same lines
/// before they moved onto the transport.
final class CLIEventLegacyNamesTests: XCTestCase {

    // MARK: Fixtures

    private static var folder: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/cli-events/legacy", isDirectory: true)
    }

    /// The runs of S2, the private shape of `import msa` and `import tree`.
    private static let nativeBundleRuns = [
        "import-msa", "import-msa-with-warning", "import-msa-failed",
        "import-tree", "import-tree-with-warning", "import-tree-failed",
    ]

    /// The runs of S3, the private shape of `import geneious` and `import application-export`.
    private static let applicationExportRuns = [
        "import-geneious", "import-geneious-with-warning", "import-geneious-failed",
        "import-application-export", "import-application-export-with-warning", "import-application-export-failed",
    ]

    /// The runs of S8 and S9, which print `progress` with an extra `operation` key.
    private static let progressRuns = ["fastq-ont-fluidigm-samples", "fastq-ont-pacbio-barcode-demux"]

    private func lines(ofRun name: String) throws -> [String] {
        let url = Self.folder.appendingPathComponent("\(name).ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func envelopes(ofRun name: String) throws -> [CLIEventLine] {
        let decoder = CLIEventLineDecoder()
        return try lines(ofRun: name).map { line in
            try XCTUnwrap(try decoder.decodeLine(line), "\(name) holds a line the decoder skips as chatter: \(line)")
        }
    }

    // MARK: The transcripts

    func testTheFolderHoldsExactlyTheCapturedRuns() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path)
            .filter { $0.hasSuffix(".ndjson") }
            .map { String($0.dropLast(".ndjson".count)) }
            .sorted()
        XCTAssertEqual(names, (Self.nativeBundleRuns + Self.applicationExportRuns + Self.progressRuns).sorted())
    }

    func testNoTranscriptNamesAPathOutsideTheScratchFolder() throws {
        let markers = ["/Users/", "/private/", "/var/", "/Volumes/", "/tmp/", ".build"]
        for name in Self.nativeBundleRuns + Self.applicationExportRuns + Self.progressRuns {
            for line in try lines(ofRun: name) {
                let unescaped = line.replacingOccurrences(of: "\\/", with: "/")
                for marker in markers {
                    XCTAssertFalse(unescaped.contains(marker), "\(name) names a path outside /work ('\(marker)'): \(line)")
                }
            }
        }
    }

    // MARK: What each old name becomes

    func testEveryLineOfEveryImportRunDecodesToAVersion2EventNotAnIgnoredLine() throws {
        for name in Self.nativeBundleRuns + Self.applicationExportRuns {
            for envelope in try envelopes(ofRun: name) {
                XCTAssertNotNil(envelope.event, "\(name) holds an event the decoder ignores: \(String(describing: envelope.eventName))")
                XCTAssertEqual(envelope.schemaVersion, 1, "\(name) was written before the envelope")
                XCTAssertTrue(
                    CLIEventLegacyNames.names.contains(envelope.eventName ?? ""),
                    "\(name) holds a name the table does not list: \(String(describing: envelope.eventName))"
                )
            }
        }
    }

    func testEveryImportRunStartsWithStartAndEndsInExactlyOneTerminalEvent() throws {
        for name in Self.nativeBundleRuns + Self.applicationExportRuns {
            let events = try envelopes(ofRun: name).compactMap(\.event)
            guard case .start = events.first else {
                XCTFail("\(name) does not open with a start event")
                continue
            }
            let terminal = events.filter {
                switch $0 {
                case .complete, .failed: return true
                case .start, .progress, .log, .output: return false
                }
            }
            XCTAssertEqual(terminal.count, 1, "\(name)")
            switch events.last {
            case .complete? where !name.hasSuffix("-failed"): break
            case .failed? where name.hasSuffix("-failed"): break
            default: XCTFail("\(name) does not end in the terminal event its name promises")
            }
        }
    }

    /// What the two runners read from a line at program commit 1171aef68, copied there and frozen. It has
    /// its own types so that no later change to the table can move it. `expected(_:)` is the version 2 event
    /// the table must give for what the runner read.
    private enum FrozenRunnerReading {
        enum Event: Equatable {
            case start(kind: String)
            case progress(Double, message: String)
            case warning(message: String)
            case complete(path: String)
            case failed(error: String)
        }

        struct Names {
            let start: String
            let progress: String
            let warning: String
            let complete: String
            let failed: String
            let pathKey: String
            let progressText: String
            let failureText: String
        }

        static let native = Names(
            start: "nativeBundleImportStart", progress: "nativeBundleImportProgress",
            warning: "nativeBundleImportWarning", complete: "nativeBundleImportComplete",
            failed: "nativeBundleImportFailed", pathKey: "bundle",
            progressText: "Importing bundle...", failureText: "Native bundle import failed"
        )

        static let application = Names(
            start: "applicationExportImportStart", progress: "applicationExportProgress",
            warning: "applicationExportWarning", complete: "applicationExportImportComplete",
            failed: "applicationExportImportFailed", pathKey: "collection",
            progressText: "Importing application export...", failureText: "Application export import failed"
        )

        /// The runner's `parseEvent(from:)`.
        static func read(_ line: String, as names: Names) -> Event? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let event = dict["event"] as? String else {
                return nil
            }
            switch event {
            case names.start:
                return .start(kind: dict["kind"] as? String ?? "")
            case names.progress:
                return .progress((dict["progress"] as? NSNumber)?.doubleValue ?? 0, message: dict["message"] as? String ?? names.progressText)
            case names.warning:
                return .warning(message: dict["message"] as? String ?? "Import warning")
            case names.complete:
                return .complete(path: dict[names.pathKey] as? String ?? "")
            case names.failed:
                return .failed(error: dict["error"] as? String ?? names.failureText)
            default:
                return nil
            }
        }

        /// What the runner did with the event, as the version 2 event that stands for it.
        static func expected(_ event: Event) -> CLIEvent {
            switch event {
            case let .start(kind):
                return .start(message: "Started \(kind) import via lungfish-cli")
            case let .progress(value, message):
                return .progress(fraction: max(0, min(1, value)), message: message)
            case let .warning(message):
                return .log(level: .warning, message: message)
            case let .complete(path):
                return .complete(outputs: path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [path], message: nil)
            case let .failed(error):
                return .failed(message: error, detail: nil)
            }
        }
    }

    func testEveryLineDecodesToWhatTheRunnersReadFromIt() throws {
        let decoder = CLIEventLineDecoder()
        var checked = 0
        for (runs, names) in [
            (Self.nativeBundleRuns, FrozenRunnerReading.native),
            (Self.applicationExportRuns, FrozenRunnerReading.application),
        ] {
            for run in runs {
                for line in try lines(ofRun: run) {
                    let read = try XCTUnwrap(FrozenRunnerReading.read(line, as: names), "\(run): \(line)")
                    XCTAssertEqual(
                        try decoder.decode(line: line),
                        FrozenRunnerReading.expected(read),
                        "\(run): \(line)"
                    )
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 79, "The twelve runs of S2 and S3 hold 79 lines between them")
    }

    func testTheOutcomeAndOutputsOfEachRunAreWhatTheRunnersGaveToday() throws {
        let completes: [String: [String]] = [
            "import-msa": ["/work/Project.lungfish/Multiple Sequence Alignments/mhc.lungfishmsa"],
            "import-msa-with-warning": ["/work/Project.lungfish/Multiple Sequence Alignments/duplicates.lungfishmsa"],
            "import-tree": ["/work/Project.lungfish/Phylogenetic Trees/mhc.lungfishtree"],
            "import-tree-with-warning": ["/work/Project.lungfish/Phylogenetic Trees/bare.lungfishtree"],
            "import-geneious": ["/work/Project.lungfish/Geneious Imports/Representative Geneious Import"],
            "import-geneious-with-warning": ["/work/Project.lungfish/Geneious Imports/Representative Geneious Import"],
            "import-application-export": ["/work/Project.lungfish/Application Exports/Alignment Tree Export Alignment Tree Import"],
            "import-application-export-with-warning": ["/work/Project.lungfish/Application Exports/Alignment Tree Export Alignment Tree Import"],
        ]
        for (run, outputs) in completes {
            let events = try envelopes(ofRun: run).compactMap(\.event)
            XCTAssertEqual(events.last, .complete(outputs: outputs, message: nil), run)
        }

        let failures: [String: String] = [
            "import-msa-failed": "Input file not found: /work/inputs/missing.aln",
            "import-tree-failed": "Input file not found: /work/inputs/missing.nwk",
            "import-geneious-failed": "Input file not found: /work/inputs/missing.geneious",
            "import-application-export-failed": "Input file not found: /work/inputs/missing",
        ]
        for (run, message) in failures {
            let events = try envelopes(ofRun: run).compactMap(\.event)
            XCTAssertEqual(events.last, .failed(message: message, detail: nil), run)
        }
    }

    func testEachWarningLineBecomesAWarningLogAndTheCountsAgree() throws {
        let warnings: [String: Int] = [
            "import-msa": 0, "import-msa-with-warning": 1, "import-tree": 0, "import-tree-with-warning": 1,
            "import-geneious": 0, "import-geneious-with-warning": 5,
            "import-application-export": 0, "import-application-export-with-warning": 1,
        ]
        for (run, count) in warnings {
            let events = try envelopes(ofRun: run).compactMap(\.event)
            let logged = events.filter {
                if case .log(.warning, _) = $0 { return true }
                return false
            }
            XCTAssertEqual(logged.count, count, run)
            // The old complete line counted the warning lines in front of it, which is why the
            // table does not carry the count.
            let raw = try lines(ofRun: run).last.flatMap { $0.data(using: .utf8) }
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(raw)) as? [String: Any])
            XCTAssertEqual(object["warningCount"] as? Int, count, run)
        }
    }

    func testTheCompleteLineHoldsOneTypedArtifactForTheBundleOrCollection() throws {
        let expected: [String: (kind: String, role: String)] = [
            "import-msa": ("multiple-sequence-alignment", "bundle"),
            "import-tree": ("phylogenetic-tree", "bundle"),
            "import-geneious": ("import-collection", "collection"),
            "import-application-export": ("import-collection", "collection"),
        ]
        for (run, shape) in expected {
            let last = try XCTUnwrap(try envelopes(ofRun: run).last)
            guard case let .complete(outputs, _)? = last.event else {
                XCTFail("\(run) does not end in complete")
                continue
            }
            XCTAssertEqual(last.artifacts.count, 1, run)
            let artifact = try XCTUnwrap(last.artifacts.first)
            XCTAssertEqual(artifact.path, outputs.first, "The artifact names the output, and outputs stays the import's only input: \(run)")
            XCTAssertEqual(artifact.kind, shape.kind, run)
            XCTAssertEqual(artifact.role, shape.role, run)
            XCTAssertNil(artifact.provenancePath, "A line of an older CLI does not name the record: \(run)")
        }
        // A registered bundle kind reads back through the registry, and the collection kind stays a string.
        let msa = try XCTUnwrap(try envelopes(ofRun: "import-msa").last?.artifacts.first)
        XCTAssertEqual(msa.bundleKind, .multipleSequenceAlignment)
        let tree = try XCTUnwrap(try envelopes(ofRun: "import-tree").last?.artifacts.first)
        XCTAssertEqual(tree.bundleKind, .phylogeneticTree)
        let collection = try XCTUnwrap(try envelopes(ofRun: "import-geneious").last?.artifacts.first)
        XCTAssertNil(collection.bundleKind)
    }

    func testOnlyACompleteLineCarriesArtifacts() throws {
        for run in Self.nativeBundleRuns + Self.applicationExportRuns {
            for envelope in try envelopes(ofRun: run).dropLast() {
                XCTAssertTrue(envelope.artifacts.isEmpty, "\(run): \(String(describing: envelope.eventName))")
            }
        }
    }

    // MARK: What the table does not read

    func testALegacyNameAtAnyVersionOtherThanNoVersionIsAnIgnoredLine() throws {
        let decoder = CLIEventLineDecoder()
        let lines = [
            #"{"event":"nativeBundleImportComplete","bundle":"/work/x.lungfishmsa","schemaVersion":2}"#,
            #"{"event":"nativeBundleImportStart","kind":"phylogenetic-tree","schemaVersion":3}"#,
            #"{"event":"applicationExportImportComplete","collection":"/work/c","schemaVersion":"2"}"#,
            #"{"event":"applicationExportProgress","progress":0.5,"schemaVersion":1}"#,
        ]
        for line in lines {
            let envelope = try XCTUnwrap(try decoder.decodeLine(line), line)
            XCTAssertNil(envelope.event, "The table is consulted only for a line with no schemaVersion: \(line)")
            XCTAssertNil(try decoder.decode(line: line), line)
        }
    }

    func testANameTheTableDoesNotKnowIsAnIgnoredLineAndNeverAThrow() throws {
        let decoder = CLIEventLineDecoder()
        let lines = [
            #"{"event":"nativeBundleImportPaused","message":"waiting"}"#,
            #"{"event":"applicationExportImportStarted","kind":"clc-workbench"}"#,
            #"{"event":"nativeBundleimportcomplete","bundle":"/work/x.lungfishmsa"}"#,
            #"{"event":"","bundle":"/work/x.lungfishmsa"}"#,
            #"{"event":7,"bundle":"/work/x.lungfishmsa"}"#,
            #"{"bundle":"/work/x.lungfishmsa"}"#,
        ]
        for line in lines {
            let envelope = try XCTUnwrap(try decoder.decodeLine(line), line)
            XCTAssertNil(envelope.event, line)
            XCTAssertEqual(envelope.schemaVersion, 1, line)
            XCTAssertNil(try decoder.decode(line: line), line)
        }
    }

    func testMissingAndMistypedFieldsTakeTheDefaultsOfTheOldRunners() throws {
        let decoder = CLIEventLineDecoder()
        let cases: [(String, CLIEvent)] = [
            (#"{"event":"nativeBundleImportStart"}"#, .start(message: "Started  import via lungfish-cli")),
            (#"{"event":"nativeBundleImportStart","kind":3}"#, .start(message: "Started  import via lungfish-cli")),
            (#"{"event":"nativeBundleImportProgress"}"#, .progress(fraction: 0, message: "Importing bundle...")),
            (#"{"event":"applicationExportProgress"}"#, .progress(fraction: 0, message: "Importing application export...")),
            (#"{"event":"applicationExportProgress","progress":5,"message":7}"#, .progress(fraction: 1, message: "Importing application export...")),
            (#"{"event":"nativeBundleImportProgress","progress":-2,"message":"back"}"#, .progress(fraction: 0, message: "back")),
            (#"{"event":"nativeBundleImportProgress","progress":"half","message":"x"}"#, .progress(fraction: 0, message: "x")),
            (#"{"event":"nativeBundleImportWarning"}"#, .log(level: .warning, message: "Import warning")),
            (#"{"event":"applicationExportWarning","message":null}"#, .log(level: .warning, message: "Import warning")),
            (#"{"event":"nativeBundleImportFailed"}"#, .failed(message: "Native bundle import failed", detail: nil)),
            (#"{"event":"applicationExportImportFailed"}"#, .failed(message: "Application export import failed", detail: nil)),
            (#"{"event":"nativeBundleImportFailed","error":4}"#, .failed(message: "Native bundle import failed", detail: nil)),
            (#"{"event":"nativeBundleImportComplete"}"#, .complete(outputs: [], message: nil)),
            (#"{"event":"nativeBundleImportComplete","bundle":3}"#, .complete(outputs: [], message: nil)),
            (#"{"event":"applicationExportImportComplete","collection":"   "}"#, .complete(outputs: [], message: nil)),
        ]
        for (line, event) in cases {
            XCTAssertEqual(try decoder.decode(line: line), event, line)
            let envelope = try XCTUnwrap(try decoder.decodeLine(line))
            XCTAssertTrue(envelope.artifacts.isEmpty, "A completion that names nothing has no artifact: \(line)")
        }
    }

    func testAKeyTheOldEncodersNeverWroteIsIgnored() throws {
        let decoder = CLIEventLineDecoder()
        let line = #"{"bundle":"/work/x.lungfishmsa","event":"nativeBundleImportComplete","padding":"ppp","progress":1,"warningCount":3,"extra":{"a":[1,2]}}"#
        XCTAssertEqual(try decoder.decode(line: line), .complete(outputs: ["/work/x.lungfishmsa"], message: nil))
    }

    // MARK: S8 and S9 need no row

    func testTheOntProgressLinesReadAsProgressWithoutAnyRow() throws {
        let decoder = CLIEventLineDecoder()
        let frozen = FrozenCLIEventV1LineDecoder()
        for run in Self.progressRuns {
            let all = try lines(ofRun: run)
            XCTAssertGreaterThanOrEqual(all.count, 5, run)
            for line in all {
                let envelope = try XCTUnwrap(try decoder.decodeLine(line), line)
                guard case .progress? = envelope.event else {
                    XCTFail("\(run) holds a line that is not progress: \(line)")
                    continue
                }
                XCTAssertEqual(envelope.schemaVersion, 1, line)
                XCTAssertEqual(envelope.eventName, "progress", line)
                // The frozen version 1 reader, which the FASTQ dialog's decoder was, reads the same event.
                XCTAssertEqual(try frozen.decode(line: line)?.asCLIEvent, envelope.event, line)
            }
        }
        XCTAssertFalse(CLIEventLegacyNames.names.contains("progress"), "S8 and S9 use a name the decoder already knows")
        let operations = Set(try Self.progressRuns.flatMap { try lines(ofRun: $0) }.compactMap { line -> String? in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["operation"] as? String
        })
        XCTAssertEqual(operations, ["ontFluidigmSamples", "ontPacBioBarcodeDemux"])
    }

    // MARK: The reason for the table

    func testTheFrozenVersion1ReaderThrowsOnEveryOldName() throws {
        let frozen = FrozenCLIEventV1LineDecoder()
        for name in CLIEventLegacyNames.names {
            XCTAssertThrowsError(try frozen.decode(line: "{\"event\":\"\(name)\"}"), name)
        }
    }

    func testTheTableIsDatedAndNamesExactlyTheTenOldNames() {
        XCTAssertEqual(CLIEventLegacyNames.dated, "2026-10-11")
        XCTAssertEqual(CLIEventLegacyNames.names, [
            "applicationExportImportComplete",
            "applicationExportImportFailed",
            "applicationExportImportStart",
            "applicationExportProgress",
            "applicationExportWarning",
            "nativeBundleImportComplete",
            "nativeBundleImportFailed",
            "nativeBundleImportProgress",
            "nativeBundleImportStart",
            "nativeBundleImportWarning",
        ])
    }
}
