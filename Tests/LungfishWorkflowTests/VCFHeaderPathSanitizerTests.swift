import XCTest
@testable import LungfishWorkflow

final class VCFHeaderPathSanitizerTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/var/folders/ab/T/lungfish-variants-1234/workspace", isDirectory: true)

    private var context: VCFHeaderPathSanitizer.Context {
        .init(
            workspaceURLs: [workspace],
            toolVersions: ["lofreq": "2.1.5", "bcftools": "1.21"]
        )
    }

    /// The header LoFreq + bcftools leave behind on the build machine.
    private let fixtureHeader = """
    ##fileformat=VCFv4.0
    ##fileDate=20260927
    ##source=/Users/dho/.lungfish/conda/envs/lofreq/bin/lofreq call -f /var/folders/ab/T/lungfish-variants-1234/workspace/reference.fa -o /var/folders/ab/T/lungfish-variants-1234/workspace/outputs/variants.raw.vcf /Users/dho/Projects/Demo/Sample.lungfishref/alignments/aln_1.sorted.bam
    ##reference=/var/folders/ab/T/lungfish-variants-1234/workspace/reference.fa
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Raw Depth">
    ##FILTER=<ID=min_dp_10,Description="Minimum Coverage 10">
    ##bcftools_viewVersion=1.21+htslib-1.21
    ##bcftools_viewCommand=view -i 'AF>=0.05' -o /var/folders/ab/T/lungfish-variants-1234/workspace/outputs/variants.raw.vcf /var/folders/ab/T/lungfish-variants-1234/workspace/outputs/variants.raw.vcf; Date=Sat Sep 27 10:00:00 2026
    ##bcftools_reheaderCommand=reheader -f /var/folders/ab/T/lungfish-variants-1234/workspace/reference.fa.fai -o /var/folders/ab/T/lungfish-variants-1234/workspace/outputs/caller-with-reference-contigs.vcf /var/folders/ab/T/lungfish-variants-1234/workspace/outputs/variants.raw.vcf; Date=Sat Sep 27 10:00:01 2026
    ##bcftools_sortCommand=sort -O v -o /var/folders/ab/T/lungfish-variants-1234/workspace/outputs/variants.normalized.vcf /var/folders/ab/T/lungfish-variants-1234/workspace/outputs/caller-with-reference-contigs.vcf; Date=Sat Sep 27 10:00:02 2026
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    MN908947.3\t241\t.\tC\tT\t1234\tPASS\tDP=100;AF=0.98
    """

    func testLoFreqSourceLineKeepsToolVersionAndCommandShapeWithoutMachinePaths() {
        let line = fixtureHeader.split(separator: "\n").map(String.init).first { $0.hasPrefix("##source=") }!
        let sanitized = VCFHeaderPathSanitizer.sanitize(headerLine: line, context: context)

        XCTAssertEqual(
            sanitized,
            "##source=lofreq 2.1.5 call -f <workspace>/reference.fa -o <workspace>/outputs/variants.raw.vcf <path>/aln_1.sorted.bam"
        )
        XCTAssertFalse(sanitized.contains("/Users/"))
        XCTAssertFalse(sanitized.contains("/var/folders/"))
    }

    func testBcftoolsCommandLinesKeepDateAndFlagsButNotTheWorkspace() {
        let line = "##bcftools_sortCommand=sort -O v -o \(workspace.path)/outputs/variants.normalized.vcf \(workspace.path)/outputs/caller-with-reference-contigs.vcf; Date=Sat Sep 27 10:00:02 2026"
        let sanitized = VCFHeaderPathSanitizer.sanitize(headerLine: line, context: context)

        XCTAssertEqual(
            sanitized,
            "##bcftools_sortCommand=sort -O v -o <workspace>/outputs/variants.normalized.vcf <workspace>/outputs/caller-with-reference-contigs.vcf; Date=Sat Sep 27 10:00:02 2026"
        )
    }

    func testQuotedAndEqualsJoinedPathsAreRewrittenInsideStructuredLines() {
        let line = "##reference=file:///var/folders/ab/T/lungfish-variants-1234/workspace/reference.fa"
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: line, context: context),
            "##reference=file://<workspace>/reference.fa"
        )
        let quoted = "##GATKCommandLine=<ID=HaplotypeCaller,CommandLine=\"HaplotypeCaller --input /Users/dho/Projects/Demo/aln.bam --reference /var/folders/ab/T/lungfish-variants-1234/workspace/reference.fa\",Version=\"4.6\">"
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: quoted, context: context),
            "##GATKCommandLine=<ID=HaplotypeCaller,CommandLine=\"HaplotypeCaller --input <path>/aln.bam --reference <workspace>/reference.fa\",Version=\"4.6\">"
        )
    }

    func testPlainReferenceValueStaysUnstructuredForHtslib() {
        let line = "##reference=\(workspace.path)/reference.fa"
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: line, context: context),
            "##reference=file://<workspace>/reference.fa"
        )
    }

    func testLinesWithoutAbsolutePathsAndNonHeaderLinesAreUntouched() {
        for line in [
            "##fileformat=VCFv4.0",
            "##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Raw Depth\">",
            "##FILTER=<ID=min_dp_10,Description=\"Minimum Coverage 10\">",
            "##bcftools_viewVersion=1.21+htslib-1.21",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO",
            "MN908947.3\t241\t.\tC\tT\t1234\tPASS\tDP=100;AF=0.98",
        ] {
            XCTAssertEqual(VCFHeaderPathSanitizer.sanitize(headerLine: line, context: context), line)
        }
    }

    func testSourceVersionIsNotInsertedTwiceOrForUnknownTools() {
        let alreadyVersioned = "##source=lofreq 2.1.5 call -f <workspace>/reference.fa"
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: alreadyVersioned, context: context),
            alreadyVersioned
        )
        let unknownTool = "##source=iVar 1.4.2 (TSV-to-VCF: Lungfish 2026.9.52)"
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: unknownTool, context: context),
            unknownTool
        )
    }

    func testSymlinkedWorkspaceIsRecognisedByItsPhysicalPath() throws {
        // /tmp is a symlink to /private/tmp on macOS; the caller may print
        // either form. Both must collapse to <workspace>.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VCFHeaderPathSanitizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let physical = try XCTUnwrap(tempRoot.path.withCString { realpath($0, nil) }.map { String(cString: $0) })
        let symlink = tempRoot.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: tempRoot)
        defer { try? FileManager.default.removeItem(at: symlink) }

        let symlinkContext = VCFHeaderPathSanitizer.Context(workspaceURLs: [symlink])
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: "##reference=\(physical)/reference.fa", context: symlinkContext),
            "##reference=file://<workspace>/reference.fa"
        )
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: "##reference=\(symlink.path)/reference.fa", context: symlinkContext),
            "##reference=file://<workspace>/reference.fa"
        )
    }

    func testSanitizeFileRewritesOnlyMetaLinesAndKeepsDataLinesByteForByte() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VCFHeaderPathSanitizerTests-\(UUID().uuidString).vcf")
        try (fixtureHeader + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let changed = try VCFHeaderPathSanitizer.sanitizeFile(at: url, context: context)
        XCTAssertEqual(changed, 5, "source, reference, and the three bcftools command lines")

        let result = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(result.contains("/var/folders/"))
        XCTAssertFalse(result.contains("/Users/"))
        XCTAssertTrue(result.contains("##source=lofreq 2.1.5 call -f <workspace>/reference.fa"))
        XCTAssertTrue(result.contains("##reference=file://<workspace>/reference.fa"))
        XCTAssertTrue(result.hasSuffix("#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nMN908947.3\t241\t.\tC\tT\t1234\tPASS\tDP=100;AF=0.98\n"))

        // A second pass finds nothing left to change and leaves the file alone.
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(try VCFHeaderPathSanitizer.sanitizeFile(at: url, context: context), 0)
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter)
    }
}
