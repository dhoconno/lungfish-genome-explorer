import XCTest
import LungfishCore
@testable import LungfishWorkflow

@MainActor
final class NativeBundleBuilderProvenanceTests: XCTestCase {
    func testCompressedReferenceBundleRecordsBgzipAndFaidxSteps() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeBundleBuilderProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let fastaURL = root.appendingPathComponent("source.fa")
        try """
        >chr1
        ACGTACGTACGT
        """.write(to: fastaURL, atomically: true, encoding: .utf8)

        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeFakeManagedTool(home: home, environment: "htslib", executable: "bgzip", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "bgzip 1.23" >&2; exit 0; fi
        for arg in "$@"; do input="$arg"; done
        cp "$input" "$input.gz"
        rm -f "$input"
        exit 0
        """)
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then
          printf "chr1\\t12\\t6\\t12\\t13\\n" > "$2.fai"
          case "$2" in
            *.gz) printf "0\\t0\\n" > "$2.gzi" ;;
          esac
          exit 0
        fi
        exit 2
        """)

        let builder = NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
        )
        let bundleURL = try await builder.build(
            configuration: BuildConfiguration(
                name: "Test Bundle",
                identifier: "org.lungfish.test.native-provenance",
                fastaURL: fastaURL,
                outputDirectory: root,
                source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
                compressFASTA: true
            )
        )

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        let compressedFASTA = bundleURL.appendingPathComponent("genome/sequence.fa.gz").path
        let fastaIndex = bundleURL.appendingPathComponent("genome/sequence.fa.gz.fai").path
        let gzipIndex = bundleURL.appendingPathComponent("genome/sequence.fa.gz.gzi").path

        let bgzipStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bgzip" })
        XCTAssertTrue(bgzipStep.argv.first?.hasSuffix("/envs/htslib/bin/bgzip") == true)
        XCTAssertEqual(bgzipStep.outputs.map(\.path), [compressedFASTA])
        XCTAssertNotNil(bgzipStep.outputs.first?.checksumSHA256)
        XCTAssertNotNil(bgzipStep.outputs.first?.fileSize)

        let faidxStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "samtools" && $0.argv.contains("faidx") })
        XCTAssertTrue(faidxStep.argv.first?.hasSuffix("/envs/samtools/bin/samtools") == true)
        XCTAssertTrue(faidxStep.inputs.contains { $0.path == compressedFASTA })
        XCTAssertTrue(faidxStep.outputs.contains { $0.path == fastaIndex && $0.checksumSHA256 != nil })
        XCTAssertTrue(faidxStep.outputs.contains { $0.path == gzipIndex && $0.checksumSHA256 != nil })
    }

    private func writeFakeManagedTool(
        home: URL,
        environment: String,
        executable: String,
        script: String
    ) throws {
        let binDir = home
            .appendingPathComponent(".lungfish/conda/envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let toolURL = binDir.appendingPathComponent(executable)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }
}
