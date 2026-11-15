// SalmonQuantRoute+Record.swift - The record lines, the writer's request and the envelope of salmon quant (lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The words of the record (ADJ-ROUTE items 2 and 8, ADJ-TAIL item 7). No line or key says a poly-G setting is `false`
/// or `no`, since a parameter map shows such a key as words a person may read wrongly (BIO-POLYG item 4).
public enum SalmonQuantRecordLines {
    public static let duplicates = "Duplicates: kept. LGE removes duplicates only with UMIs."
    public static let notTrimmed = "Reads not trimmed"

    /// The route's own trimming.
    public static func trimming(_ trim: SalmonQuantTrim, version: String?) -> String {
        switch trim {
        case .none: return notTrimmed
        case .trimGalore(polyG: false): return "Poly-G trimming: off (LGE default)"
        case .trimGalore(polyG: true): return "Poly-G trimming: on (chosen), Trim Galore \(version ?? "2.3.0") --poly_g"
        }
    }

    /// The import's poly-G state, from the import record in the sidecar of the bundle's reads and, for Trim Galore, a
    /// trimming report kept in the bundle. Never "off (LGE default)", which only the route's own call can be.
    public static func importPolyG(payloads: [URL], bundle: URL) -> String {
        let steps = payloads.lazy.compactMap { FASTQMetadataStore.load(for: $0)?.ingestion?.recipeApplied?.stepResults }.first ?? []
        let trimmers = steps.filter { trimmerName($0.tool) != nil }
        guard !trimmers.isEmpty else { return "Poly-G trimming at import: not enabled (no trimmer ran at import)" }
        return "Poly-G trimming at import: " + trimmers.map { describe($0, bundle: bundle) }.joined(separator: "; ")
    }

    static func trimmerName(_ tool: String) -> String? {
        switch tool.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "trim_galore", "trimgalore", "trim galore": return "Trim Galore"
        case "fastp": return "fastp"
        default: return nil
        }
    }

    static func describe(_ step: RecipeStepResult, bundle: URL) -> String {
        let name = trimmerName(step.tool) ?? step.tool
        let version = step.toolVersion.map { " \($0)" } ?? ""
        let words = step.commandArguments ?? (step.commandLine ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let flags = name == "fastp" ? ["-g", "--trim_poly_g", "-G", "--disable_trim_poly_g"] : ["--poly_g", "--no_poly_g"]
        if let flag = words.first(where: flags.contains) { return "\(name)\(version) \(flag) (passed at import)" }
        return "left to \(name)\(version) auto-detection (not set by LGE), \(outcome(name, bundle: bundle))"
    }

    /// `parameters.poly_g` of the read 1 Trim Galore report in the bundle, the effective state the call used.
    static func outcome(_ name: String, bundle: URL) -> String {
        guard name == "Trim Galore" else { return "outcome not recorded" }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? [])
            .filter { $0.hasSuffix("_trimming_report.json") }.sorted()
        for name in names {
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent(name)),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["read_number"] as? Int ?? 1) == 1,
                  let polyG = (json["parameters"] as? [String: Any])?["poly_g"] as? Bool else { continue }
            return polyG ? "enabled (auto-detected)" : "not enabled"
        }
        return "outcome not recorded"
    }

    /// RS-INSTRUMENT's fields from the sidecar of the bundle's reads.
    public static func instrument(payloads: [URL]) -> String {
        guard let found = payloads.lazy.compactMap({ FASTQMetadataStore.load(for: $0)?.sequencerInstrument }).first,
              found.nameForm != .notRecorded else { return "Instrument: Not recorded" }
        return "Instrument: \(found.summary)" + (found.modelsAreInferred && !found.instrumentIDs.isEmpty ? ", inferred from read names" : "")
    }
}

extension SalmonQuantRoute {
    /// The lines of one sample's salmon step.
    func recordLines(for sample: SampleReads, trim: SalmonQuantTrim, trimVersion: String?) -> [String: ParameterValue] {
        [
            "sample": .string(sample.id), "bundle": .file(sample.bundle),
            "trimming": .string(SalmonQuantRecordLines.trimming(trim, version: trimVersion)),
            "importPolyG": .string(SalmonQuantRecordLines.importPolyG(payloads: sample.payloads, bundle: sample.bundle)),
            "instrument": .string(SalmonQuantRecordLines.instrument(payloads: sample.payloads)),
            "duplicates": .string(SalmonQuantRecordLines.duplicates),
        ]
    }

    /// The writer's request: gene sums by the set's transcript table, the set's genes, its not-host ids and salmon's
    /// files as written.
    func writerRequest(
        name: String, folders: [SalmonQuantFolder], set: ReferenceSetOutcome, index: SalmonIndexOutcome,
        trim: SalmonQuantTrim, trimVersion: String?
    ) throws -> RNASeqResultWriter.Request {
        let pairs = set.manifest.derived.transcriptGenes.path
        let genes = try SalmonQuantFolderReader.geneCounts(folders, tx2gene: try SalmonTx2Gene.read(set.url.appendingPathComponent(pairs)))
        let transcripts = try SalmonQuantFolderReader.transcriptCounts(folders)
        // The reader's route refuses folders of two salmon versions or two indexes; its settings are salmon's own.
        let salmon = try SalmonQuantFolderReader.route(folders, tx2geneName: nil)
        func onOff(_ key: String) -> String {
            switch salmon.settings[key] {
            case "false": return "off"
            case "true": return "on"
            default: return RNASeqImportFacts.notRecorded
            }
        }
        var settings = [
            "mapping": "selective alignment on reads", "libraryType": "A",
            "detectedLibraryType": salmon.settings["libraryType"] ?? RNASeqImportFacts.notRecorded,
            "k": String(index.key.k), "decoys": index.key.decoys.rawValue, "index": index.key.folderName,
            "seqBias": onOff("seqBiasCorrect"), "gcBias": onOff("gcBiasCorrect"), "posBias": onOff("posBiasCorrect"),
            "trimming": SalmonQuantRecordLines.trimming(trim, version: trimVersion),
            "duplicates": SalmonQuantRecordLines.duplicates, "counts": "NumReads",
            "geneSums": "NumReads summed by gene through the reference set's \(pairs)",
            "indexSeqHash": index.hashes.seqHash, "indexNameHash": index.hashes.nameHash,
        ]
        if let hash = index.hashes.decoySeqHash { settings["indexDecoySeqHash"] = hash }
        if let hash = index.hashes.decoyNameHash { settings["indexDecoyNameHash"] = hash }
        let genesURL = set.url.appendingPathComponent(set.manifest.derived.genes.path)
        return RNASeqResultWriter.Request(
            name: name, modality: .bulk, origin: .init(kind: .quantified, tool: "salmon", toolVersion: salmon.toolVersion),
            route: .init(id: Self.routeID, tool: "salmon", toolVersion: salmon.toolVersion, settings: settings),
            referenceSet: .init(id: set.manifest.id, layout: set.manifest.layout.kind == "deposit" ? .deposit : .lge),
            samples: try RNASeqSampleSheet.match(nil, fileIDs: folders.map(\.sample), byRun: true).records,
            genes: .referenceSetTable(url: genesURL, keeping: genes.rows.map(\.id)),
            counts: [
                .init(rows: .gene, column: .default, unit: .estimated, table: genes),
                .init(rows: .transcript, column: .default, unit: .estimated, table: transcripts),
            ],
            sourceFiles: SalmonQuantFolderReader.sourceFiles(folders), notHost: try Self.notHostIDs(genesURL),
            quality: SalmonQuantFolderReader.qualityTable(folders))
    }

    /// The genes of the set's `derived/genes.tsv` whose `not_host` reads `true`.
    static func notHostIDs(_ url: URL) throws -> [String] {
        let rows = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard let header = rows.first, let id = header.firstIndex(of: "gene_id"), let column = header.firstIndex(of: "not_host") else {
            throw RNASeqResultWriterError.invalidGeneTable(url.lastPathComponent)
        }
        return rows.dropFirst().filter { $0.count > max(id, column) && $0[column] == "true" }.map { $0[id] }
    }

    /// The root record, handed to the writer: the command as run, the set and the four index hashes, each bundle's reads
    /// as inputs, the two count tables at their final paths with the hashes of the bytes the writer writes, and the steps.
    func envelope(
        _ request: SalmonQuantRequest, samples: [SampleReads], steps: [ProvenanceStep], index: SalmonIndexOutcome,
        salmonBuild: String, result: URL, counts: [RNASeqResultWriter.CountInput], started: Date
    ) throws -> ProvenanceEnvelope {
        var resolved: [String: ParameterValue] = [
            "index_seq_hash": .string(index.hashes.seqHash), "index_name_hash": .string(index.hashes.nameHash),
            "index": .file(index.indexURL), "salmonBuild": .string(salmonBuild),
        ]
        if let hash = index.hashes.decoySeqHash { resolved["index_decoy_seq_hash"] = .string(hash) }
        if let hash = index.hashes.decoyNameHash { resolved["index_decoy_name_hash"] = .string(hash) }
        let trimVersion = steps.first { $0.toolName == "trim_galore" }?.toolVersion
        var builder = ProvenanceRunBuilder(
            workflowName: "RNA-seq salmon quant", workflowVersion: WorkflowRun.currentAppVersion, toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion)
            .argv(request.argv)
            .reproducibleCommand(request.argv.map(Self.shellQuoted).joined(separator: " "))
            .options(
                explicit: [
                    "set": .string(request.setID), "project": .file(request.projectURL), "name": .string(request.name),
                    "bundles": .array(request.bundles.map(ParameterValue.file)), "threads": .integer(request.threads),
                    "trim": .string(SalmonQuantRecordLines.trimming(request.trim, version: trimVersion)),
                ],
                defaults: ["k": .integer(request.k), "decoys": .string(request.decoys.rawValue), "libraryType": .string("A")],
                resolved: resolved)
            .runtime(ProvenanceRuntimeIdentity())
        for url in samples.flatMap(\.payloads) { builder = try builder.input(url) }
        for count in counts {
            let data = try count.table.tsvData()
            let name = count.rows == .gene ? "genes.counts.tsv" : "transcripts.counts.tsv"
            builder = try builder.recordedOutputSnapshot(ProvenanceFileDescriptor(
                path: result.appendingPathComponent("counts/\(name)").path, checksumSHA256: RNASeqResultBundle.sha256Hex(data),
                fileSize: UInt64(data.count), role: .output))
        }
        for step in steps { builder = builder.step(step) }
        return try builder.complete(exitStatus: 0, status: .completed, startedAt: started, endedAt: Date())
    }

    static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./_-"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ plain.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
