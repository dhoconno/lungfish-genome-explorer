import Testing
import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow

/// The Python 3 that runs `ivar_variants_to_vcf.py`, the viralrecon script the Swift converter is
/// compared against. The script imports numpy, Bio, scipy and pandas (`ivar_variants_to_vcf.py:10-13`).
enum IVarParityOracle {
    static let modules = ["numpy", "scipy", "pandas", "Bio"]

    /// The first executable named `python3` on PATH, which is the one `/usr/bin/env python3` runs.
    static var interpreter: URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// True when the interpreter exists and imports every module the script needs. The probe waits up to 30 seconds.
    static var canRun: Bool {
        guard let interpreter else { return false }
        return ToolAvailability.pythonCanImport(modules, interpreter: interpreter, timeout: 30)
    }
}

@Suite("IVarConverterViralReconParity")
struct IVarConverterViralReconParityTests {
    @Test(
        "Swift converter matches viralrecon output on SRR36291587 fixture",
        .enabled(
            if: ToolAvailability.requireTools || IVarParityOracle.canRun,
            "the python3 on PATH is missing or cannot import numpy, scipy, pandas and Bio, which ivar_variants_to_vcf.py needs. LUNGFISH_REQUIRE_TOOLS=1 turns this skip into a failure"
        )
    )
    func parity() async throws {
        guard let oracleInterpreter = IVarParityOracle.interpreter else {
            // Reached only under LUNGFISH_REQUIRE_TOOLS=1, because without it the trait above skips the test.
            Issue.record("python3 was not found on PATH, so ivar_variants_to_vcf.py could not run and nothing was compared")
            return
        }

        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ivar-converter-parity")
        let tsvGZ = fixturesDir.appendingPathComponent("sarscov2-srr36291587.tsv.gz")
        let scratch = try TestTempDirectory.make(prefix: "parity")
        defer { TestTempDirectory.cleanup(scratch) }
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
        let vendoredScript = fixturesDir.appendingPathComponent("ivar_variants_to_vcf.py")
        let oracle = try ProcessRunner.run(
            oracleInterpreter,
            [
                ProcessInfo.processInfo.environment["LUNGFISH_IVAR_TO_VCF_PY"] ?? vendoredScript.path,
                tsv.path,
                pyOut.path,
                "--fasta", fixturesDir.appendingPathComponent("MN908947.3.fasta").path
            ],
            timeout: 30
        )
        guard oracle.status == 0 else {
            // The trait above skipped a machine without the libraries, so a script that still fails
            // is a failure. Returning quietly here would count a pass that compared nothing.
            Issue.record("ivar_variants_to_vcf.py exited \(oracle.status) under \(oracleInterpreter.path), so nothing was compared. The end of its stderr reads: \(oracle.stderr.suffix(600))")
            return
        }

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
        var mismatchNote: Comment?
        if cleanedSwift != cleanedPython {
            // Keep both outputs in a folder from TestTempDirectory, so a failed run is debuggable.
            let dump = try TestTempDirectory.make(prefix: "ivar-parity-mismatch")
            try swift.write(to: dump.appendingPathComponent("swift-out.vcf"), atomically: true, encoding: .utf8)
            try python.write(to: dump.appendingPathComponent("python-out.vcf"), atomically: true, encoding: .utf8)
            mismatchNote = "The Swift VCF and the viralrecon VCF differ. Both outputs are kept in \(dump.path)"
        }
        #expect(cleanedSwift == cleanedPython, mismatchNote)
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
            .appendingPathComponent("Fixtures/sarscov2-srr36291587/ivar.expected.vcf")
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
