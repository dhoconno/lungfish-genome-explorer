import XCTest
@testable import LungfishApp
import LungfishIO

final class CLIMSAActionCommandBuilderTests: XCTestCase {
    func testDistanceMatrixExportUsesMSADistanceWithModelAndForce() {
        let bundle = URL(fileURLWithPath: "/project/example.lungfishmsa")
        let output = URL(fileURLWithPath: "/exports/example-identity.tsv")
        XCTAssertEqual(
            CLIMSAActionCommandBuilder.buildDistanceArguments(bundleURL: bundle, options: MSADistanceOptions(), outputURL: output),
            ["msa", "distance", bundle.path, "--model", "identity", "--output", output.path, "--force", "--format", "json"]
        )
        XCTAssertEqual(
            CLIMSAActionCommandBuilder.buildDistanceArguments(
                bundleURL: bundle,
                options: MSADistanceOptions(model: .pDistance),
                outputURL: output,
                force: false
            ),
            ["msa", "distance", bundle.path, "--model", "p-distance", "--output", output.path, "--format", "json"]
        )
    }

    /// Non-default gap policy and order are passed in the CLI's canonical spelling and order.
    /// The alphabet never is, because the CLI reads it from the bundle manifest.
    func testDistanceMatrixExportPassesNonDefaultGapsAndOrder() {
        let bundle = URL(fileURLWithPath: "/project/example.lungfishmsa")
        let output = URL(fileURLWithPath: "/exports/example-k2p.tsv")
        XCTAssertEqual(
            CLIMSAActionCommandBuilder.buildDistanceArguments(
                bundleURL: bundle,
                options: MSADistanceOptions(model: .k2p, gaps: .complete, order: .averageLinkage),
                outputURL: output
            ),
            [
                "msa", "distance", bundle.path,
                "--model", "k2p",
                "--gaps", "complete",
                "--order", "average-linkage",
                "--output", output.path,
                "--force",
                "--format", "json",
            ]
        )
        XCTAssertEqual(
            CLIMSAActionCommandBuilder.buildDistanceArguments(
                bundleURL: bundle,
                options: MSADistanceOptions(model: .poisson, alphabet: .protein),
                outputURL: output,
                force: false
            ),
            ["msa", "distance", bundle.path, "--model", "poisson", "--output", output.path, "--format", "json"]
        )
    }

    /// The Inspector's file-based run must spell the command the manual documents:
    /// bundle, --exclusion-sequences, the two numeric options at their defaults,
    /// --output, --force for a rerun, and JSON progress for the Operation Center.
    func testDiscriminatingSitesFileExclusionsMatchTheDocumentedCLISpelling() {
        let bundle = URL(fileURLWithPath: "/project/Analyses/Multiple Sequence Alignments/lineage.lungfishmsa")
        let exclusions = URL(fileURLWithPath: "/project/Reference Sequences/exclusion.lungfishref")
        let output = URL(fileURLWithPath: "/project/Analyses/lineage-discriminating-sites.tsv")
        let request = MSADiscriminatingSitesRequest(bundleURL: bundle, exclusionSequencesURL: exclusions)
        XCTAssertEqual(
            CLIMSAActionCommandBuilder.buildDiscriminatingSitesArguments(request: request, outputURL: output),
            [
                "msa", "discriminating-sites", bundle.path,
                "--exclusion-sequences", exclusions.path,
                "--target-mismatch-tolerance", "0",
                "--window-length", "25",
                "--output", output.path,
                "--force", "--format", "json",
            ]
        )
    }

    func testDiscriminatingSitesRowExclusionsPassEverySelectionAndOptionalOutputs() {
        let bundle = URL(fileURLWithPath: "/project/panel.lungfishmsa")
        let output = URL(fileURLWithPath: "/exports/sites.tsv")
        let json = URL(fileURLWithPath: "/exports/report.json")
        let windows = URL(fileURLWithPath: "/exports/windows.tsv")
        let request = MSADiscriminatingSitesRequest(
            bundleURL: bundle,
            targets: "t1,t2",
            exclusions: "x1,x2",
            template: "t2",
            targetMismatchTolerance: 1,
            minimumExclusionDifferences: 1,
            windowLength: 150
        )
        XCTAssertEqual(
            CLIMSAActionCommandBuilder.buildDiscriminatingSitesArguments(
                request: request, outputURL: output, windowsOutputURL: windows, jsonOutputURL: json, force: false
            ),
            [
                "msa", "discriminating-sites", bundle.path,
                "--targets", "t1,t2",
                "--exclusions", "x1,x2",
                "--template", "t2",
                "--target-mismatch-tolerance", "1",
                "--min-exclusion-differences", "1",
                "--window-length", "150",
                "--output", output.path,
                "--windows-output", windows.path,
                "--json-output", json.path,
                "--format", "json",
            ]
        )
        XCTAssertEqual(
            MSADiscriminatingSitesRequest.defaultJSONOutputURL(for: output).path, "/exports/sites.json")
        XCTAssertEqual(
            MSADiscriminatingSitesRequest.defaultWindowsOutputURL(for: output).path, "/exports/sites.windows.tsv")
    }

    func testAlignedSelectionExportUsesSupportedCommandAndExactScope() {
        let bundle = URL(fileURLWithPath: "/project/example.lungfishmsa")
        let output = URL(fileURLWithPath: "/exports/subalignment.fasta")
        let request = MultipleSequenceAlignmentSelectionExportRequest(
            bundleURL: bundle, outputKind: "aligned-fasta", rows: "row-a,row-c",
            columns: "2-5", suggestedName: "subalignment.fasta", displayName: "Selection"
        )
        XCTAssertEqual(CLIMSAActionCommandBuilder.buildSelectionExportArguments(request: request, outputURL: output), [
            "msa", "export", bundle.path, "--output-format", "aligned-fasta",
            "--output", output.path, "--rows", "row-a,row-c", "--columns", "2-5",
            "--force", "--format", "json",
        ])
    }

    func testSelectionBundleCreationKeepsExtractCommand() {
        let bundle = URL(fileURLWithPath: "/project/example.lungfishmsa")
        let output = URL(fileURLWithPath: "/exports/subalignment.lungfishmsa")
        let request = MultipleSequenceAlignmentSelectionExportRequest(
            bundleURL: bundle, outputKind: "msa", rows: "row-a,row-c",
            columns: nil, suggestedName: "subalignment.lungfishmsa", displayName: "Selection"
        )
        XCTAssertEqual(CLIMSAActionCommandBuilder.buildSelectionExportArguments(request: request, outputURL: output), [
            "msa", "extract", bundle.path, "--output-kind", "msa",
            "--output", output.path, "--rows", "row-a,row-c", "--name", "subalignment",
            "--force", "--format", "json",
        ])
    }

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
                .hasPrefix("lungfish-cli msa extract")
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
            "--model", "GTR+G",
            "--threads", "4",
            "--name", "example tree",
            "--bootstrap", "1000",
            "--seed", "42",
            "--iqtree-path", "/opt/lungfish/bin/iqtree3",
            "--force",
            "--format", "json",
        ])
        XCTAssertTrue(
            CLIMSAActionCommandBuilder.displayCommand(arguments: args)
                .hasPrefix("lungfish-cli tree infer iqtree")
        )
    }

    func testBuildIQTreeInferenceArgumentsPassCuratedAndAdvancedOptions() {
        let bundle = URL(fileURLWithPath: "/project/Multiple Sequence Alignments/example.lungfishmsa", isDirectory: true)
        let project = URL(fileURLWithPath: "/project", isDirectory: true)
        let output = URL(fileURLWithPath: "/project/Phylogenetic Trees/example.lungfishtree", isDirectory: true)

        let args = CLIMSAActionCommandBuilder.buildIQTreeInferenceArguments(
            bundleURL: bundle,
            projectURL: project,
            outputURL: output,
            rows: "row-a,row-b",
            columns: "10-50",
            name: "example tree",
            model: "JC",
            sequenceType: "DNA",
            bootstrap: 1000,
            alrt: 1000,
            seed: 12345,
            threads: 2,
            safeMode: true,
            keepIdenticalSequences: true,
            extraIQTreeOptions: "-bnni --pathogen",
            iqtreePath: nil,
            force: false
        )

        XCTAssertEqual(args, [
            "tree", "infer", "iqtree", bundle.path,
            "--project", project.path,
            "--output", output.path,
            "--model", "JC",
            "--sequence-type", "DNA",
            "--rows", "row-a,row-b",
            "--columns", "10-50",
            "--threads", "2",
            "--name", "example tree",
            "--bootstrap", "1000",
            "--alrt", "1000",
            "--seed", "12345",
            "--safe",
            "--keep-identical",
            "--extra-args", "-bnni --pathogen",
            "--format", "json",
        ])
    }

    /// Fix F1 (m4, m6): the argv follows the CLI's canonicalArgv order and
    /// joins the outgroup row IDs after the seed.
    func testBuildIQTreeInferenceArgumentsJoinOutgroupRowIDsAfterSeed() {
        let bundle = URL(fileURLWithPath: "/project/Multiple Sequence Alignments/example.lungfishmsa", isDirectory: true)
        let project = URL(fileURLWithPath: "/project", isDirectory: true)
        let output = URL(fileURLWithPath: "/project/Phylogenetic Trees/example.lungfishtree", isDirectory: true)

        let args = CLIMSAActionCommandBuilder.buildIQTreeInferenceArguments(
            bundleURL: bundle,
            projectURL: project,
            outputURL: output,
            name: "example tree",
            model: "MFP",
            bootstrap: nil,
            seed: 7,
            threads: 1,
            outgroup: ["row-2", " ", "row-4"],
            iqtreePath: nil,
            force: false
        )

        XCTAssertEqual(args, [
            "tree", "infer", "iqtree", bundle.path,
            "--project", project.path,
            "--output", output.path,
            "--model", "MFP",
            "--threads", "1",
            "--name", "example tree",
            "--seed", "7",
            "--outgroup", "row-2,row-4",
            "--format", "json",
        ])
    }

    /// Fix F1 (m4): paths are standardized as the CLI records them.
    func testBuildIQTreeInferenceArgumentsStandardizePaths() {
        let args = CLIMSAActionCommandBuilder.buildIQTreeInferenceArguments(
            bundleURL: URL(fileURLWithPath: "/project/./Analyses/../Multiple Sequence Alignments/example.lungfishmsa"),
            projectURL: URL(fileURLWithPath: "/project/Analyses/.."),
            outputURL: URL(fileURLWithPath: "/project/Phylogenetic Trees/./example.lungfishtree"),
            name: nil,
            model: "MFP",
            bootstrap: nil,
            seed: nil,
            threads: nil,
            iqtreePath: nil,
            force: false
        )

        XCTAssertEqual(Array(args.prefix(8)), [
            "tree", "infer", "iqtree", "/project/Multiple Sequence Alignments/example.lungfishmsa",
            "--project", "/project",
            "--output", "/project/Phylogenetic Trees/example.lungfishtree",
        ])
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
                .hasPrefix("lungfish-cli msa annotate add")
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
                .hasPrefix("lungfish-cli msa annotate project")
        )
    }
}
