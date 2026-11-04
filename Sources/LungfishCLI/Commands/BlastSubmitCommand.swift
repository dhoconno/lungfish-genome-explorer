// BlastSubmitCommand.swift - `blast submit`, BLAST the sequences of a query FASTA against NCBI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishWorkflow

extension BlastCommand {

    /// BLASTs every sequence of a FASTA file and saves the result beside a copy of the query (Phase 2.11
    /// lane A65, plan decision C1). The viewers' BLAST actions write their reads or contigs to a query
    /// file and run this leaf, so the row of each one names a command. The query reaches NCBI from the
    /// file and never as command-line text. SIGTERM cancels the search, records the run as cancelled
    /// and exits 125, as the app's other CLI routes do.
    struct SubmitSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "submit",
            abstract: "BLAST the sequences of a FASTA file against NCBI",
            discussion: """
            Submits every sequence of the query FASTA to NCBI BLAST and saves the result in the \
            --output folder, beside a copy of the query. The record names the copy's SHA-256 and \
            the lineage options, which say which result, sample, taxon or contig and which \
            subsample the sequences came from.

            \(BlastSearchWords.commandLineConsent(stays: "in --output"))
            """
        )

        static let workflowName = "lungfish blast submit"

        // MARK: - Options

        @Option(name: .customLong("query"), help: "FASTA file of the sequences to BLAST")
        var queryPath: String

        @Option(
            name: .customLong("output"),
            help: "Result folder to create, which gets query.fasta, blast-result.json and its provenance"
        )
        var outputPath: String

        @Option(name: .customLong("name"), help: "Label of the search in the result (default: the query's file name)")
        var label: String?

        @Option(
            name: .customLong("taxid"),
            help: "Taxon the sequences were assigned to, recorded. --accepted-taxid and --accepted-name judge hits, or else the --name label"
        )
        var taxId: Int?

        @Option(name: .customLong("contig"), help: "Contig the sequences are, or came from, recorded")
        var contig: String?

        @Option(name: .customLong("source-result"), help: "Result folder the sequences came from, recorded")
        var sourceResult: String?

        @Option(name: .customLong("sample"), help: "Sample the sequences came from, recorded")
        var sample: String?

        @Option(name: .customLong("subsample-count"), help: "Number of sequences a subsample drew, recorded")
        var subsampleCount: Int?

        @Option(name: .customLong("subsample-seed"), help: "Seed of that subsample, recorded")
        var subsampleSeed: UInt64?

        @Option(name: .customLong("database"), help: "BLAST database to search")
        var database: String = BlastDatabaseID.coreNT.rawValue

        @Option(name: .customLong("entrez-query"), help: "Entrez query that restricts the search, for example txid11320[Organism:exp]")
        var entrezQuery: String?

        @Option(name: .customLong("accepted-taxid"), help: "Taxon whose hits support the assignment (repeatable)")
        var acceptedTaxIds: [Int] = []

        @Option(name: .customLong("accepted-name"), help: "Organism name whose hits support the assignment (repeatable)")
        var acceptedNames: [String] = []

        @Option(name: .customLong("related-taxid"), help: "Taxon whose hits count as a relative (repeatable)")
        var relatedTaxIds: [Int] = []

        @Option(name: .customLong("related-name"), help: "Organism name whose hits count as a relative (repeatable)")
        var relatedNames: [String] = []

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional BLAST URL API parameters as KEY=VALUE tokens (for example WORD_SIZE=11)"
        )
        var extraArgs: String = ""

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            if let subsampleCount, subsampleCount < 1 {
                throw ValidationError("--subsample-count must be at least 1")
            }
            _ = try BlastVerificationRequest.parseBlastURLAPIExtraParameters(extraArgs)
        }

        // MARK: - Run

        /// The message of the leaf's complete event. `reads` counts the rows, which are fragments when read pairs
        /// were sent, and ` sent=M` then says how many sequences went to NCBI.
        static func completionSummary(for result: BlastVerificationResult) -> String {
            let summary = "rid=\(result.rid) supporting=\(result.supportingCount) contradicting=\(result.contradictingCount) reads=\(result.totalReads)"
            return result.judgedSequenceCount == result.totalReads ? summary : summary + " sent=\(result.judgedSequenceCount)"
        }

        func run() async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
            let chatty = !eventsOn && !globalOptions.quiet
            let runClock = ProvenanceRunClock()
            let output = URL(fileURLWithPath: outputPath).absoluteURL.standardizedFileURL
            events.emitStart("Preparing to BLAST \(URL(fileURLWithPath: queryPath).lastPathComponent)")

            let query: StagedQuery
            do {
                query = try stageQuery(into: output)
            } catch let refusal as SubmitRefusal {
                events.emitFailed(refusal.message)
                FileHandle.standardError.write(Data("Error: \(refusal.message)\n".utf8))
                throw refusal.exitCode.exitCode
            }

            let request = makeRequest(sequences: query.sequences)
            if chatty { print("\(BlastSearchWords.sending(query.sequences.count, noun: "sequences"))...") }
            let environment = ProcessInfo.processInfo.environment
            let clock = await BlastCommand.searchClock(environment: environment)
            let submitArgv = recordedCommandLine()
            let outcome = await runCancellingOnSIGTERM { [self] in
                try await BlastService.shared.search(
                    request: request,
                    in: output,
                    query: BlastSubmissionRecord.Query(
                        fileName: BlastSubmissionRecord.queryFileName,
                        sha256: query.sha256,
                        sequenceCount: query.sequences.count
                    ),
                    submitArgv: submitArgv,
                    origin: BlastSearchFile.Origin(environment: environment),
                    clock: clock,
                    noun: "sequences",
                    progress: { events.emitProgress($0, message: $1) },
                    publish: { result in
                        try publishRecord(result: result, request: request, query: query, in: output, runClock: runClock, argv: nil)
                    }
                )
            }

            switch outcome {
            case .success(let ending):
                try finishSearch(ending, output: output, query: query, events: events, chatty: chatty, startedAt: runClock.startedAt)
            case .failure(let error) where error is CancellationError:
                writeCancelledRecord(in: output, query: query, startedAt: runClock.startedAt)
                FileHandle.standardError.write(Data("BLAST search cancelled. No result was saved.\n".utf8))
                throw CLIExitCode.cancelled.exitCode
            case .failure(let error):
                let message = "BLAST search failed: \(error.localizedDescription)"
                writeFailedRecord(in: output, query: query, startedAt: runClock.startedAt, message: message)
                events.emitFailed(message)
                FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
                throw CLIExitCode.failure.exitCode
            }
        }
    }
}
