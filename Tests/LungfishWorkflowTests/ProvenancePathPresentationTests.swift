// ProvenancePathPresentationTests.swift - Recorded paths as the Inspector shows them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

struct ProvenancePathPresentationTests {
    private let project = URL(fileURLWithPath: "/Users/someone/Desktop/HG002 chr20.lungfish", isDirectory: true)

    private func present(_ path: String, existing: Set<String> = []) -> ProvenancePathPresentation {
        ProvenancePathPresentation.present(path, projectURL: project, fileExists: { existing.contains($0) })
    }

    @Test("A file inside the open project shows its project-relative path")
    func projectFileIsRelative() {
        let path = "/Users/someone/Desktop/HG002 chr20.lungfish/Analyses/minimap2-1/ref.lungfishref/alignments/mapped/aln_1.bam"
        let shown = present(path, existing: [path])
        #expect(shown.location == .project)
        #expect(shown.label == "Analyses/minimap2-1/ref.lungfishref/alignments/mapped/aln_1.bam")
        #expect(shown.isPresent)
        #expect(shown.detail == nil)
        #expect(shown.helpText == path)
        #expect(shown.accessibilityValue == path)
    }

    @Test("A path recorded under another project root that no longer exists is an intermediate")
    func foreignIntermediateIsNotKept() {
        let path = "/tmp/lge-demo-build/projects/Human Mapping.lungfish/Analyses/minimap2-1/HG002.raw.sam"
        let shown = present(path)
        #expect(shown.location == .otherProject)
        #expect(shown.label == "Analyses/minimap2-1/HG002.raw.sam")
        #expect(!shown.isPresent)
        #expect(shown.detail == "intermediate file, not kept")
        #expect(shown.helpText.contains(path))
        #expect(shown.accessibilityValue.contains("not kept"))
        #expect(shown.accessibilityValue.contains(path))
        #expect(shown.listLabel == "Analyses/minimap2-1/HG002.raw.sam (intermediate file, not kept)")
    }

    @Test("A file in the open project that was deleted is an intermediate too")
    func deletedProjectFileIsNotKept() {
        let shown = present("/Users/someone/Desktop/HG002 chr20.lungfish/Analyses/minimap2-1/filtered.bam")
        #expect(shown.location == .project)
        #expect(shown.label == "Analyses/minimap2-1/filtered.bam")
        #expect(shown.detail == "intermediate file, not kept")
    }

    @Test("A scratch workspace file is an intermediate")
    func workspaceFileIsNotKept() {
        for path in [
            "/var/folders/xx/T/variants-1234/workspace/outputs/bcftools.raw.vcf",
            "/private/tmp/lge-run/reference.fa",
            "<workspace>/outputs/bcftools.raw.vcf",
        ] {
            let shown = present(path)
            #expect(shown.location == .external, Comment(rawValue: path))
            #expect(shown.label == URL(fileURLWithPath: path).lastPathComponent, Comment(rawValue: path))
            #expect(shown.detail == "intermediate file, not kept", Comment(rawValue: path))
        }
    }

    @Test("A file outside the project shows its name and keeps the recorded path for help")
    func externalFileShowsBasename() {
        let path = "/Volumes/Data/reads/HG002_R1.fastq.gz"
        let shown = present(path, existing: [path])
        #expect(shown.location == .external)
        #expect(shown.label == "HG002_R1.fastq.gz")
        #expect(shown.detail == "outside the project")
        #expect(shown.helpText.contains(path))
        #expect(shown.accessibilityValue.contains(path))

        let missing = present("<external>/reads/HG002_R1.fastq.gz")
        #expect(missing.label == "HG002_R1.fastq.gz")
        #expect(missing.detail == "outside the project")
    }

    @Test("A stream between piped steps is named as one")
    func pipedStreamIsNamed() {
        let shown = present("pipe:stdout:bcftools-mpileup")
        #expect(shown.location == .stream)
        #expect(shown.label == "stdout of bcftools-mpileup")
        #expect(shown.detail == "stream between piped steps")
    }

    @Test("Without a project every path keeps its recorded form")
    func noProjectKeepsPaths() {
        let path = "/Volumes/Data/out/aln.bam"
        let shown = ProvenancePathPresentation.present(path, projectURL: nil, fileExists: { _ in true })
        #expect(shown.label == path)
        #expect(shown.detail == nil)
    }

    @Test("The sidecar row is the record's project-relative path")
    func sidecarIsRelative() {
        let sidecar = project.appendingPathComponent("Analyses/minimap2-1/.lungfish-provenance.json")
        let shown = ProvenancePathPresentation.present(sidecar.path, projectURL: project, fileExists: { _ in true })
        #expect(shown.label == "Analyses/minimap2-1/.lungfish-provenance.json")
    }
}
