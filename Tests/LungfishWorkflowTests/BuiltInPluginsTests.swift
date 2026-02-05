// BuiltInPluginsTests.swift - Tests for built-in container plugins
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class BuiltInPluginsTests: XCTestCase {

    // MARK: - All Plugins Tests

    func testAllPluginsAvailable() {
        let plugins = BuiltInContainerPlugins.all
        XCTAssertEqual(plugins.count, 5)

        let ids = plugins.map { $0.id }
        XCTAssertTrue(ids.contains("samtools"))
        XCTAssertTrue(ids.contains("bcftools"))
        XCTAssertTrue(ids.contains("bedToBigBed"))
        XCTAssertTrue(ids.contains("bedGraphToBigWig"))
        XCTAssertTrue(ids.contains("bgzip"))
    }

    func testPluginLookupById() {
        XCTAssertNotNil(BuiltInContainerPlugins.plugin(id: "samtools"))
        XCTAssertNotNil(BuiltInContainerPlugins.plugin(id: "bcftools"))
        XCTAssertNotNil(BuiltInContainerPlugins.plugin(id: "bedToBigBed"))
        XCTAssertNotNil(BuiltInContainerPlugins.plugin(id: "bedGraphToBigWig"))
        XCTAssertNotNil(BuiltInContainerPlugins.plugin(id: "bgzip"))
        XCTAssertNil(BuiltInContainerPlugins.plugin(id: "nonexistent"))
    }

    // MARK: - SAMtools Tests

    func testSamtoolsPlugin() {
        let samtools = BuiltInContainerPlugins.samtools

        XCTAssertEqual(samtools.id, "samtools")
        XCTAssertEqual(samtools.name, "SAMtools")
        XCTAssertTrue(samtools.imageReference.contains("samtools"))
        XCTAssertEqual(samtools.category, .indexing)
        XCTAssertEqual(samtools.version, "1.18")
        XCTAssertNotNil(samtools.documentationURL)
    }

    func testSamtoolsCommands() {
        let samtools = BuiltInContainerPlugins.samtools

        // Check faidx command
        XCTAssertNotNil(samtools.commands["faidx"])
        let faidx = samtools.commands["faidx"]!
        XCTAssertEqual(faidx.executable, "samtools")
        XCTAssertTrue(faidx.arguments.contains("faidx"))
        XCTAssertTrue(faidx.arguments.contains("${INPUT}"))

        // Check other commands exist
        XCTAssertNotNil(samtools.commands["faidx_bgzip"])
        XCTAssertNotNil(samtools.commands["view"])
        XCTAssertNotNil(samtools.commands["sort"])
        XCTAssertNotNil(samtools.commands["index"])
        XCTAssertNotNil(samtools.commands["dict"])
    }

    func testSamtoolsInputs() {
        let samtools = BuiltInContainerPlugins.samtools

        XCTAssertEqual(samtools.inputs.count, 1)
        let input = samtools.inputs[0]
        XCTAssertEqual(input.name, "INPUT")
        XCTAssertEqual(input.type, .file)
        XCTAssertTrue(input.required)
        XCTAssertTrue(input.acceptedExtensions.contains("fa"))
        XCTAssertTrue(input.acceptedExtensions.contains("fasta"))
        XCTAssertTrue(input.acceptedExtensions.contains("bam"))
    }

    // MARK: - BCFtools Tests

    func testBcftoolsPlugin() {
        let bcftools = BuiltInContainerPlugins.bcftools

        XCTAssertEqual(bcftools.id, "bcftools")
        XCTAssertEqual(bcftools.name, "BCFtools")
        XCTAssertTrue(bcftools.imageReference.contains("bcftools"))
        XCTAssertEqual(bcftools.category, .variants)
        XCTAssertEqual(bcftools.version, "1.18")
        XCTAssertNotNil(bcftools.documentationURL)
    }

    func testBcftoolsCommands() {
        let bcftools = BuiltInContainerPlugins.bcftools

        // Check view command (VCF to BCF)
        XCTAssertNotNil(bcftools.commands["view"])
        let view = bcftools.commands["view"]!
        XCTAssertEqual(view.executable, "bcftools")
        XCTAssertTrue(view.arguments.contains("view"))
        XCTAssertTrue(view.arguments.contains("${INPUT}"))
        XCTAssertTrue(view.arguments.contains("${OUTPUT}"))

        // Check other commands
        XCTAssertNotNil(bcftools.commands["view_vcf"])
        XCTAssertNotNil(bcftools.commands["index"])
        XCTAssertNotNil(bcftools.commands["index_tbi"])
        XCTAssertNotNil(bcftools.commands["sort"])
        XCTAssertNotNil(bcftools.commands["norm"])
    }

    func testBcftoolsInputs() {
        let bcftools = BuiltInContainerPlugins.bcftools

        XCTAssertGreaterThanOrEqual(bcftools.inputs.count, 1)
        let input = bcftools.inputs.first { $0.name == "INPUT" }
        XCTAssertNotNil(input)
        XCTAssertTrue(input!.acceptedExtensions.contains("vcf"))
        XCTAssertTrue(input!.acceptedExtensions.contains("bcf"))
    }

    // MARK: - bedToBigBed Tests

    func testBedToBigBedPlugin() {
        let bedToBigBed = BuiltInContainerPlugins.bedToBigBed

        XCTAssertEqual(bedToBigBed.id, "bedToBigBed")
        XCTAssertEqual(bedToBigBed.name, "bedToBigBed")
        XCTAssertTrue(bedToBigBed.imageReference.contains("ucsc"))
        XCTAssertEqual(bedToBigBed.category, .conversion)
        XCTAssertNotNil(bedToBigBed.documentationURL)
    }

    func testBedToBigBedCommands() {
        let bedToBigBed = BuiltInContainerPlugins.bedToBigBed

        XCTAssertNotNil(bedToBigBed.commands["convert"])
        let convert = bedToBigBed.commands["convert"]!
        XCTAssertEqual(convert.executable, "bedToBigBed")
        XCTAssertTrue(convert.arguments.contains("${INPUT}"))
        XCTAssertTrue(convert.arguments.contains("${CHROM_SIZES}"))
        XCTAssertTrue(convert.arguments.contains("${OUTPUT}"))

        XCTAssertNotNil(bedToBigBed.commands["convert_as"])
    }

    func testBedToBigBedInputs() {
        let bedToBigBed = BuiltInContainerPlugins.bedToBigBed

        let bedInput = bedToBigBed.inputs.first { $0.name == "INPUT" }
        XCTAssertNotNil(bedInput)
        XCTAssertTrue(bedInput!.acceptedExtensions.contains("bed"))

        let chromSizes = bedToBigBed.inputs.first { $0.name == "CHROM_SIZES" }
        XCTAssertNotNil(chromSizes)
        XCTAssertTrue(chromSizes!.required)
    }

    func testBedToBigBedOutputs() {
        let bedToBigBed = BuiltInContainerPlugins.bedToBigBed

        let output = bedToBigBed.outputs.first { $0.name == "OUTPUT" }
        XCTAssertNotNil(output)
        XCTAssertEqual(output!.fileExtension, "bb")
    }

    // MARK: - bedGraphToBigWig Tests

    func testBedGraphToBigWigPlugin() {
        let bedGraphToBigWig = BuiltInContainerPlugins.bedGraphToBigWig

        XCTAssertEqual(bedGraphToBigWig.id, "bedGraphToBigWig")
        XCTAssertEqual(bedGraphToBigWig.name, "bedGraphToBigWig")
        XCTAssertTrue(bedGraphToBigWig.imageReference.contains("ucsc"))
        XCTAssertEqual(bedGraphToBigWig.category, .conversion)
        XCTAssertNotNil(bedGraphToBigWig.documentationURL)
    }

    func testBedGraphToBigWigCommands() {
        let bedGraphToBigWig = BuiltInContainerPlugins.bedGraphToBigWig

        XCTAssertNotNil(bedGraphToBigWig.commands["convert"])
        let convert = bedGraphToBigWig.commands["convert"]!
        XCTAssertEqual(convert.executable, "bedGraphToBigWig")
        XCTAssertTrue(convert.arguments.contains("${INPUT}"))
        XCTAssertTrue(convert.arguments.contains("${CHROM_SIZES}"))
        XCTAssertTrue(convert.arguments.contains("${OUTPUT}"))
    }

    func testBedGraphToBigWigOutputs() {
        let bedGraphToBigWig = BuiltInContainerPlugins.bedGraphToBigWig

        let output = bedGraphToBigWig.outputs.first { $0.name == "OUTPUT" }
        XCTAssertNotNil(output)
        XCTAssertEqual(output!.fileExtension, "bw")
    }

    // MARK: - bgzip Tests

    func testBgzipPlugin() {
        let bgzip = BuiltInContainerPlugins.bgzip

        XCTAssertEqual(bgzip.id, "bgzip")
        XCTAssertEqual(bgzip.name, "bgzip")
        XCTAssertTrue(bgzip.imageReference.contains("htslib"))
        XCTAssertEqual(bgzip.category, .conversion)
        XCTAssertEqual(bgzip.version, "1.18")
        XCTAssertNotNil(bgzip.documentationURL)
    }

    func testBgzipCommands() {
        let bgzip = BuiltInContainerPlugins.bgzip

        XCTAssertNotNil(bgzip.commands["compress"])
        XCTAssertNotNil(bgzip.commands["compress_force"])
        XCTAssertNotNil(bgzip.commands["decompress"])
        XCTAssertNotNil(bgzip.commands["index"])

        let compress = bgzip.commands["compress"]!
        XCTAssertEqual(compress.executable, "bgzip")
        XCTAssertTrue(compress.arguments.contains("-c"))
        XCTAssertTrue(compress.arguments.contains("-i"))
    }

    func testBgzipOutputs() {
        let bgzip = BuiltInContainerPlugins.bgzip

        let gzOutput = bgzip.outputs.first { $0.name == "OUTPUT" }
        XCTAssertNotNil(gzOutput)
        XCTAssertEqual(gzOutput!.fileExtension, "gz")

        let indexOutput = bgzip.outputs.first { $0.name == "INDEX" }
        XCTAssertNotNil(indexOutput)
        XCTAssertEqual(indexOutput!.fileExtension, "gzi")
    }

    // MARK: - Plugin Discovery Tests

    func testPluginsForCategory() {
        let indexingPlugins = BuiltInContainerPlugins.plugins(for: .indexing)
        XCTAssertTrue(indexingPlugins.contains { $0.id == "samtools" })

        let conversionPlugins = BuiltInContainerPlugins.plugins(for: .conversion)
        XCTAssertTrue(conversionPlugins.contains { $0.id == "bedToBigBed" })
        XCTAssertTrue(conversionPlugins.contains { $0.id == "bedGraphToBigWig" })
        XCTAssertTrue(conversionPlugins.contains { $0.id == "bgzip" })

        let variantPlugins = BuiltInContainerPlugins.plugins(for: .variants)
        XCTAssertTrue(variantPlugins.contains { $0.id == "bcftools" })
    }

    func testPluginsForExtension() {
        let fastaPlugins = BuiltInContainerPlugins.plugins(forExtension: "fa")
        XCTAssertTrue(fastaPlugins.contains { $0.id == "samtools" })
        XCTAssertTrue(fastaPlugins.contains { $0.id == "bgzip" })

        let vcfPlugins = BuiltInContainerPlugins.plugins(forExtension: "vcf")
        XCTAssertTrue(vcfPlugins.contains { $0.id == "bcftools" })
        XCTAssertTrue(vcfPlugins.contains { $0.id == "bgzip" })

        let bedPlugins = BuiltInContainerPlugins.plugins(forExtension: "bed")
        XCTAssertTrue(bedPlugins.contains { $0.id == "bedToBigBed" })
        XCTAssertTrue(bedPlugins.contains { $0.id == "bgzip" })
    }

    func testBundleCreationPlugins() {
        let plugins = BuiltInContainerPlugins.bundleCreationPlugins
        XCTAssertEqual(plugins.count, 5)

        let ids = plugins.map { $0.id }
        XCTAssertTrue(ids.contains("samtools"))
        XCTAssertTrue(ids.contains("bcftools"))
        XCTAssertTrue(ids.contains("bedToBigBed"))
        XCTAssertTrue(ids.contains("bedGraphToBigWig"))
        XCTAssertTrue(ids.contains("bgzip"))
    }

    // MARK: - Command Template Resolution Tests

    func testSamtoolsFaidxResolution() {
        let samtools = BuiltInContainerPlugins.samtools
        let faidx = samtools.commands["faidx"]!

        let resolved = faidx.resolve(with: [
            "INPUT": "/workspace/genome.fa"
        ])

        XCTAssertEqual(resolved[0], "samtools")
        XCTAssertEqual(resolved[1], "faidx")
        XCTAssertEqual(resolved[2], "/workspace/genome.fa")
    }

    func testBcftoolsViewResolution() {
        let bcftools = BuiltInContainerPlugins.bcftools
        let view = bcftools.commands["view"]!

        let resolved = view.resolve(with: [
            "INPUT": "/workspace/variants.vcf",
            "OUTPUT": "/workspace/variants.bcf"
        ])

        XCTAssertTrue(resolved.contains("bcftools"))
        XCTAssertTrue(resolved.contains("view"))
        XCTAssertTrue(resolved.contains("/workspace/variants.vcf"))
        XCTAssertTrue(resolved.contains("/workspace/variants.bcf"))
    }

    func testBedToBigBedResolution() {
        let bedToBigBed = BuiltInContainerPlugins.bedToBigBed
        let convert = bedToBigBed.commands["convert"]!

        let resolved = convert.resolve(with: [
            "INPUT": "/workspace/genes.bed",
            "CHROM_SIZES": "/workspace/chrom.sizes",
            "OUTPUT": "/workspace/genes.bb"
        ])

        XCTAssertEqual(resolved[0], "bedToBigBed")
        XCTAssertTrue(resolved.contains("/workspace/genes.bed"))
        XCTAssertTrue(resolved.contains("/workspace/chrom.sizes"))
        XCTAssertTrue(resolved.contains("/workspace/genes.bb"))
    }
}
