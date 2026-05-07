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
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        unzip.arguments = ["-k", "-c", tsvGZ.path]
        let outFH = try FileHandle(forWritingTo: tsv)
        try FileManager.default.createFile(atPath: tsv.path, contents: nil)
        unzip.standardOutput = outFH
        try unzip.run()
        unzip.waitUntilExit()
        outFH.closeFile()

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
        let stripHeader: (String) -> String = { text in
            text.split(separator: "\n").filter { !$0.hasPrefix("##fileDate") && !$0.hasPrefix("##source") }.joined(separator: "\n")
        }
        #expect(stripHeader(swift) == stripHeader(python))
    }
}
