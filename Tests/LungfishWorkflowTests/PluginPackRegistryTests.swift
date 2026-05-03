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
                "vsearch", "pigz", "sra-tools", "ucsc-bedtobigbed", "ucsc-bedgraphtobigwig",
            ]
        )
    }

    func testRequiredSetupPackDefinesPerToolChecks() {
        let pack = PluginPack.requiredSetupPack
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, [
            "nextflow", "snakemake", "bbtools", "fastp", "deacon",
            "samtools", "bcftools", "htslib", "seqkit", "cutadapt",
            "vsearch", "pigz", "sra-tools", "ucsc-bedtobigbed", "ucsc-bedgraphtobigwig",
            "deacon-panhuman",
        ])
        XCTAssertEqual(pack.estimatedSizeMB, 2600)
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "bbtools" })?.installPackages,
            ["bioconda::bbmap=39.80=h2e3bd82_0"]
        )
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "bbtools" })?.executables, [
            "clumpify.sh", "bbduk.sh", "bbmerge.sh",
            "repair.sh", "tadpole.sh", "reformat.sh", "bbmap.sh", "mapPacBio.sh", "java",
        ])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "fastp" })?.executables, ["fastp"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "deacon" })?.executables, ["deacon"])
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "deacon-panhuman" })?.displayName,
            "Human Read Removal Data"
        )
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "deacon-panhuman" })?.executables, [])
    }

    func testRequiredSetupPackMatchesPinnedManagedToolLock() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(lock.packID, "lungfish-tools")
        XCTAssertEqual(lock.displayName, "Third-Party Tools")
        XCTAssertEqual(pack.name, lock.displayName)
        XCTAssertEqual(pack.packages, lock.tools.map(\.environment))
        XCTAssertEqual(lock.tools.count, 15)
        XCTAssertEqual(lock.managedData.count, 1)
    }

    func testRequiredSetupPackExposesPinnedAboutMetadata() throws {
        let pack = PluginPack.requiredSetupPack

        let nextflow = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "nextflow" }))
        XCTAssertEqual(nextflow.version, "25.10.4")
        XCTAssertEqual(nextflow.license, "Apache-2.0")
        XCTAssertEqual(nextflow.sourceURL, "https://github.com/nextflow-io/nextflow")

        let bcftools = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "bcftools" }))
        XCTAssertEqual(bcftools.version, "1.23.1")
        XCTAssertEqual(bcftools.license, "GPL")
        XCTAssertEqual(bcftools.sourceURL, "https://github.com/samtools/bcftools")

        let ucscBedToBigBed = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "ucsc-bedtobigbed" }))
        XCTAssertEqual(ucscBedToBigBed.version, "482")
        XCTAssertEqual(ucscBedToBigBed.license, "Varies; see https://genome.ucsc.edu/license")
        XCTAssertEqual(ucscBedToBigBed.sourceURL, "https://genome.ucsc.edu/goldenPath/help/bigBed.html")
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
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))

        let kraken2 = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "kraken2" }))
        XCTAssertEqual(kraken2.installPackages, ["bioconda::kraken2=2.17.1"])
        XCTAssertEqual(kraken2.version, "2.17.1")
        XCTAssertEqual(kraken2.license, "GPL-3.0-or-later")
        XCTAssertEqual(kraken2.sourceURL, "https://github.com/DerrickWood/kraken2")

        let bracken = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "bracken" }))
        XCTAssertEqual(bracken.installPackages, ["bioconda::bracken=1.0.0"])
        XCTAssertEqual(bracken.version, "1.0.0")
        XCTAssertEqual(bracken.license, "GPL-3.0")
        XCTAssertEqual(bracken.sourceURL, "https://github.com/jenniferlu717/Bracken")

        let esviritu = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "esviritu" }))
        XCTAssertEqual(esviritu.installPackages, ["bioconda::esviritu=1.2.0"])
        XCTAssertEqual(esviritu.version, "1.2.0")
        XCTAssertEqual(esviritu.license, "MIT")
        XCTAssertEqual(esviritu.sourceURL, "https://github.com/cmmr/EsViritu")

        let ribodetector = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "ribodetector" }))
        XCTAssertEqual(ribodetector.installPackages, ["bioconda::ribodetector=0.3.3"])
        XCTAssertEqual(ribodetector.executables, ["ribodetector_cpu"])
        XCTAssertEqual(ribodetector.smokeTest?.executable, "ribodetector_cpu")
        XCTAssertEqual(ribodetector.smokeTest?.arguments, ["--help"])
        XCTAssertEqual(ribodetector.smokeTest?.requiredOutputSubstring, "usage:")
        XCTAssertEqual(ribodetector.version, "0.3.3")
        XCTAssertEqual(ribodetector.license, "GPL-3.0-or-later")
        XCTAssertEqual(ribodetector.sourceURL, "https://github.com/hzi-bifo/RiboDetector")
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
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "assembly" }))

        let spades = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "spades" }))
        XCTAssertEqual(spades.installPackages, ["bioconda::spades=4.2.0"])
        XCTAssertEqual(spades.version, "4.2.0")
        XCTAssertEqual(spades.license, "GPL-2.0-only")
        XCTAssertEqual(spades.sourceURL, "https://github.com/ablab/spades")

        let megahit = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "megahit" }))
        XCTAssertEqual(megahit.installPackages, ["bioconda::megahit=1.2.9"])
        XCTAssertEqual(megahit.version, "1.2.9")
        XCTAssertEqual(megahit.license, "GPL-3.0")
        XCTAssertEqual(megahit.sourceURL, "https://github.com/voutcn/megahit")

        let skesa = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "skesa" }))
        XCTAssertEqual(skesa.installPackages, ["bioconda::skesa=2.5.1"])
        XCTAssertEqual(skesa.version, "2.5.1")
        XCTAssertEqual(skesa.license, "Public Domain")
        XCTAssertEqual(skesa.sourceURL, "https://github.com/ncbi/SKESA")

        let flye = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "flye" }))
        XCTAssertEqual(flye.installPackages, ["bioconda::flye=2.9.6"])
        XCTAssertEqual(flye.version, "2.9.6")
        XCTAssertEqual(flye.license, "BSD")
        XCTAssertEqual(flye.sourceURL, "https://github.com/mikolmogorov/Flye")

        let hifiasm = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "hifiasm" }))
        XCTAssertEqual(hifiasm.installPackages, ["bioconda::hifiasm=0.25.0"])
        XCTAssertEqual(hifiasm.version, "0.25.0")
        XCTAssertEqual(hifiasm.license, "MIT")
        XCTAssertEqual(hifiasm.sourceURL, "https://github.com/chhylp123/hifiasm")
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

        for environment in ["ucsc-bedtobigbed", "ucsc-bedgraphtobigwig"] {
            let smokeTest = pack.toolRequirements.first(where: { $0.environment == environment })?.smokeTest
            XCTAssertEqual(smokeTest?.arguments, [])
            XCTAssertEqual(smokeTest?.acceptedExitCodes, [255])
            XCTAssertEqual(smokeTest?.requiredOutputSubstring, "usage:")
        }
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
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "variant-calling" }))

        XCTAssertEqual(pack.description, "Viral BAM variant calling from bundle-owned alignment tracks")
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["lofreq", "ivar", "medaka"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })

        let lofreq = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "lofreq" }))
        XCTAssertEqual(lofreq.installPackages, ["bioconda::lofreq=2.1.5"])
        XCTAssertEqual(lofreq.version, "2.1.5")
        XCTAssertEqual(lofreq.license, "MIT")
        XCTAssertEqual(lofreq.sourceURL, "https://csb5.github.io/lofreq/")

        let ivar = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "ivar" }))
        XCTAssertEqual(ivar.installPackages, ["bioconda::ivar=1.4.4"])
        XCTAssertEqual(ivar.version, "1.4.4")
        XCTAssertEqual(ivar.license, "GPL-3.0-or-later")
        XCTAssertEqual(ivar.sourceURL, "https://andersen-lab.github.io/ivar/html/")

        let medaka = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "medaka" }))
        XCTAssertEqual(medaka.installPackages, ["bioconda::medaka=2.1.1"])
        XCTAssertEqual(medaka.version, "2.1.1")
        XCTAssertEqual(medaka.license, "MPL-2.0")
        XCTAssertEqual(medaka.sourceURL, "https://github.com/nanoporetech/medaka")
    }

    func testVariantCallingPackUsesVersionProbeForLofreq() throws {
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "variant-calling" }))
        let lofreq = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "lofreq" }))

        XCTAssertEqual(lofreq.smokeTest?.arguments, ["version"])
        XCTAssertEqual(lofreq.smokeTest?.acceptedExitCodes, [0])
        XCTAssertEqual(lofreq.smokeTest?.requiredOutputSubstring, "version:")
    }

    func testActiveOptionalPacksExposeReadMappingVariantCallingAssemblyAndMetagenomics() {
        XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), [
            "read-mapping",
            "variant-calling",
            "assembly",
            "multiple-sequence-alignment",
            "phylogenetics",
            "metagenomics",
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
            "variant-calling",
            "assembly",
            "multiple-sequence-alignment",
            "phylogenetics",
            "metagenomics",
        ])
    }

    func testMultipleSequenceAlignmentPackDefinesNativeArm64Tools() throws {
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "multiple-sequence-alignment" }))

        XCTAssertEqual(pack.name, "Multiple Sequence Alignment")
        XCTAssertEqual(pack.packages, ["mafft", "muscle", "clustalo", "famsa", "trimal", "clipkit", "goalign"])
        XCTAssertEqual(pack.category, "Phylogenetics")
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["mafft", "muscle", "clustalo", "famsa", "trimal", "clipkit", "goalign"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })

        let mafft = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "mafft" }))
        XCTAssertEqual(mafft.installPackages, ["conda-forge::mafft=7.526"])
        XCTAssertEqual(mafft.version, "7.526")
        XCTAssertEqual(mafft.license, "BSD-3-Clause")

        let muscle = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "muscle" }))
        XCTAssertEqual(muscle.installPackages, ["bioconda::muscle=5.3"])
        XCTAssertEqual(muscle.version, "5.3")
        XCTAssertEqual(muscle.license, "GPL-3.0-only")

        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "seqkit" }))
    }

    func testPhylogeneticsPackDefinesGenericNativeArm64Tools() throws {
        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "phylogenetics" }))

        XCTAssertEqual(pack.description, "Infer, annotate, and inspect native Apple Silicon phylogenetic trees")
        XCTAssertEqual(pack.packages, ["iqtree", "fasttree", "raxml-ng", "treetime", "gotree", "treeswift"])
        XCTAssertEqual(pack.toolRequirements.map(\.environment), ["iqtree", "fasttree", "raxml-ng", "treetime", "gotree", "treeswift"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "newick_utils" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "nextclade" }))
        XCTAssertFalse(pack.toolRequirements.contains(where: { $0.id == "usher" }))

        let iqtree = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "iqtree" }))
        XCTAssertEqual(iqtree.installPackages, ["bioconda::iqtree=3.1.1"])
        XCTAssertEqual(iqtree.version, "3.1.1")
        XCTAssertEqual(iqtree.license, "GPL-2.0-or-later")

        let fasttree = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "fasttree" }))
        XCTAssertEqual(fasttree.installPackages, ["bioconda::fasttree=2.2.0"])
        XCTAssertEqual(fasttree.executables, ["FastTree"])

        let treeswift = try XCTUnwrap(pack.toolRequirements.first(where: { $0.id == "treeswift" }))
        XCTAssertEqual(treeswift.installPackages, ["bioconda::treeswift=1.1.45"])
        XCTAssertEqual(treeswift.executables, ["python"])
        XCTAssertEqual(treeswift.smokeTest?.arguments, ["-c", "import treeswift; print('treeswift')"])
    }
}
