// ExecutorRunAdoption+RNASeqResult.swift - The counts adopt's result: the writer's request with the plan's route and the
// run's salmon facts, its record, and the entries `import rnaseq --adopt` runs (Phase 5.3 lane EX-ADOPT M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension ExecutorRunAdoption {
    /// Adopts a returned folder or batch as one RNA-seq result in the project's `Analyses/` and returns its folder.
    /// `storageRoot` nil reads the configured location. Every refusal comes before any file is written. `warn` takes each
    /// warning the record keeps, such as reads that do not look unstranded, once the result is written.
    package static func adoptCounts(
        resultFolder: URL, projectDirectory: URL, name: String, storageRoot: URL? = nil, eventsOn: Bool = false,
        warn: (String) -> Void = { _ in }
    ) throws -> URL {
        try adoptCounts(
            resultFolder: resultFolder, projectDirectory: projectDirectory, name: name, storageRoot: storageRoot,
            eventsOn: eventsOn, policy: .release, provenanceWriter: ProvenanceWriter(), warn: warn
        )
    }

    static func adoptCounts(
        resultFolder: URL, projectDirectory: URL, name: String, storageRoot: URL?, eventsOn: Bool = false,
        policy: ExecutorAdoptPolicy, provenanceWriter: ProvenanceWriter, warn: (String) -> Void = { _ in }
    ) throws -> URL {
        let started = Date()
        let root = storageRoot ?? ManagedStorageConfigStore().currentLocation().rootURL
        let adoption = try prepareCounts(resultFolder, storageRoot: root, name: name, policy: policy)
        let analyses = projectDirectory.appendingPathComponent("Analyses", isDirectory: true)
        let resultURL = AnalysesFolder.batchSampleFileURL(named: name, extension: "lungfishrnaseq", in: analyses)
        let argv = [CLICommandIdentity.executableName] + countsCLIArguments(
            resultFolder: resultFolder, projectDirectory: projectDirectory, name: name, storageRoot: storageRoot, eventsOn: eventsOn
        )
        let envelope = try countsEnvelope(
            adoption, argv: argv, resultFolder: resultFolder, projectDirectory: projectDirectory, result: resultURL, started: started
        )
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        try RNASeqResultWriter(provenanceWriter: provenanceWriter).write(adoption.request, to: resultURL, envelope: envelope)
        _ = try ReferenceSetOwner(storageRoot: root).recordUse(of: adoption.setURL, resultFolder: resultURL)
        adoption.warnings.forEach(warn)
        return resultURL
    }

    /// Every check and read of the adopt with nothing written (`--dry-run`), and the folder name the result would take.
    /// `warn` takes each warning the adopt would keep.
    package static func dryRunCounts(
        resultFolder: URL, projectDirectory: URL, name: String, storageRoot: URL? = nil, warn: (String) -> Void = { _ in }
    ) throws -> String {
        let root = storageRoot ?? ManagedStorageConfigStore().currentLocation().rootURL
        try prepareCounts(resultFolder, storageRoot: root, name: name, policy: .release).warnings.forEach(warn)
        let analyses = projectDirectory.appendingPathComponent("Analyses", isDirectory: true)
        return AnalysesFolder.batchSampleFileURL(named: name, extension: "lungfishrnaseq", in: analyses)
            .lastPathComponent
    }

    /// The argv of `lungfish-cli import rnaseq <folder> --adopt` after the executable, the command the record names.
    package static func countsCLIArguments(
        resultFolder: URL, projectDirectory: URL, name: String, storageRoot: URL?, eventsOn: Bool
    ) -> [String] {
        var arguments = [
            "import", "rnaseq", resultFolder.standardizedFileURL.path, "--adopt",
            "--project", projectDirectory.standardizedFileURL.path, "--name", name,
        ]
        if let storageRoot { arguments += ["--storage-root", storageRoot.standardizedFileURL.path] }
        if eventsOn { arguments += ["--format", "json"] }
        return arguments
    }

    /// The writer's request as `rnaseq quant` makes it: gene sums by the set's transcript table, the set's genes and
    /// not-host ids, salmon's files as written, and the plan's route with the run's facts that the Mac route records
    /// under the same keys, read from the salmon files.
    static func countsRequest(
        name: String, samples: [ExecutorCountsAdoptedSample], set: ReferenceSetOutcome
    ) throws -> RNASeqResultWriter.Request {
        if samples[0].starCounts != nil { return try starCountsRequest(name: name, samples: samples, set: set) }
        if samples[0].umiCounts != nil { return try umiCountsRequest(name: name, samples: samples, set: set) }
        let folders = samples.compactMap(\.salmonFolder)
        let route = samples[0].run.route
        let pairs = set.manifest.derived.transcriptGenes.path
        let genes = try SalmonQuantFolderReader.geneCounts(folders, tx2gene: try SalmonTx2Gene.read(set.url.appendingPathComponent(pairs)))
        let transcripts = try SalmonQuantFolderReader.transcriptCounts(folders)
        let salmon = try SalmonQuantFolderReader.route(folders, tx2geneName: nil)
        guard salmon.toolVersion == route.toolVersion else {
            throw refusal(
                "pipeline.route.toolVersion",
                "salmon states version \(salmon.toolVersion) in meta_info.json, and the plan counts with salmon \(route.toolVersion)."
            )
        }
        var settings = route.settings
        for (key, value) in try salmonRunFacts(folders, salmon: salmon) { settings[key] = value }
        // Each plan states its own sample's words; the route states how the result's samples were counted, with the
        // one writer `rnaseq quant` uses (ruling ARCH-ADOPT-ROUTE items 1 and 3).
        settings["duplicates"] = SalmonQuantRecordLines.duplicatesSetting(samples.map(\.duplicates))
        let genesURL = set.url.appendingPathComponent(set.manifest.derived.genes.path)
        let referenceSet = samples[0].run.pipeline.referenceSet
        return RNASeqResultWriter.Request(
            name: name, modality: .bulk, origin: .init(kind: .quantified, tool: route.tool, toolVersion: route.toolVersion),
            route: .init(id: route.id, tool: route.tool, toolVersion: route.toolVersion, settings: settings),
            referenceSet: .init(id: referenceSet.id, layout: referenceSet.layout == .deposit ? .deposit : .lge),
            samples: try RNASeqSampleSheet.match(nil, fileIDs: folders.map(\.sample), byRun: true).records,
            genes: .referenceSetTable(url: genesURL, keeping: genes.rows.map(\.id)),
            counts: [
                .init(rows: .gene, column: .default, unit: .estimated, table: genes),
                .init(rows: .transcript, column: .default, unit: .estimated, table: transcripts),
            ],
            sourceFiles: SalmonQuantFolderReader.sourceFiles(folders), notHost: try SalmonQuantRoute.notHostIDs(genesURL),
            quality: SalmonQuantFolderReader.qualityTable(folders))
    }

    /// The Mac route's run facts (`SalmonQuantRoute+Record.swift`, `writerRequest`): `detectedLibraryType`, the three
    /// bias flags as on or off, and the index hashes, here from each folder's `meta_info.json`. Two samples whose
    /// index hashes differ are refused, since their counts would join two indexes in one table.
    static func salmonRunFacts(_ folders: [SalmonQuantFolder], salmon: RNASeqResultManifest.Route) throws -> [String: String] {
        func onOff(_ key: String) -> String {
            switch salmon.settings[key] {
            case "false": return "off"
            case "true": return "on"
            default: return RNASeqImportFacts.notRecorded
            }
        }
        var facts = [
            "detectedLibraryType": salmon.settings["libraryType"] ?? RNASeqImportFacts.notRecorded,
            "seqBias": onOff("seqBiasCorrect"), "gcBias": onOff("gcBiasCorrect"), "posBias": onOff("posBiasCorrect"),
        ]
        let hashes = [
            ("index_seq_hash", "indexSeqHash", true), ("index_name_hash", "indexNameHash", true),
            ("index_decoy_seq_hash", "indexDecoySeqHash", false), ("index_decoy_name_hash", "indexDecoyNameHash", false),
        ]
        for (column, key, always) in hashes {
            let values = Set(folders.map { $0.quality.indexHashes[column] })
            guard values.count <= 1 else { throw RNASeqImportError.routesDiffer("index (\(column))") }
            if let value = values.first ?? nil {
                facts[key] = value
            } else if always {
                facts[key] = RNASeqImportFacts.notRecorded
            }
        }
        return facts
    }
}
