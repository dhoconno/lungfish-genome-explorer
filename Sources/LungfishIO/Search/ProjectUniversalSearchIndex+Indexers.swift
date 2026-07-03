// ProjectUniversalSearchIndex+Indexers.swift - SQLite-backed project-scoped universal search catalog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

extension ProjectUniversalSearchIndex {

    // MARK: - Indexers

    func indexFASTQBundle(
        at bundleURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let title = bundleURL.deletingPathExtension().lastPathComponent
        let relPath = relativePath(for: bundleURL)

        let row = entityRow(
            id: "fastq_dataset:\(relPath)",
            kind: "fastq_dataset",
            title: title,
            subtitle: nil,
            format: "fastq",
            url: bundleURL
        )

        var attributes: [String: Any] = [
            "dataset_name": title,
            "bundle_extension": FASTQBundle.directoryExtension,
        ]

        if let csvMetadata = FASTQBundleCSVMetadata.load(from: bundleURL) {
            let sample = FASTQSampleMetadata(from: csvMetadata, fallbackName: title)
            appendFASTQSampleAttributes(sample, to: &attributes)
        }

        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL),
           let sidecar = FASTQMetadataStore.load(for: fastqURL) {
            if let stats = sidecar.computedStatistics {
                attributes["read_count"] = stats.readCount
                attributes["base_count"] = stats.baseCount
                attributes["mean_read_length"] = stats.meanReadLength
                attributes["median_read_length"] = stats.medianReadLength
                attributes["n50_read_length"] = stats.n50ReadLength
                attributes["mean_quality"] = stats.meanQuality
                attributes["q20_percentage"] = stats.q20Percentage
                attributes["q30_percentage"] = stats.q30Percentage
                attributes["gc_content"] = stats.gcContent * 100.0
                attributes["min_read_length"] = stats.minReadLength
                attributes["max_read_length"] = stats.maxReadLength
            }

            if let seqkit = sidecar.seqkitStats {
                attributes["seqkit_num_seqs"] = seqkit.numSeqs
                attributes["seqkit_sum_len"] = seqkit.sumLen
                attributes["seqkit_min_len"] = seqkit.minLen
                attributes["seqkit_avg_len"] = seqkit.avgLen
                attributes["seqkit_max_len"] = seqkit.maxLen
                attributes["seqkit_q20_percentage"] = seqkit.q20Percentage
                attributes["seqkit_q30_percentage"] = seqkit.q30Percentage
                attributes["seqkit_average_quality"] = seqkit.averageQuality
                attributes["seqkit_gc_percentage"] = seqkit.gcPercentage
            }

            if let ingestion = sidecar.ingestion {
                attributes["is_clumpified"] = ingestion.isClumpified
                attributes["is_compressed"] = ingestion.isCompressed
                attributes["pairing_mode"] = ingestion.pairingMode.rawValue
                attributes["quality_binning"] = ingestion.qualityBinning
                attributes["ingestion_date"] = ingestion.ingestionDate
                attributes["original_size_bytes"] = ingestion.originalSizeBytes
            }

            if let source = sidecar.downloadSource {
                attributes["download_source"] = source
            }
            if let downloadDate = sidecar.downloadDate {
                attributes["download_date"] = downloadDate
            }

            if let platform = sidecar.sequencingPlatform {
                attributes["sequencing_platform"] = platform.rawValue
            }

            if let sra = sidecar.sraRunInfo {
                attributes["sra_accession"] = sra.accession
                attributes["sra_experiment"] = sra.experiment
                attributes["sra_sample"] = sra.sample
                attributes["sra_study"] = sra.study
                attributes["sra_bioproject"] = sra.bioproject
                attributes["sra_biosample"] = sra.biosample
                attributes["sra_organism"] = sra.organism
                attributes["sra_platform"] = sra.platform
                attributes["sra_library_strategy"] = sra.libraryStrategy
                attributes["sra_library_layout"] = sra.libraryLayout
                attributes["sra_spots"] = sra.spots
                attributes["sra_bases"] = sra.bases
                attributes["sra_release_date"] = sra.releaseDate
            }

            if let ena = sidecar.enaReadRecord {
                attributes["ena_run_accession"] = ena.runAccession
                attributes["ena_experiment_accession"] = ena.experimentAccession
                attributes["ena_sample_accession"] = ena.sampleAccession
                attributes["ena_study_accession"] = ena.studyAccession
                attributes["ena_experiment_title"] = ena.experimentTitle
                attributes["ena_library_layout"] = ena.libraryLayout
                attributes["ena_library_source"] = ena.librarySource
                attributes["ena_library_strategy"] = ena.libraryStrategy
                attributes["ena_platform"] = ena.instrumentPlatform
                attributes["ena_base_count"] = ena.baseCount
                attributes["ena_read_count"] = ena.readCount
                attributes["ena_first_public"] = ena.firstPublic
            }
        }

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    func indexReferenceBundle(
        at bundleURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)

        var attributes: [String: Any] = [:]
        if let flattened = flattenJSONFile(at: manifestURL) {
            for (key, value) in flattened {
                attributes[key] = value
            }
        }

        let bundleTitle: String = {
            if let title = attributes["name"] as? String, !title.isEmpty {
                return title
            }
            return bundleURL.deletingPathExtension().lastPathComponent
        }()

        let row = entityRow(
            id: "reference_bundle:\(relPath)",
            kind: "reference_bundle",
            title: bundleTitle,
            subtitle: nil,
            format: "reference",
            url: bundleURL
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        guard let manifest = try? BundleManifest.load(from: bundleURL) else { return }

        for track in manifest.variants {
            let trackID = track.id
            let trackTitle = track.name
            let trackEntityID = "vcf_track:\(relPath):\(trackID)"
            var trackAttributes: [String: Any] = [
                "track_id": trackID,
                "track_name": trackTitle,
                "path": track.path,
                "index_path": track.indexPath,
                "variant_type": track.variantType.rawValue,
            ]
            if let variantCount = track.variantCount { trackAttributes["variant_count"] = variantCount }
            if let source = track.source { trackAttributes["source"] = source }
            if let description = track.description { trackAttributes["description"] = description }
            if let version = track.version { trackAttributes["version"] = version }
            if let dbPath = track.databasePath { trackAttributes["database_path"] = dbPath }

            let trackRow = entityRow(
                id: trackEntityID,
                kind: "vcf_track",
                title: trackTitle,
                subtitle: track.description ?? track.path,
                format: "vcf",
                url: bundleURL
            )

            try insertEntity(
                trackRow,
                attributes: trackAttributes,
                entityCount: &entityCount,
                attributeCount: &attributeCount,
                perKindCounts: &perKindCounts
            )

            guard let dbPath = track.databasePath else { continue }
            let dbURL = bundleURL.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            guard let variantDB = try? VariantDatabase(url: dbURL) else { continue }

            let sampleMetadata = variantDB.allSampleMetadata()
            for entry in sampleMetadata {
                let sampleName = entry.name
                let sampleEntityID = "vcf_sample:\(relPath):\(trackID):\(sampleName)"
                var sampleAttributes: [String: Any] = [
                    "sample_name": sampleName,
                    "track_id": trackID,
                    "track_name": trackTitle,
                ]
                for (key, value) in entry.metadata {
                    sampleAttributes[key] = value
                }

                let sampleRow = entityRow(
                    id: sampleEntityID,
                    kind: "vcf_sample",
                    title: sampleName,
                    subtitle: trackTitle,
                    format: "vcf",
                    url: bundleURL
                )

                try insertEntity(
                    sampleRow,
                    attributes: sampleAttributes,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }
        }
    }

    func indexClassificationResult(
        at resultDirectory: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultDirectory)
        let sidecarURL = resultDirectory.appendingPathComponent("classification-result.json")
        var attributes: [String: Any] = [
            "result_directory": resultDirectory.lastPathComponent,
        ]
        var deferredTaxonNames: [String] = []
        var taxonomySeeds: [ClassificationTaxonSeed] = []

        if let flattened = flattenJSONFile(at: sidecarURL) {
            for (key, value) in flattened {
                attributes[key] = value
            }
        }

        if let reportPath = attributes["reportpath"] as? String {
            let reportURL = resultDirectory.appendingPathComponent(reportPath)
            if FileManager.default.fileExists(atPath: reportURL.path),
               let tree = try? KreportParser.parse(url: reportURL) {
                attributes["classified_reads"] = tree.classifiedReads
                attributes["unclassified_reads"] = tree.unclassifiedReads
                attributes["classified_fraction"] = tree.classifiedFraction
                attributes["species_count"] = tree.speciesCount
                if let dominant = tree.dominantSpecies {
                    attributes["dominant_species"] = dominant.name
                }

                let topTaxa = tree.allNodes()
                    .filter { $0.readsClade > 0 }
                    .sorted { $0.readsClade > $1.readsClade }
                    .prefix(400)
                deferredTaxonNames = topTaxa.map(\.name)
                taxonomySeeds.append(
                    contentsOf: topTaxa.map {
                        ClassificationTaxonSeed(
                            source: "kraken",
                            name: $0.name,
                            taxID: $0.taxId,
                            rank: $0.rank.code,
                            readCount: $0.readsClade,
                            fraction: $0.fractionClade
                        )
                    }
                )
                if !deferredTaxonNames.isEmpty {
                    attributes["top_taxa"] = deferredTaxonNames.prefix(120).joined(separator: " | ")
                    let aliases = Set(deferredTaxonNames.flatMap(organismAliases(for:)))
                    if !aliases.isEmpty {
                        attributes["top_taxa_aliases"] = aliases.sorted().prefix(200).joined(separator: " | ")
                    }
                }
            }
        }

        if let brackenPath = attributes["brackenpath"] as? String {
            let brackenURL = resultDirectory.appendingPathComponent(brackenPath)
            if FileManager.default.fileExists(atPath: brackenURL.path),
               let brackenRows = try? BrackenParser.parse(url: brackenURL) {
                let topBracken = brackenRows
                    .sorted { $0.newEstReads > $1.newEstReads }
                    .prefix(400)
                if !topBracken.isEmpty {
                    attributes["bracken_taxa_count"] = topBracken.count
                    attributes["bracken_top_taxa"] = topBracken.prefix(120).map(\.name).joined(separator: " | ")
                }
                taxonomySeeds.append(
                    contentsOf: topBracken.map {
                        ClassificationTaxonSeed(
                            source: "bracken",
                            name: $0.name,
                            taxID: $0.taxId,
                            rank: $0.taxonomyLevel,
                            readCount: $0.newEstReads,
                            fraction: $0.fractionTotalReads
                        )
                    }
                )
            }
        }

        let title: String = {
            if let value = attributes["config.databasename"] as? String, !value.isEmpty {
                return "Classification: \(value)"
            }
            return resultDirectory.lastPathComponent
        }()

        let row = entityRow(
            id: "classification_result:\(relPath)",
            kind: "classification_result",
            title: title,
            subtitle: resultDirectory.lastPathComponent,
            format: "classification",
            url: resultDirectory
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        for taxonName in Set(deferredTaxonNames) {
            try insertOrganismAttributes(
                entityID: row.id,
                keys: ["taxon", "virus_name"],
                name: taxonName,
                includeOriginal: true,
                attributeCount: &attributeCount
            )
        }

        var seenTaxonEntityIDs = Set<String>()
        for seed in taxonomySeeds {
            let entityID = "classification_taxon:\(relPath):\(seed.source):\(seed.taxID):\(stableIdentifierComponent(seed.name))"
            guard seenTaxonEntityIDs.insert(entityID).inserted else { continue }

            let aliases = organismAliases(for: seed.name)
            var taxonAttributes: [String: Any] = [
                "taxon": seed.name,
                "virus_name": seed.name,
                "organism": seed.name,
                "tax_id": seed.taxID,
                "rank": seed.rank,
                "source": seed.source,
                "read_count": seed.readCount,
            ]
            if let fraction = seed.fraction {
                taxonAttributes["abundance_fraction"] = fraction
                taxonAttributes["abundance_percentage"] = fraction * 100.0
            }
            if !aliases.isEmpty {
                taxonAttributes["search_aliases"] = aliases.joined(separator: " | ")
            }

            let taxonRow = entityRow(
                id: entityID,
                kind: "classification_taxon",
                title: seed.name,
                subtitle: "\(seed.source.capitalized) • \(resultDirectory.lastPathComponent)",
                format: "classification",
                url: resultDirectory
            )

            try insertEntity(
                taxonRow,
                attributes: taxonAttributes,
                entityCount: &entityCount,
                attributeCount: &attributeCount,
                perKindCounts: &perKindCounts
            )

            try insertOrganismAttributes(
                entityID: entityID,
                keys: ["taxon", "virus_name", "organism"],
                name: seed.name,
                includeOriginal: false,
                attributeCount: &attributeCount
            )
        }

        try indexSampleMetadata(
            at: resultDirectory,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    func indexEsVirituResult(
        at resultDirectory: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultDirectory)
        let parentEntityID = "esviritu_result:\(relPath)"
        let sidecarURL = resultDirectory.appendingPathComponent("esviritu-result.json")

        var attributes: [String: Any] = [
            "result_directory": resultDirectory.lastPathComponent,
        ]
        var deferredVirusNames: [String] = []
        var deferredFamilies: [String] = []
        var deferredSpecies: [String] = []
        var deferredVirusAliases: Set<String> = []

        if let flattened = flattenJSONFile(at: sidecarURL) {
            for (key, value) in flattened {
                attributes[key] = value
            }
        }

        if let detectionPath = attributes["detectionpath"] as? String {
            let detectionURL = resultDirectory.appendingPathComponent(detectionPath)
            if FileManager.default.fileExists(atPath: detectionURL.path),
               let detections = try? EsVirituDetectionParser.parse(url: detectionURL) {
                attributes["detection_count"] = detections.count

                let topDetections = detections
                    .sorted { $0.readCount > $1.readCount }
                    .prefix(300)

                for detection in topDetections {
                    let hitEntityID = "virus_hit:\(relPath):\(detection.accession)"
                    let nameAliases = organismAliases(for: detection.name)
                    var hitAttributes: [String: Any] = [
                        "virus_name": detection.name,
                        "sample_id": detection.sampleId,
                        "accession": detection.accession,
                        "assembly": detection.assembly,
                        "unique_reads": detection.readCount,
                        "supporting_reads": detection.readCount,
                        "total_reads": detection.filteredReadsInSample,
                        "read_count": detection.readCount,
                        "filtered_reads_in_sample": detection.filteredReadsInSample,
                        "rpkmf": detection.rpkmf,
                        "covered_bases": detection.coveredBases,
                        "mean_coverage": detection.meanCoverage,
                        "avg_read_identity": detection.avgReadIdentity,
                    ]
                    if !nameAliases.isEmpty {
                        hitAttributes["search_aliases"] = nameAliases.joined(separator: " | ")
                    }

                    if let species = detection.species {
                        hitAttributes["species"] = species
                        deferredSpecies.append(species)
                        deferredVirusAliases.formUnion(organismAliases(for: species))
                    }
                    if let genus = detection.genus { hitAttributes["genus"] = genus }
                    if let family = detection.family {
                        hitAttributes["family"] = family
                        deferredFamilies.append(family)
                    }
                    if let order = detection.order { hitAttributes["order"] = order }
                    if let segment = detection.segment { hitAttributes["segment"] = segment }

                    let hitRow = entityRow(
                        id: hitEntityID,
                        kind: "virus_hit",
                        title: detection.name,
                        subtitle: detection.sampleId,
                        format: "esviritu",
                        url: resultDirectory
                    )

                    try insertEntity(
                        hitRow,
                        attributes: hitAttributes,
                        entityCount: &entityCount,
                        attributeCount: &attributeCount,
                        perKindCounts: &perKindCounts
                    )

                    deferredVirusNames.append(detection.name)
                    deferredVirusAliases.formUnion(nameAliases)

                    try insertOrganismAttributes(
                        entityID: hitEntityID,
                        keys: ["virus_name"],
                        name: detection.name,
                        includeOriginal: false,
                        attributeCount: &attributeCount
                    )
                }
                if !deferredVirusNames.isEmpty {
                    attributes["detected_viruses"] = deferredVirusNames.prefix(200).joined(separator: " | ")
                }
                if !deferredVirusAliases.isEmpty {
                    attributes["detected_virus_aliases"] = deferredVirusAliases.sorted().prefix(200).joined(separator: " | ")
                }
                if !deferredFamilies.isEmpty {
                    attributes["detected_families"] = Array(Set(deferredFamilies.map { $0.lowercased() })).joined(separator: " | ")
                }
                if !deferredSpecies.isEmpty {
                    attributes["detected_species"] = Array(Set(deferredSpecies.map { $0.lowercased() })).joined(separator: " | ")
                }
            }
        }

        let title: String = {
            if let sampleName = attributes["config.samplename"] as? String, !sampleName.isEmpty {
                return "EsViritu: \(sampleName)"
            }
            return resultDirectory.lastPathComponent
        }()

        let row = entityRow(
            id: parentEntityID,
            kind: "esviritu_result",
            title: title,
            subtitle: resultDirectory.lastPathComponent,
            format: "esviritu",
            url: resultDirectory
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        for virusName in Set(deferredVirusNames) {
            try insertOrganismAttributes(
                entityID: parentEntityID,
                keys: ["virus_name"],
                name: virusName,
                includeOriginal: true,
                attributeCount: &attributeCount
            )
        }
        for family in Set(deferredFamilies) {
            try insertAttribute(entityID: parentEntityID, key: "family", value: family)
            attributeCount += 1
        }
        for species in Set(deferredSpecies) {
            try insertAttribute(entityID: parentEntityID, key: "species", value: species)
            attributeCount += 1
        }

        try indexSampleMetadata(
            at: resultDirectory,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    func indexTaxTriageResult(
        at resultDirectory: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultDirectory)
        let sidecarURL = resultDirectory.appendingPathComponent("taxtriage-result.json")

        var attributes: [String: Any] = [
            "result_directory": resultDirectory.lastPathComponent,
        ]
        var organismSeeds: [TaxTriageOrganismSeed] = []

        if let flattened = flattenJSONFile(at: sidecarURL) {
            for (key, value) in flattened {
                guard !TaxTriageOutputArtifactPolicy.containsPrunedIntermediatePath(in: key),
                      !TaxTriageOutputArtifactPolicy.containsPrunedIntermediatePath(in: value) else {
                    continue
                }
                attributes[key] = value
            }
        }

        let allOutputFiles = TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles(
            collectOutputFiles(in: resultDirectory),
            outputDirectory: resultDirectory
        )
        let metricFiles = allOutputFiles.filter {
            let filename = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            guard ext == "txt" || ext == "tsv" else { return false }
            if filename == "top_report.tsv" { return false }
            return filename == "multiqc_confidences.txt"
                || filename.hasSuffix(".organisms.report.txt")
                || filename.contains("confidence")
                || filename.contains("tass")
                || filename.contains("metrics")
        }

        var metricsByCompositeKey: [String: TaxTriageMetric] = [:]
        for metricsURL in metricFiles.sorted(by: pathCompare) {
            guard let parsed = try? TaxTriageMetricsParser.parse(url: metricsURL), !parsed.isEmpty else {
                continue
            }
            for metric in parsed {
                let key = "\(OrganismNameNormalizer.normalizedKey(metric.organism))\t\(metric.sample ?? "")"
                if let existing = metricsByCompositeKey[key] {
                    if metric.tassScore > existing.tassScore {
                        metricsByCompositeKey[key] = metric
                    }
                } else {
                    metricsByCompositeKey[key] = metric
                }
            }
        }

        organismSeeds.append(
            contentsOf: metricsByCompositeKey.values.map {
                TaxTriageOrganismSeed(
                    name: $0.organism,
                    sampleName: $0.sample,
                    taxID: $0.taxId,
                    rank: $0.rank,
                    readCount: $0.reads,
                    uniqueReads: nil,
                    tassScore: $0.tassScore,
                    confidence: $0.confidence,
                    coverageBreadth: $0.coverageBreadth,
                    coverageDepth: $0.coverageDepth,
                    abundance: $0.abundance,
                    source: "metrics"
                )
            }
        )

        let topReportFiles = allOutputFiles.filter { $0.lastPathComponent.lowercased().contains("top_report.tsv") }
        for topReportURL in topReportFiles {
            organismSeeds.append(contentsOf: parseTaxTriageTopReport(url: topReportURL))
        }

        if organismSeeds.isEmpty {
            let reportFiles = allOutputFiles.filter { $0.lastPathComponent.lowercased().hasSuffix(".report.txt") }
            for reportURL in reportFiles {
                guard let organisms = try? TaxTriageReportParser.parse(url: reportURL), !organisms.isEmpty else { continue }
                organismSeeds.append(
                    contentsOf: organisms.map {
                        TaxTriageOrganismSeed(
                            name: $0.name,
                            sampleName: nil,
                            taxID: $0.taxId,
                            rank: $0.rank,
                            readCount: $0.reads,
                            uniqueReads: nil,
                            tassScore: $0.score,
                            confidence: nil,
                            coverageBreadth: $0.coverage,
                            coverageDepth: nil,
                            abundance: nil,
                            source: "report"
                        )
                    }
                )
            }
        }

        if !organismSeeds.isEmpty {
            let sortedSeeds = organismSeeds.sorted {
                if $0.readCount == $1.readCount {
                    return ($0.tassScore ?? 0) > ($1.tassScore ?? 0)
                }
                return $0.readCount > $1.readCount
            }
            let names = sortedSeeds.map(\.name)
            attributes["detected_organism_count"] = Set(names.map(OrganismNameNormalizer.normalizedKey)).count
            attributes["detected_organisms"] = names.prefix(300).joined(separator: " | ")

            let aliases = Set(names.flatMap(organismAliases(for:)))
            if !aliases.isEmpty {
                attributes["detected_organism_aliases"] = aliases.sorted().prefix(300).joined(separator: " | ")
            }

            let foundPathogenNames = sortedSeeds
                .filter { isLikelyFoundPathogen(tassScore: $0.tassScore, confidence: $0.confidence, readCount: $0.readCount) }
                .map(\.name)
            if !foundPathogenNames.isEmpty {
                attributes["found_pathogen_count"] = Set(foundPathogenNames.map(OrganismNameNormalizer.normalizedKey)).count
                attributes["found_pathogens"] = foundPathogenNames.prefix(200).joined(separator: " | ")
                attributes["found_pathogen"] = true
            } else {
                attributes["found_pathogen"] = false
            }
        }

        let row = entityRow(
            id: "taxtriage_result:\(relPath)",
            kind: "taxtriage_result",
            title: resultDirectory.lastPathComponent,
            subtitle: "TaxTriage",
            format: "taxtriage",
            url: resultDirectory
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        let uniqueOrganisms = Set(organismSeeds.map(\.name))
        for organismName in uniqueOrganisms {
            try insertOrganismAttributes(
                entityID: row.id,
                keys: ["organism", "taxon", "virus_name"],
                name: organismName,
                includeOriginal: true,
                attributeCount: &attributeCount
            )
        }

        if !organismSeeds.isEmpty {
            let groupedByEntity = Dictionary(grouping: organismSeeds) { seed in
                let sample = seed.sampleName ?? "all"
                return "\(sample):\(OrganismNameNormalizer.normalizedKey(seed.name))"
            }

            for (_, group) in groupedByEntity {
                guard let best = group.max(by: {
                    if $0.readCount == $1.readCount {
                        return ($0.tassScore ?? 0) < ($1.tassScore ?? 0)
                    }
                    return $0.readCount < $1.readCount
                }) else { continue }

                let sampleComponent = best.sampleName.map(stableIdentifierComponent(_:)) ?? "all"
                let entityID = "taxtriage_organism:\(relPath):\(sampleComponent):\(stableIdentifierComponent(best.name))"
                let aliases = organismAliases(for: best.name)
                var organismAttributes: [String: Any] = [
                    "organism": best.name,
                    "taxon": best.name,
                    "virus_name": best.name,
                    "read_count": best.readCount,
                    "source": best.source,
                    "found_pathogen": isLikelyFoundPathogen(
                        tassScore: best.tassScore,
                        confidence: best.confidence,
                        readCount: best.readCount
                    ),
                ]
                if let sampleName = best.sampleName { organismAttributes["sample_name"] = sampleName }
                if let taxID = best.taxID { organismAttributes["tax_id"] = taxID }
                if let rank = best.rank { organismAttributes["rank"] = rank }
                if let uniqueReads = best.uniqueReads { organismAttributes["unique_reads"] = uniqueReads }
                if let tassScore = best.tassScore { organismAttributes["tass_score"] = tassScore }
                if let confidence = best.confidence { organismAttributes["confidence"] = confidence }
                if let coverageBreadth = best.coverageBreadth { organismAttributes["coverage_breadth"] = coverageBreadth }
                if let coverageDepth = best.coverageDepth { organismAttributes["coverage_depth"] = coverageDepth }
                if let abundance = best.abundance { organismAttributes["abundance_fraction"] = abundance }
                if !aliases.isEmpty { organismAttributes["search_aliases"] = aliases.joined(separator: " | ") }

                let organismRow = entityRow(
                    id: entityID,
                    kind: "taxtriage_organism",
                    title: best.name,
                    subtitle: best.sampleName ?? "TaxTriage",
                    format: "taxtriage",
                    url: resultDirectory
                )

                try insertEntity(
                    organismRow,
                    attributes: organismAttributes,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )

                try insertOrganismAttributes(
                    entityID: entityID,
                    keys: ["organism", "taxon", "virus_name"],
                    name: best.name,
                    includeOriginal: false,
                    attributeCount: &attributeCount
                )
            }
        }

        try indexSampleMetadata(
            at: resultDirectory,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    func indexNaoMgsResult(
        at resultURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultURL)
        let manifestURL = resultURL.appendingPathComponent("manifest.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestURL.path) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(NaoMgsManifest.self, from: manifestData) else {
            return
        }

        let title = manifest.sampleName

        // Build parent entity attributes
        var attributes: [String: Any] = [
            "sample_name": manifest.sampleName,
            "hit_count": manifest.hitCount,
            "read_count": manifest.hitCount,
            "taxon_count": manifest.taxonCount,
            "source_file": (manifest.sourceFilePath as NSString).lastPathComponent,
            "import_date": manifest.importDate,
            "fetched_references": manifest.fetchedAccessions.count,
        ]
        if let topTaxon = manifest.topTaxon {
            attributes["top_taxon"] = topTaxon
            attributes["taxon"] = topTaxon
            attributes["virus_name"] = topTaxon
        }
        if let topTaxonId = manifest.topTaxonId {
            attributes["top_taxon_id"] = topTaxonId
        }
        if let version = manifest.workflowVersion {
            attributes["workflow_version"] = version
        }

        // Load individual taxa — prefer cached rows from manifest, fall back to database
        let taxonRows: [NaoMgsTaxonSummaryRow]
        if let cached = manifest.cachedTaxonRows, !cached.isEmpty {
            taxonRows = cached
        } else {
            let dbURL = resultURL.appendingPathComponent("hits.sqlite")
            if fm.fileExists(atPath: dbURL.path),
               let db = try? NaoMgsDatabase(at: dbURL) {
                taxonRows = (try? db.fetchTaxonSummaryRows(samples: nil)) ?? []
            } else {
                taxonRows = []
            }
        }

        // Deduplicate by taxId — same taxon may appear across multiple samples
        var seenTaxIds = Set<Int>()
        let uniqueTaxa = taxonRows.filter { seenTaxIds.insert($0.taxId).inserted }

        // Collect organism names for parent entity detected_organisms attribute
        let organismNames = uniqueTaxa.prefix(400).map { $0.name.isEmpty ? "Taxon \($0.taxId)" : $0.name }
        if !organismNames.isEmpty {
            attributes["detected_organisms"] = organismNames.prefix(200).joined(separator: " | ")
            let allAliases = organismNames.prefix(200).flatMap { organismAliases(for: $0) }
            if !allAliases.isEmpty {
                attributes["detected_organism_aliases"] = allAliases.joined(separator: " ")
            }
        }

        let row = entityRow(
            id: "naomgs_result:\(relPath)",
            kind: "naomgs_result",
            title: title,
            subtitle: "NAO-MGS: \(manifest.hitCount) hits, \(manifest.taxonCount) taxa",
            format: "naomgs",
            url: resultURL
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        // Insert organism name attributes on parent entity for search
        let uniqueOrganismNames = Set(organismNames)
        for organismName in uniqueOrganismNames {
            try insertOrganismAttributes(
                entityID: row.id,
                keys: ["organism", "taxon", "virus_name"],
                name: organismName,
                includeOriginal: true,
                attributeCount: &attributeCount
            )
        }

        // Index child entities for each unique taxon
        for taxon in uniqueTaxa.prefix(400) {
            let taxonName = taxon.name.isEmpty ? "Taxon \(taxon.taxId)" : taxon.name
            let taxonComponent = stableIdentifierComponent(taxonName)
            let childId = "naomgs_taxon:\(relPath):\(taxon.taxId):\(taxonComponent)"

            var taxonAttrs: [String: Any] = [
                "taxon": taxonName,
                "virus_name": taxonName,
                "organism": taxonName,
                "tax_id": taxon.taxId,
                "read_count": taxon.hitCount,
                "hit_count": taxon.hitCount,
                "unique_reads": taxon.uniqueReadCount,
                "accession_count": taxon.accessionCount,
            ]
            if taxon.avgIdentity > 0 {
                taxonAttrs["avg_identity"] = taxon.avgIdentity
            }
            let aliases = organismAliases(for: taxonName)
            if !aliases.isEmpty {
                taxonAttrs["search_aliases"] = aliases.joined(separator: " ")
            }

            let childRow = entityRow(
                id: childId,
                kind: "naomgs_taxon",
                title: taxonName,
                subtitle: "\(taxon.hitCount) hits, \(taxon.uniqueReadCount) unique",
                format: "naomgs",
                url: resultURL
            )

            try insertEntity(
                childRow,
                attributes: taxonAttrs,
                entityCount: &entityCount,
                attributeCount: &attributeCount,
                perKindCounts: &perKindCounts
            )

            try insertOrganismAttributes(
                entityID: childId,
                keys: ["organism", "taxon", "virus_name"],
                name: taxonName,
                includeOriginal: false,
                attributeCount: &attributeCount
            )
        }

        try indexSampleMetadata(
            at: resultURL,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    func indexNvdResult(
        at resultURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultURL)
        let dbURL = resultURL.appendingPathComponent("hits.sqlite")
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else { return }

        guard let db = try? NvdDatabase(at: dbURL) else { return }

        let title = resultURL.lastPathComponent

        // Collect all samples and a count of hits
        let samples: [NvdSampleMetadata] = (try? db.allSamples()) ?? []
        let sampleIds = samples.map { $0.sampleId }
        let hitCount = (try? db.totalHitCount(samples: sampleIds.isEmpty ? nil : sampleIds)) ?? 0

        // Collect distinct taxon groups
        let taxonGroups: [NvdTaxonGroup] = sampleIds.isEmpty
            ? []
            : ((try? db.taxonGroups(forSamples: sampleIds)) ?? [])

        let taxonNames = taxonGroups.map { $0.adjustedTaxidName }.filter { !$0.isEmpty }

        var attributes: [String: Any] = [
            "hit_count": hitCount,
            "sample_count": samples.count,
        ]
        if let topTaxon = taxonNames.first {
            attributes["top_taxon"] = topTaxon
            attributes["taxon"] = topTaxon
        }
        if !taxonNames.isEmpty {
            attributes["detected_organisms"] = taxonNames.prefix(200).joined(separator: " | ")
            let allAliases = taxonNames.prefix(200).flatMap { organismAliases(for: $0) }
            if !allAliases.isEmpty {
                attributes["detected_organism_aliases"] = allAliases.joined(separator: " ")
            }
        }

        let row = entityRow(
            id: "nvd_result:\(relPath)",
            kind: "nvd_result",
            title: title,
            subtitle: "NVD: \(hitCount) hits, \(taxonGroups.count) taxa",
            format: "nvd",
            url: resultURL
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        // Insert organism name attributes on parent entity
        let uniqueTaxonNames = Array(Set(taxonNames))
        for name in uniqueTaxonNames {
            try insertOrganismAttributes(
                entityID: row.id,
                keys: ["organism", "taxon"],
                name: name,
                includeOriginal: true,
                attributeCount: &attributeCount
            )
        }

        // Index child entities for each distinct taxon
        for taxon in taxonGroups.prefix(400) {
            let taxonName = taxon.adjustedTaxidName
            guard !taxonName.isEmpty else { continue }
            let taxonComponent = stableIdentifierComponent(taxonName)
            let childId = "nvd_taxon:\(relPath):\(taxonComponent)"

            var taxonAttrs: [String: Any] = [
                "taxon": taxonName,
                "organism": taxonName,
                "contig_count": taxon.contigCount,
                "mapped_reads": taxon.totalMappedReads,
            ]
            let aliases = organismAliases(for: taxonName)
            if !aliases.isEmpty {
                taxonAttrs["search_aliases"] = aliases.joined(separator: " ")
            }

            let childRow = entityRow(
                id: childId,
                kind: "nvd_taxon",
                title: taxonName,
                subtitle: "\(taxon.contigCount) contigs, \(taxon.totalMappedReads) mapped reads",
                format: "nvd",
                url: resultURL
            )

            try insertEntity(
                childRow,
                attributes: taxonAttrs,
                entityCount: &entityCount,
                attributeCount: &attributeCount,
                perKindCounts: &perKindCounts
            )

            try insertOrganismAttributes(
                entityID: childId,
                keys: ["organism", "taxon"],
                name: taxonName,
                includeOriginal: false,
                attributeCount: &attributeCount
            )
        }

        try indexSampleMetadata(
            at: resultURL,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    /// Index sample metadata values from a classification bundle.
    func indexSampleMetadata(
        at bundleURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let tsvURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
        guard FileManager.default.fileExists(atPath: tsvURL.path),
              let data = try? Data(contentsOf: tsvURL) else { return }

        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first, lines.count > 1 else { return }
        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let headers = headerLine.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard headers.count >= 2 else { return }
        let columns = Array(headers.dropFirst())

        let relPath = bundleURL.lastPathComponent

        for line in lines.dropFirst() {
            let fields = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
            guard let sampleId = fields.first else { continue }

            for (i, col) in columns.enumerated() {
                let value = (i + 1) < fields.count ? fields[i + 1] : ""
                guard !value.isEmpty else { continue }

                let entityId = "sample_metadata:\(relPath):\(sampleId):\(col)"
                let row = EntityRow(
                    id: entityId,
                    kind: "sample_metadata",
                    title: value,
                    subtitle: "Sample: \(sampleId), Field: \(col)",
                    format: nil,
                    relPath: relPath,
                    url: bundleURL,
                    mtime: nil,
                    sizeBytes: nil
                )
                try insertEntity(
                    row,
                    attributes: [
                        "sample_id": sampleId,
                        "field_name": col,
                        "field_value": value,
                    ],
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }
        }
    }

    func indexManifestDocument(
        at fileURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        guard let flattened = flattenJSONFile(at: fileURL), !flattened.isEmpty else { return }

        let relPath = relativePath(for: fileURL)
        let row = entityRow(
            id: "manifest_document:\(relPath)",
            kind: "manifest_document",
            title: fileURL.lastPathComponent,
            subtitle: relPath,
            format: "json",
            url: fileURL
        )

        var attributes: [String: Any] = [
            "filename": fileURL.lastPathComponent,
            "relative_path": relPath,
        ]

        for (key, value) in flattened {
            attributes[key] = value
        }

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }
}
