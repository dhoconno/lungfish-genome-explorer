import XCTest
@testable import LungfishWorkflow

final class PluginPackRegistryTests: XCTestCase {

    func testRequiredSetupPackIsLungfishTools() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(pack.id, "lungfish-tools")
        XCTAssertEqual(pack.name, "Third-Party Tools")
        XCTAssertTrue(pack.isRequiredBeforeLaunch)
        XCTAssertTrue(pack.isActive)
        XCTAssertEqual(
            pack.packages,
            [
                "nextflow", "snakemake", "bbtools", "fastp", "deacon",
                "samtools", "bcftools", "htslib", "seqkit", "cutadapt",
                "trim_galore", "vsearch", "pigz", "sra-tools", "ucsc-bedgraphtobigwig", "pysam", "openpyxl",
            ]
        )
    }

    func testRequiredSetupPackDefinesPerToolChecks() {
        let pack = PluginPack.requiredSetupPack
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, [
            "nextflow", "snakemake", "bbtools", "fastp", "deacon",
            "samtools", "bcftools", "htslib", "seqkit", "cutadapt",
            "trim_galore", "vsearch", "pigz", "sra-tools", "ucsc-bedgraphtobigwig", "pysam", "openpyxl",
            "deacon-panhuman", "deacon-ribokmers",
        ])
        XCTAssertEqual(pack.estimatedSizeMB, 2700)
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "bbtools" })?.installPackages,
            ["bioconda::bbmap=40.02=he046917_0"]
        )
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "bbtools" })?.executables, [
            "clumpify.sh", "bbduk.sh", "bbmerge.sh",
            "repair.sh", "tadpole.sh", "reformat.sh", "bbmap.sh", "mapPacBio.sh", "java",
        ])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "fastp" })?.executables, ["fastp"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "deacon" })?.executables, ["deacon"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "trim_galore" })?.executables, ["trim_galore"])
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "deacon-panhuman" })?.displayName,
            "Human Read Removal Data"
        )
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "deacon-panhuman" })?.executables, [])
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "deacon-ribokmers" })?.displayName,
            "Ribosomal RNA Removal Data"
        )
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "deacon-ribokmers" })?.executables, [])
    }

    func testRequiredSetupPackMatchesPinnedManagedToolLock() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(lock.packID, "lungfish-tools")
        XCTAssertEqual(lock.displayName, "Third-Party Tools")
        XCTAssertEqual(pack.name, lock.displayName)
        XCTAssertEqual(pack.packages, lock.tools.map(\.environment))
        XCTAssertEqual(lock.tools.count, 17)
        XCTAssertEqual(lock.managedData.count, 2)
    }

    func testRequiredSetupPackFallsBackWhenManagedToolLockCannotLoad() throws {
        let pack = PluginPack.makeRequiredSetupPack {
            throw NSError(
                domain: "PluginPackRegistryTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing test lock"]
            )
        }

        XCTAssertEqual(pack.id, "lungfish-tools")
        XCTAssertEqual(pack.name, "Third-Party Tools")
        XCTAssertTrue(pack.isRequiredBeforeLaunch)
        XCTAssertTrue(pack.isActive)
        XCTAssertTrue(pack.description.contains("missing test lock"))
        XCTAssertEqual(pack.packages, ["managed-tool-lock-manifest"])

        let requirement = try XCTUnwrap(pack.toolRequirements.first)
        XCTAssertEqual(requirement.id, "managed-tool-lock-manifest")
        XCTAssertEqual(requirement.displayName, "Managed tool lock manifest")
        XCTAssertEqual(requirement.environment, "lungfish-tools-lock")
        XCTAssertEqual(requirement.executables, ["third-party-tools-lock.json"])
    }

    func testFullLengthMHCGenotypingPackDefinesSavontAndBlastnOnly() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "full-length-mhc-genotyping"))

        XCTAssertEqual(pack.name, "Full-length MHC Genotyping")
        XCTAssertEqual(pack.category, "Specialized Workflows")
        XCTAssertTrue(pack.isActive)
        XCTAssertEqual(pack.packages, ["savont", "blast"])
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["savont", "blast"])

        let savont = try XCTUnwrap(pack.toolRequirements.first { $0.id == "savont" })
        XCTAssertEqual(savont.installPackages, [try XCTUnwrap(manifest.packTool(packID: "full-length-mhc-genotyping", id: "savont")).packageSpec])
        XCTAssertEqual(savont.executables, ["savont"])
        XCTAssertEqual(savont.smokeTest?.arguments, ["--help"])

        let blast = try XCTUnwrap(pack.toolRequirements.first { $0.id == "blast" })
        XCTAssertEqual(blast.installPackages, [try XCTUnwrap(manifest.packTool(packID: "full-length-mhc-genotyping", id: "blast")).packageSpec])
        XCTAssertEqual(blast.executables, ["blastn"])
        XCTAssertEqual(blast.smokeTest?.executable, "blastn")
        XCTAssertEqual(blast.smokeTest?.arguments, ["-help"])
    }

    func testRequiredSetupPackExposesPinnedAboutMetadata() throws {
        let pack = PluginPack.requiredSetupPack

        let nextflow = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "nextflow" }))
        XCTAssertEqual(nextflow.version, "26.04.6")
        XCTAssertEqual(nextflow.license, "Apache-2.0")
        XCTAssertEqual(nextflow.sourceURL, "https://github.com/nextflow-io/nextflow")

        let bcftools = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "bcftools" }))
        XCTAssertEqual(bcftools.version, "1.24")
        XCTAssertEqual(bcftools.license, "GPL")
        XCTAssertEqual(bcftools.sourceURL, "https://github.com/samtools/bcftools")

        XCTAssertNil(pack.toolRequirements.first(where: { $0.id == "ucsc-bedtobigbed" }))

        let ucscBedGraphToBigWig = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "ucsc-bedgraphtobigwig" }))
        XCTAssertEqual(ucscBedGraphToBigWig.version, "482")
        XCTAssertEqual(ucscBedGraphToBigWig.license, "Varies; see https://genome.ucsc.edu/license")
        XCTAssertEqual(ucscBedGraphToBigWig.sourceURL, "https://genome.ucsc.edu/goldenPath/help/bigWig.html")

        let pysam = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "pysam" }))
        XCTAssertEqual(pysam.displayName, "pysam")
        XCTAssertEqual(pysam.environment, "pysam")
        XCTAssertEqual(pysam.installPackages, ["bioconda::pysam=0.24.0=py310hf7cbfa5_1"])
        XCTAssertEqual(pysam.executables, ["python"])
        XCTAssertEqual(pysam.smokeTest?.executable, "python")
        XCTAssertEqual(pysam.smokeTest?.arguments, ["-c", "import pysam; print(pysam.__version__)"])
        XCTAssertEqual(pysam.smokeTest?.requiredOutputSubstring, "0.24.0")
        XCTAssertEqual(pysam.version, "0.24.0")
        XCTAssertEqual(pysam.license, "MIT")
        XCTAssertEqual(pysam.sourceURL, "https://github.com/pysam-developers/pysam")

        let openpyxl = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "openpyxl" }))
        XCTAssertEqual(openpyxl.displayName, "openpyxl")
        XCTAssertEqual(openpyxl.environment, "openpyxl")
        XCTAssertEqual(openpyxl.installPackages, ["conda-forge::openpyxl=3.1.5=py312h2a925e6_3"])
        XCTAssertEqual(openpyxl.executables, ["python"])
        XCTAssertEqual(openpyxl.smokeTest?.executable, "python")
        XCTAssertEqual(openpyxl.smokeTest?.arguments, ["-c", "import openpyxl; print(openpyxl.__version__)"])
        XCTAssertEqual(openpyxl.smokeTest?.requiredOutputSubstring, "3.1.5")
        XCTAssertEqual(openpyxl.version, "3.1.5")
        XCTAssertEqual(openpyxl.license, "MIT")
        XCTAssertEqual(openpyxl.sourceURL, "https://openpyxl.readthedocs.io/")
    }

    func testMetagenomicsPackDefinesSmokeChecksForVisibleTools() {
        guard let pack = PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }) else {
            XCTFail("Expected active metagenomics pack")
            return
        }
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, ["kraken2", "bracken", "esviritu", "ribodetector"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "esviritu" })?.executables, ["EsViritu"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "ribodetector" })?.executables, ["ribodetector_cpu"])
    }

    func testMetagenomicsPackPinsExactToolMetadata() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))

        let kraken2 = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "kraken2" }))
        XCTAssertEqual(kraken2.installPackages, [try XCTUnwrap(manifest.packTool(packID: "metagenomics", id: "kraken2")).packageSpec])

        let bracken = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "bracken" }))
        XCTAssertEqual(bracken.installPackages, [try XCTUnwrap(manifest.packTool(packID: "metagenomics", id: "bracken")).packageSpec])

        let esviritu = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "esviritu" }))
        XCTAssertEqual(esviritu.installPackages, [try XCTUnwrap(manifest.packTool(packID: "metagenomics", id: "esviritu")).packageSpec])

        let ribodetector = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "ribodetector" }))
        XCTAssertEqual(ribodetector.installPackages, [try XCTUnwrap(manifest.packTool(packID: "metagenomics", id: "ribodetector")).packageSpec])
        XCTAssertEqual(ribodetector.executables, ["ribodetector_cpu"])
        XCTAssertEqual(ribodetector.smokeTest?.executable, "ribodetector_cpu")
        XCTAssertEqual(ribodetector.smokeTest?.arguments, ["--help"])
        XCTAssertEqual(ribodetector.smokeTest?.requiredOutputSubstring, "usage:")
    }

    func testAssemblyPackDefinesSmokeChecksForVisibleTools() {
        guard let pack = PluginPack.activeOptionalPacks.first(where: { $0.id == "assembly" }) else {
            XCTFail("Expected active assembly pack")
            return
        }
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, ["spades", "megahit", "skesa", "flye", "hifiasm"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "spades" })?.executables, ["spades.py"])
    }

    func testAssemblyPackPinsExactToolMetadata() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "assembly" }))

        let spades = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "spades" }))
        XCTAssertEqual(spades.installPackages, [try XCTUnwrap(manifest.packTool(packID: "assembly", id: "spades")).packageSpec])

        let megahit = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "megahit" }))
        XCTAssertEqual(megahit.installPackages, [try XCTUnwrap(manifest.packTool(packID: "assembly", id: "megahit")).packageSpec])

        let skesa = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "skesa" }))
        XCTAssertEqual(skesa.installPackages, [try XCTUnwrap(manifest.packTool(packID: "assembly", id: "skesa")).packageSpec])

        let flye = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "flye" }))
        XCTAssertEqual(flye.installPackages, [try XCTUnwrap(manifest.packTool(packID: "assembly", id: "flye")).packageSpec])

        let hifiasm = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "hifiasm" }))
        XCTAssertEqual(hifiasm.installPackages, [try XCTUnwrap(manifest.packTool(packID: "assembly", id: "hifiasm")).packageSpec])
    }

    func testRequiredSetupPackUsesBoundedSnakemakeVersionSmokeProbe() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "snakemake" })?.smokeTest?.arguments,
            ["--version"]
        )
    }

    func testRequiredSetupPackRequiresSeqkitSample2ForExactSubsampling() {
        let pack = PluginPack.requiredSetupPack
        let smokeTest = pack.toolRequirements.first(where: { $0.environment == "seqkit" })?.smokeTest

        XCTAssertEqual(smokeTest?.arguments, ["sample2", "--help"])
        XCTAssertEqual(smokeTest?.requiredOutputSubstring, "sample sequences by number or proportion")
    }

    func testRequiredSetupPackUsesUsageSmokeProbeForUcscTools() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertNil(pack.toolRequirements.first(where: { $0.environment == "ucsc-bedtobigbed" }))

        let smokeTest = pack.toolRequirements.first(where: { $0.environment == "ucsc-bedgraphtobigwig" })?.smokeTest
        XCTAssertEqual(smokeTest?.arguments, [])
        XCTAssertEqual(smokeTest?.acceptedExitCodes, [255])
        XCTAssertEqual(smokeTest?.requiredOutputSubstring, "usage:")
    }

    func testReadMappingPackDefinesExpectedToolsAndMetadata() throws {
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "read-mapping" }))

        XCTAssertEqual(pack.name, "Read Mapping")
        XCTAssertEqual(pack.description, "Reference-guided mapping for short and long sequencing reads")
        XCTAssertEqual(pack.packages, ["minimap2", "bwa-mem2", "bowtie2"])
        XCTAssertEqual(pack.category, "Mapping")
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["minimap2", "bwa-mem2", "bowtie2"])
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "hisat2" }))
    }

    func testReadMappingPackUsesUsageProbeForBwaMem2() throws {
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "read-mapping" }))
        let bwaMem2 = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "bwa-mem2" }))

        XCTAssertEqual(bwaMem2.smokeTest?.executable, "bwa-mem2")
        XCTAssertEqual(bwaMem2.smokeTest?.arguments, [])
        XCTAssertEqual(bwaMem2.smokeTest?.acceptedExitCodes, [1])
        XCTAssertEqual(bwaMem2.smokeTest?.requiredOutputSubstring, "Usage: bwa-mem2")
    }

    func testVariantCallingPackDefinesViralToolMetadata() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "variant-calling" }))

        XCTAssertEqual(pack.description, "Viral BAM variant calling from bundle-owned alignment tracks")
        XCTAssertEqual(pack.packages, ["lofreq", "ivar", "medaka", "clair3"])
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["lofreq", "ivar", "medaka", "clair3"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })

        let lofreq = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "lofreq" }))
        XCTAssertEqual(lofreq.installPackages, [try XCTUnwrap(manifest.packTool(packID: "variant-calling", id: "lofreq")).packageSpec])

        let ivar = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "ivar" }))
        XCTAssertEqual(ivar.installPackages, [try XCTUnwrap(manifest.packTool(packID: "variant-calling", id: "ivar")).packageSpec])

        let medaka = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "medaka" }))
        XCTAssertEqual(medaka.installPackages, [try XCTUnwrap(manifest.packTool(packID: "variant-calling", id: "medaka")).packageSpec])

        let clair3 = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "clair3" }))
        XCTAssertEqual(clair3.installPackages, [try XCTUnwrap(manifest.packTool(packID: "variant-calling", id: "clair3")).packageSpec])
        XCTAssertEqual(clair3.executables, ["run_clair3.sh"])
    }

    func testVariantCallingPackUsesVersionProbeForLofreq() throws {
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "variant-calling" }))
        let lofreq = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "lofreq" }))

        XCTAssertEqual(lofreq.smokeTest?.arguments, ["version"])
        XCTAssertEqual(lofreq.smokeTest?.acceptedExitCodes, [0])
        XCTAssertEqual(lofreq.smokeTest?.requiredOutputSubstring, "version:")
    }

    func testGATKCorePackDefinesPinnedBiocondaToolMetadata() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.experimentalOptionalPacks.first(where: { $0.id == "gatk-core" }))

        XCTAssertEqual(pack.name, "GATK Core")
        XCTAssertTrue(pack.isExperimental)
        XCTAssertEqual(pack.description, "GATK4 command construction and dry-run support for human germline workflows")
        XCTAssertEqual(pack.category, "Variant Calling")
        XCTAssertEqual(pack.packages, ["gatk4"])
        XCTAssertEqual(pack.estimatedSizeMB, 600)
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["gatk-core"])

        let gatk = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "gatk4" }))
        XCTAssertEqual(gatk.displayName, "GATK4")
        XCTAssertEqual(gatk.environment, "gatk-core")
        XCTAssertEqual(gatk.installPackages, [try XCTUnwrap(manifest.packTool(packID: "gatk-core", id: "gatk4")).packageSpec])
        XCTAssertEqual(gatk.executables, ["gatk"])
        XCTAssertEqual(gatk.smokeTest?.executable, "gatk")
        XCTAssertEqual(gatk.smokeTest?.arguments, ["--version"])
        XCTAssertEqual(gatk.smokeTest?.requiredOutputSubstring, "The Genome Analysis Toolkit")
    }

    func testPhasingPackDefinesWhatsHapForPhasedVariantPlans() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.experimentalOptionalPacks.first(where: { $0.id == "phasing" }))

        XCTAssertEqual(pack.name, "Variant Phasing")
        XCTAssertTrue(pack.isExperimental)
        XCTAssertEqual(pack.category, "Variant Calling")
        XCTAssertEqual(pack.packages, ["whatshap"])
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["phasing"])

        let whatshap = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "whatshap" }))
        XCTAssertEqual(whatshap.displayName, "WhatsHap")
        XCTAssertEqual(whatshap.installPackages, [try XCTUnwrap(manifest.packTool(packID: "phasing", id: "whatshap")).packageSpec])
        XCTAssertEqual(whatshap.executables, ["whatshap"])
        XCTAssertEqual(whatshap.smokeTest?.arguments, ["--version"])
    }

    func testWastewaterSurveillancePackIsExperimentalAndDefinesFreyja() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.experimentalOptionalPacks.first(where: { $0.id == "wastewater-surveillance" }))

        XCTAssertEqual(pack.name, "Wastewater Surveillance")
        XCTAssertTrue(pack.isExperimental)
        XCTAssertTrue(pack.packages.contains("freyja"))
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["freyja", "ivar", "pangolin", "nextclade", "minimap2"])
        XCTAssertFalse(pack.packages.contains("nextflow"))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "nextflow" || $0.environment == "nextflow" }))
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.id == "freyja" })?.environment, "freyja")
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.id == "freyja" })?.installPackages,
            [try XCTUnwrap(manifest.packTool(packID: "wastewater-surveillance", id: "freyja")).packageSpec]
        )
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.id == "freyja" })?.executables, ["freyja"])
        XCTAssertNotNil(pack.toolRequirements.first(where: { $0.id == "pangolin" }))
    }

    func testOptionalPacksDoNotDuplicateRequiredSetupTools() {
        let requiredToolIDs = Set(PluginPack.requiredSetupPack.toolRequirements.map(\.id))
        let requiredEnvironments = Set(PluginPack.requiredSetupPack.toolRequirements.map(\.environment))
        let optionalPacks = PluginPack.builtIn.filter { $0.kind == .optionalTools }

        for pack in optionalPacks {
            XCTAssertTrue(
                pack.toolRequirements.allSatisfy {
                    !requiredToolIDs.contains($0.id) && !requiredEnvironments.contains($0.environment)
                },
                "\(pack.id) should not include tools from the required setup pack"
            )
        }
    }

    func testAmpliconGenotypingPackIsNotBuiltIn() {
        XCTAssertNil(PluginPack.builtInPack(id: "amplicon-genotyping"))
        XCTAssertFalse(PluginPack.builtIn.contains { $0.id == "amplicon-genotyping" })
    }

    func testActiveOptionalPacksExposeReadMappingFullLengthMHCVariantCallingAssemblyAndMetagenomics() {
        XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), [
            "read-mapping",
            "full-length-mhc-genotyping",
            "variant-calling",
            "assembly",
            "multiple-sequence-alignment",
            "phylogenetics",
            "metagenomics",
        ])
    }

    func testExperimentalOptionalPacksAreExcludedFromReleaseVisiblePacks() {
        XCTAssertEqual(PluginPack.experimentalOptionalPacks.map(\.id), [
            "gatk-core",
            "phasing",
            "wastewater-surveillance",
        ])
        XCTAssertFalse(PluginPack.activeOptionalPacks.contains(where: { $0.isExperimental }))
    }

    func testOptionalPacksCanIncludeExperimentalWhenRequested() {
        XCTAssertEqual(PluginPack.activeOptionalPacks(includeExperimental: true).map(\.id), [
            "read-mapping",
            "full-length-mhc-genotyping",
            "variant-calling",
            "gatk-core",
            "phasing",
            "assembly",
            "multiple-sequence-alignment",
            "phylogenetics",
            "metagenomics",
            "wastewater-surveillance",
        ])
    }

    func testActiveMetagenomicsPackUsesUnifiedClassifierDescription() throws {
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))

        XCTAssertEqual(
            pack.description,
            "Taxonomic classification and pathogen detection from metagenomic samples"
        )
    }

    func testVisibleCLIPacksIncludeRequiredAndActiveOptional() {
        XCTAssertEqual(PluginPack.visibleForCLI.map(\.id), [
            "lungfish-tools",
            "read-mapping",
            "full-length-mhc-genotyping",
            "variant-calling",
            "assembly",
            "multiple-sequence-alignment",
            "phylogenetics",
            "metagenomics",
        ])
    }

    func testMultipleSequenceAlignmentPackOnlyIncludesImplementedMAFFTTool() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "multiple-sequence-alignment" }))

        XCTAssertEqual(pack.name, "Multiple Sequence Alignment")
        XCTAssertEqual(pack.packages, ["mafft"])
        XCTAssertEqual(pack.category, "Phylogenetics")
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["mafft"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })

        let mafft = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "mafft" }))
        XCTAssertEqual(mafft.installPackages, [try XCTUnwrap(manifest.packTool(packID: "multiple-sequence-alignment", id: "mafft")).packageSpec])

        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "seqkit" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "muscle" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "clustalo" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "famsa" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "trimal" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "clipkit" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "goalign" }))
    }

    func testPhylogeneticsPackOnlyIncludesImplementedIQTreeTool() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "phylogenetics" }))

        XCTAssertEqual(pack.description, "Infer, annotate, and inspect native Apple Silicon phylogenetic trees")
        XCTAssertEqual(pack.packages, ["iqtree"])
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["iqtree"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "newick_utils" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "nextclade" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "usher" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "fasttree" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "raxml-ng" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "treetime" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "gotree" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "treeswift" }))

        let iqtree = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "iqtree" }))
        XCTAssertEqual(iqtree.installPackages, [try XCTUnwrap(manifest.packTool(packID: "phylogenetics", id: "iqtree")).packageSpec])
    }
}
