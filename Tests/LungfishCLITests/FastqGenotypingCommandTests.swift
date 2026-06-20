import XCTest
@testable import LungfishCLI

final class FastqGenotypingCommandTests: XCTestCase {
    func testFastqCommandRegistersPlatformNeutralGenotype() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("genotype"))
        XCTAssertTrue(names.contains("genotype-cohort"))
        XCTAssertTrue(names.contains("update-current-workbook"))
        XCTAssertTrue(names.contains("ont-fluidigm-samples"))
        XCTAssertTrue(names.contains("ont-pacbio-barcode-demux"))
        XCTAssertTrue(names.contains("mhc-reference-bundle"))
    }

    func testUpdateCurrentWorkbookParsesBundleCallsAndAnnotations() throws {
        let command = try FastqUpdateCurrentWorkbookSubcommand.parse([
            "/tmp/barcode11-mhc.lungfishgenotype",
            "--calls-json", "/tmp/barcode11-mhc/artifacts/workbooks/updates/calls.json",
            "--annotations", "/tmp/barcode11-mhc.lungfishgenotype/annotations.json",
        ])

        XCTAssertEqual(command.bundle, "/tmp/barcode11-mhc.lungfishgenotype")
        XCTAssertEqual(command.callsJSON, "/tmp/barcode11-mhc/artifacts/workbooks/updates/calls.json")
        XCTAssertEqual(command.annotations, "/tmp/barcode11-mhc.lungfishgenotype/annotations.json")
    }

    func testONTFluidigmSamplesCommandParsesRequiredInputs() throws {
        let command = try FastqONTFluidigmSamplesSubcommand.parse([
            "/tmp/barcode11.lungfishfastq",
            "--barcodes", "/tmp/ONT09_NB11_samples.csv",
            "--output", "/tmp/ont-fluidigm-samples",
            "--threads", "8",
            "--primer-mismatches", "2",
            "--minimum-insert-length", "40",
            "--no-canonicalize-reverse-complements",
            "--force",
        ])

        XCTAssertEqual(command.input, "/tmp/barcode11.lungfishfastq")
        XCTAssertEqual(command.barcodes, "/tmp/ONT09_NB11_samples.csv")
        XCTAssertEqual(command.output, "/tmp/ont-fluidigm-samples")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.primerMismatches, 2)
        XCTAssertEqual(command.minimumInsertLength, 40)
        XCTAssertFalse(command.canonicalizeReverseComplements)
        XCTAssertTrue(command.force)
    }

    func testONTPacBioBarcodeDemuxCommandParsesRequiredInputs() throws {
        let command = try FastqONTPacBioBarcodeDemuxSubcommand.parse([
            "/tmp/fastq_pass/barcode13",
            "--barcodes", "/tmp/NB13_MHC-I_plate1.barcodes.csv",
            "--output", "/tmp/mhc-pacbio-demux",
            "--threads", "4",
            "--chunk-jobs", "6",
            "--max-reads-per-slice", "100000",
            "--max-bytes-per-cutadapt", "536870912",
            "--force",
        ])

        XCTAssertEqual(command.input, "/tmp/fastq_pass/barcode13")
        XCTAssertEqual(command.barcodes, "/tmp/NB13_MHC-I_plate1.barcodes.csv")
        XCTAssertEqual(command.output, "/tmp/mhc-pacbio-demux")
        XCTAssertEqual(command.threads, 4)
        XCTAssertEqual(command.chunkJobs, 6)
        XCTAssertEqual(command.maxReadsPerSlice, 100_000)
        XCTAssertEqual(command.maxBytesPerCutadapt, 536_870_912)
        XCTAssertTrue(command.force)
    }

    func testONTPacBioBarcodeDemuxCommandDefaultsToOneChunkJobPerActiveProcessor() throws {
        let command = try FastqONTPacBioBarcodeDemuxSubcommand.parse([
            "/tmp/fastq_pass/barcode13",
            "--barcodes", "/tmp/NB13_MHC-I_plate1.barcodes.csv",
            "--output", "/tmp/mhc-pacbio-demux",
        ])

        XCTAssertEqual(command.threads, 1)
        XCTAssertEqual(command.chunkJobs, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    func testGenotypeCohortParsesONTSampleBundlesWithoutBarcodes() throws {
        let command = try FastqGenotypingCohortSubcommand.parse([
            "/tmp/LF2871.lungfishfastq",
            "/tmp/LF2872.lungfishfastq",
            "--mode", "ont-sample-bundles",
            "--read-type", "ont",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "ont-mhc",
            "--project", "/tmp/project.lungfish",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
        ])

        XCTAssertEqual(command.inputs, ["/tmp/LF2871.lungfishfastq", "/tmp/LF2872.lungfishfastq"])
        XCTAssertEqual(command.mode, "ont-sample-bundles")
        XCTAssertEqual(command.readType, "ont")
        XCTAssertNil(command.barcodes)
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputName, "ont-mhc")
    }

    func testGenotypeCohortParsesIlluminaPairedInputsWithoutBarcodes() throws {
        let command = try FastqGenotypingCohortSubcommand.parse([
            "/tmp/DW001.lungfishfastq",
            "/tmp/DW002.lungfishfastq",
            "/tmp/DW003.lungfishfastq",
            "--mode", "illumina-paired",
            "--read-type", "illumina",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "miseq-mhc",
            "--project", "/tmp/project.lungfish",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-definition", "MHC-exon2-miSeq.rhesus-macaques",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
        ])

        XCTAssertEqual(command.inputs, [
            "/tmp/DW001.lungfishfastq",
            "/tmp/DW002.lungfishfastq",
            "/tmp/DW003.lungfishfastq",
        ])
        XCTAssertEqual(command.mode, "illumina-paired")
        XCTAssertEqual(command.readType, "illumina")
        XCTAssertNil(command.barcodes)
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputName, "miseq-mhc")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.sortThreads, 2)
        XCTAssertEqual(command.minSupport, 3)
    }

    func testGenotypeParsesIlluminaPairedInputsWithoutBarcodes() throws {
        let command = try FastqGenotypingSubcommand.parse([
            "/tmp/DW001.lungfishfastq",
            "/tmp/DW002.lungfishfastq",
            "--mode", "illumina-paired",
            "--read-type", "illumina",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "miseq-mhc",
            "--project", "/tmp/project.lungfish",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-definition", "MHC-exon2-miSeq.rhesus-macaques",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
        ])

        XCTAssertEqual(command.inputs, ["/tmp/DW001.lungfishfastq", "/tmp/DW002.lungfishfastq"])
        XCTAssertEqual(command.mode, "illumina-paired")
        XCTAssertEqual(command.readType, "illumina")
        XCTAssertNil(command.barcodes)
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputName, "miseq-mhc")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.sortThreads, 2)
        XCTAssertEqual(command.minSupport, 3)
    }

    func testGenotypeParsesLockedMCMMiSeqPresetWithoutReference() throws {
        let command = try FastqGenotypingSubcommand.parse([
            "/tmp/LF2823.lungfishfastq",
            "--preset", "mcm-mhc-miseq",
            "--barcodes", "/tmp/fluidigm.csv",
            "--output-dir", "/tmp/out",
            "--output-name", "mcm-miseq",
        ])

        XCTAssertEqual(command.preset, "mcm-mhc-miseq")
        XCTAssertNil(command.reference)
    }

    func testGenotypePresetRejectsUserReferenceOverride() throws {
        XCTAssertThrowsError(try FastqGenotypingSubcommand.parse([
            "/tmp/LF2823.lungfishfastq",
            "--preset", "mcm-mhc-miseq",
            "--reference", "/tmp/other.fa",
            "--barcodes", "/tmp/fluidigm.csv",
            "--output-dir", "/tmp/out",
        ]))
    }

    func testGenotypeParsesHaplotypeThresholdsAndDefinitionScope() throws {
        let command = try FastqGenotypingSubcommand.parse([
            "/tmp/barcode11.lungfishfastq",
            "--mode", "ont-barcode-demux",
            "--read-type", "ont",
            "--reference", "/tmp/mhc.lungfishmhcref",
            "--output-dir", "/tmp/out",
            "--output-name", "barcode11-mhc-test",
            "--project", "/tmp/project.lungfish",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-species", "MCM",
            "--haplotype-definition-scope", "project",
            "--haplotype-definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            "--haplotype-min-sample-percent", "1",
            "--haplotype-min-locus-percent", "1",
            "--haplotype-min-locus-percent-override", "MHC-DQ=10",
            "--haplotype-min-locus-percent-override", "MHC-DP=10",
            "--barcodes", "/tmp/fluidigm.csv",
            "--threads", "14",
            "--min-support", "10",
        ])

        XCTAssertEqual(command.haplotypeDefinitionScope, "project")
        XCTAssertEqual(command.haplotypeMinSamplePercent, 1)
        XCTAssertEqual(command.haplotypeMinLocusPercent, 1)
        XCTAssertEqual(command.haplotypeMinLocusPercentOverrides, ["MHC-DQ=10", "MHC-DP=10"])
    }

    func testMHCReferenceBundleParsesOptions() throws {
        let command = try FastqMHCReferenceBundleSubcommand.parse([
            "--reference-fasta", "/tmp/MCM_MHC.fa",
            "--haplotype-definition", "/tmp/mcm.json",
            "--haplotype-definition", "/tmp/mamu.json",
            "--default-haplotype-definition", "mcm-mhc",
            "--output", "/tmp/MCM-MHC.lungfishmhcref",
            "--name", "MCM MHC",
            "--source-file", "/tmp/build.log",
            "--force",
        ])

        XCTAssertEqual(command.referenceFASTA, "/tmp/MCM_MHC.fa")
        XCTAssertEqual(command.haplotypeDefinitions, ["/tmp/mcm.json", "/tmp/mamu.json"])
        XCTAssertEqual(command.defaultHaplotypeDefinition, "mcm-mhc")
        XCTAssertEqual(command.output, "/tmp/MCM-MHC.lungfishmhcref")
        XCTAssertEqual(command.name, "MCM MHC")
        XCTAssertEqual(command.sourceFiles, ["/tmp/build.log"])
        XCTAssertTrue(command.force)
        XCTAssertEqual(command.configurationForTesting().defaultHaplotypeDefinitionID, "mcm-mhc")
    }
}
