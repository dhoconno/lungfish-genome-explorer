// BAMConsensusSubcommand.swift - lungfish-cli bam consensus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Calls an evidence-only consensus for a region of a BAM or CRAM and writes it with its record, the
/// viewer's Generate Consensus (Phase 2.10 lane A51, census row 27, panel C14).
///
/// It hashes the evidence, reads the contig's length from the header, filters the reads with
/// `samtools view`, calls them with `samtools consensus`, and publishes one base per reference
/// position through `AlignmentConsensusPublicationService`. A result whose every position is below
/// the minimum depth is refused with exit 3 before anything is written, unless the run is given
/// `--allow-all-low-depth`. SIGTERM, the app's Cancel, stops the run before it writes, records it as
/// cancelled beside `--output` and exits 125. With `--format json` standard output holds only
/// `CLIEvent` lines.
struct BAMConsensusSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "consensus",
        abstract: "Call an evidence-only consensus for a region of a BAM or CRAM",
        discussion: """
            Writes one base per reference position of the region. A position covered by fewer than \
            --min-depth reads after the filters is N, and the reference never fills one. An output \
            ending in .lungfishref is written as a reference bundle with its record inside, and any \
            other as a FASTA with its record beside it. A consensus that is N at every position is \
            refused with exit 3 unless --allow-all-low-depth is given.
            """
    )

    static let startMessage = "Calling evidence-only consensus…"

    @Option(name: .customLong("alignment"), help: "Path to the sorted BAM or CRAM")
    var alignmentPath: String

    @Option(name: .customLong("index"), help: "Path to the alignment's index (.bai, .csi or .crai)")
    var indexPath: String

    @Option(name: .customLong("decoding-reference"), help: "FASTA that decodes a CRAM")
    var decodingReferencePath: String?

    @Option(name: .customLong("scope"), help: "wholeContig or selectedRegion, recorded with the run")
    var scope: String = AlignmentConsensusScope.selectedRegion.rawValue

    @Option(name: .customLong("region"), help: "Region as contig:start-end, 1-based and inclusive, as samtools takes it")
    var region: String

    @Option(name: .customLong("min-depth"), help: "Fewest reads that call a base. Fewer give N")
    var minimumDepth: Int = 1

    @Option(name: .customLong("min-mapq"), help: "Lowest mapping quality of a read that counts")
    var minimumMapQ: Int = 0

    @Option(name: .customLong("min-baseq"), help: "Lowest base quality of a base that counts")
    var minimumBaseQuality: Int = 0

    @Option(name: .customLong("exclude-flags"), help: "SAM flag bits of the reads left out")
    var excludedFlags: Int = 0x904

    @Option(name: .customLong("read-group"), help: "Read group to keep. Repeat for more. All when none is given")
    var readGroups: [String] = []

    @Option(name: .customLong("caller-mode"), help: "samtools consensus mode, bayesian or simple")
    var callerMode: String = AlignmentConsensusMode.bayesian.rawValue

    @Option(name: .customLong("use-ambiguity"), help: "Write IUPAC ambiguity codes, true or false")
    var useAmbiguity: Bool = false

    @Option(name: .customLong("insertion-policy"), help: "omit, the only policy, one base per reference position")
    var insertionPolicy: String = AlignmentConsensusRequest.InsertionPolicy.omit.rawValue

    @Option(name: .customLong("deletion-policy"), help: "n, the only policy, a deleted position is N")
    var deletionPolicy: String = AlignmentConsensusRequest.DeletionPolicy.n.rawValue

    @Option(name: .customLong("reference-fill"), help: "never, the only policy, the reference never fills a base")
    var referenceFill: String = "never"

    @Option(name: .customLong("name"), help: "FASTA header and bundle name. Default: <contig> consensus")
    var name: String?

    @Option(name: .customLong("result-id"), help: "Analysis result the alignment belongs to, a bundle's source assembly. Default: the alignment's name")
    var resultID: String?

    @Option(name: [.customShort("o"), .customLong("output")], help: "Output FASTA, or a .lungfishref bundle")
    var outputPath: String

    @Flag(name: .customLong("allow-all-low-depth"), help: "Write a consensus that is N at every position")
    var allowAllLowDepth = false

    @OptionGroup var globalOptions: TextAndJSONGlobalOptions

    func validate() throws {
        guard GenomicRegionArgument.parseRegion(region) != nil else {
            throw ValidationError("--region must be contig:start-end, 1-based and inclusive, such as chr1:101-200.")
        }
        guard AlignmentConsensusScope(rawValue: scope) != nil else {
            throw ValidationError("--scope must be wholeContig or selectedRegion.")
        }
        guard AlignmentConsensusMode(rawValue: callerMode) != nil else {
            throw ValidationError("--caller-mode must be bayesian or simple.")
        }
        guard minimumDepth >= 0, minimumMapQ >= 0, minimumBaseQuality >= 0 else {
            throw ValidationError("--min-depth, --min-mapq and --min-baseq must not be negative.")
        }
        guard (0...Int(UInt16.max)).contains(excludedFlags) else {
            throw ValidationError("--exclude-flags must be a SAM flag value from 0 to 65535.")
        }
        guard insertionPolicy == "omit", deletionPolicy == "n", referenceFill == "never" else {
            throw ValidationError("bam consensus writes one base per reference position, so it takes --insertion-policy omit, --deletion-policy n and --reference-fill never only.")
        }
        for (option, value) in [("--output", outputPath), ("--name", name ?? "consensus"), ("--result-id", resultID ?? "result")]
        where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("\(option) must not be empty.")
        }
    }

    func run() async throws {
        let options = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
        try await execute(eventsOn: options.outputFormat == .json, quiet: options.quiet, emit: printEventLine)
    }

    /// The run, with each event line handed to `emit`, so a test can keep them.
    func execute(eventsOn: Bool, quiet: Bool, emit: @escaping (String) -> Void) async throws {
        let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
        let say: (String) -> Void = { text in
            if eventsOn || !quiet { printHumanLine(text, eventsOn: eventsOn) }
        }
        let plan = try makePlan()
        if let refusal = plan.refusal() {
            throw refuse(refusal, events)
        }
        events.emitStart(Self.startMessage)
        say(Self.startMessage)

        let startedAt = Date()
        switch await consensusCancellingOnSIGTERM(plan) {
        case .success(.published(let publication, let records)):
            records.forEach { say($0.reproducibleCommand) }
            let bundle = plan.destination.isBundle
            let message = bundle ? "Consensus reference bundle created" : "Consensus FASTA saved"
            let outputs = bundle ? [publication.finalURL.path] : [publication.finalURL.path, publication.provenanceURL.path]
            events.emitComplete(outputs: outputs, message: message)
            say(message)
        case .success(.refused(let message, let records)):
            records.forEach { say($0.reproducibleCommand) }
            throw refuse(message, events)
        case .failure(let error) where error is CancellationError:
            _ = try? AlignmentConsensusPublicationService.recordCancelledRun(
                plan.invocation, outputURL: plan.destination.finalURL, startedAt: startedAt
            )
            events.emitFailed("Consensus cancelled. Nothing was written.")
            say("Consensus cancelled. Nothing was written.")
            throw CLIExitCode.cancelled.exitCode
        case .failure(let error):
            for line in Self.failureLog(error) {
                events.emitLog(.error, line)
            }
            events.emitFailed(CLIFailureWords.describe(error))
            say("Error: \(CLIFailureWords.describe(error))")
            throw CLIExitCode.workflowError.exitCode
        }
    }

    /// The run's inputs, with its paths resolved from the folder it runs in.
    private func makePlan() throws -> Plan {
        // validate() has checked each of these.
        let parsed = GenomicRegionArgument.parseRegion(region)!
        let alignmentURL = URL(fileURLWithPath: alignmentPath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let destination: AlignmentConsensusPublicationDestination = outputURL.pathExtension.lowercased() == "lungfishref"
            ? .referenceBundle(outputURL) : .fasta(outputURL)
        let filters = AlignmentConsensusFilters(
            minimumDepth: minimumDepth,
            minimumMapQ: minimumMapQ,
            minimumBaseQuality: minimumBaseQuality,
            excludedFlags: UInt16(excludedFlags),
            readGroups: Set(readGroups)
        )
        let invocation = AlignmentConsensusInvocation(
            alignmentURL: alignmentURL,
            indexURL: URL(fileURLWithPath: indexPath),
            decodingReferenceURL: decodingReferencePath.map { URL(fileURLWithPath: $0) },
            region: ResolvedAlignmentRegion(
                scope: AlignmentConsensusScope(rawValue: scope)!,
                contig: parsed.contig, start: parsed.start, end: parsed.end
            ),
            consensusRequest: AlignmentConsensusRequest(
                chromosome: parsed.contig, start: parsed.start, end: parsed.end, filters: filters,
                mode: AlignmentConsensusMode(rawValue: callerMode)!, useAmbiguity: useAmbiguity,
                insertionPolicy: .omit, deletionPolicy: .n
            ),
            recordName: name ?? "\(parsed.contig) consensus",
            resultID: resultID ?? alignmentURL.deletingPathExtension().lastPathComponent,
            output: outputURL.path,
            allowAllLowDepth: allowAllLowDepth
        )
        return Plan(invocation: invocation, destination: destination)
    }

    /// Runs the consensus so that SIGTERM cancels it instead of ending the command. The command
    /// listens before the task starts, so a SIGTERM caught before then cancels the task as soon as it
    /// exists, and a second SIGTERM ends the command at once.
    private func consensusCancellingOnSIGTERM(_ plan: Plan) async -> Result<Outcome, any Error> {
        let pendingCancel = PendingTaskCancel<Result<Outcome, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        defer { termination.end() }
        let task = Task { () -> Result<Outcome, any Error> in
            do {
                return .success(try await Self.consensus(plan))
            } catch {
                // A tool stopped by the cancel fails with its own error, which is the cancel.
                return .failure(Task.isCancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        return await task.value
    }

    /// A refusal before anything was written, which exits 3 and names the fix.
    private func refuse(_ message: String, _ events: CLIEventEmitter) -> ExitCode {
        events.emitFailed(message)
        printHumanLine("Error: \(message)", eventsOn: true)
        return CLIExitCode.inputError.exitCode
    }
}
