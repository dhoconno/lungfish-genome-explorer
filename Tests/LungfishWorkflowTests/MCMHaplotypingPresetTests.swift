import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class MCMHaplotypingPresetTests: XCTestCase {
    func testBundledMCMReferenceBundleMatchesLockedMiSeqReference() throws {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let bundleURL = try preset.bundledReferenceBundleURL()

        XCTAssertTrue(MHCAmpliconReferenceBundle.isBundleURL(bundleURL))
        XCTAssertEqual(preset.id, "mcm-mhc-miseq")
        XCTAssertEqual(preset.referenceFASTASHA256, "13134729eba56d42479e251b53299152d823947a0bc2c64fb82a61023e1b6561")
        XCTAssertEqual(preset.referenceFASTARecordCount, 189)

        let fastaURL = try XCTUnwrap(MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL))
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: fastaURL), preset.referenceFASTASHA256)

        let definition = try XCTUnwrap(MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: bundleURL))
        XCTAssertEqual(definition.id, preset.haplotypeDefinitionSetID)
        XCTAssertEqual(definition.assayID, preset.haplotypeAssayID)
        XCTAssertEqual(definition.speciesCode, preset.haplotypeSpeciesCode)
    }

    func testPresetRequestUsesBundledReferenceAndReplayablePresetArgument() throws {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let request = try preset.makeGenotypingRunRequest(
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/LF2823.lungfishfastq", isDirectory: true)],
            barcodeDefinitionsURL: URL(fileURLWithPath: "/tmp/barcodes.csv"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "mcm-miseq"
        )

        XCTAssertEqual(request.presetID, preset.id)
        XCTAssertEqual(request.referenceSourceURL, try preset.bundledReferenceBundleURL())
        XCTAssertEqual(request.haplotypeDefinitionSetID, preset.haplotypeDefinitionSetID)
        XCTAssertEqual(request.haplotypeAssayID, preset.haplotypeAssayID)
        XCTAssertEqual(request.haplotypeSpeciesCode, preset.haplotypeSpeciesCode)
        XCTAssertEqual(try testValue(after: "--preset", in: request.argv), preset.id)
        XCTAssertFalse(request.argv.contains("--reference"))
    }

    func testBundledSpecialistPromptIsPresetResource() throws {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let prompt = try preset.bundledSpecialistPromptMarkdown()

        XCTAssertEqual(preset.aiPromptTemplateID(for: .aiDiscovery), "lungfish.ai-haplotyping.mcm-mhc-miseq-specialist.discovery")
        XCTAssertEqual(preset.aiPromptTemplateID(for: .aiRefinement), "lungfish.ai-haplotyping.mcm-mhc-miseq-specialist.refinement")
        XCTAssertEqual(preset.aiPromptTemplateVersion, "2026-06-19.1")
        XCTAssertTrue(prompt.contains("MCM MHC MiSeq Haplotyping Specialist Prompt"))
        XCTAssertTrue(prompt.contains("Overcall Guard And Human-Curation Trigger"))
        XCTAssertTrue(prompt.contains("Secondary Allele Map"))
        XCTAssertTrue(prompt.contains("MHC-A Secondary Alleles"))
        XCTAssertTrue(prompt.contains("Mafa-L/MHC-L is located between MHC-A and MHC-E"))
        XCTAssertTrue(prompt.contains("MHC-A secondary-conflict calibration"))
        XCTAssertTrue(prompt.contains("M4 and M7 have the same MHC-DP genotypes"))
        XCTAssertTrue(prompt.contains("Do not split M4/M7 or M5/M6 shared DP evidence using MHC-A, MHC-E, or MHC-B context alone"))
        XCTAssertTrue(prompt.contains("shared 0012 has strong support"))
        XCTAssertTrue(prompt.contains("return exactly six locus rows: MHC-A, MHC-E, MHC-B, MHC-DR, MHC-DQ, and MHC-DP"))
        XCTAssertTrue(prompt.contains("Use `?` for unresolved slots instead of omitting the locus"))
        XCTAssertTrue(prompt.contains("overcall-human-curation"))
        XCTAssertTrue(prompt.contains("Do not use the words phase, phasing, copy number, inherited, inheritance, clinical, confirmation, or follow-up"))
        XCTAssertFalse(prompt.contains("knowledgePack.populationProfiles"))
        XCTAssertFalse(prompt.contains("knowledgePack.haplotypeBlockDefinitions"))
    }
}

private func testValue(after flag: String, in arguments: [String]) throws -> String {
    let index = try XCTUnwrap(arguments.firstIndex(of: flag))
    let valueIndex = arguments.index(after: index)
    XCTAssertLessThan(valueIndex, arguments.endIndex)
    return arguments[valueIndex]
}
