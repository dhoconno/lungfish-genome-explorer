// AnalysisRunRecordTests.swift - In-progress record for analysis result directories
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing
@testable import LungfishCore

struct AnalysisRunRecordTests {

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func directoryWithoutRecordIsComplete() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AnalysisRunRecord.isIncomplete(dir))
        #expect(AnalysisRunRecord.load(from: dir) == nil)
    }

    @Test
    func beginRoundTripsAndMarkCompleteRemovesRecord() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = AnalysisRunRecord(
            analysisName: "TaxTriage",
            command: "lungfish-cli taxtriage --input a.fastq",
            startedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        try AnalysisRunRecord.begin(record, in: dir)

        #expect(AnalysisRunRecord.isIncomplete(dir))
        let loaded = try #require(AnalysisRunRecord.load(from: dir))
        #expect(loaded == record)
        #expect(loaded.processIdentifier == getpid())
        #expect(loaded.hostName == AnalysisRunRecord.currentHostName())

        #expect(AnalysisRunRecord.markComplete(dir))
        #expect(!AnalysisRunRecord.isIncomplete(dir))
        #expect(!AnalysisRunRecord.markComplete(dir))
    }

    @Test
    func recordFileIsHidden() {
        #expect(AnalysisRunRecord.fileName.hasPrefix("."))
    }

    @Test
    func updateCommandOnlyTouchesIncompleteDirectories() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        AnalysisRunRecord.updateCommand("lungfish-cli map", in: dir)
        #expect(!AnalysisRunRecord.isIncomplete(dir))

        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "Minimap2"), in: dir)
        AnalysisRunRecord.updateCommand("lungfish-cli map", in: dir)
        #expect(AnalysisRunRecord.load(from: dir)?.command == "lungfish-cli map")
    }

    @Test
    func currentProcessIsRunning() {
        let record = AnalysisRunRecord(analysisName: "Kraken2")
        #expect(record.liveness() == .running)
    }

    @Test
    func deadProducerOnThisHostIsInterrupted() {
        let record = AnalysisRunRecord(
            analysisName: "Kraken2",
            hostName: "lab-mac",
            processIdentifier: 4242,
            processStartTime: 1
        )
        let liveness = record.liveness(currentHostName: "lab-mac") { _ in .notRunning }
        #expect(liveness == .interrupted)
    }

    @Test
    func reusedPIDIsInterrupted() {
        let record = AnalysisRunRecord(
            analysisName: "Kraken2",
            hostName: "lab-mac",
            processIdentifier: 4242,
            processStartTime: 1
        )
        let liveness = record.liveness(currentHostName: "lab-mac") { _ in .running(startTime: 2) }
        #expect(liveness == .interrupted)
    }

    @Test
    func otherHostIsNeverInterrupted() {
        let record = AnalysisRunRecord(
            analysisName: "Kraken2",
            hostName: "other-mac",
            processIdentifier: 4242,
            processStartTime: 1
        )
        let liveness = record.liveness(currentHostName: "lab-mac") { _ in .notRunning }
        #expect(liveness == .otherHost)
    }

    @Test
    func localSuffixDoesNotMakeAHostDifferent() {
        let record = AnalysisRunRecord(
            analysisName: "Kraken2",
            hostName: "Lab-Mac.local",
            processIdentifier: 4242,
            processStartTime: nil
        )
        let liveness = record.liveness(currentHostName: "lab-mac") { _ in .running(startTime: 9) }
        #expect(liveness == .running)
    }

    // MARK: - beginRun / completeRun

    @Test
    func beginRunCreatesMissingDirectoryWithRecordAndParents() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Analyses/Genotypes/run.lungfishgenotype", isDirectory: true)

        let claim = try AnalysisRunRecord.beginRun(in: dir, record: AnalysisRunRecord(analysisName: "Genotyping"))

        #expect(claim == .owned)
        #expect(AnalysisRunRecord.isIncomplete(dir))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        #expect(siblings == ["run.lungfishgenotype"], "no staging directory is left behind")
        #expect(AnalysisRunRecord.completeRun(claim, in: dir))
        #expect(!AnalysisRunRecord.isIncomplete(dir))
    }

    @Test
    func beginRunClaimsExistingDirectoryWithoutRecord() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claim = try AnalysisRunRecord.beginRun(in: dir, record: AnalysisRunRecord(analysisName: "Genotyping"))
        #expect(claim == .owned)
        #expect(AnalysisRunRecord.isIncomplete(dir))
    }

    @Test
    func beginRunLeavesALiveProducersRecordAlone() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = AnalysisRunRecord(analysisName: "Genotyping (app)", command: "app", startedAt: Date(timeIntervalSince1970: 1_000_000), processIdentifier: 777, processStartTime: nil)
        try AnalysisRunRecord.begin(parent, in: dir)

        let joiner = AnalysisRunRecord(analysisName: "Genotyping (cli)", processIdentifier: 888, processStartTime: 42)
        let claim = try AnalysisRunRecord.beginRun(
            in: dir,
            record: joiner,
            processProbe: { _ in .running(startTime: nil) }
        )

        #expect(claim == .heldByLiveProducer)
        // The producer's record stands; the joining process is only noted
        // as a participant so its scratch can be attributed to the run.
        var expected = parent
        expected.participants = [.init(processIdentifier: 888, processStartTime: 42)]
        #expect(AnalysisRunRecord.load(from: dir) == expected)
        _ = try AnalysisRunRecord.beginRun(in: dir, record: joiner, processProbe: { _ in .running(startTime: nil) })
        #expect(AnalysisRunRecord.load(from: dir)?.participants?.count == 1)
        // Finishing does not complete a directory a live producer still decides.
        let completedWhileLauncherLives = AnalysisRunRecord.completeRun(claim, in: dir, processProbe: { _ in .running(startTime: nil) })
        #expect(!completedWhileLauncherLives)
        #expect(AnalysisRunRecord.isIncomplete(dir))
        // Once that producer is gone, the finished run completes it.
        let completedAfterLauncherQuit = AnalysisRunRecord.completeRun(claim, in: dir, processProbe: { _ in .notRunning })
        #expect(completedAfterLauncherQuit)
        #expect(!AnalysisRunRecord.isIncomplete(dir))
    }

    @Test
    func beginRunTakesOverADeadProducersRecord() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisRunRecord.begin(
            AnalysisRunRecord(analysisName: "Old", processIdentifier: 777, processStartTime: 1),
            in: dir
        )
        let fresh = AnalysisRunRecord(analysisName: "New", startedAt: Date(timeIntervalSince1970: 1_000_000))
        let claim = try AnalysisRunRecord.beginRun(in: dir, record: fresh, processProbe: { _ in .notRunning })
        #expect(claim == .owned)
        #expect(AnalysisRunRecord.load(from: dir) == fresh)
    }

    @Test
    func beginRunRefusesAFile() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("taken")
        try Data().write(to: file)
        #expect(throws: (any Error).self) {
            _ = try AnalysisRunRecord.beginRun(in: file, record: AnalysisRunRecord(analysisName: "X"))
        }
    }

    @Test
    func recordsWithoutParticipantsStillDecode() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"analysisName":"Old","hostName":"h","processIdentifier":5,"schemaVersion":1,"startedAt":"2026-09-01T00:00:00Z"}
        """
        try Data(json.utf8).write(to: AnalysisRunRecord.url(in: dir))
        let record = try #require(AnalysisRunRecord.load(from: dir))
        #expect(record.participants == nil)
        #expect(record.producerProcesses == [.init(processIdentifier: 5, processStartTime: nil)])
    }
}
