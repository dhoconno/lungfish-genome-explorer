// SalmonPlan+Frame.swift - The index a salmon plan pins, its pipeline and a sample's reads (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishPortable

extension SalmonPlan {
    /// Each file under the published index's `index/` as a `reference` entry with `index` `{key, tool}`, where the tool is
    /// the salmon of its `index-key.json` (`docs/formats/executor-plan.md`, Reference entries). A key with no published
    /// index is refused in words that name `lungfish-cli rnaseq index`.
    static func indexEntries(key: SalmonIndexKey, storageRoot: URL) throws -> (entries: [PlanEntry], sources: [String: URL]) {
        let cache = SalmonIndexCache(storageRoot: storageRoot, host: RunFitHostFacts(physicalMemoryBytes: 0))
        guard let published = try cache.published(key) else {
            let options = (key.k == 31 ? "" : " --k \(key.k)") + (key.decoys == .none ? " --decoys none" : "")
            throw SalmonPlanError("The set \(key.setID) has no published salmon index \(key.folderName) on this Mac, and a plan "
                + "never builds one. Build it with lungfish-cli rnaseq index --set \(key.setID)\(options), then write the plan again.")
        }
        let file = try JSONDecoder().decode(
            SalmonIndexKeyFile.self, from: Data(contentsOf: published.url.appendingPathComponent(SalmonIndexKeyFile.filename)))
        let prefix = "salmon-\(file.salmonVersion)-"
        let build = file.salmonBuild.hasPrefix(prefix) ? String(file.salmonBuild.dropFirst(prefix.count)) : file.salmonBuild
        let identity = PlanReferenceIndex(key: key.folderName, tool: PlanToolPin(id: "salmon", version: file.salmonVersion, build: build))
        let folder = published.indexURL.resolvingSymlinksInPath()
        var files: [String] = []
        if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walk where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(String(url.resolvingSymlinksInPath().path.dropFirst(folder.path.count + 1)))
            }
        }
        var entries: [PlanEntry] = [], sources: [String: URL] = [:]
        for path in files {
            let measured = try ExecutorPlanSourceFile.measuring(folder.appendingPathComponent(path))
            let reference = PlanReferenceIdentity(setID: key.setID, path: path, index: identity)
            entries.append(PlanEntry(role: .reference, relativePath: reference.relativePath, sha256: measured.sha256,
                                     size: measured.size, reference: reference))
            sources[reference.relativePath] = measured.url
        }
        return (entries.sorted { $0.relativePath < $1.relativePath }, sources)
    }

    /// The chain's identity. `route.settings` holds each key of the Mac route known before the run, in the words the Mac
    /// writes (`SalmonQuantRoute+Record.swift`, `writerRequest`), and the facts of the run, `detectedLibraryType`, the bias
    /// flags and the four index hashes, are left to the adopt.
    static func pipeline(manifest: ReferenceSetManifest, request: SalmonPlanRequest, key: SalmonIndexKey) -> PlanPipeline {
        let trimVersion = request.pins.trimGalore.version
        var polyGChosen = false
        if case .trimGalore(let polyG) = request.trim { polyGChosen = polyG }
        var settings = [
            PlanPipelineSetting(id: "mapping", label: "Mapping", value: "selective alignment on reads", source: .default),
            PlanPipelineSetting(id: "libraryType", label: "Library type", value: "A", source: .default),
            PlanPipelineSetting(id: "k", label: "k-mer length", value: String(request.k), source: request.k == 31 ? .default : .option),
            PlanPipelineSetting(id: "decoys", label: "Decoys", value: request.decoys.rawValue,
                                source: request.decoys == .genome ? .default : .option),
            PlanPipelineSetting(id: "index", label: "Index", value: key.folderName, source: .default),
            PlanPipelineSetting(id: "trimming", label: "Trimming", value: SalmonQuantRecordLines.trimming(request.trim, version: trimVersion),
                                source: polyGChosen ? .option : .default),
            PlanPipelineSetting(id: "duplicates", label: "Duplicates", value: request.sample.duplicates,
                                source: request.sample.duplicatesSource),
            PlanPipelineSetting(id: "counts", label: "Counts", value: "NumReads", source: .default),
            PlanPipelineSetting(id: "geneSums", label: "Gene sums",
                                value: "NumReads summed by gene through the reference set's \(manifest.derived.transcriptGenes.path)",
                                source: .default),
        ]
        if let adapter = SalmonQuantRecordLines.adapter(request.trim, version: trimVersion) {
            settings.append(PlanPipelineSetting(id: "adapter", label: "Adapter", value: adapter, source: .default))
        }
        settings.sort { $0.id < $1.id }
        return PlanPipeline(
            id: pipelineID, version: pipelineVersion, preset: PlanPipelinePreset(id: pipelineID, name: presetName), modality: .bulk,
            route: PlanPipelineRoute(id: SalmonQuantRoute.routeID, tool: request.pins.salmon.id, toolVersion: request.pins.salmon.version,
                                     settings: Dictionary(uniqueKeysWithValues: settings.map { ($0.id, $0.value) })),
            referenceSet: PlanPipelineReferenceSet(id: manifest.id, layout: manifest.layout.kind == "deposit" ? .deposit : .lge),
            settings: settings)
    }
}
