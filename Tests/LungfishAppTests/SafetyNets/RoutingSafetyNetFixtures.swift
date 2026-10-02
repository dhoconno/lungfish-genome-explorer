// RoutingSafetyNetFixtures.swift - Fixtures for the routing-table safety net
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One builder per routed kind. Committed inputs come from Tests/Fixtures,
// TestData and the demo-project builder inputs under docs/user-manual/fixtures.
// Where no committed bundle exists, a small bundle is written with the same
// production writers, manifests and importers the app uses. Every builder
// writes under a scratch root and never into the repository.
//
// The MHC builder reads the demo-project builder's inputs under
// docs/user-manual/fixtures/mhc-simulated. If those inputs move, update
// SafetyNetPaths.manualFixture callers here and in the sidebar projects.

import AppKit
import Foundation
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

enum RoutingSafetyNetFixtures {

    // MARK: - Plain files

    /// The SARS-CoV-2 (MT192765.1) fixture set described in Tests/Fixtures/README.md.
    static var sarsCoV2: URL { SafetyNetPaths.fixture("sarscov2") }

    /// Writes a 2 by 2 pixel PNG, since no image is committed under Tests/Fixtures.
    static func pngImage(named name: String, in directory: URL) throws -> URL {
        let bitmap = try unwrapped(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let data = try unwrapped(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try SafetyNetFiles.makeDirectory(directory)
        try data.write(to: url)
        return url
    }

    private struct MissingValue: Error {}

    private static func unwrapped<T>(_ value: T?) throws -> T {
        guard let value else { throw MissingValue() }
        return value
    }

    // MARK: - Reference bundles

    /// Packages the committed SARS-CoV-2 genome as a `.lungfishref` bundle.
    ///
    /// With `publishTracks`, the committed sorted BAM is registered as an
    /// alignment track and the committed VCF as a variant track, which is the
    /// state a mapping run or Viral Recon publication leaves the bundle in.
    /// The alignment track carries a metadata database, so no viewport has to
    /// derive per-sample statistics before it can list the track.
    @discardableResult
    static func sarsCoV2ReferenceBundle(
        named name: String,
        in directory: URL,
        publishTracks: Bool
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try SafetyNetFiles.copy(
            sarsCoV2.appendingPathComponent("genome.fasta"),
            to: bundleURL.appendingPathComponent("genome/sequence.fa")
        )
        let indexURL = try SafetyNetFiles.copy(
            sarsCoV2.appendingPathComponent("genome.fasta.fai"),
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai")
        )
        let chromosomes = try chromosomeInfos(fromFASTAIndex: indexURL)

        var alignments: [AlignmentTrackInfo] = []
        var variants: [VariantTrackInfo] = []
        if publishTracks {
            try SafetyNetFiles.copy(
                sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam"),
                to: bundleURL.appendingPathComponent(publishedBAMPath)
            )
            try SafetyNetFiles.copy(
                sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam.bai"),
                to: bundleURL.appendingPathComponent(publishedBAMPath + ".bai")
            )
            let metadataPath = "alignments/sample.metadata.sqlite"
            let metadata = try AlignmentMetadataDatabase.create(
                at: bundleURL.appendingPathComponent(metadataPath)
            )
            for chromosome in chromosomes {
                metadata.addChromosomeStats(
                    chromosome: chromosome.name,
                    length: chromosome.length,
                    mapped: 200,
                    unmapped: 0
                )
            }
            alignments = [
                AlignmentTrackInfo(
                    id: publishedAlignmentTrackID,
                    name: "sample alignment",
                    sourcePath: publishedBAMPath,
                    indexPath: publishedBAMPath + ".bai",
                    metadataDBPath: metadataPath,
                    mappedReadCount: 200,
                    unmappedReadCount: 0,
                    sampleNames: ["sample"]
                ),
            ]
            try SafetyNetFiles.copy(
                sarsCoV2.appendingPathComponent("test.vcf.gz"),
                to: bundleURL.appendingPathComponent(publishedVCFPath)
            )
            try SafetyNetFiles.copy(
                sarsCoV2.appendingPathComponent("test.vcf.gz.tbi"),
                to: bundleURL.appendingPathComponent(publishedVCFPath + ".tbi")
            )
            variants = [
                VariantTrackInfo(
                    id: publishedVariantTrackID,
                    name: "sample variants",
                    path: publishedVCFPath,
                    indexPath: publishedVCFPath + ".tbi"
                ),
            ]
        }

        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.safetynet.\(name)",
            source: SourceInfo(
                organism: "Severe acute respiratory syndrome coronavirus 2",
                assembly: chromosomes.first?.name ?? name
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: chromosomes.reduce(0) { $0 + $1.length },
                chromosomes: chromosomes
            ),
            variants: variants,
            alignments: alignments
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    static let publishedAlignmentTrackID = "sample-alignment"
    static let publishedVariantTrackID = "sample-variants"
    static let publishedBAMPath = "alignments/sample.sorted.bam"
    static let publishedVCFPath = "variants/sample.vcf.gz"

    /// Reads a samtools `.fai` index into the manifest's chromosome records.
    static func chromosomeInfos(fromFASTAIndex indexURL: URL) throws -> [ChromosomeInfo] {
        try String(contentsOf: indexURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { line in
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count >= 5,
                      let length = Int64(fields[1]),
                      let offset = Int64(fields[2]),
                      let lineBases = Int(fields[3]),
                      let lineWidth = Int(fields[4]) else {
                    throw MissingValue()
                }
                return ChromosomeInfo(
                    name: fields[0],
                    length: length,
                    offset: offset,
                    lineBases: lineBases,
                    lineWidth: lineWidth
                )
            }
    }

    /// The committed TestData genome bundle with annotation, variant and signal tracks.
    static func testGenomeReferenceBundle(in directory: URL) throws -> URL {
        try SafetyNetFiles.copy(SafetyNetPaths.testData("TestGenome.lungfishref"), into: directory)
    }

    /// An MHC amplicon reference bundle built from the simulated macaque
    /// inputs of the demo-project builder, which are the three-allele reference
    /// and the teaching haplotype definition the MHC Genotyping demo installs.
    static func mhcReferenceBundle(in directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent(
            "SIMULATED-MHC-MCM-teaching.\(MHCAmpliconReferenceBundle.directoryExtension)",
            isDirectory: true
        )
        try SafetyNetFiles.copy(
            SafetyNetPaths.manualFixture("mhc-simulated/SIMULATED-MHC-reference.fasta"),
            to: bundleURL.appendingPathComponent("reference.fa")
        )
        let definitionPath = "haplotypes/mhc-simulated-mcm-teaching.json"
        try SafetyNetFiles.copy(
            SafetyNetPaths.manualFixture("mhc-simulated/mhc-simulated-mcm-teaching.lungfishhaplotypedef.json"),
            to: bundleURL.appendingPathComponent(definitionPath)
        )
        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "SIMULATED-MHC-MCM-teaching",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: [definitionPath],
            defaultHaplotypeDefinitionID: "mhc-simulated-mcm-teaching",
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 3, haplotypeDefinitionCount: 1),
            createdAt: "2026-09-25T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)
        return bundleURL
    }

    // MARK: - Sequence-analysis bundles

    /// The committed MAFFT alignment bundle from the alignment fixture project.
    static func multipleSequenceAlignmentBundle(in directory: URL) throws -> URL {
        try SafetyNetFiles.copy(
            SafetyNetPaths.fixture(
                "alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa"
            ),
            into: directory
        )
    }

    /// A tree bundle imported from the committed sarcopterygian Newick tree.
    static func phylogeneticTreeBundle(in directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent("known-sarcopterygian.lungfishtree", isDirectory: true)
        try SafetyNetFiles.makeDirectory(directory)
        _ = try PhylogeneticTreeBundleImporter.importTree(
            from: SafetyNetPaths.fixture("phylogenetics/known-sarcopterygian/expected.nwk"),
            to: bundleURL
        )
        return bundleURL
    }

    /// A FASTQ bundle around the committed Illumina R1 reads, with cached
    /// statistics so the dashboard opens without running seqkit.
    static func fastqBundle(in directory: URL) async throws -> (bundle: URL, fastq: URL) {
        let bundleURL = directory.appendingPathComponent(
            "illumina-reads.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let fastqURL = try SafetyNetFiles.copy(
            SafetyNetPaths.fixture("assembly-ui/illumina/reads_R1.fastq"),
            to: bundleURL.appendingPathComponent("illumina-reads.fastq")
        )
        let computed = try await FASTQReader(validateSequence: false).computeStatistics(from: fastqURL)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(computedStatistics: computed.statistics),
            for: fastqURL
        )
        return (bundleURL, fastqURL)
    }

    /// An empty saved primer analysis. The viewer installs before it loads, so
    /// the route and its Inspector binding do not depend on the payload.
    static func primerAnalysisBundle(in directory: URL) throws -> URL {
        try SafetyNetFiles.makeDirectory(
            directory.appendingPathComponent("Mamu-A1 assay.lungfishprimeranalysis", isDirectory: true)
        )
    }

    /// The committed QIAseq DIRECT SARS-CoV-2 primer scheme.
    static func primerSchemeBundle(in directory: URL) throws -> URL {
        try SafetyNetFiles.copy(
            SafetyNetPaths.fixture("primerschemes/QIASeqDIRECT-SARS2.lungfishprimers"),
            into: directory
        )
    }

    /// A genotype result bundle for one cynomolgus macaque sample. With calls it
    /// opens the native matrix. Without calls it previews the primary workbook.
    static func genotypeResultBundle(in directory: URL, withCalls: Bool) throws -> URL {
        let name = withCalls ? "DW472-mhc" : "DW472-mhc-workbook"
        let bundleURL = directory.appendingPathComponent("\(name).lungfishgenotype", isDirectory: true)
        try SafetyNetFiles.makeDirectory(bundleURL)
        try Data("workbook".utf8).write(to: bundleURL.appendingPathComponent("\(name).xlsx"))
        let calls = withCalls ? "DW472,01_Mafa_A1_063g,10,8\n" : ""
        try SafetyNetFiles.write(
            "sample,genotype,passed_alignments,passed_unique_reads\n" + calls,
            to: bundleURL.appendingPathComponent("\(name).retained-demux-genotypes.csv")
        )
        try SafetyNetFiles.write(
            "sample,passed_alignments,passed_unique_reads\n" + (withCalls ? "DW472,10,8\n" : ""),
            to: bundleURL.appendingPathComponent("\(name).retained-demux-samples.csv")
        )
        try SafetyNetFiles.write(
            #"{"totalInputReads":10,"retainedUniqueReads":8}"#,
            to: bundleURL.appendingPathComponent("\(name).retained-demux-stats.json")
        )
        try SafetyNetFiles.write(
            #"{"workflow":"safety-net"}"#,
            to: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: name,
            analysisName: name,
            primaryWorkbookPath: "\(name).xlsx",
            longSummaryCSVPath: "\(name).retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "\(name).retained-demux-samples.csv",
            statsJSONPath: "\(name).retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json",
            haplotypeAnalysisPath: nil,
            haplotypeDefinitionSetID: nil
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return bundleURL
    }

    /// A 12S amplicon result with a human sample and a rhesus macaque sample.
    static func twelveSResultBundle(in directory: URL) throws -> (bundle: URL, sampleIDs: [String]) {
        let bundleURL = directory.appendingPathComponent(
            "primate-12s.\(TwelveSAmpliconResultBundle.directoryExtension)",
            isDirectory: true
        )
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "primate-12s",
            analysisName: "Primate 12S",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-09-25T00:00:00Z"
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)
        try SafetyNetFiles.write(">human\nACGT\n>rhesus\nACGA\n", to: bundleURL.appendingPathComponent("reference.fa"))
        try SafetyNetFiles.write("{}", to: bundleURL.appendingPathComponent(".lungfish-provenance.json"))
        try SafetyNetFiles.write(
            """
            target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header
            human\thuman (Homo sapiens)\tHomo sapiens\thuman\t9606\tMammal\troot; Eukaryota; Chordata; Mammalia; Primates; Homo sapiens\tncbi_common\t12S\t107\t12\t1\t12S_vert_F_x_12S_vert_R\thuman (Homo sapiens)|locus=12S|len=107
            rhesus\trhesus macaque (Macaca mulatta)\tMacaca mulatta\trhesus macaque\t9544\tMammal\troot; Eukaryota; Chordata; Mammalia; Primates; Macaca mulatta\tncbi_common\t12S\t106\t4\t1\t12S_vert_F_x_12S_vert_R\trhesus macaque (Macaca mulatta)|locus=12S|len=106

            """,
            to: bundleURL.appendingPathComponent("targets.tsv")
        )
        try SafetyNetFiles.write(
            """
            target_id\tHG002\tMMU-17\tExtractionBlank
            human\t40\t0\t1
            rhesus\t0\t35\t0

            """,
            to: bundleURL.appendingPathComponent("sample-target-counts.tsv")
        )
        try SafetyNetFiles.write(
            """
            sample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent
            HG002\tHG002 human\t50\t40\t10\t0\t0\t80.0\t20.0
            MMU-17\tMMU-17 rhesus\t40\t35\t5\t0\t0\t87.5\t12.5
            ExtractionBlank\tExtraction blank\t5\t1\t4\t0\t0\t20.0\t80.0

            """,
            to: bundleURL.appendingPathComponent("samples.tsv")
        )
        try SafetyNetFiles.write(
            #"{"totalReads":95,"exactMatchReads":76,"unresolvedReads":19,"ambiguousExactReads":0,"chimeraCandidateReads":0}"#,
            to: bundleURL.appendingPathComponent("read-fate.json")
        )
        return (bundleURL, ["HG002", "MMU-17", "ExtractionBlank"])
    }

    // MARK: - Classifier results

    /// A Kraken2 result directory holding a built `kraken2.sqlite`. With
    /// `sampleSubdirectories`, each sample also gets its own result folder, the
    /// batch layout the per-sample route filters to.
    static func kraken2Result(
        named name: String,
        in directory: URL,
        samples: [String],
        sampleSubdirectories: Bool = false
    ) throws -> URL {
        let resultURL = try SafetyNetFiles.makeDirectory(directory.appendingPathComponent(name, isDirectory: true))
        _ = try Kraken2Database.create(
            at: resultURL.appendingPathComponent("kraken2.sqlite"),
            rows: samples.map { sample in
                Kraken2ClassificationRow(
                    sample: sample, taxonName: "Homo sapiens", taxId: 9606, rank: "S",
                    rankDisplayName: "Species", readsDirect: 50, readsClade: 100, percentage: 1.0,
                    parentTaxId: nil, depth: 0, fractionDirect: 0.0
                )
            },
            metadata: ["tool": "kraken2"]
        )
        if sampleSubdirectories {
            for sample in samples {
                try SafetyNetFiles.makeDirectory(resultURL.appendingPathComponent(sample, isDirectory: true))
            }
        }
        return resultURL
    }

    /// An EsViritu result directory holding a built `esviritu.sqlite`.
    static func esVirituResult(named name: String, in directory: URL, samples: [String]) throws -> URL {
        let resultURL = try SafetyNetFiles.makeDirectory(directory.appendingPathComponent(name, isDirectory: true))
        try EsVirituDatabase.create(
            at: resultURL.appendingPathComponent("esviritu.sqlite"),
            rows: samples.map { sample in
                EsVirituDetectionRow(
                    sample: sample, virusName: "Human mastadenovirus C", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_001405.1",
                    assembly: "GCF_000845085.1", assemblyLength: 35_937, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
                )
            },
            metadata: ["tool": "esviritu"]
        )
        return resultURL
    }

    /// A TaxTriage result directory holding a built `taxtriage.sqlite`.
    static func taxTriageResult(named name: String, in directory: URL, samples: [String]) throws -> URL {
        let resultURL = try SafetyNetFiles.makeDirectory(directory.appendingPathComponent(name, isDirectory: true))
        _ = try TaxTriageDatabase.create(
            at: resultURL.appendingPathComponent("taxtriage.sqlite"),
            rows: samples.map { sample in
                TaxTriageTaxonomyRow(
                    sample: sample, organism: "Human alphaherpesvirus 1", taxId: nil, status: nil,
                    tassScore: 0.9, readsAligned: 100, uniqueReads: nil,
                    pctReads: nil, pctAlignedReads: nil, coverageBreadth: nil,
                    meanCoverage: nil, meanDepth: nil, confidence: nil,
                    k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
                    meanBaseQ: nil, meanMapQ: nil, mapqScore: nil,
                    disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
                    k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
                    hhsPercentile: nil, isAnnotated: nil, annClass: nil,
                    microbialCategory: nil, highConsequence: nil, isSpecies: nil,
                    pathogenicSubstrains: nil, sampleType: nil,
                    bamPath: nil, bamIndexPath: nil,
                    primaryAccession: nil, accessionLength: nil
                )
            },
            metadata: ["tool": "taxtriage"]
        )
        return resultURL
    }

    /// A NAO-MGS result bundle built from the committed virus hits table, the
    /// file the Pathogen Detection demo ships as practice data.
    static func naoMgsResult(named name: String, in directory: URL) async throws -> (bundle: URL, samples: Set<String>) {
        let bundleURL = try SafetyNetFiles.makeDirectory(directory.appendingPathComponent(name, isDirectory: true))
        let hits = try await NaoMgsResultParser().parseVirusHits(
            at: SafetyNetPaths.fixture("naomgs/virus_hits_final.tsv.gz")
        )
        try NaoMgsDatabase.create(at: bundleURL.appendingPathComponent("hits.sqlite"), hits: hits)
        let samples = Set(hits.map(\.sample))
        let manifest = NaoMgsManifest(
            sampleName: samples.sorted().first ?? name,
            sourceFilePath: "virus_hits_final.tsv.gz",
            hitCount: hits.count,
            taxonCount: Set(hits.map(\.taxId)).count
        )
        try writeISO8601JSON(manifest, to: bundleURL.appendingPathComponent("manifest.json"))
        return (bundleURL, samples)
    }

    /// An NVD result bundle built from the committed BLAST table.
    static func nvdResult(named name: String, in directory: URL) async throws -> (bundle: URL, samples: Set<String>) {
        let bundleURL = try SafetyNetFiles.makeDirectory(directory.appendingPathComponent(name, isDirectory: true))
        let parsed = try await NvdResultParser().parse(at: SafetyNetPaths.fixture("nvd/test_blast_concatenated.csv"))
        let sampleIDs = parsed.sampleIds.sorted()
        let samples = sampleIDs.map { sampleID -> NvdSampleMetadata in
            let sampleHits = parsed.hits.filter { $0.sampleId == sampleID }
            return NvdSampleMetadata(
                sampleId: sampleID,
                bamPath: "\(sampleID).bam",
                fastaPath: "\(sampleID).fasta",
                totalReads: sampleHits.first?.totalReads ?? 0,
                contigCount: Set(sampleHits.map(\.qseqid)).count,
                hitCount: sampleHits.count
            )
        }
        try NvdDatabase.create(at: bundleURL.appendingPathComponent("hits.sqlite"), hits: parsed.hits, samples: samples)
        let manifest = NvdManifest(
            experiment: parsed.experiment,
            sampleCount: samples.count,
            contigCount: samples.reduce(0) { $0 + $1.contigCount },
            hitCount: parsed.hits.count,
            blastDbVersion: parsed.hits.first?.blastDbVersion,
            snakemakeRunId: parsed.hits.first?.snakemakeRunId,
            sourceDirectoryPath: "nvd",
            samples: samples.map {
                NvdSampleSummary(
                    sampleId: $0.sampleId,
                    contigCount: $0.contigCount,
                    hitCount: $0.hitCount,
                    totalReads: $0.totalReads,
                    bamRelativePath: $0.bamPath,
                    fastaRelativePath: $0.fastaPath
                )
            },
            cachedTopContigs: nil
        )
        try writeISO8601JSON(manifest, to: bundleURL.appendingPathComponent("manifest.json"))
        return (bundleURL, parsed.sampleIds)
    }

    /// A CZ ID taxonomy bundle converted in process from the committed taxon
    /// report, which the Pathogen Detection demo also ships.
    static func czIdResult(named name: String, in directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent(name, isDirectory: true)
        _ = try CzIdDataConverter.convertTaxonReport(
            at: SafetyNetPaths.fixture("czid/minimal_taxon_report.tsv"),
            outputDirectory: bundleURL
        )
        return bundleURL
    }

    // MARK: - Analysis results

    /// The committed SPAdes analysis seed. Its schema 1 sidecar lacks the
    /// fields the assembly loader reads, so selecting it reports a load failure.
    static func assemblySeedAnalysis(in analysesDirectory: URL) throws -> URL {
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("analyses/spades-2026-01-15T13-00-00"), into: analysesDirectory)
    }

    /// The committed minimap2 analysis seed. Its `alignment-result.json`
    /// stores `runtime` where the legacy loader reads `wallClockSeconds`, so
    /// selecting it reports a load failure.
    static func mappingSeedAnalysis(in analysesDirectory: URL) throws -> URL {
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("analyses/minimap2-2026-01-15T14-00-00"), into: analysesDirectory)
    }

    /// A SPAdes assembly saved with the assembly pipeline's own writer, around
    /// the contigs of the committed SPAdes seed.
    static func assemblyAnalysis(in analysesDirectory: URL) throws -> (result: URL, contigs: URL) {
        let resultURL = try SafetyNetFiles.makeDirectory(
            analysesDirectory.appendingPathComponent("spades-2026-01-15T13-30-00", isDirectory: true)
        )
        let contigs = try SafetyNetFiles.copy(
            SafetyNetPaths.fixture("analyses/spades-2026-01-15T13-00-00/contigs.fasta"),
            into: resultURL
        )
        try AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: contigs,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "4.0.0",
            commandLine: "spades.py --isolate -1 HG002_R1.fastq.gz -2 HG002_R2.fastq.gz -o spades",
            outputDirectory: resultURL,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigs),
            wallTimeSeconds: 1
        ).save(to: resultURL)
        return (resultURL, contigs)
    }

    /// A minimap2 result from before mapping results carried a viewer bundle,
    /// with only the `alignment-result.json` sidecar beside the committed BAM.
    static func legacyMappingAnalysis(in analysesDirectory: URL) throws -> (result: URL, bam: URL) {
        let resultURL = try SafetyNetFiles.makeDirectory(
            analysesDirectory.appendingPathComponent("minimap2-2026-01-15T14-30-00", isDirectory: true)
        )
        let bam = try SafetyNetFiles.copy(
            sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam"),
            to: resultURL.appendingPathComponent("sample.sorted.bam")
        )
        try SafetyNetFiles.copy(
            sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam.bai"),
            to: resultURL.appendingPathComponent("sample.sorted.bam.bai")
        )
        try SafetyNetFiles.write(
            """
            {
              "baiPath" : "sample.sorted.bam.bai",
              "bamPath" : "sample.sorted.bam",
              "mappedReads" : 200,
              "savedAt" : "2026-01-15T14:30:00Z",
              "schemaVersion" : 1,
              "toolVersion" : "2.28",
              "totalReads" : 200,
              "unmappedReads" : 0,
              "wallClockSeconds" : 45.2
            }
            """,
            to: resultURL.appendingPathComponent("alignment-result.json")
        )
        return (resultURL, bam)
    }

    /// A minimap2 analysis whose viewer bundle registers the committed BAM.
    static func mappingAnalysis(in analysesDirectory: URL) throws -> (result: URL, viewerBundle: URL, bam: URL) {
        let resultURL = try SafetyNetFiles.makeDirectory(
            analysesDirectory.appendingPathComponent("minimap2-2026-01-15T16-00-00", isDirectory: true)
        )
        let viewerBundle = try sarsCoV2ReferenceBundle(named: "MT192765.1", in: resultURL, publishTracks: true)
        let bamURL = viewerBundle.appendingPathComponent(publishedBAMPath)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundle,
            bamURL: bamURL,
            baiURL: bamURL.appendingPathExtension("bai"),
            totalReads: 200,
            mappedReads: 200,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: [
                MappingContigSummary(
                    contigName: "MT192765.1",
                    contigLength: 29_829,
                    mappedReads: 200,
                    mappedReadPercent: 100,
                    meanDepth: 1,
                    coverageBreadth: 0.5,
                    medianMAPQ: 60,
                    meanIdentity: 99
                ),
            ]
        )
        try result.save(to: resultURL)
        return (resultURL, viewerBundle, bamURL)
    }

    /// A Viral Recon run ingested with the production ingest step, then
    /// published the way ViralReconViewerPublication leaves it, with the run's
    /// BAM and VCF registered in the manifest of the copied `.lungfishref`.
    ///
    /// Publication itself runs samtools through BAMImportService, so the
    /// registration is written directly with the committed BAM and VCF.
    static func viralReconAnalyses(
        projectURL: URL,
        scratch: URL,
        sampleNames: [String]
    ) throws -> [ViralReconResultIngest.Ingested] {
        let reference = try sarsCoV2ReferenceBundle(
            named: "MT192765.1",
            in: scratch.appendingPathComponent("viralrecon-reference", isDirectory: true),
            publishTracks: false
        )
        let results = scratch.appendingPathComponent("nf-core-results", isDirectory: true)
        for sample in sampleNames {
            try SafetyNetFiles.write("", to: results.appendingPathComponent("variants/bowtie2/\(sample).sorted.bam"))
            try SafetyNetFiles.write("", to: results.appendingPathComponent("variants/bowtie2/\(sample).sorted.bam.bai"))
            try SafetyNetFiles.write("", to: results.appendingPathComponent("variants/ivar/\(sample).vcf.gz"))
            try SafetyNetFiles.write(
                ">\(sample)\nACGT\n",
                to: results.appendingPathComponent("variants/ivar/consensus/bcftools/\(sample).consensus.fa")
            )
        }
        try SafetyNetFiles.write("<html></html>", to: results.appendingPathComponent("multiqc/multiqc_report.html"))
        try SafetyNetFiles.makeDirectory(projectURL)

        let ingested = try ViralReconResultIngest.ingestRun(
            resultsDirectory: results,
            sampleNames: sampleNames,
            referenceBundleURL: reference,
            projectURL: projectURL
        )
        for entry in ingested {
            try publishCommittedTracks(into: entry.referenceBundleURL)
        }
        return ingested
    }

    /// Registers the committed BAM and VCF in an existing reference bundle.
    static func publishCommittedTracks(into bundleURL: URL) throws {
        let staged = try sarsCoV2ReferenceBundle(
            named: "staged",
            in: bundleURL.deletingLastPathComponent().appendingPathComponent(".staged-tracks", isDirectory: true),
            publishTracks: true
        )
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        for directory in ["alignments", "variants"] {
            try FileManager.default.copyItem(
                at: staged.appendingPathComponent(directory, isDirectory: true),
                to: bundleURL.appendingPathComponent(directory, isDirectory: true)
            )
        }
        let manifest = try BundleManifest.load(from: bundleURL)
        let published = try BundleManifest.load(from: staged)
        try BundleManifest(
            formatVersion: manifest.formatVersion,
            name: manifest.name,
            identifier: manifest.identifier,
            description: manifest.description,
            originBundlePath: manifest.originBundlePath,
            createdDate: manifest.createdDate,
            modifiedDate: manifest.modifiedDate,
            source: manifest.source,
            genome: manifest.genome,
            annotations: manifest.annotations,
            variants: manifest.variants + published.variants,
            tracks: manifest.tracks,
            alignments: manifest.alignments + published.alignments,
            metadata: manifest.metadata,
            browserSummary: manifest.browserSummary,
            warnings: manifest.warnings,
            recordStore: manifest.recordStore
        ).save(to: bundleURL)
    }

    /// A reviewed primer order, recognised by its analysis metadata.
    static func primerOrderAnalysis(in analysesDirectory: URL) throws -> URL {
        let url = try SafetyNetFiles.makeDirectory(
            analysesDirectory.appendingPathComponent("primer-order-2026-01-15T18-00-00", isDirectory: true)
        )
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "primer-order", isBatch: false), to: url)
        return url
    }

    /// A Savont batch with one per-sample FASTA output, the loose-file layout
    /// the batch scan lists as children.
    static func savontBatch(in analysesDirectory: URL) throws -> (batch: URL, sampleFASTA: URL) {
        let batch = try SafetyNetFiles.makeDirectory(
            analysesDirectory.appendingPathComponent("savont-batch-2026-01-15T19-00-00", isDirectory: true)
        )
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "savont", isBatch: true), to: batch)
        let fasta = try SafetyNetFiles.copy(
            sarsCoV2.appendingPathComponent("genome.fasta"),
            to: batch.appendingPathComponent("sample-a.fasta")
        )
        return (batch, fasta)
    }

    /// An analysis directory for a recognised tool that has no viewer.
    static func viewerlessAnalysis(tool: String, in analysesDirectory: URL) throws -> URL {
        let url = try SafetyNetFiles.makeDirectory(
            analysesDirectory.appendingPathComponent("\(tool)-2026-01-15T20-00-00", isDirectory: true)
        )
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: tool, isBatch: false), to: url)
        return url
    }

    // MARK: - Helpers

    static func writeISO8601JSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SafetyNetFiles.makeDirectory(url.deletingLastPathComponent())
        try encoder.encode(value).write(to: url)
    }
}
