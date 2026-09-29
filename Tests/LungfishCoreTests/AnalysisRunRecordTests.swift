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
}
