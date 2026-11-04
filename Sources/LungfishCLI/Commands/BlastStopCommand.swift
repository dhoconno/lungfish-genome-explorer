// BlastStopCommand.swift - `blast stop` and `blast in-flight`, a person's Stop and the list of searches not ended
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension BlastCommand {

    /// A person's Stop. It writes `stopped`, then the cancelled record, and contacts nothing. SIGTERM alone never does
    /// this, since a quit does not stop a search (ARCH-BLAST-RESILIENCE item 14).
    struct StopSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop a BLAST search, so that LGE no longer checks it",
            discussion: """
            Marks the search in the --output folder as stopped and records that it was cancelled. LGE keeps its \
            request IDs and contacts nothing, and NCBI may still finish it. lungfish-cli blast resume --output <folder> \
            takes it up again while NCBI holds it.
            """
        )

        @Option(name: .customLong("output"), help: "Result folder that holds the search's blast-search.json")
        var outputPath: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
            let chatty = !eventsOn && !globalOptions.quiet
            let output = URL(fileURLWithPath: outputPath).absoluteURL.standardizedFileURL
            events.emitStart("Stopping the BLAST search in \(output.lastPathComponent)")

            func refuse(_ message: String, exit: CLIExitCode) -> ExitCode {
                events.emitFailed(message)
                FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
                return exit.exitCode
            }
            func finish(_ words: String) {
                let searchFile = output.appendingPathComponent(BlastSearchFile.fileName)
                events.emitComplete(outputs: [searchFile.path], message: words)
                if chatty { print(words) }
            }

            let store = BlastSearchStore(folder: output)
            store.recoverInterruptedSwap()
            let first: BlastSearchFile
            do {
                first = try store.load()
            } catch {
                throw refuse(error.localizedDescription, exit: .inputError)
            }
            if first.state == .done {
                finish(BlastSearchWords.nothingToStop)
                return
            }

            let shared = await BlastService.shared.searchShared
            if case .heldByAnother = await shared.inFlight?.takeLockForStop(of: first.searchID) {
                throw refuse(BlastSearchWords.stopNotTaken, exit: .failure)
            }
            var file: BlastSearchFile
            do {
                file = try store.load()
            } catch {
                throw refuse(error.localizedDescription, exit: .inputError)
            }
            if file.state == .done {
                finish(BlastSearchWords.nothingToStop)
                return
            }
            if file.state.isEnding {
                finish(file.ending?.words ?? BlastSearchWords.stopped)
                return
            }

            let clock = await BlastCommand.searchClock()
            let now = clock.now()
            file.state = .stopped
            file.ending = BlastSearchFile.Ending(state: .stopped, at: now, words: BlastSearchWords.stopped)
            do {
                try store.save(file)
            } catch {
                throw refuse(BlastSearchWords.fileNotWritten(folder: output.path, reason: error.localizedDescription), exit: .outputError)
            }
            if let submit = try? ResumeSubcommand.submitCommand(for: file, in: output) {
                let queryURL = output.appendingPathComponent(file.query.fileName)
                let query = StagedQuery(
                    url: queryURL, sha256: file.query.sha256,
                    sequences: (try? Data(contentsOf: queryURL)).map(SubmitSubcommand.parseFASTA) ?? []
                )
                // A stand-in's scaled clock can read ahead of the wall clock, and a record cannot end before it started.
                submit.writeCancelledRecord(in: output, query: query, startedAt: min(file.createdAt, Date()))
            }
            await shared.searchLog?.append(BlastSearchLog.line(for: file, at: now, ending: file.state.rawValue, replyBytes: nil))
            await shared.inFlight?.write(BlastInFlightLine(file, output: output, words: BlastSearchWords.stopped, now: now))
            finish(BlastSearchWords.stopped)
        }
    }

    /// Lists the searches that have not ended, reading only under the storage root unless a project is named, so that
    /// a launch never waits on a project folder (ARCH-BLAST-RESILIENCE section 4). A project's opening names its path,
    /// which adopts any search there with no line and any whose line names a folder that has gone (item 18).
    struct InFlightSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "in-flight",
            abstract: "List the BLAST searches that have not ended",
            discussion: """
            Reads the lines under the storage root, each naming a search's result folder, and lists those not ended. A line \
            whose folder has been missing for 72 hours since its last contact is retired, and the search is taken up \
            again when its project reopens. --project also adopts the searches in that project's result folders.
            """
        )

        @Option(name: .customLong("project"), help: "Project folder that has just opened, whose searches this adopts")
        var projectPath: String?

        @OptionGroup var globalOptions: GlobalOptions

        /// The JSON document this leaf prints with `--format json`.
        struct Document: Codable {
            var schemaVersion = 1
            /// One search a line, for one row each.
            var lines: [BlastInFlightLine]
            /// Result folders under `--project` that hold another folder's search, which collect only on a person's press.
            var copies: [String]
        }

        func run() async throws {
            let shared = await BlastService.shared.searchShared
            let clock = await BlastCommand.searchClock()
            let now = clock.now()
            var copies: [String] = []
            if let index = shared.inFlight {
                await Self.retire(in: index, log: shared.searchLog, now: now)
                if let projectPath {
                    copies = await Self.adopt(project: URL(fileURLWithPath: projectPath).absoluteURL, into: index, now: now)
                }
            }
            let live = await shared.inFlight?.lines().filter { !$0.state.isEnding } ?? []
            guard globalOptions.outputFormat == .json else {
                if !globalOptions.quiet {
                    for line in live { print("\(line.label): \(line.words) (\(line.output))") }
                    if live.isEmpty { print("No BLAST search is waiting.") }
                }
                return
            }
            let data = try BlastSubmissionRecord.encoder.encode(Document(lines: live, copies: copies))
            printEventLine(String(decoding: data, as: UTF8.self))
        }

        /// Retires each line past its time. A search whose folder still exists is kept, since a Mac left off for days has
        /// lost nothing, so only a line this old makes a stat of a project path.
        static func retire(in index: BlastInFlightIndex, log: BlastSearchLog?, now: Date) async {
            for line in await index.lines() where now.timeIntervalSince(line.lastContactAt) >= BlastSearchPolicy.lineRetention {
                if line.state.isEnding {
                    await index.remove(line.searchID)
                } else if !FileManager.default.fileExists(atPath: line.output) {
                    await log?.append(BlastSearchLog.retiredLine(for: line, at: now))
                    await index.remove(line.searchID)
                }
            }
        }

        /// Adopts the searches in `project`'s result folders, and returns those that are copies of another folder's.
        static func adopt(project: URL, into index: BlastInFlightIndex, now: Date) async -> [String] {
            let verifications = project.standardizedFileURL
                .appendingPathComponent(BlastVerificationArchive.directoryName, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: verifications.path)) ?? []
            var copies: [String] = []
            for name in names.sorted() where !name.hasPrefix("._") {
                let folder = verifications.appendingPathComponent(name, isDirectory: true)
                let store = BlastSearchStore(folder: folder)
                store.recoverInterruptedSwap()
                guard let file = try? store.load(), !file.state.isEnding else { continue }
                switch await index.standing(of: file.searchID, folder: folder) {
                case .home:
                    break
                case .copy:
                    copies.append(folder.path)
                case .noLine, .moved:
                    let words = BlastSearchWords.adopted(rid: file.copies.compactMap(\.rid).last)
                    await index.write(BlastInFlightLine(file, output: folder, words: words, now: now))
                }
            }
            return copies
        }
    }
}
