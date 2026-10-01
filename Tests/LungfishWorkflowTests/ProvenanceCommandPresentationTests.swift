// ProvenanceCommandPresentationTests.swift - Recorded commands as the Inspector shows them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

struct ProvenanceCommandPresentationTests {
    private let project = URL(fileURLWithPath: "/Users/someone/Desktop/HG002 chr20.lungfish", isDirectory: true)
    private let foreign = "/tmp/lge-demo-build/projects/Human Mapping and Variants (with results).lungfish"

    private func display(_ command: String, existing: Set<String> = []) -> String {
        ProvenanceCommandPresentation.display(command, projectURL: project, fileExists: { existing.contains($0) })
    }

    @Test("The recorded minimap2 command shows every project path project-relative and leaves the rest alone")
    func minimap2CommandIsProjectRelative() {
        let readGroup = #"'@RG\tID:HG002.chr20\tSM:HG002.chr20\tPL:ILLUMINA'"#
        let command = "micromamba run -n minimap2 minimap2 -a -x sr -t 14 -R \(readGroup) --secondary=no"
            + " -o '\(foreign)/Analyses/minimap2-1/HG002.raw.sam'"
            + " '\(foreign)/Reference Sequences/GRCh38.lungfishref/genome/sequence.fa.gz'"
            + " '\(foreign)/Imports/HG002.lungfishfastq/HG002.fastq.gz'"
        let shown = display(command)
        #expect(shown == "micromamba run -n minimap2 minimap2 -a -x sr -t 14 -R \(readGroup) --secondary=no"
            + " -o Analyses/minimap2-1/HG002.raw.sam"
            + " 'Reference Sequences/GRCh38.lungfishref/genome/sequence.fa.gz'"
            + " Imports/HG002.lungfishfastq/HG002.fastq.gz")
        #expect(!shown.contains("/tmp/lge-demo-build"))
    }

    @Test("A path in the open project is shown relative to it, however it was quoted")
    func projectPathsAreRelativeUnderEveryQuoting() {
        let base = "/Users/someone/Desktop/HG002 chr20.lungfish/Imports/reads.fq"
        #expect(display("cat '\(base)'") == "cat Imports/reads.fq")
        #expect(display("cat \"\(base)\"") == "cat Imports/reads.fq")
        #expect(display(#"cat /Users/someone/Desktop/HG002\ chr20.lungfish/Imports/reads.fq"#) == "cat Imports/reads.fq")
        #expect(display("cat '\(base)'", existing: [base]) == "cat Imports/reads.fq")
    }

    @Test("A project-relative path that needs quoting is quoted again")
    func rewrittenPathsAreRequoted() {
        let path = "\(foreign)/Reference Sequences/ref (v2).fa"
        #expect(display("samtools faidx '\(path)'") == "samtools faidx 'Reference Sequences/ref (v2).fa'")
    }

    @Test("The value of a key=value or --flag=value argument is rewritten and the key kept")
    func flagValuesAreRewritten() {
        #expect(display("tool --output='\(foreign)/Analyses/x.vcf'") == "tool --output=Analyses/x.vcf")
        #expect(display("tool '--output=\(foreign)/Analyses/x y.vcf'") == "tool '--output=Analyses/x y.vcf'")
        #expect(display("tool REF=/Users/someone/Desktop/HG002\\ chr20.lungfish/ref.fa") == "tool REF=ref.fa")
        #expect(display("tool --secondary=no --preset=sr k=v") == "tool --secondary=no --preset=sr k=v")
    }

    @Test("A scratch or temporary path the project did not keep shows its file name")
    func scratchPathsShowTheirName() {
        #expect(display("bcftools view -o /var/folders/ab/T/variants-1/workspace/outputs/raw.vcf") == "bcftools view -o raw.vcf")
        #expect(display("bcftools view -o '<workspace>/outputs/raw.vcf'") == "bcftools view -o raw.vcf")
        #expect(display("tool > /private/tmp/lge-run/log.txt") == "tool > log.txt")
        #expect(display("tool 2>/tmp/lge-run/err.txt") == "tool 2>err.txt")
    }

    @Test("Arguments that are not paths are never rewritten")
    func nonPathArgumentsAreUntouched() {
        let command = #"tool -t 14 -R '@RG\tID:x' --url=https://example.org/a/b sub/dir/file.txt | sort && echo "a  b" -"#
        #expect(display(command) == command)
        #expect(display("tool  -x   sr") == "tool  -x   sr")
        #expect(display("") == "")
    }

    @Test("A path outside the project that is not scratch stays as recorded")
    func externalPathsStayWhole() {
        let path = "/Volumes/Data/reads/HG002_R1.fastq.gz"
        #expect(display("cat \(path)") == "cat \(path)")
        #expect(display("cat '\(path)'", existing: [path]) == "cat '\(path)'")
        #expect(display("tool 2>/dev/null") == "tool 2>/dev/null")
    }

    @Test("Without a project the command is shown as recorded")
    func noProjectKeepsCommand() {
        let command = "cat '\(foreign)/Imports/reads.fq' /tmp/lge-run/x.txt"
        #expect(ProvenanceCommandPresentation.display(command, projectURL: nil, fileExists: { _ in false }) == command)
    }

    @Test("A command with an unterminated quote is shown as recorded")
    func unterminatedQuoteKeepsCommand() {
        let command = "cat '\(foreign)/Imports/reads.fq"
        #expect(display(command) == command)
    }

    @Test("A single path is presented without shell quoting")
    func singlePathIsPresentedBare() {
        #expect(ProvenanceCommandPresentation.displayPath("\(foreign)/Reference Sequences/ref.fa", projectURL: project, fileExists: { _ in false })
            == "Reference Sequences/ref.fa")
        #expect(ProvenanceCommandPresentation.displayPath("/Volumes/Data/ref.fa", projectURL: project, fileExists: { _ in false })
            == "/Volumes/Data/ref.fa")
    }
}
