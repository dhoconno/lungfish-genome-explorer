// ImportRNASeqSubcommand.swift - `lungfish-cli import rnaseq`, bulk counts another tool made (Phase 5.1 lane RS-BULK-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ImportCommand {
    /// Imports salmon folders, or one plain genes-by-samples table, into a project's `Analyses/` folder as one
    /// `.lungfishrnaseq` result written by `RNASeqResultWriter` (`docs/formats/rnaseq-bundle.md`). The counts stay as
    /// given, gene sums come only from the person's `--tx2gene`, the tool's files are kept byte for byte, and what the
    /// files do not state reads Not recorded in the record. SIGTERM cancels the read and the write on the run's own
    /// task, so a cancel publishes no result and the writer removes its staging folder.
    struct RNASeqSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rnaseq",
            abstract: "Import bulk RNA-seq counts into a project"
        )

        @Argument(help: "salmon quant folders, one count table of genes by samples, or Cell Ranger outs and STARsolo run folders")
        var inputPaths: [String]

        @Option(name: .customLong("project"), help: "Lungfish project directory to import into")
        var projectPath: String

        @Option(name: .customLong("name"), help: "Name of the RNA-seq result")
        var name: String

        @Option(name: .customLong("tx2gene"), help: "Transcript-to-gene table for gene sums of salmon folders")
        var tx2genePath: String?

        @Option(name: .customLong("samples"), help: "Sample sheet (sample, run, animal, species, origin, group)")
        var samplesPath: String?

        @Option(name: .customLong("unit"), help: "Unit of a count table: reads, pairs, umis or estimated")
        var unit: String?

        @Option(name: .customLong("genome"), help: "Gene id prefix of one genome of a single-cell reference of two or more, such as hg19 (repeat for each genome)")
        var genomes: [String] = []

        @Option(name: .customLong("reference-set"), help: "Reference set folder whose not-host sequences a single-cell import counts in each cell and in the ambient pool")
        var referenceSetPath: String?

        @Option(name: .customLong("not-host-bam"), help: "A sample's sorted, indexed BAM as <sample>=<path>, one for each sample with --reference-set (repeat)")
        var notHostBAMValues: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
            let inputs = inputPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let tx2geneURL = tx2genePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let sheetURL = samplesPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let eventsOn = globalOptions.outputFormat == .json
            let emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
            emitter.emitStart(kind: RNASeqResultManifest.kindName)

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let isTable = inputs.count == 1 && !Self.isDirectory(inputs[0])
            let isSingleCell = !inputs.isEmpty && inputs.allSatisfy(SingleCellFolderReader.isSingleCellFolder)
            let countUnit: RNASeqResultManifest.CountEntry.Unit? =
                isTable ? unit.flatMap(RNASeqResultManifest.CountEntry.Unit.init(rawValue:)) : .estimated
            let setURL = referenceSetPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let bams = Self.notHostBAMs(notHostBAMValues)
            if let words = Self.notHostRefusal(isSingleCell: isSingleCell, hasSet: setURL != nil, bams: notHostBAMValues) {
                emitter.emitFailed(words)
                throw CLIExitCode.inputError.exitCode
            }
            if let refusal = Self.refusal(
                project: projectURL, files: inputs + [tx2geneURL, sheetURL, setURL].compactMap { $0 } + bams.map(\.url), name: trimmedName,
                isTable: isTable, inputs: inputs, unit: unit, countUnit: countUnit, hasTx2Gene: tx2geneURL != nil,
                singleCell: (isSingleCell, Self.singleCellRefusal(inputs: inputs, hasTx2Gene: tx2geneURL != nil, unit: unit, genomes: genomes))
            ) {
                emitter.emitFailed(refusal)
                throw CLIExitCode.inputError.exitCode
            }

            var command = [CLICommandIdentity.executableName, "import", "rnaseq"] + inputs.map(\.path)
                + ["--project", projectURL.path, "--name", trimmedName]
            if let tx2geneURL { command += ["--tx2gene", tx2geneURL.path] }
            if let sheetURL { command += ["--samples", sheetURL.path] }
            if isTable, let unit { command += ["--unit", unit] }
            for genome in genomes { command += ["--genome", genome] }
            if let setURL { command += ["--reference-set", setURL.path] }
            for bam in bams { command += ["--not-host-bam", "\(bam.sample)=\(bam.url.path)"] }
            var explicit: [String: ParameterValue] = [
                "inputs": .array(inputs.map(ParameterValue.file)), "project": .file(projectURL), "name": .string(trimmedName),
                "tx2gene": tx2geneURL.map(ParameterValue.file) ?? .null, "samples": sheetURL.map(ParameterValue.file) ?? .null,
                "unit": isTable ? unit.map(ParameterValue.string) ?? .null : .null,
            ]
            if isSingleCell { explicit["genome"] = .array(genomes.map(ParameterValue.string)) }
            if let setURL {
                explicit["referenceSet"] = .file(setURL)
                explicit["notHostBAM"] = .array(bams.map { .string("\($0.sample)=\($0.url.path)") })
            }
            let plan = Plan(
                inputs: inputs, isTable: isTable, unit: countUnit ?? .estimated, tx2gene: tx2geneURL, sheet: sheetURL,
                name: trimmedName, command: command, explicit: explicit, isSingleCell: isSingleCell, genomes: genomes,
                referenceSet: setURL, notHostBAMs: bams)

            let analysesURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
            let resultURL = AnalysesFolder.batchSampleFileURL(named: trimmedName, extension: "lungfishrnaseq", in: analysesURL)
            let startedAt = Date()
            let destination = ImportDestination()
            let outcome = await ImportCancellation.run { () async throws -> String in
                // The Analyses folder is made once the cancel is scoped, which the SIGTERM test waits for.
                try FileManager.default.createDirectory(at: analysesURL, withIntermediateDirectories: true)
                destination.set(resultURL)
                let many = isSingleCell ? "\(inputs.count) single-cell folders" : "\(inputs.count) salmon folders"
                emitter.emitProgress(0.1, message: "Reading \(inputs.count == 1 ? inputs[0].lastPathComponent : many)...")
                let (request, facts, summary) = try await plan.fullRequest()
                emitter.emitProgress(0.6, message: "Writing \(resultURL.lastPathComponent)...")
                let envelope = plan.envelope(facts: facts, startedAt: startedAt)
                try RNASeqResultWriter().write(request, to: resultURL, envelope: envelope)
                try Task.checkCancellation()
                return summary
            }

            switch outcome {
            case .success(let summary):
                emitter.emitComplete(bundle: resultURL, kind: BundleKindID(rawValue: RNASeqResultManifest.kindName))
                if !globalOptions.quiet {
                    printHumanLine("Imported \(summary) into \(resultURL.path)", eventsOn: eventsOn)
                }
            case .failure(let error) where error is CancellationError:
                destination.removeIfCreatedByThisRun()
                throw await ImportCancellation.finish(
                    emitter: emitter,
                    command: "import rnaseq",
                    parameters: ["inputs": .array(inputs.map(ParameterValue.file)), "project": .file(projectURL)],
                    recordDirectory: projectURL,
                    startedAt: startedAt
                )
            case .failure(let exitCode as ExitCode):
                throw exitCode
            case .failure(let error):
                // The writer removes its own stage on every throw and never leaves the result's name, so whatever
                // stands there now is another run's and stays (`docs/formats/rnaseq-bundle.md`, The one writer).
                emitter.emitFailed(CLIFailureWords.describe(error))
                let isInput = error is RNASeqImportError || error is SingleCellImportError || error is MatrixMarketError
                    || error is SingleCellNotHostError || error is ReferenceSetError
                throw (isInput ? CLIExitCode.inputError : CLIExitCode.formatError).exitCode
            }
        }

        private static func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        /// The words of a refusal before anything is read, or nil when the command can run.
        private static func refusal(
            project: URL, files: [URL], name: String, isTable: Bool, inputs: [URL], unit: String?,
            countUnit: RNASeqResultManifest.CountEntry.Unit?, hasTx2Gene: Bool, singleCell: (isSingleCell: Bool, refusal: String?)
        ) -> String? {
            guard isDirectory(project) else { return "Project directory not found: \(project.path)" }
            guard !name.isEmpty else { return "--name cannot be empty" }
            guard !inputs.isEmpty else { return "Pass salmon folders, or one count table." }
            if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                return "Input not found: \(missing.path)"
            }
            if let words = singleCell.refusal { return words }
            if singleCell.isSingleCell { return nil }
            if isTable {
                guard unit != nil, countUnit != nil else { return "A count table states no unit. Pass --unit reads, pairs, umis or estimated." }
                guard !hasTx2Gene else { return "--tx2gene sums the transcripts of salmon folders and takes no count table." }
            } else {
                guard inputs.allSatisfy(isDirectory) else { return "Pass salmon folders, or one count table, and not both." }
                guard unit == nil else { return "salmon states its own unit, so --unit takes only a count table." }
            }
            return nil
        }
    }
}

extension ImportCommand.RNASeqSubcommand {
    /// What one run reads and records, in values that cross into the cancellable task.
    struct Plan: Sendable {
        let inputs: [URL]
        let isTable: Bool
        let unit: RNASeqResultManifest.CountEntry.Unit
        let tx2gene: URL?
        let sheet: URL?
        let name: String
        let command: [String]
        let explicit: [String: ParameterValue]
        var isSingleCell = false
        var genomes: [String] = []
        var referenceSet: URL?
        var notHostBAMs: [(sample: String, url: URL)] = []

        /// Reads the files and returns the writer's request, the record's facts and a summary line.
        func request() throws -> (RNASeqResultWriter.Request, [String: ParameterValue], String) {
            let sheet = try self.sheet.map(RNASeqSampleSheet.read)
            if isSingleCell { return try singleCellRequest(sheet: sheet) }
            var facts = RNASeqImportFacts.unstated
            let notRecorded = RNASeqImportFacts.notRecorded
            if isTable {
                let table = try RNASeqCountTableReader.read(inputs[0])
                let match = try RNASeqSampleSheet.match(sheet, fileIDs: table.sampleIDs, byRun: false)
                let request = RNASeqResultWriter.Request(
                    name: name, modality: .bulk, origin: .init(kind: .imported),
                    route: .init(id: "imported-table", tool: notRecorded, toolVersion: notRecorded, settings: [:]),
                    referenceSet: nil, samples: match.records, genes: .ids(table.rows.map(\.id)),
                    counts: [.init(rows: .gene, column: .default, unit: unit, table: table)],
                    sourceFiles: [.init(url: inputs[0], relativePath: inputs[0].lastPathComponent, sample: nil, tool: notRecorded)],
                    notHost: [])
                return (request, facts, "\(table.sampleIDs.count) samples and \(table.rows.count) features")
            }
            var folders: [SalmonQuantFolder] = []
            for url in inputs {
                try Task.checkCancellation()
                folders.append(try SalmonQuantFolderReader.read(folder: url))
            }
            let match = try RNASeqSampleSheet.match(sheet, fileIDs: folders.map(\.sample), byRun: true)
            for index in folders.indices { folders[index].sample = match.sampleIDs[index] }
            let ordered = match.records.compactMap { record in folders.first { $0.sample == record.id } }
            let leftOut = ordered.flatMap { folder in folder.leftOut.map { ParameterValue.string("\(folder.sample)/\($0)") } }
            if !leftOut.isEmpty { facts[RNASeqImportFacts.filesLeftOutKey] = .array(leftOut) }
            let transcripts = try SalmonQuantFolderReader.transcriptCounts(ordered)
            var counts = [RNASeqResultWriter.CountInput(rows: .transcript, column: .default, unit: .estimated, table: transcripts)]
            var features = transcripts.rows.map(\.id)
            if let tx2gene {
                let genes = try SalmonQuantFolderReader.geneCounts(ordered, tx2gene: try SalmonTx2Gene.read(tx2gene))
                counts.insert(.init(rows: .gene, column: .default, unit: .estimated, table: genes), at: 0)
                features = genes.rows.map(\.id)
            }
            let route = try SalmonQuantFolderReader.route(ordered, tx2geneName: tx2gene?.lastPathComponent)
            let request = RNASeqResultWriter.Request(
                name: name, modality: .bulk,
                origin: .init(kind: .imported, tool: SalmonQuantFolderReader.tool, toolVersion: route.toolVersion),
                route: route, referenceSet: nil, samples: match.records, genes: .ids(features), counts: counts,
                sourceFiles: SalmonQuantFolderReader.sourceFiles(ordered), notHost: [],
                quality: SalmonQuantFolderReader.qualityTable(ordered))
            return (request, facts, "\(ordered.count) salmon folders and \(features.count) features")
        }

        /// The root record: the recorded command, the options given, and the facts the files state or do not.
        func envelope(facts: [String: ParameterValue], startedAt: Date) -> ProvenanceEnvelope {
            var envelope = ProvenanceEnvelope(
                createdAt: startedAt, workflowName: "RNA-seq import", toolName: "lungfish import rnaseq",
                toolVersion: LungfishCLI.configuration.version)
            envelope.argv = command
            envelope.reproducibleCommand = command.map(Self.shellQuoted).joined(separator: " ")
            envelope.options = ProvenanceOptions(explicit: explicit, defaults: [:], resolvedDefaults: facts)
            envelope.runtimeIdentity = ProvenanceRuntimeIdentity()
            envelope.wallTimeSeconds = Date().timeIntervalSince(startedAt)
            envelope.exitStatus = 0
            envelope.status = .completed
            return envelope
        }

        static func shellQuoted(_ word: String) -> String {
            let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./_-"))
            if !word.isEmpty, word.unicodeScalars.allSatisfy({ plain.contains($0) }) { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}
