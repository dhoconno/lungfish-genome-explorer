// CLIEventCompatibilityTests.swift - Event transcripts against the frozen version 1 reader
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

// MARK: - The frozen version 1 reader

/// How a version 1 app reads one event line, copied from the shipped decoder at
/// program commit 90d34c550 and then frozen. It has its own types on purpose, so
/// no later change to `CLIEvent` can move it.
///
/// Never edit this type. It stands for every `lungfish-cli` and app pair that
/// was released before the version 2 envelope, and the tests below show that
/// whatever the writer prints today, this reader still gets the same outcome and
/// the same outputs. A reader with new behavior belongs in a new type.
enum FrozenCLIEventV1: Equatable, Decodable {
    case start(message: String)
    case progress(fraction: Double, message: String)
    case log(level: Level, message: String)
    case output(path: String, role: String)
    case complete(outputs: [String], message: String?)
    case failed(message: String, detail: String?)

    enum Level: String, Equatable, Decodable {
        case debug
        case info
        case warning
        case error
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case progress
        case message
        case output
        case outputs
        case error
        case detail
        case level
        case role
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .event)
        switch name {
        case "start":
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .start(message: message)
        case "progress":
            let fraction = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .progress(fraction: max(0, min(1, fraction)), message: message)
        case "log":
            let level = try container.decodeIfPresent(Level.self, forKey: .level) ?? .info
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .log(level: level, message: message)
        case "output":
            let path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
            let role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
            self = .output(path: path, role: role)
        case "complete":
            var outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? []
            if outputs.isEmpty, let singular = try container.decodeIfPresent(String.self, forKey: .output),
               !singular.isEmpty {
                outputs = [singular]
            }
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            self = .complete(outputs: outputs, message: message)
        case "failed":
            let message = try container.decodeIfPresent(String.self, forKey: .error)
                ?? container.decodeIfPresent(String.self, forKey: .message)
                ?? "Operation failed"
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            self = .failed(message: message, detail: detail)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [CodingKeys.event], debugDescription: "Unknown CLIEvent name '\(name)'")
            )
        }
    }

    /// The same event as the shared type, for comparing the two readers.
    var asCLIEvent: CLIEvent {
        switch self {
        case let .start(message):
            return .start(message: message)
        case let .progress(fraction, message):
            return .progress(fraction: fraction, message: message)
        case let .log(level, message):
            return .log(level: CLIEventLogLevel(rawValue: level.rawValue) ?? .info, message: message)
        case let .output(path, role):
            return .output(path: path, role: role)
        case let .complete(outputs, message):
            return .complete(outputs: outputs, message: message)
        case let .failed(message, detail):
            return .failed(message: message, detail: detail)
        }
    }

    var isTerminal: Bool {
        switch self {
        case .complete, .failed: return true
        case .start, .progress, .log, .output: return false
        }
    }
}

/// The line step of the frozen reader. A line that is not a JSON object is
/// chatter and reads as nil, and a line that looks like an event but does not
/// decode throws.
struct FrozenCLIEventV1LineDecoder {
    private let decoder = JSONDecoder()

    func decode(line: String) throws -> FrozenCLIEventV1? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try decoder.decode(FrozenCLIEventV1.self, from: data)
    }
}

// MARK: - Tests

/// Version 1 transcripts, captured from real runs of the emitters before the
/// envelope, read by the frozen version 1 reader and by the current decoder. The
/// version 2 lines the current emitter writes are read back by the frozen reader,
/// and lines from a later version are read by the current decoder.
final class CLIEventCompatibilityTests: XCTestCase {

    // MARK: Fixtures

    /// The captured runs in `Tests/Fixtures/cli-events/v1`, by file name without the extension.
    /// A run added to or removed from the folder needs an edit here too.
    static let capturedRuns = [
        "fastq-platform",
        "fastq-platform-failed",
        "msa-annotate-add",
        "msa-annotate-delete",
        "msa-annotate-edit",
        "msa-annotate-project",
        "msa-consensus",
        "msa-discriminating-sites",
        "msa-distance",
        "msa-export",
        "msa-export-failed",
        "msa-export-with-warning",
        "msa-extract",
        "msa-mask-columns",
        "msa-trim-columns",
        "tree-export-subtree",
        "tree-extract-subtree",
        "tree-relabel",
        "tree-reroot",
        "tree-reroot-failed",
    ]

    private static var version1Folder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LungfishWorkflowTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures/cli-events/v1", isDirectory: true)
    }

    private func lines(ofRun name: String) throws -> [String] {
        let url = Self.version1Folder.appendingPathComponent("\(name).ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func frozenEvents(ofRun name: String) throws -> [FrozenCLIEventV1] {
        let decoder = FrozenCLIEventV1LineDecoder()
        return try lines(ofRun: name).map { line in
            try XCTUnwrap(decoder.decode(line: line), "\(name) holds a line the frozen reader skips: \(line)")
        }
    }

    // MARK: Version 1 transcripts

    func testTheFolderHoldsExactlyTheCapturedRuns() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.version1Folder.path)
            .filter { $0.hasSuffix(".ndjson") }
            .map { String($0.dropLast(".ndjson".count)) }
            .sorted()
        XCTAssertEqual(names, Self.capturedRuns)
    }

    func testFrozenReaderDecodesEveryLineOfEveryTranscript() throws {
        for name in Self.capturedRuns {
            let events = try frozenEvents(ofRun: name)
            XCTAssertGreaterThanOrEqual(events.count, 2, "\(name) is too short to be a run")
        }
    }

    func testEveryTranscriptStartsWithStartAndEndsWithOneTerminalEvent() throws {
        for name in Self.capturedRuns {
            let events = try frozenEvents(ofRun: name)
            guard case .start = events.first else {
                XCTFail("\(name) does not open with a start event")
                continue
            }
            XCTAssertTrue(events.last?.isTerminal == true, "\(name) does not end with complete or failed")
            XCTAssertEqual(events.filter(\.isTerminal).count, 1, "\(name) has more than one terminal event")
        }
    }

    func testRunsEndInCompleteUnlessTheirNameSaysFailed() throws {
        for name in Self.capturedRuns {
            let events = try frozenEvents(ofRun: name)
            switch events.last {
            case .some(.complete(let outputs, _)):
                XCTAssertFalse(name.hasSuffix("-failed"), "\(name) completed")
                XCTAssertFalse(outputs.isEmpty, "\(name) completed without naming an output")
            case .some(.failed(let message, _)):
                XCTAssertTrue(name.hasSuffix("-failed"), "\(name) failed")
                XCTAssertFalse(message.isEmpty, "\(name) failed without a message")
            default:
                XCTFail("\(name) has no terminal event")
            }
        }
    }

    /// Version 1 writers put the first output in a singular `output` key beside the
    /// `outputs` list, and the app reads the list by position.
    func testCompleteLinesKeepTheSingularOutputAsTheFirstOfTheList() throws {
        var completes = 0
        for name in Self.capturedRuns {
            for line in try lines(ofRun: name) {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                guard object["event"] as? String == "complete" else { continue }
                completes += 1
                let outputs = try XCTUnwrap(object["outputs"] as? [String], "\(name) has no outputs list")
                XCTAssertEqual(object["output"] as? String, outputs.first, "\(name)")
                XCTAssertEqual(object["progress"] as? Double, 1, "\(name)")
            }
        }
        XCTAssertEqual(completes, Self.capturedRuns.filter { !$0.hasSuffix("-failed") }.count)
    }

    func testTodaysDecoderReadsEveryTranscriptLikeTheFrozenReader() throws {
        let decoder = CLIEventLineDecoder()
        for name in Self.capturedRuns {
            let frozen = try frozenEvents(ofRun: name).map(\.asCLIEvent)
            let current = try lines(ofRun: name).map { line in
                try XCTUnwrap(decoder.decode(line: line), "\(name) holds a line the current decoder skips: \(line)")
            }
            XCTAssertEqual(current, frozen, name)
        }
    }

    // MARK: The frozen reader's own behavior

    func testFrozenReaderKeepsTheVersion1Spellings() throws {
        let reader = FrozenCLIEventV1LineDecoder()

        // A complete line with only the singular output key.
        XCTAssertEqual(
            try reader.decode(line: #"{"event":"complete","output":"/project/x.lungfishtree","progress":1}"#),
            .complete(outputs: ["/project/x.lungfishtree"], message: nil))
        // The list wins over the singular key, and its order is kept.
        XCTAssertEqual(
            try reader.decode(line: #"{"event":"complete","output":"/b","outputs":["/b","/a"]}"#),
            .complete(outputs: ["/b", "/a"], message: nil))
        // A failed line may carry `message` instead of `error`, and has a default text.
        XCTAssertEqual(
            try reader.decode(line: #"{"event":"failed","message":"no good"}"#),
            .failed(message: "no good", detail: nil))
        XCTAssertEqual(
            try reader.decode(line: #"{"event":"failed"}"#),
            .failed(message: "Operation failed", detail: nil))
        // Missing fields take their defaults, and a fraction is clamped.
        XCTAssertEqual(try reader.decode(line: #"{"event":"start"}"#), .start(message: ""))
        XCTAssertEqual(
            try reader.decode(line: #"{"event":"progress","progress":1.5}"#),
            .progress(fraction: 1, message: ""))
        XCTAssertEqual(
            try reader.decode(line: #"{"event":"log","message":"hello"}"#),
            .log(level: .info, message: "hello"))
        // Unknown keys are ignored.
        XCTAssertEqual(
            try reader.decode(line: #"{"event":"progress","progress":0.5,"message":"x","operation":"demux","eta":3}"#),
            .progress(fraction: 0.5, message: "x"))
        // Text that is not a JSON object is chatter.
        XCTAssertNil(try reader.decode(line: "Wrote tree bundle: /path"))
        XCTAssertNil(try reader.decode(line: ""))
    }

    /// What a version 1 app does with a line it cannot read. These are the
    /// failures the envelope work must keep out of its own decoder.
    func testFrozenReaderThrowsOnWhatItCannotRead() {
        let reader = FrozenCLIEventV1LineDecoder()
        XCTAssertThrowsError(try reader.decode(line: #"{"event":"somethingElse"}"#), "an unknown name")
        XCTAssertThrowsError(try reader.decode(line: #"{"progress":0.5}"#), "no event name")
        XCTAssertThrowsError(try reader.decode(line: #"{"event":"log","level":"critical","message":"x"}"#), "an unknown level")
        XCTAssertThrowsError(try reader.decode(line: #"{"event":"progress","progress":"half"}"#), "a wrong type")
        XCTAssertThrowsError(try reader.decode(line: #"{"event":"progress""#), "a truncated line")
    }

    // MARK: Shapes no captured run holds

    /// No command writes an `output` event and none sets `detail` on a `failed`
    /// event today, so these lines are written here instead of captured.
    func testShapesNoRunProducedReadTheSameInBothReaders() throws {
        let lines = [
            #"{"event":"output","path":"/work/a.bam","role":"alignment"}"#,
            #"{"event":"failed","error":"node not found","detail":"stderr excerpt"}"#,
            #"{"event":"log","level":"debug","message":"d"}"#,
            #"{"event":"log","level":"info","message":"i"}"#,
            #"{"event":"log","level":"warning","message":"w"}"#,
            #"{"event":"log","level":"error","message":"e"}"#,
            #"{"event":"progress","operation":"ontPacBioBarcodeDemux","progress":0.46,"message":"Processed 1/2 chunks"}"#,
            #"{"event":"complete","outputs":[],"progress":1}"#,
        ]
        let frozen = FrozenCLIEventV1LineDecoder()
        let current = CLIEventLineDecoder()
        for line in lines {
            let old = try XCTUnwrap(frozen.decode(line: line), line)
            XCTAssertEqual(try current.decode(line: line), old.asCLIEvent, line)
        }
        XCTAssertEqual(
            try frozen.decode(line: lines[0]),
            .output(path: "/work/a.bam", role: "alignment"))
        XCTAssertEqual(
            try frozen.decode(line: lines[1]),
            .failed(message: "node not found", detail: "stderr excerpt"))
    }

    // MARK: Version 1 transcripts under the envelope

    /// A line with no `schemaVersion` key is a version 1 line, and the envelope
    /// reads the same event from it that the version 1 reader does.
    func testVersion1TranscriptsDecodeUnchangedUnderTheEnvelope() throws {
        let decoder = CLIEventLineDecoder()
        for name in Self.capturedRuns {
            let raw = try lines(ofRun: name)
            let frozen = try frozenEvents(ofRun: name)
            XCTAssertEqual(raw.count, frozen.count, name)
            for (line, old) in zip(raw, frozen) {
                let envelope = try XCTUnwrap(decoder.decodeLine(line), "\(name): \(line)")
                XCTAssertEqual(envelope.schemaVersion, 1, name)
                XCTAssertEqual(envelope.event, old.asCLIEvent, name)
                XCTAssertTrue(envelope.artifacts.isEmpty, name)
                XCTAssertEqual(envelope.eventName, try eventName(of: line), name)
            }
        }
    }

    // MARK: Version 2 lines under the frozen version 1 reader

    /// Writes each captured run again with today's emitter, gives every completion
    /// artifacts of a kind no reader knows, and reads the result with the frozen
    /// version 1 reader. It must reach the same events, so the same outcome and the
    /// same outputs in the same order.
    func testVersion2LinesReadUnderTheFrozenReaderToTheSameOutcomeAndOutputs() throws {
        let frozenDecoder = FrozenCLIEventV1LineDecoder()
        let currentDecoder = CLIEventLineDecoder()
        for name in Self.capturedRuns {
            let events = try lines(ofRun: name).map { try XCTUnwrap(currentDecoder.decode(line: $0), name) }

            var written: [String] = []
            let emitter = CLIEventEmitter(enabled: true) { written.append($0) }
            for event in events {
                if case let .complete(outputs, message) = event {
                    let artifacts = outputs.map {
                        CLIEventArtifact(kind: "kind-from-a-later-registry", path: $0, role: "primary", provenancePath: $0 + ".provenance")
                    }
                    emitter.emitComplete(outputs: outputs, artifacts: artifacts, message: message)
                } else {
                    emitter.emit(event)
                }
            }

            XCTAssertEqual(written.count, events.count, name)
            for line in written {
                XCTAssertEqual(try schemaVersion(of: line), 2, "\(name): \(line)")
                XCTAssertFalse(line.contains(Character("\n")), name)
            }

            let readBack = try written.map { try XCTUnwrap(frozenDecoder.decode(line: $0), "\(name): \($0)") }
            XCTAssertEqual(readBack, try frozenEvents(ofRun: name), name)
            XCTAssertEqual(readBack.last, try frozenEvents(ofRun: name).last, "\(name) outcome and outputs")
        }
    }

    /// The primer trim runner finds its provenance record by the position of an
    /// output, so a completion keeps `outputs` in the order its writer gave, and the
    /// singular `output` stays the first of them, with artifacts beside the list.
    func testCompleteKeepsItsOutputsInVersion1OrderBesideArtifacts() throws {
        var written: [String] = []
        let emitter = CLIEventEmitter(enabled: true) { written.append($0) }
        let outputs = ["/work/trimmed.bam", "/work/trimmed.bam.bai", "/work/trimmed.provenance.json"]
        // Artifacts are listed in a different order from the outputs on purpose.
        let artifacts = [
            CLIEventArtifact(kind: "provenance", path: outputs[2]),
            CLIEventArtifact(kind: "alignment", path: outputs[0], provenancePath: outputs[2]),
        ]
        emitter.emitComplete(outputs: outputs, artifacts: artifacts, message: "trackID=aln_1 trackName=Trimmed")

        let line = try XCTUnwrap(written.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["outputs"] as? [String], outputs)
        XCTAssertEqual(object["output"] as? String, outputs[0])
        XCTAssertEqual(
            try FrozenCLIEventV1LineDecoder().decode(line: line),
            .complete(outputs: outputs, message: "trackID=aln_1 trackName=Trimmed"))

        let envelope = try XCTUnwrap(CLIEventLineDecoder().decodeLine(line))
        XCTAssertEqual(envelope.event, .complete(outputs: outputs, message: "trackID=aln_1 trackName=Trimmed"))
        XCTAssertEqual(envelope.artifacts, artifacts)
    }

    // MARK: Lines from a later version

    /// A line from a writer that is newer than this reader decodes, whatever it adds.
    func testAVersion3LineWithUnknownKeysNamesAndKindsDecodes() throws {
        let decoder = CLIEventLineDecoder()

        // A completion with a new key on the line, new keys on its artifacts, and
        // artifact kinds and roles no reader has heard of.
        let complete = """
        {"schemaVersion":3,"event":"complete","outputs":["/work/a","/work/b"],"output":"/work/a","progress":1,\
        "message":"done","checksums":{"a":"abc"},"artifacts":[\
        {"kind":"holographic-bundle","path":"/work/a","role":"primary","provenancePath":"/work/a/.provenance.json",\
        "sizeBytes":12,"tags":["x"]},{"kind":"another-new-kind","path":"/work/b","role":"mystery"}]}
        """
        let line = try XCTUnwrap(decoder.decodeLine(complete))
        XCTAssertEqual(line.schemaVersion, 3)
        XCTAssertEqual(line.event, .complete(outputs: ["/work/a", "/work/b"], message: "done"))
        XCTAssertEqual(line.artifacts, [
            CLIEventArtifact(kind: "holographic-bundle", path: "/work/a", role: "primary", provenancePath: "/work/a/.provenance.json"),
            CLIEventArtifact(kind: "another-new-kind", path: "/work/b", role: "mystery"),
        ])
        // A version 1 app reads the same completion and ignores what it does not know.
        XCTAssertEqual(
            try FrozenCLIEventV1LineDecoder().decode(line: complete),
            .complete(outputs: ["/work/a", "/work/b"], message: "done"))

        // A known event with new keys.
        let progress = try XCTUnwrap(decoder.decodeLine(
            #"{"schemaVersion":3,"event":"progress","progress":0.4,"message":"Working","eta":12,"phase":{"n":2}}"#))
        XCTAssertEqual(progress.event, .progress(fraction: 0.4, message: "Working"))

        // A new event name is an ignored line. The name is kept for the report, and
        // artifacts on a line the reader ignores are not read.
        let checkpoint = try XCTUnwrap(decoder.decodeLine(
            #"{"schemaVersion":3,"event":"checkpoint","step":4,"artifacts":[{"kind":"k","path":"/work/x"}]}"#))
        XCTAssertNil(checkpoint.event)
        XCTAssertEqual(checkpoint.eventName, "checkpoint")
        XCTAssertEqual(checkpoint.schemaVersion, 3)
        XCTAssertTrue(checkpoint.artifacts.isEmpty)
        XCTAssertNil(try decoder.decode(line: #"{"schemaVersion":3,"event":"checkpoint"}"#))

        // A version 1 app throws on the new name, which it logs as a warning for each such line.
        XCTAssertThrowsError(try FrozenCLIEventV1LineDecoder().decode(line: #"{"schemaVersion":3,"event":"checkpoint"}"#))
    }

    /// At a higher version a writer may have changed the fields of a known event. The
    /// stream goes on without that line, where a line at a known version is an error.
    func testAnEventThatCannotBeReadAtAHigherVersionIsIgnoredNotThrown() throws {
        let decoder = CLIEventLineDecoder()
        let line = try XCTUnwrap(decoder.decodeLine(#"{"schemaVersion":4,"event":"progress","progress":{"done":2,"of":9}}"#))
        XCTAssertNil(line.event)
        XCTAssertEqual(line.eventName, "progress")
        XCTAssertEqual(line.schemaVersion, 4)
        XCTAssertThrowsError(try decoder.decodeLine(#"{"schemaVersion":2,"event":"progress","progress":{"done":2,"of":9}}"#))
    }

    func testSchemaVersionReadsLeniently() throws {
        let decoder = CLIEventLineDecoder()
        let cases: [(json: String, version: Int)] = [
            (#"{"event":"start"}"#, 1),
            (#"{"schemaVersion":1,"event":"start"}"#, 1),
            (#"{"schemaVersion":2,"event":"start"}"#, 2),
            (#"{"schemaVersion":7,"event":"start"}"#, 7),
            (#"{"schemaVersion":0,"event":"start"}"#, 1),
            (#"{"schemaVersion":-3,"event":"start"}"#, 1),
            // Present but unreadable still means a writer that has the key.
            (#"{"schemaVersion":"3","event":"start"}"#, 2),
            (#"{"schemaVersion":2.5,"event":"start"}"#, 2),
            (#"{"schemaVersion":null,"event":"start"}"#, 2),
        ]
        for (json, version) in cases {
            let line = try XCTUnwrap(decoder.decodeLine(json), json)
            XCTAssertEqual(line.schemaVersion, version, json)
            XCTAssertEqual(line.event, .start(message: ""), json)
        }
    }

    // MARK: Artifacts

    func testArtifactsAreReadOnlyFromCompleteAndOutputLines() throws {
        let decoder = CLIEventLineDecoder()
        let artifacts = #""artifacts":[{"kind":"k","path":"/work/a"}]"#
        let expected = [CLIEventArtifact(kind: "k", path: "/work/a")]
        XCTAssertEqual(try decoder.decodeLine(#"{"event":"complete","outputs":["/work/a"],\#(artifacts)}"#)?.artifacts, expected)
        XCTAssertEqual(try decoder.decodeLine(#"{"event":"output","path":"/work/a","role":"r",\#(artifacts)}"#)?.artifacts, expected)
        for name in ["start", "progress", "log", "failed"] {
            XCTAssertEqual(try decoder.decodeLine(#"{"event":"\#(name)",\#(artifacts)}"#)?.artifacts, [], name)
        }
    }

    /// An artifact is dropped when it cannot be read, and a field of the wrong type
    /// reads as absent, so one bad entry never costs the line or its neighbours.
    func testBrokenArtifactsAreDroppedAndTheLineSurvives() throws {
        let decoder = CLIEventLineDecoder()
        let line = try XCTUnwrap(decoder.decodeLine("""
        {"event":"complete","outputs":["/work/a"],"artifacts":[{"kind":"k","path":"/work/a"},{"kind":"no-path"},\
        "text",7,null,{"path":"/work/b","kind":5,"role":["x"],"provenancePath":false}]}
        """))
        XCTAssertEqual(line.event, .complete(outputs: ["/work/a"], message: nil))
        XCTAssertEqual(line.artifacts, [
            CLIEventArtifact(kind: "k", path: "/work/a"),
            CLIEventArtifact(kind: "", path: "/work/b"),
        ])

        for value in [#"{"kind":"k","path":"/work/a"}"#, #""text""#, "7", "null"] {
            let odd = try XCTUnwrap(decoder.decodeLine(#"{"event":"complete","outputs":["/work/a"],"artifacts":\#(value)}"#), value)
            XCTAssertEqual(odd.event, .complete(outputs: ["/work/a"], message: nil), value)
            XCTAssertTrue(odd.artifacts.isEmpty, value)
        }
    }

    // MARK: Where the current decoder is more tolerant than version 1

    /// Each line below makes the frozen version 1 reader throw and the current
    /// decoder keep the stream going.
    func testTheCurrentDecoderAcceptsWhatTheFrozenReaderThrowsOn() throws {
        let frozen = FrozenCLIEventV1LineDecoder()
        let current = CLIEventLineDecoder()

        let unknownName = #"{"event":"checkpoint"}"#
        XCTAssertThrowsError(try frozen.decode(line: unknownName))
        XCTAssertNil(try current.decodeLine(unknownName)?.event)

        let noName = #"{"progress":0.5,"message":"a JSON object that is not an event"}"#
        XCTAssertThrowsError(try frozen.decode(line: noName))
        let nameless = try XCTUnwrap(current.decodeLine(noName))
        XCTAssertNil(nameless.event)
        XCTAssertNil(nameless.eventName)

        let newLevel = #"{"event":"log","level":"critical","message":"disk almost full"}"#
        XCTAssertThrowsError(try frozen.decode(line: newLevel))
        XCTAssertEqual(try current.decode(line: newLevel), .log(level: .info, message: "disk almost full"))
    }

    func testChatterReadsAsNothingInBothReaders() throws {
        for text in ["", "   ", "Wrote tree bundle: /work/t", "[50%] Working", "12S amplicon result bundle written to /work/x"] {
            XCTAssertNil(try FrozenCLIEventV1LineDecoder().decode(line: text), text)
            XCTAssertNil(try CLIEventLineDecoder().decodeLine(text), text)
        }
        // Text glued in front of an event line hides the event from both. This is why
        // human text goes to standard error while events are on.
        let glued = #"Working...{"event":"progress","progress":0.5,"message":"x"}"#
        XCTAssertNil(try FrozenCLIEventV1LineDecoder().decode(line: glued))
        XCTAssertNil(try CLIEventLineDecoder().decodeLine(glued))
    }

    // MARK: Helpers

    private func jsonObject(of line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
    }

    private func schemaVersion(of line: String) throws -> Int? {
        try jsonObject(of: line)["schemaVersion"] as? Int
    }

    private func eventName(of line: String) throws -> String? {
        try jsonObject(of: line)["event"] as? String
    }
}
