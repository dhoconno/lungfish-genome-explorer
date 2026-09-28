// PortablePathTests.swift - Private-path sanitizing and resolving for project records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class PortablePathTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var toolRoot: URL!
    private var storageRoot: URL!
    private let home = "/Users/someone"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-path-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Human Mapping (with results).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true),
            withIntermediateDirectories: true
        )
        toolRoot = URL(fileURLWithPath: "\(home)/.lungfish/conda", isDirectory: true)
        storageRoot = URL(fileURLWithPath: "\(home)/.lungfish", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func context(workspaces: [URL] = []) -> PortablePath.Context {
        PortablePath.Context(
            projectURL: project,
            workspaceURLs: workspaces,
            toolRootURL: toolRoot,
            storageRootURL: storageRoot,
            accountName: "someone"
        )
    }

    // MARK: - Paths

    func testProjectPathsBecomeProjectRelative() {
        let path = project.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        XCTAssertEqual(PortablePath.sanitize(path: path, context: context()), "@/Imports/reads.lungfishfastq/reads.fastq.gz")
        XCTAssertEqual(PortablePath.sanitize(path: project.path, context: context()), "@/")
    }

    func testManagedToolAndStorageRoots() {
        XCTAssertEqual(
            PortablePath.sanitize(path: "\(home)/.lungfish/conda/envs/samtools/bin/samtools", context: context()),
            "<tool-root>/envs/samtools/bin/samtools"
        )
        XCTAssertEqual(
            PortablePath.sanitize(path: "\(home)/.lungfish/databases/kraken2/hash.k2d", context: context()),
            "<storage-root>/databases/kraken2/hash.k2d"
        )
    }

    func testExternalTemporaryAndSystemPaths() {
        XCTAssertEqual(
            PortablePath.sanitize(path: "\(home)/Downloads/sample R1.fastq.gz", context: context()),
            "<external>/sample R1.fastq.gz"
        )
        XCTAssertEqual(PortablePath.sanitize(path: "/usr/bin/java", context: context()), "/usr/bin/java")
        XCTAssertEqual(
            PortablePath.sanitize(path: "/private/tmp/lge-scratch/x.bam", context: context()),
            "<workspace>/lge-scratch/x.bam"
        )
        XCTAssertEqual(
            PortablePath.sanitize(path: "/var/folders/ab/cd/T/run/x.vcf", context: context()),
            "<workspace>/ab/cd/T/run/x.vcf"
        )
        XCTAssertEqual(PortablePath.sanitize(path: "relative/path", context: context()), "relative/path")
    }

    func testDeclaredWorkspaceWinsOverProjectAndTemporaryRoots() {
        let workspace = URL(fileURLWithPath: "/tmp/lge/variants-1234/workspace", isDirectory: true)
        XCTAssertEqual(
            PortablePath.sanitize(path: "/tmp/lge/variants-1234/workspace/inputs/reference.fa", context: context(workspaces: [workspace])),
            "<workspace>/inputs/reference.fa"
        )
        let inProject = project.appendingPathComponent(".tmp/run-1", isDirectory: true)
        XCTAssertEqual(
            PortablePath.sanitize(path: inProject.appendingPathComponent("out.vcf").path, context: context(workspaces: [inProject])),
            "<workspace>/out.vcf"
        )
    }

    func testProjectUnderTemporaryDirectoryStaysProjectRelative() {
        // Demo projects are built under /tmp; the project must win over /tmp.
        let tmpProject = URL(fileURLWithPath: "/tmp/lge-demo-build/projects/Demo.lungfish", isDirectory: true)
        let context = PortablePath.Context(projectURL: tmpProject, toolRootURL: toolRoot, storageRootURL: storageRoot)
        XCTAssertEqual(
            PortablePath.sanitize(path: "/private/tmp/lge-demo-build/projects/Demo.lungfish/Imports/a.fastq", context: context),
            "@/Imports/a.fastq"
        )
    }

    // MARK: - Text

    func testCommandLineWithSpacesInProjectName() {
        let reference = project.appendingPathComponent("Reference Sequences/ref.lungfishref/genome/sequence.fa.gz").path
        let command = "\(home)/.lungfish/conda/envs/bcftools/bin/bcftools mpileup -f \(reference) /tmp/ws/in.bam | bcftools call -o '\(project.path)/out.vcf'"
        let sanitized = PortablePath.sanitize(text: command, context: context())
        XCTAssertEqual(
            sanitized,
            "<tool-root>/envs/bcftools/bin/bcftools mpileup -f @/Reference Sequences/ref.lungfishref/genome/sequence.fa.gz <workspace>/ws/in.bam | bcftools call -o '@/out.vcf'"
        )
        XCTAssertFalse(sanitized.contains(home))
        XCTAssertEqual(PortablePath.sanitize(text: sanitized, context: context()), sanitized, "sanitizing is idempotent")
    }

    func testRuntimeDescriptionAndStderr() {
        let text = "java -cp \(home)/.lungfish/conda/envs/bbtools/opt/bbmap/current/ clump.Clumpify in=\(home)/data/r1.fq\nWriting to /tmp/x//bcftools.CEwK"
        let sanitized = PortablePath.sanitize(text: text, context: context())
        XCTAssertEqual(
            sanitized,
            "java -cp <tool-root>/envs/bbtools/opt/bbmap/current/ clump.Clumpify in=<external>/r1.fq\nWriting to <workspace>/x//bcftools.CEwK"
        )
    }

    func testURLsAndNonPaths() {
        let context = context()
        XCTAssertEqual(PortablePath.sanitize(text: "https://example.org/a/b", context: context), "https://example.org/a/b")
        XCTAssertEqual(PortablePath.sanitize(text: "ratio 1/2 and A/B", context: context), "ratio 1/2 and A/B")
        XCTAssertEqual(
            PortablePath.sanitize(text: "file:///tmp/lge/inputs/GRCh38%20chr20.fasta", context: context),
            "file:///%3Cworkspace%3E/lge/inputs/GRCh38%20chr20.fasta"
        )
        let projectURL = project.appendingPathComponent("Imports/reads.lungfishfastq/r 1.fq").absoluteString
        let sanitized = PortablePath.sanitize(text: projectURL, context: context)
        XCTAssertEqual(sanitized, "file:///@/Imports/reads.lungfishfastq/r%201.fq")
        XCTAssertEqual(PortablePath.resolve(text: sanitized, context: context), projectURL)
        XCTAssertEqual(URL(string: PortablePath.resolve(text: sanitized, context: context))?.path, project.appendingPathComponent("Imports/reads.lungfishfastq/r 1.fq").path)
    }

    func testArgvKeepsSpacesInsideWholePathElements() {
        let argv = [
            "\(home)/.lungfish/conda/envs/minimap2/bin/minimap2",
            "-o",
            project.appendingPathComponent("Analyses/run 1/raw.sam").path,
            "out=\(home)/Desktop/x.fq",
            "@RG\\tID:HG002",
        ]
        XCTAssertEqual(PortablePath.sanitize(argv: argv, context: context()), [
            "<tool-root>/envs/minimap2/bin/minimap2",
            "-o",
            "@/Analyses/run 1/raw.sam",
            "out=<external>/x.fq",
            "@RG\\tID:HG002",
        ])
    }

    // MARK: - Resolve

    func testResolveRoundTripsProjectAndToolPaths() {
        let context = context()
        let argv = [
            "\(home)/.lungfish/conda/envs/samtools/bin/samtools", "sort", "-o",
            project.appendingPathComponent("Analyses/run 1/sorted.bam").path,
            "--reference=\(project.appendingPathComponent("ref.fa").path)",
        ]
        let sanitized = PortablePath.sanitize(argv: argv, context: context)
        XCTAssertEqual(PortablePath.resolve(argv: sanitized, context: context), argv)
    }

    func testResolveAgainstMovedProject() {
        let sanitized = "@/Imports/reads.lungfishfastq/reads.fastq.gz"
        let moved = URL(fileURLWithPath: "/Volumes/Shared/Copy.lungfish", isDirectory: true)
        let context = PortablePath.Context(projectURL: moved)
        XCTAssertEqual(
            PortablePath.resolve(path: sanitized, context: context),
            "/Volumes/Shared/Copy.lungfish/Imports/reads.lungfishfastq/reads.fastq.gz"
        )
    }

    func testExternalNeverResolvesAndWorkspaceResolvesOnlyWhenPresent() throws {
        let context = context()
        XCTAssertEqual(PortablePath.resolve(path: "<external>/a.fq", context: context), "<external>/a.fq")
        XCTAssertTrue(PortablePath.containsUnresolvedPlaceholder("<external>/a.fq"))

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString).txt")
        try "x".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sanitized = PortablePath.sanitize(path: scratch.path, context: context)
        XCTAssertTrue(sanitized.hasPrefix("<workspace>/"), sanitized)
        let resolved = PortablePath.resolve(path: sanitized, context: context)
        XCTAssertEqual(CanonicalFilePath.path(for: URL(fileURLWithPath: resolved)), CanonicalFilePath.path(for: scratch))
        XCTAssertEqual(PortablePath.resolve(path: "<workspace>/gone-\(UUID().uuidString)/x", context: context).prefix(12), "<workspace>/")
    }

    func testBundleOutsideProjectUsesBundlePlaceholder() throws {
        let bundle = root.appendingPathComponent("Staged.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("genome"), withIntermediateDirectories: true)
        let sidecar = bundle.appendingPathComponent(".lungfish-provenance.json")
        let anchors = PortablePath.anchors(for: sidecar)
        XCTAssertNil(anchors.project)
        XCTAssertEqual(anchors.bundle?.standardizedFileURL.path, bundle.standardizedFileURL.path)

        let write = try XCTUnwrap(PortablePath.Context.forWriting(at: sidecar, toolRootURL: toolRoot, storageRootURL: storageRoot))
        let fasta = bundle.appendingPathComponent("genome/sequence.fa.gz").path
        XCTAssertEqual(PortablePath.sanitize(path: fasta, context: write), "<bundle>/genome/sequence.fa.gz")

        // The bundle moves into a project; `<bundle>` still resolves to it.
        let moved = project.appendingPathComponent("Reference Sequences/Staged.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bundle, to: moved)
        let read = PortablePath.Context.forFile(at: moved.appendingPathComponent(".lungfish-provenance.json"), toolRootURL: toolRoot, storageRootURL: storageRoot)
        XCTAssertEqual(
            PortablePath.resolve(path: "<bundle>/genome/sequence.fa.gz", context: read),
            moved.standardizedFileURL.appendingPathComponent("genome/sequence.fa.gz").path
        )
    }

    func testFilesOutsideProjectsAndBundlesAreNotSanitized() {
        let plain = root.appendingPathComponent("plain/out.bam.lungfish-provenance.json")
        XCTAssertNil(PortablePath.Context.forWriting(at: plain))
        let data = Data(#"{"path":"/Users/someone/x.fq"}"#.utf8)
        XCTAssertEqual(PortablePath.sanitizeJSON(data, forFileAt: plain), data)
    }

    // MARK: - JSON

    func testJSONSanitizeDropsAccountAndResolveRestoresPaths() throws {
        let input = project.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        let object: [String: Any] = [
            "argv": ["\(home)/.lungfish/conda/envs/minimap2/bin/minimap2", input],
            "runtimeIdentity": [
                "executablePath": "\(home)/Code/build/Lungfish Debug.app/Contents/MacOS/lungfish-cli",
                "user": "someone",
                "processIdentifier": 12,
            ],
            "toolVersion": "2.31 (managed conda environment minimap2; executable minimap2)",
            "wallTimeSeconds": 1.5,
            "ok": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let sanitized = try PortablePath.sanitizeJSON(data, context: context())
        let text = String(decoding: sanitized, as: UTF8.self)
        XCTAssertFalse(text.contains("someone"), text)
        XCTAssertFalse(text.contains("/Users/"), text)

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let runtime = try XCTUnwrap(decoded["runtimeIdentity"] as? [String: Any])
        XCTAssertNil(runtime["user"])
        XCTAssertEqual(runtime["executablePath"] as? String, "<external>/lungfish-cli")
        XCTAssertEqual(runtime["processIdentifier"] as? Int, 12)
        XCTAssertEqual(decoded["wallTimeSeconds"] as? Double, 1.5)
        XCTAssertEqual(decoded["ok"] as? Bool, true)

        let resolved = try PortablePath.resolveJSON(sanitized, context: context())
        let resolvedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: resolved) as? [String: Any])
        XCTAssertEqual(resolvedObject["argv"] as? [String], ["\(home)/.lungfish/conda/envs/minimap2/bin/minimap2", input])
    }

    func testResolveJSONLeavesPlainDataAlone() throws {
        let data = Data(#"{"a":"b"}"#.utf8)
        XCTAssertEqual(try PortablePath.resolveJSON(data, context: context()), data)
        let notJSON = Data("not json @/x".utf8)
        XCTAssertEqual(try PortablePath.resolveJSON(notJSON, context: context()), notJSON)
    }
}
