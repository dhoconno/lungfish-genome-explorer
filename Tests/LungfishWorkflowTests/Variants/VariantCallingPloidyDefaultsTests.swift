import XCTest
@testable import LungfishCore
@testable import LungfishWorkflow

/// `VariantCallingPloidyDefaults` decides whether `bcftools call` runs
/// `--ploidy 1` or `--ploidy 2` when the user has not chosen. The rules are
/// pure functions of the bundle manifest, so each signal is exercised alone.
final class VariantCallingPloidyDefaultsTests: XCTestCase {

    // MARK: - Viral and bacterial references stay haploid (SCI-04)

    func testNCBIVirusMetadataGroupIsHaploid() {
        let manifest = makeManifest(
            organism: "Severe acute respiratory syndrome coronavirus 2",
            totalLength: 29_903,
            metadata: [MetadataGroup(name: "Virus", items: [MetadataItem(label: "Organism", value: "SARS-CoV-2")])]
        )

        let inference = VariantCallingPloidyDefaults.infer(for: manifest)

        XCTAssertEqual(inference.ploidy, .haploid)
        XCTAssertEqual(inference.basis, .virusMetadata)
    }

    func testViralOrganismNameIsHaploid() {
        for organism in ["Severe acute respiratory syndrome coronavirus 2", "Influenza A virus", "Human immunodeficiency virus 1", "Enterobacteria phage lambda"] {
            let inference = VariantCallingPloidyDefaults.infer(for: makeManifest(organism: organism, totalLength: 29_903))
            XCTAssertEqual(inference.ploidy, .haploid, organism)
            XCTAssertEqual(inference.basis, .organismName, organism)
        }
    }

    func testBacterialOrganismNameIsHaploid() {
        for organism in ["Escherichia coli K-12", "Mycobacterium tuberculosis H37Rv", "Staphylococcus aureus"] {
            let inference = VariantCallingPloidyDefaults.infer(for: makeManifest(organism: organism, totalLength: 4_600_000))
            XCTAssertEqual(inference.ploidy, .haploid, organism)
            XCTAssertEqual(inference.basis, .organismName, organism)
        }
    }

    func testGenBankViralAndBacterialDivisionsAreHaploid() {
        for code in ["VRL", "PHG", "BCT"] {
            let manifest = makeManifest(
                organism: "Unspecified",
                totalLength: 29_903,
                metadata: [MetadataGroup(name: "Record", items: [MetadataItem(label: "Division", value: code)])]
            )
            let inference = VariantCallingPloidyDefaults.infer(for: manifest)
            XCTAssertEqual(inference.ploidy, .haploid, code)
            XCTAssertEqual(inference.basis, .genbankDivision, code)
        }
    }

    // MARK: - Eukaryotic references are diploid

    func testHumanAndMacaqueOrganismNamesAreDiploid() {
        for organism in ["Homo sapiens", "Macaca mulatta", "Macaca fascicularis", "Mus musculus"] {
            let inference = VariantCallingPloidyDefaults.infer(for: makeManifest(organism: organism, totalLength: 500_001))
            XCTAssertEqual(inference.ploidy, .diploid, organism)
            XCTAssertEqual(inference.basis, .organismName, organism)
        }
    }

    func testCommonNameIsDiploid() {
        let manifest = makeManifest(organism: "Unspecified", commonName: "Rhesus macaque", totalLength: 500_001)

        XCTAssertEqual(VariantCallingPloidyDefaults.defaultPloidy(for: manifest), .diploid)
    }

    func testGenBankEukaryoticDivisionIsDiploid() {
        for code in ["PRI", "MAM", "ROD", "VRT", "PLN"] {
            let manifest = makeManifest(
                organism: "Unspecified",
                totalLength: 500_001,
                metadata: [MetadataGroup(name: "Record", items: [MetadataItem(label: "Division", value: code)])]
            )
            let inference = VariantCallingPloidyDefaults.infer(for: manifest)
            XCTAssertEqual(inference.ploidy, .diploid, code)
            XCTAssertEqual(inference.basis, .genbankDivision, code)
        }
    }

    func testTaxonomyMetadataOrganismItemIsDiploid() {
        let manifest = makeManifest(
            organism: "Unspecified",
            totalLength: 500_001,
            metadata: [MetadataGroup(name: "Taxonomy", items: [MetadataItem(label: "Organism", value: "Homo sapiens")])]
        )

        XCTAssertEqual(VariantCallingPloidyDefaults.infer(for: manifest).basis, .organismName)
        XCTAssertEqual(VariantCallingPloidyDefaults.defaultPloidy(for: manifest), .diploid)
    }

    func testManualHG002Chr20SliceImportedFromFASTAIsDiploid() {
        // The user manual's HG002 example imports `GRCh38.chr20.10.0-10.5Mb.fasta`
        // through Import Center, which records the bundle name as the organism.
        // The 500 kb slice is far below the 10 Mb length rule, so the assembly
        // token is what must carry it.
        let manifest = makeManifest(
            organism: "GRCh38.chr20.10.0-10.5Mb",
            assembly: "GRCh38.chr20.10.0-10.5Mb",
            totalLength: 500_001
        )

        let inference = VariantCallingPloidyDefaults.infer(for: manifest)

        XCTAssertEqual(inference.ploidy, .diploid)
        XCTAssertEqual(inference.basis, .assemblyName)
    }

    func testEukaryoticAssemblyTokensAreDiploid() {
        for assembly in ["hg38", "T2T-CHM13v2.0", "GRCm39", "Mmul_10", "rheMac10", "canFam4"] {
            let inference = VariantCallingPloidyDefaults.infer(for: makeManifest(organism: "Unspecified", assembly: assembly, totalLength: 500_001))
            XCTAssertEqual(inference.ploidy, .diploid, assembly)
            XCTAssertEqual(inference.basis, .assemblyName, assembly)
        }
    }

    func testLargeGenomeWithNoOrganismSignalIsDiploid() {
        let inference = VariantCallingPloidyDefaults.infer(for: makeManifest(organism: "Unspecified", totalLength: 64_444_167))

        XCTAssertEqual(inference.ploidy, .diploid)
        XCTAssertEqual(inference.basis, .genomeLength)
    }

    // MARK: - Explicit notes and the unknown fallback

    func testMetadataPloidyNoteWinsOverEveryOtherSignal() {
        let haploidHuman = makeManifest(
            organism: "Homo sapiens",
            totalLength: 3_000_000_000,
            metadata: [MetadataGroup(name: "Sample", items: [MetadataItem(label: "Ploidy", value: "haploid")])]
        )
        let diploidVirus = makeManifest(
            organism: "Influenza A virus",
            totalLength: 13_000,
            metadata: [
                MetadataGroup(name: "Virus", items: []),
                MetadataGroup(name: "Sample", items: [MetadataItem(label: "Default Ploidy", value: "Diploid")]),
            ]
        )

        XCTAssertEqual(VariantCallingPloidyDefaults.infer(for: haploidHuman).basis, .metadataPloidyNote)
        XCTAssertEqual(VariantCallingPloidyDefaults.defaultPloidy(for: haploidHuman), .haploid)
        XCTAssertEqual(VariantCallingPloidyDefaults.infer(for: diploidVirus).basis, .metadataPloidyNote)
        XCTAssertEqual(VariantCallingPloidyDefaults.defaultPloidy(for: diploidVirus), .diploid)
    }

    func testSmallGenomeWithNoOrganismSignalKeepsViralDefaultAndSaysSo() {
        let inference = VariantCallingPloidyDefaults.infer(for: makeManifest(organism: "sample", assembly: "sample", totalLength: 500_001))

        XCTAssertEqual(inference.ploidy, .haploid)
        XCTAssertEqual(inference.basis, .unknown)
        XCTAssertTrue(inference.summary.contains("Choose Diploid"), inference.summary)
    }

    func testVariantOnlyBundleWithNoSignalIsHaploidUnknown() {
        let inference = VariantCallingPloidyDefaults.infer(for: makeManifest(organism: "Unspecified", totalLength: nil))

        XCTAssertEqual(inference.ploidy, .haploid)
        XCTAssertEqual(inference.basis, .unknown)
    }

    // MARK: - Extra-argument conflict detection

    func testExtraArgumentsSetPloidyRecognisesEverySpelling() {
        XCTAssertTrue(VariantCallingPloidy.extraArgumentsSetPloidy(["--ploidy", "2"]))
        XCTAssertTrue(VariantCallingPloidy.extraArgumentsSetPloidy(["-P", "0.01", "--ploidy=1"]))
        XCTAssertTrue(VariantCallingPloidy.extraArgumentsSetPloidy(["--ploidy-file", "ploidy.txt"]))
        XCTAssertFalse(VariantCallingPloidy.extraArgumentsSetPloidy(["-P", "0.01", "--prior-freqs", "AN,AC"]))
        XCTAssertFalse(VariantCallingPloidy.extraArgumentsSetPloidy([]))
    }

    // MARK: - Helpers

    private func makeManifest(
        organism: String,
        commonName: String? = nil,
        assembly: String = "TestAssembly",
        totalLength: Int64?,
        metadata: [MetadataGroup]? = nil
    ) -> BundleManifest {
        let genome = totalLength.map { length in
            GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: length,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: length, offset: 0, lineBases: 60, lineWidth: 61, aliases: [])
                ],
                md5Checksum: nil
            )
        }
        return BundleManifest(
            name: assembly,
            identifier: "test.ploidy",
            source: SourceInfo(organism: organism, commonName: commonName, assembly: assembly, database: "Test"),
            genome: genome,
            metadata: metadata
        )
    }
}
