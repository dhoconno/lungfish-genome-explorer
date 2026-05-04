import XCTest
@testable import LungfishApp

final class CLIMSAActionCommandBuilderTests: XCTestCase {
    func testBuildExtractArgumentsUseSelectionAndJSONProgress() {
        let bundle = URL(fileURLWithPath: "/project/Multiple Sequence Alignments/example.lungfishmsa", isDirectory: true)
        let output = URL(fileURLWithPath: "/project/Exports/example-selection.fasta")

        let args = CLIMSAActionCommandBuilder.buildExtractArguments(
            bundleURL: bundle,
            outputURL: output,
            outputKind: "fasta",
            rows: "row-a,row-b",
            columns: "10-20,35",
            name: "example-selection",
            force: true
        )

        XCTAssertEqual(args, [
            "msa", "extract", bundle.path,
            "--output-kind", "fasta",
            "--output", output.path,
            "--rows", "row-a,row-b",
            "--columns", "10-20,35",
            "--name", "example-selection",
            "--force",
            "--format", "json",
        ])
        XCTAssertTrue(
            CLIMSAActionCommandBuilder.displayCommand(arguments: args)
                .hasPrefix("lungfish msa extract")
        )
    }

    func testBuildIQTreeInferenceArgumentsUseProjectOutputAndJSONProgress() {
        let bundle = URL(fileURLWithPath: "/project/Multiple Sequence Alignments/example.lungfishmsa", isDirectory: true)
        let project = URL(fileURLWithPath: "/project", isDirectory: true)
        let output = URL(fileURLWithPath: "/project/Phylogenetic Trees/example.lungfishtree", isDirectory: true)

        let args = CLIMSAActionCommandBuilder.buildIQTreeInferenceArguments(
            bundleURL: bundle,
            projectURL: project,
            outputURL: output,
            name: "example tree",
            model: "GTR+G",
            bootstrap: 1000,
            seed: 42,
            threads: 4,
            iqtreePath: "/opt/lungfish/bin/iqtree3",
            force: true
        )

        XCTAssertEqual(args, [
            "tree", "infer", "iqtree", bundle.path,
            "--project", project.path,
            "--output", output.path,
            "--name", "example tree",
            "--model", "GTR+G",
            "--bootstrap", "1000",
            "--seed", "42",
            "--threads", "4",
            "--iqtree-path", "/opt/lungfish/bin/iqtree3",
            "--force",
            "--format", "json",
        ])
        XCTAssertTrue(
            CLIMSAActionCommandBuilder.displayCommand(arguments: args)
                .hasPrefix("lungfish tree infer iqtree")
        )
    }

    func testBuildAnnotationAddArgumentsUseCLIAnnotationSubcommandAndJSONProgress() {
        let bundle = URL(fileURLWithPath: "/project/Multiple Sequence Alignments/example.lungfishmsa", isDirectory: true)

        let args = CLIMSAActionCommandBuilder.buildAnnotationAddArguments(
            bundleURL: bundle,
            row: "row-seq1",
            columns: "10-20",
            name: "spike",
            type: "gene",
            strand: "+",
            note: "manual landmark",
            qualifiers: ["created_by=lungfish-gui"]
        )

        XCTAssertEqual(args, [
            "msa", "annotate", "add", bundle.path,
            "--row", "row-seq1",
            "--columns", "10-20",
            "--name", "spike",
            "--type", "gene",
            "--strand", "+",
            "--note", "manual landmark",
            "--qualifier", "created_by=lungfish-gui",
            "--format", "json",
        ])
        XCTAssertTrue(
            CLIMSAActionCommandBuilder.displayCommand(arguments: args)
                .hasPrefix("lungfish msa annotate add")
        )
    }

    func testBuildAnnotationProjectArgumentsUseCLIAnnotationSubcommandAndJSONProgress() {
        let bundle = URL(fileURLWithPath: "/project/Multiple Sequence Alignments/example.lungfishmsa", isDirectory: true)

        let args = CLIMSAActionCommandBuilder.buildAnnotationProjectArguments(
            bundleURL: bundle,
            sourceAnnotationID: "ann-1",
            targetRows: "row-seq2,row-seq3",
            conflictPolicy: "append"
        )

        XCTAssertEqual(args, [
            "msa", "annotate", "project", bundle.path,
            "--source-annotation", "ann-1",
            "--target-rows", "row-seq2,row-seq3",
            "--conflict-policy", "append",
            "--format", "json",
        ])
        XCTAssertTrue(
            CLIMSAActionCommandBuilder.displayCommand(arguments: args)
                .hasPrefix("lungfish msa annotate project")
        )
    }
}
