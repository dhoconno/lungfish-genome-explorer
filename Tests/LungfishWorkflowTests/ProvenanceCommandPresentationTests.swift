// ProvenanceCommandPresentationTests.swift - Recorded commands as the Inspector shows them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishTestSupport
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

    /// Lane U3, finding P5 of Phase 2.8. A record names a file of its project as `@/Inputs/x`, and the reader
    /// turns that into the project's path without quotes, so a project folder with a space becomes two words.
    /// The shortener once showed the path whole, naming the project folder and leaving the space unquoted,
    /// where Files & Outputs shows `Inputs/x`. It now reads the project's path as one word.
    @Test("A project path with a space that a record resolved without quotes shows project-relative")
    func anUnquotedProjectPathWithASpaceShowsProjectRelative() {
        let command = "lungfish-cli fastq trim /Users/someone/Desktop/HG002 chr20.lungfish/Inputs/reads.fastq"
            + " --output /Users/someone/Desktop/HG002 chr20.lungfish/Analyses/trim-1/trimmed.fastq"
        #expect(display(command) == "lungfish-cli fastq trim Inputs/reads.fastq --output Analyses/trim-1/trimmed.fastq")
    }

    @Test("An unquoted project path with a space is read as one word under every prefix a path can have")
    func anUnquotedProjectPathIsOneWordUnderEveryPrefix() {
        #expect(display("tool --ref=/Users/someone/Desktop/HG002 chr20.lungfish/ref.fa") == "tool --ref=ref.fa")
        #expect(display("tool 2>/Users/someone/Desktop/HG002 chr20.lungfish/err.txt") == "tool 2>err.txt")
        #expect(display("tool > /Users/someone/Desktop/HG002 chr20.lungfish/log.txt") == "tool > log.txt")
    }

    @Test("The project folder itself, unquoted with a space, is quoted and not shortened")
    func theProjectFolderItselfIsQuoted() {
        #expect(display("lungfish-cli kraken2 classify --project /Users/someone/Desktop/HG002 chr20.lungfish --batch")
            == "lungfish-cli kraken2 classify --project '/Users/someone/Desktop/HG002 chr20.lungfish' --batch")
    }

    // MARK: - The full command, quoted (Phase 2.10 lane U35, M2 item 3)

    private func quoted(_ command: String) -> String {
        ProvenanceCommandPresentation.quotingProjectPath(command, projectURL: project)
    }

    @Test("An unquoted project path with a space is quoted as one word in the full command and shortens as before")
    func anUnquotedProjectPathIsQuotedInTheFullCommand() {
        let root = "/Users/someone/Desktop/HG002 chr20.lungfish"
        let command = "lungfish-cli fastq trim \(root)/Inputs/reads.fastq --output \(root)/Analyses/trim-1/trimmed.fastq"

        #expect(quoted(command)
            == "lungfish-cli fastq trim '\(root)/Inputs/reads.fastq' --output '\(root)/Analyses/trim-1/trimmed.fastq'")
        #expect(display(quoted(command)) == display(command))
        #expect(quoted(quoted(command)) == quoted(command), "a quoted command quotes no further")
    }

    @Test("The quotes go round the whole word, and an operator stays outside them")
    func quotesGoRoundTheWordAndOperatorsStayOutside() {
        let root = "/Users/someone/Desktop/HG002 chr20.lungfish"

        #expect(quoted("tool --ref=\(root)/ref.fa") == "tool '--ref=\(root)/ref.fa'")
        #expect(quoted("tool 2>\(root)/err.txt") == "tool 2>'\(root)/err.txt'")
        #expect(quoted("tool > \(root)/log.txt") == "tool > '\(root)/log.txt'")
        #expect(quoted("tool \(root)") == "tool '\(root)'")
        #expect(quoted("tool  -x   \(root)/a.fa") == "tool  -x   '\(root)/a.fa'")
    }

    @Test("A command that needs no quoting is returned as recorded")
    func aCommandThatNeedsNoQuotingIsReturnedAsRecorded() {
        let root = "/Users/someone/Desktop/HG002 chr20.lungfish"
        let alreadyQuoted = "samtools faidx '\(root)/Inputs/ref.fa' \"\(root)/Inputs/b.fa\" \(root.replacingOccurrences(of: " ", with: "\\ "))/c.fa"
        let plain = #"tool -t 14 -R '@RG\tID:x' --url=https://example.org/a/b sub/dir/file.txt | sort && echo "a  b" -"#

        #expect(quoted(alreadyQuoted) == alreadyQuoted)
        #expect(quoted(plain) == plain)
        #expect(quoted("cat /Users/someone/Desktop/HG002 chr20.lungfish-copy/x.fa") == "cat /Users/someone/Desktop/HG002 chr20.lungfish-copy/x.fa")
        #expect(quoted("cat '\(root)/Inputs/reads.fq") == "cat '\(root)/Inputs/reads.fq", "an unterminated quote")
        #expect(quoted("") == "")
        let command = "tool \(root)/x.fa"
        #expect(ProvenanceCommandPresentation.quotingProjectPath(command, projectURL: nil) == command)
        let noSpace = URL(fileURLWithPath: "/Users/someone/Desktop/HG002.lungfish", isDirectory: true)
        let unspaced = "tool /Users/someone/Desktop/HG002.lungfish/x.fa"
        #expect(ProvenanceCommandPresentation.quotingProjectPath(unspaced, projectURL: noSpace) == unspaced)
    }

    @Test("A folder whose name only starts like the project's is not joined")
    func aSiblingFolderIsNotJoined() {
        let command = "cat /Users/someone/Desktop/HG002 chr20.lungfish-copy/x.fa"
        #expect(display(command) == command)
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

    // MARK: - A quoted project path with a space (Phase 2.11 lane U60, decision U1)

    /// Decision U1 of Phase 2.11 (question Q-U61, answer (a)) keeps `pathPart` as it is, so a word whose value splits
    /// into several shell words is still read as one path when it starts with the project's path. A project folder with
    /// a space in its name is the common case. These rows pass at the base. They guard the shell rule against a refusal
    /// of such a word, which would leave the project's whole path in the row.
    @Test("A quoted project path with a space still shortens as an argument, a flag value, a redirect target and a script path")
    func aQuotedProjectPathWithASpaceStillShortens() {
        let root = "/Users/someone/Desktop/HG002 chr20.lungfish"
        #expect(display("cat '\(root)/Imports/reads.fq'") == "cat Imports/reads.fq")
        #expect(display("tool --ref='\(root)/Inputs/ref.fa'") == "tool --ref=Inputs/ref.fa")
        #expect(display("tool > '\(root)/Logs/run.log'") == "tool > Logs/run.log")
        #expect(display("tool '\(root)/Analyses/run 1/out.vcf'") == "tool 'Analyses/run 1/out.vcf'")
        #expect(display("/bin/sh -c '\(root)/Scripts/run one.sh'") == "/bin/sh -c 'Scripts/run one.sh'")
    }

    // MARK: - A shell's script (Phase 2.11 lane U60, O3 walk defect 1)

    /// Every shell argv the product records, from `rg -n '"/bin/(ba|z|da)?sh"' Sources`. The product records
    /// `/bin/sh` and, at `BundleVariantTrackAttachmentService.swift:252` and `ReadExtractionService.swift:949`, a
    /// bare `sh -lc`. The `/bin/sh -c` form is the Kraken2 gzip replay, the classifier copy, the metagenomics import,
    /// the ONT BAM import and the mapping member `cat`. The `/bin/sh -lc` cluster is the
    /// assembly, mapping, fastp, grouped FASTQ and CLI provenance commands. The other rows are the shells the rule
    /// names and a cluster that is not `-lc`.
    private let shellForms: [(program: String, flag: String)] = [
        ("/bin/sh", "-c"), ("/bin/sh", "-lc"), ("sh", "-lc"),
        ("/bin/bash", "-c"), ("/bin/zsh", "-c"), ("/bin/dash", "-c"), ("sh", "-c"), ("/bin/bash", "-ec"),
    ]

    @Test("A shell's script keeps its program and shortens its paths under every shell form")
    func testAShellScriptKeepsItsProgramAndShortensItsPaths() {
        let root = "/Users/someone/Desktop/HG002 chr20.lungfish"
        let kraken = "\(root)/Analyses/kraken2-1/classification.kraken"
        let shown = "/usr/bin/gzip -c Analyses/kraken2-1/classification.kraken > Analyses/kraken2-1/classification.kraken.gz"
        for form in shellForms {
            let lead = "\(form.program) \(form.flag)"
            // Both paths hold a space, so the join of the argv quotes each inside the script and quotes the script again.
            let quotedPaths = #"\#(lead) '/usr/bin/gzip -c '\''\#(kraken)'\'' > '\''\#(kraken).gz'\'''"#
            #expect(display(quotedPaths) == "\(lead) '\(shown)'", "\(lead), paths quoted inside the script")
            // The reader resolves a record's portable `@/Analyses/...` into the project's path, unquoted.
            let unquotedPaths = "\(lead) '/usr/bin/gzip -c \(kraken) > \(kraken).gz'"
            #expect(display(unquotedPaths) == "\(lead) '\(shown)'", "\(lead), paths unquoted inside the script")
            // A script that does not start with a path has its paths shortened as well.
            let merge = "\(lead) 'cat \(root)/Inputs/a.fq \(root)/Inputs/b.fq > \(root)/Analyses/map-1/merged.fq'"
            #expect(display(merge) == "\(lead) 'cat Inputs/a.fq Inputs/b.fq > Analyses/map-1/merged.fq'", "\(lead), a cat merge")
            // A multi-line script keeps its line breaks.
            let copy = "\(lead) 'set -e\nmkdir -p \(root)/Analyses/x\ncp \(root)/Inputs/a.fq \(root)/Analyses/x/a.fq'"
            #expect(display(copy) == "\(lead) 'set -e\nmkdir -p Analyses/x\ncp Inputs/a.fq Analyses/x/a.fq'", "\(lead), a multi-line script")
        }
    }

    @Test("A shell's script in a project whose path holds no space keeps its program")
    func testAShellScriptInAProjectWithNoSpaceKeepsItsProgram() {
        let plain = URL(fileURLWithPath: "/Users/someone/Desktop/HG002.lungfish", isDirectory: true)
        let kraken = "\(plain.path)/Analyses/kraken2-1/classification.kraken"
        for form in shellForms {
            let lead = "\(form.program) \(form.flag)"
            // No path in the script needs quotes, so the script is the one quoted word the join of the argv leaves.
            let command = "\(lead) '/usr/bin/gzip -c \(kraken) > \(kraken).gz'"
            let shown = ProvenanceCommandPresentation.display(command, projectURL: plain, fileExists: { _ in false })
            #expect(shown == "\(lead) '/usr/bin/gzip -c Analyses/kraken2-1/classification.kraken"
                + " > Analyses/kraken2-1/classification.kraken.gz'", "\(lead)")
            #expect(shown.hasPrefix("\(lead) '/usr/bin/gzip -c "), "\(lead) keeps its program")
        }
    }

    @Test("A shell's script that holds no project path is returned as recorded, quotes and all")
    func aShellScriptWithNoProjectPathIsReturnedAsRecorded() {
        let scripts = [
            "'echo hello world'", "\"echo hello world\"", "''", "'cat a.fq | sort > b.fq'",
            "'/usr/bin/gzip -c /Volumes/Data/a.fq > /Volumes/Data/a.fq.gz'",
        ]
        for form in shellForms {
            for script in scripts {
                let command = "\(form.program) \(form.flag) \(script)"
                #expect(display(command) == command)
            }
        }
        // Only a shell's script is read as a script, so `-c` after another program keeps its meaning.
        #expect(display("/usr/bin/gzip -c '/Users/someone/Desktop/HG002 chr20.lungfish/Analyses/x.kraken'")
            == "/usr/bin/gzip -c Analyses/x.kraken")
    }

    /// Kraken2 batch records written until Phase 2.9 hold a `/bin/sh -c` script that guards each sample with
    /// `/bin/test -d DB; /bin/test -f DB/.lungfish-provenance.json; ...` (`legacyBatchReplayCommand` in
    /// `Tests/LungfishAppTests/ClassifierLegacyRuns.swift` builds it, and `kraken2-batch.facts.json` pins its bytes).
    /// The splitter cuts on white space only, so `DB;` is one word, and the managed database sits under
    /// `~/.lungfish/`, where the path presentation cuts a path. The `;` that ends the command stays outside the
    /// shortened path and its quotes, so the row keeps the command boundaries and gains no `'\''` noise.
    @Test("An older Kraken2 batch record's replay script keeps its command boundaries and shortens its paths")
    func aLegacyKraken2BatchReplayScriptKeepsItsCommandBoundaries() {
        let root = "/Users/someone/Desktop/HG002 chr20.lungfish"
        let db = "/Users/someone/.lungfish/databases/kraken2/Viral"
        let script = "set -e\n/bin/test -d \(db); /bin/test -f \(db)/.lungfish-provenance.json;"
            + " lungfish-cli kraken2 classify --db Viral --output-dir '\(root)/Analyses/kraken2-batch/SampleA' '\(root)/reads.fastq'"
        let command = "/bin/sh -c \(shellEscape(script))"
        #expect(display(command) == "/bin/sh -c 'set -e\n/bin/test -d databases/kraken2/Viral;"
            + " /bin/test -f databases/kraken2/Viral/.lungfish-provenance.json;"
            + " lungfish-cli kraken2 classify --db Viral --output-dir Analyses/kraken2-batch/SampleA reads.fastq'")
    }

    @Test("The Kraken2 golden record's gzip step shows its program, and showing it writes nothing")
    func theKraken2GoldenShellStepShowsItsProgramAndTheRecordIsUntouched() throws {
        let url = ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/golden/classifiers/kraken2/lungfish-provenance.json")
        let before = try Data(contentsOf: url)
        let document = try #require(try JSONSerialization.jsonObject(with: before) as? [String: Any])
        let steps = try #require(document["steps"] as? [[String: Any]])
        let commands = steps.compactMap { $0["reproducibleCommand"] as? String }
        let recorded = try #require(commands.first { $0.hasPrefix("/bin/sh -c ") })

        // The reader resolves the portable `@/` into the project's path, unquoted.
        let command = recorded.replacingOccurrences(of: "@/", with: "/Users/someone/Desktop/HG002 chr20.lungfish/")
        let row = display(command)
        #expect(row == "/bin/sh -c '/usr/bin/gzip -c Analyses/kraken2-golden/classification.kraken"
            + " > Analyses/kraken2-golden/classification.kraken.gz'")
        // Copy Command carries the recorded command whole, and the row of that text is the row.
        let copied = ProvenanceCommandPresentation.quotingProjectPath(command, projectURL: project)
        #expect(copied == command)
        #expect(display(copied) == row)
        for each in commands { _ = display(each) }

        let after = try Data(contentsOf: url)
        #expect(sha256Hex(before) == sha256Hex(after), "the record's bytes are the same after the rows are built")
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
