// BlastResumeCommand.swift - `blast resume`, go on with a BLAST search from its result folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension BlastCommand {

    /// The clock of a search in this run. The storage root is read only for a stand-in, whose shared folder it
    /// must stay out of.
    static func searchClock(environment: [String: String] = ProcessInfo.processInfo.environment) async -> BlastSearchClock {
        guard BlastStandInState(environment: environment) != nil else { return .system }
        let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
        return BlastSearchClock(
            environment: environment,
            sharedFolder: BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
        )
    }

    /// What a leaf says when SIGTERM ends it. The search stays at NCBI and nothing is recorded as cancelled, since only a
    /// person's Stop ends a search (ARCH-BLAST-RESILIENCE item 14, UX-BLAST-WORDS Q3).
    static func sayLeftForLater(output: URL) {
        let rid = (try? BlastSearchStore(folder: output).load())?.copies.compactMap(\.rid).last
        let words = rid.map { BlastSearchWords.leftAtNCBI(rid: $0, folder: output.path) } ?? BlastSearchWords.stoppedBeforeAnAnswer
        FileHandle.standardError.write(Data("\(words)\n".utf8))
    }

    /// Goes on with a search from `blast-search.json` in its result folder, until NCBI's answer or the person ends it
    /// (ARCH-BLAST-RESILIENCE item 13). It uses the request IDs the file holds, and a search NCBI already has is not
    /// sent again. With `--once` it makes one pass of what is due and exits 75 while the search waits. Only one process at
    /// a time advances a search, and a folder that is a copy of the one the search's line names never POSTs. SIGTERM
    /// exits 125 and leaves the file as it stands, so the search lives on.
    struct ResumeSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Go on with a BLAST search from its result folder",
            discussion: """
            Reads blast-search.json in the --output folder, goes on from where the search stands with the \
            request IDs it holds, and saves the result there. SIGTERM exits 125 and leaves the search as it \
            stands, so another resume can go on with it. --once makes one pass of what is due and exits 75 with a \
            waiting event while the search stays at NCBI. A search someone stopped is taken up again.
            """
        )

        @Option(name: .customLong("output"), help: "Result folder that holds the search's blast-search.json")
        var outputPath: String

        @Flag(name: .customLong("once"), help: "Make one pass of what is due, then exit, with 75 while the search still waits")
        var once = false

        @Flag(name: .customLong("check-now"), help: "Check every send now, as often as NCBI allows, whatever its next check says")
        var checkNow = false

        @Flag(name: .customLong("send-again"), help: "Send the same sequences to NCBI once more, as a person's own choice")
        var sendAgain = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
            let chatty = !eventsOn && !globalOptions.quiet
            let runClock = ProvenanceRunClock()
            let output = URL(fileURLWithPath: outputPath).absoluteURL.standardizedFileURL
            events.emitStart("Going on with the BLAST search in \(output.lastPathComponent)")

            func stop(_ message: String, exit: CLIExitCode) -> ExitCode {
                events.emitFailed(message)
                FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
                return exit.exitCode
            }
            func wait(_ words: String, _ state: CLIEventWaitingState) {
                events.emit(.waiting(message: words, state: state))
                if chatty { print(words) }
            }

            let index = await BlastService.shared.searchShared.inFlight
            if !FileManager.default.fileExists(atPath: output.path), let line = await index?.line(forOutput: output) {
                wait(BlastSearchWords.folderMissing(path: output.path, rid: line.rids.last), .folderMissing)
                throw CLIExitCode.parked.exitCode
            }

            let store = BlastSearchStore(folder: output)
            store.recoverInterruptedSwap()
            let found: BlastSearchFile
            do {
                found = try store.load()
            } catch {
                throw stop(error.localizedDescription, exit: .inputError)
            }
            let environment = ProcessInfo.processInfo.environment
            guard found.origin.allowsContact(environment: environment) else {
                throw stop(
                    "This BLAST search belongs to \(found.origin == .standIn ? "a test stand-in" : "NCBI"), and this run talks to the other, so LGE contacted neither and left the search as it is.",
                    exit: .inputError
                )
            }
            if case .heldByAnother = await index?.takeLock(of: found.searchID) {
                wait(BlastSearchWords.alreadyRunning, .alreadyRunning)
                return
            }
            // Read again under the lock, since the process that held it may have moved the search on.
            var file: BlastSearchFile
            do {
                file = try store.load()
            } catch {
                throw stop(error.localizedDescription, exit: .inputError)
            }
            let queryURL = output.appendingPathComponent(file.query.fileName)
            guard let queryData = try? Data(contentsOf: queryURL) else {
                throw stop("The query of this BLAST search is missing from \(output.path). Choose the folder that holds \(file.query.fileName).", exit: .inputError)
            }
            let sequences = SubmitSubcommand.parseFASTA(queryData)
            let query = StagedQuery(url: queryURL, sha256: file.query.sha256, sequences: sequences)
            let submit: SubmitSubcommand
            do {
                submit = try Self.submitCommand(for: file, in: output)
            } catch {
                throw stop("LGE could not read the command that started this BLAST search: \(error.localizedDescription)", exit: .inputError)
            }

            let recordURL = output.appendingPathComponent(BlastSubmissionRecord.recordFileName)
            if file.state == .done, FileManager.default.fileExists(atPath: recordURL.path) {
                events.emitComplete(outputs: [recordURL.path, queryURL.path], message: file.ending?.words ?? "The result is saved.")
                if chatty { print("This BLAST search is already saved in \(recordURL.path)") }
                return
            }
            let standing = await index?.standing(of: file.searchID, folder: output) ?? .home
            let mayPost = standing != .copy
            let willSendAgain = sendAgain && mayPost
            if file.state.isEnding, file.state != .done, file.state != .stopped, !willSendAgain {
                throw stop(file.ending?.words ?? "This BLAST search has ended.", exit: .failure)
            }

            let replayArgv = file.submitArgv.isEmpty ? nil : file.submitArgv
            let facts = file.facts
            let clock = await BlastCommand.searchClock(environment: environment)
            let advancer = BlastSearchAdvancer(
                service: BlastService.shared,
                store: store,
                request: facts.request(sequences: sequences),
                clock: clock,
                noun: "sequences",
                progress: { events.emitProgress($0, message: $1) },
                publish: { result in
                    try submit.publishRecord(
                        result: result, request: facts.request(sequences: sequences), query: query,
                        in: output, runClock: runClock, argv: replayArgv
                    )
                },
                pass: once ? .once : .toAnEnding,
                index: index,
                mayPost: mayPost
            )
            if file.state == .stopped, !willSendAgain { file.takeUp() }
            if checkNow { file.checkNow(at: clock.now()) }
            let start = file
            let outcome = await runCancellingOnSIGTERM {
                let work: @Sendable () async throws -> BlastSearchOutcome = {
                    // A person's press and a folder taken up are durable before any contact, and the line finds this folder.
                    try await advancer.takeStock(start)
                    let current = willSendAgain ? try await advancer.sendAgain(start) : start
                    return try await advancer.advance(current)
                }
                if let index { return try await index.runStoppable(start.searchID, work) }
                return try await work()
            }
            switch outcome {
            case .failure(let error) where error is CancellationError:
                BlastCommand.sayLeftForLater(output: output)
                throw CLIExitCode.cancelled.exitCode
            case .failure(BlastServiceError.rateLimitExceeded(let refusal)):
                throw stop(BlastSearchWords.limitRefusal(refusal), exit: .failure)
            case .failure(let error):
                throw stop("BLAST search failed: \(error.localizedDescription)", exit: .failure)
            case .success(let ending):
                try submit.finishSearch(ending, output: output, query: query, events: events, chatty: chatty, startedAt: runClock.startedAt)
            }
        }

        /// The `blast submit` that keeps this search's record. A search `blast submit` started parses its own command,
        /// and one `blast verify` started says the same in options, from the file's facts.
        static func submitCommand(for file: BlastSearchFile, in output: URL) throws -> SubmitSubcommand {
            let argv = file.submitArgv
            if let word = argv.firstIndex(of: "submit"), word > 0, argv[word - 1] == "blast",
               let parsed = try? SubmitSubcommand.parse(Array(argv[(word + 1)...])) {
                return parsed
            }
            let facts = file.facts
            var arguments = [
                "--query", output.appendingPathComponent(file.query.fileName).path, "--output", output.path,
                "--name", facts.taxonName, "--database", facts.database,
            ]
            if facts.taxId != 0 { arguments += ["--taxid", String(facts.taxId)] }
            if let entrezQuery = facts.entrezQuery { arguments += ["--entrez-query", entrezQuery] }
            arguments += facts.acceptedTaxIds.flatMap { ["--accepted-taxid", String($0)] }
            arguments += facts.acceptedTaxonNames.flatMap { ["--accepted-name", $0] }
            arguments += facts.relatedTaxIds.flatMap { ["--related-taxid", String($0)] }
            arguments += facts.relatedTaxonNames.flatMap { ["--related-name", $0] }
            return try SubmitSubcommand.parse(arguments)
        }
    }
}
