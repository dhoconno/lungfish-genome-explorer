// BlastSubmitCommand+Record.swift - The query copy, request and records of `blast submit`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishWorkflow

/// The query as the result folder keeps it.
struct StagedQuery: Sendable {
    let url: URL
    let sha256: String
    let sequences: [(id: String, sequence: String)]
}

/// An input or output the command refuses before it submits anything.
struct SubmitRefusal: Error {
    let message: String
    let exitCode: CLIExitCode
}

extension BlastCommand.SubmitSubcommand {
    /// Reads the query once, refuses one with no sequence, and publishes its bytes as `query.fasta`
    /// in the result folder through `DurableReplace`, hashing the same bytes once (SWIFT 4, 5). A
    /// folder that already holds a result is refused, so no run replaces another's record.
    func stageQuery(into output: URL) throws -> StagedQuery {
        let source = URL(fileURLWithPath: queryPath)
        guard let data = try? Data(contentsOf: source) else {
            throw SubmitRefusal(message: "Query FASTA not found or unreadable: \(queryPath)", exitCode: .inputError)
        }
        let sequences = Self.parseFASTA(data)
        guard !sequences.isEmpty else {
            throw SubmitRefusal(message: "Query FASTA holds no sequence: \(queryPath)", exitCode: .inputError)
        }
        let recordURL = output.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        guard !FileManager.default.fileExists(atPath: recordURL.path) else {
            throw SubmitRefusal(message: "\(output.path) already holds a BLAST result", exitCode: .outputError)
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try DurableReplace.replace(data, named: BlastSubmissionRecord.queryFileName, in: output)
        } catch {
            throw SubmitRefusal(
                message: "Could not copy the query into \(output.path): \(error.localizedDescription)",
                exitCode: .outputError
            )
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return StagedQuery(
            url: output.appendingPathComponent(BlastSubmissionRecord.queryFileName),
            sha256: digest,
            sequences: sequences
        )
    }

    /// The sequences of a FASTA file, each named by its whole header line, so a query that
    /// `BlastVerificationRequest.toMultiFASTA()` wrote reaches NCBI as the same bytes.
    static func parseFASTA(_ data: Data) -> [(id: String, sequence: String)] {
        var sequences: [(id: String, sequence: String)] = []
        var id: String?
        var residues = ""
        func finish() {
            if let id, !residues.isEmpty { sequences.append((id: id, sequence: residues)) }
        }
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.hasPrefix(">") {
                finish()
                id = String(line.dropFirst())
                residues = ""
            } else if id != nil {
                residues += line.filter { !$0.isWhitespace }
            }
        }
        finish()
        return sequences
    }

    /// The request `sequences` make with this command's options.
    func makeRequest(sequences: [(id: String, sequence: String)]) -> BlastVerificationRequest {
        BlastVerificationRequest(
            taxonName: label ?? URL(fileURLWithPath: queryPath).deletingPathExtension().lastPathComponent,
            taxId: taxId ?? 0,
            sequences: sequences,
            database: database,
            entrezQuery: entrezQuery,
            extraArgs: extraArgs,
            acceptedTaxIds: Set(acceptedTaxIds),
            acceptedTaxonNames: acceptedNames,
            relatedTaxIds: Set(relatedTaxIds),
            relatedTaxonNames: relatedNames
        )
    }

    /// The lineage the options name, as a record at `recordURL` keeps it. A source result in the record's
    /// project becomes `@/<path in the project>` through `PortablePath`, so the lineage survives a move of
    /// the project and names no account (BIO 6, 2.12 lane 12.08). A record outside any project keeps the
    /// path as given, the way `PortablePath.Context.forWriting` leaves such records.
    func lineage(recordAt recordURL: URL) -> BlastSubmissionRecord.Lineage {
        let portableSource = sourceResult.map { path in
            PortablePath.Context.forWriting(at: recordURL).map { PortablePath.sanitize(path: path, context: $0) } ?? path
        }
        return BlastSubmissionRecord.Lineage(
            sourceResult: portableSource, sample: sample, taxId: taxId, contig: contig,
            subsampleCount: subsampleCount, subsampleSeed: subsampleSeed
        )
    }

    /// The query and lineage as provenance options, each one present only when given.
    func explicitOptions(query: StagedQuery) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "query": .file(query.url),
            "querySHA256": .string(query.sha256),
            "sequenceCount": .integer(query.sequences.count),
            "database": .string(database),
        ]
        if let label { options["name"] = .string(label) }
        if let taxId { options["taxId"] = .integer(taxId) }
        if let contig { options["contig"] = .string(contig) }
        if let sourceResult { options["sourceResult"] = .string(sourceResult) }
        if let sample { options["sample"] = .string(sample) }
        if let subsampleCount { options["subsampleCount"] = .integer(subsampleCount) }
        if let subsampleSeed { options["subsampleSeed"] = .string(String(subsampleSeed)) }
        if let entrezQuery { options["entrezQuery"] = .string(entrezQuery) }
        if !extraArgs.isEmpty { options["extraArgs"] = .string(extraArgs) }
        return options
    }

    /// Writes `blast-result.json` with its provenance, whose source is the query copy, so the
    /// provenance fingerprints the file the record names. Returns the record's URL.
    func writeRecord(
        result: BlastVerificationResult,
        request: BlastVerificationRequest,
        query: StagedQuery,
        in output: URL,
        runClock: ProvenanceRunClock
    ) throws -> URL {
        let recordURL = output.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        let record = BlastSubmissionRecord(
            savedAt: Date(),
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: query.sha256, sequenceCount: query.sequences.count),
            lineage: lineage(recordAt: recordURL),
            search: .init(request),
            result: result
        )
        let data = try BlastSubmissionRecord.encoder.encode(record)
        var explicit = explicitOptions(query: query)
        explicit["outputPath"] = .file(recordURL)
        let provenance = ScientificFileExportProvenance.Request(
            workflowName: Self.workflowName,
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: [query.url],
            outputURL: recordURL,
            outputFormat: .json,
            argv: recordedCommandLine(),
            explicitOptions: explicit,
            resolved: [
                "rid": .string(result.rid),
                "supportingCount": .integer(result.supportingCount),
                "contradictingCount": .integer(result.contradictingCount),
                "errorCount": .integer(result.errorCount),
                "totalReads": .integer(result.totalReads),
            ],
            runClock: runClock
        )
        let sidecar = try ScientificFileExportProvenance.writeAtomically(provenance) { staged in
            try data.write(to: staged, options: .atomic)
        }
        try Self.signRecord(sidecar: sidecar)
        return recordURL
    }

    /// Signs the provenance of the record the way the other leaves sign theirs (ARCH 3). The export
    /// writer leaves its sidecars unsigned, so the leaf writes the same envelope again through
    /// `ProvenanceWriter` with the provider `LUNGFISH_PROVENANCE_SIGNING_KEY` or
    /// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` names, which adds the signature and public key files
    /// beside it and lets `provenance verify` check it. With no key set the sidecar stays as written.
    static func signRecord(
        sidecar: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let provider = ProvenanceSigningConfiguration.defaultProvider(environment: environment),
              let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: sidecar) else { return }
        try ProvenanceWriter(signingProvider: provider).write(envelope, toSidecar: sidecar)
    }

    /// The record of a run that SIGTERM cancelled, in the result folder beside the query copy.
    func writeCancelledRecord(in output: URL, query: StagedQuery, startedAt: Date) {
        let record = CancelledAlignmentWorkflowRecord(
            workflow: Self.workflowName,
            argv: recordedCommandLine(),
            explicit: explicitOptions(query: query),
            note: "SIGTERM cancelled the BLAST search. No result was saved, and the folder keeps the query copy.",
            startedAt: startedAt,
            url: CancelledAlignmentWorkflowRecord.newURL(in: output, workflow: Self.workflowName)
        )
        do {
            try record.write()
        } catch {
            FileHandle.standardError.write(Data("Warning: could not write the cancelled record: \(error.localizedDescription)\n".utf8))
        }
    }

    /// The record of a search that failed, in the result folder beside the query copy (BIO 4, 2.12 lane
    /// 12.08), so a person who opens the folder sees why it holds no result. Its status is `failed`, its
    /// exit status that of the leaf, and its standard error the leaf's `message`. The record is the one a
    /// cancel writes in the same place, with that status in place of `cancelled`.
    func writeFailedRecord(in output: URL, query: StagedQuery, startedAt: Date, message: String) {
        let argv = recordedCommandLine()
        let explicit = explicitOptions(query: query)
        let builder = ProvenanceRunBuilder(
            workflowName: Self.workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: Self.workflowName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(explicit: explicit, defaults: [:], resolved: explicit)
        .runtime(ProvenanceRuntimeIdentity())
        do {
            let envelope = try builder.complete(
                exitStatus: Int(CLIExitCode.failure.rawValue), status: .failed, stderr: message,
                startedAt: startedAt, endedAt: Date()
            )
            let url = CancelledAlignmentWorkflowRecord.newURL(in: output, workflow: Self.workflowName)
            try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: url)
        } catch {
            FileHandle.standardError.write(Data("Warning: could not write the failed record: \(error.localizedDescription)\n".utf8))
        }
    }

    /// The command this process was started with when it names `blast submit`, as typed, else the
    /// command its parsed options name (a test runs the command inside another process).
    func recordedCommandLine(arguments: [String] = CommandLine.arguments) -> [String] {
        let words = arguments.dropFirst()
        if zip(words, words.dropFirst()).contains(where: { $0 == "blast" && $1 == "submit" }) {
            return [CLICommandIdentity.executableName] + Array(words)
        }
        var argv = [CLICommandIdentity.executableName, "blast", "submit", "--query", queryPath, "--output", outputPath]
        if let label { argv += ["--name", label] }
        if let taxId { argv += ["--taxid", String(taxId)] }
        if let contig { argv += ["--contig", contig] }
        if let sourceResult { argv += ["--source-result", sourceResult] }
        if let sample { argv += ["--sample", sample] }
        if let subsampleCount { argv += ["--subsample-count", String(subsampleCount)] }
        if let subsampleSeed { argv += ["--subsample-seed", String(subsampleSeed)] }
        if database != BlastDatabaseID.coreNT.rawValue { argv += ["--database", database] }
        if let entrezQuery { argv += ["--entrez-query", entrezQuery] }
        return argv
    }
}
