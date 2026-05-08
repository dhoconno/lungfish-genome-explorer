import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("IVarConverterViralReconParity")
struct IVarConverterViralReconParityTests {
    @Test("Swift converter matches viralrecon output on SRR36291587 fixture")
    func parity() async throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_VIRALRECON_PARITY"] == "1" else {
            // Opt-in only; CI sets the env var.
            return
        }
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ivar-converter-parity")
        let tsvGZ = fixturesDir.appendingPathComponent("sarscov2-srr36291587.tsv.gz")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tsv = scratch.appendingPathComponent("ivar.tsv")
        FileManager.default.createFile(atPath: tsv.path, contents: nil)
        let outFH = try FileHandle(forWritingTo: tsv)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        unzip.arguments = ["-k", "-c", tsvGZ.path]
        unzip.standardOutput = outFH
        try unzip.run()
        unzip.waitUntilExit()
        try outFH.close()

        let swiftOut = scratch.appendingPathComponent("swift.vcf")
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsv,
            primaryVCFURL: swiftOut,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: false,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "MN908947.3", length: 29903)]
            )
        )

        let pyOut = scratch.appendingPathComponent("py.vcf")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        py.arguments = [
            "python3",
            ProcessInfo.processInfo.environment["LUNGFISH_IVAR_TO_VCF_PY"] ?? "ivar_variants_to_vcf.py",
            tsv.path,
            pyOut.path,
            "--fasta", fixturesDir.appendingPathComponent("MN908947.3.fasta").path
        ]
        try py.run()
        py.waitUntilExit()

        let swift = try String(contentsOf: swiftOut, encoding: .utf8)
        let python = try String(contentsOf: pyOut, encoding: .utf8)
        let stripCosmetic: (String) -> String = { text in
            text.split(separator: "\n").filter { line in
                !line.hasPrefix("##fileDate")
                && !line.hasPrefix("##source")
                && !line.hasPrefix("##LungfishNote")
            }.joined(separator: "\n")
        }
        let cleanedSwift = stripCosmetic(swift)
        let cleanedPython = stripCosmetic(python)
        if cleanedSwift != cleanedPython {
            // Persist outputs alongside the parity script so a failed run is debuggable.
            let dump = URL(fileURLWithPath: "/tmp/parity-check")
            try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
            try? swift.write(to: dump.appendingPathComponent("swift-out.vcf"), atomically: true, encoding: .utf8)
            try? python.write(to: dump.appendingPathComponent("python-out.vcf"), atomically: true, encoding: .utf8)
        }
        #expect(cleanedSwift == cleanedPython)
    }

    /// Regenerates the chapter-fixture iVar VCF using the live converter against
    /// the parity-test TSV. Gated on LUNGFISH_REGENERATE_CHAPTER_VCF=1 so the
    /// regular test run never overwrites the committed fixture.
    @Test("Regenerates chapter fixture iVar VCF (manual)")
    func regenerateChapterFixture() async throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_REGENERATE_CHAPTER_VCF"] == "1" else {
            return
        }
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ivar-converter-parity")
        let tsvGZ = fixturesDir.appendingPathComponent("sarscov2-srr36291587.tsv.gz")
        let chapterFixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/user-manual/fixtures/sarscov2-srr36291587/ivar.expected.vcf")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("regen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Match the on-disk filename produced by `lungfish variants call` so the
        // fixture's SAMPLE column header matches a real pipeline run.
        let tsv = scratch.appendingPathComponent("ivar.tsv-prefix.tsv")
        FileManager.default.createFile(atPath: tsv.path, contents: nil)
        let outFH = try FileHandle(forWritingTo: tsv)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        unzip.arguments = ["-k", "-c", tsvGZ.path]
        unzip.standardOutput = outFH
        try unzip.run()
        unzip.waitUntilExit()
        try outFH.close()

        // Match ViralVariantCallingPipeline's actual options for the iVar caller.
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsv,
            primaryVCFURL: chapterFixture,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: false,
                sourceLine: "iVar (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "MN908947.3", length: 29903)],
                gffMissingNote: true
            )
        )
    }
}
