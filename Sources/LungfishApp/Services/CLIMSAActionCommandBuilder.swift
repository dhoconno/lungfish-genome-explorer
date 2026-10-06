import Foundation
import LungfishIO
import LungfishKit

enum CLIMSAActionCommandBuilder {
    static func buildSelectionExportArguments(
        request: MultipleSequenceAlignmentSelectionExportRequest,
        outputURL: URL
    ) -> [String] {
        if request.outputKind == "aligned-fasta" {
            return buildExportArguments(
                bundleURL: request.bundleURL,
                outputURL: outputURL,
                outputFormat: "aligned-fasta",
                rows: request.rows,
                columns: request.columns,
                force: true
            )
        }
        return buildExtractArguments(
            bundleURL: request.bundleURL,
            outputURL: outputURL,
            outputKind: request.outputKind,
            rows: request.rows,
            columns: request.columns,
            name: outputURL.deletingPathExtension().lastPathComponent,
            force: true
        )
    }

    static func buildExtractArguments(
        bundleURL: URL,
        outputURL: URL,
        outputKind: String,
        rows: String?,
        columns: String?,
        name: String?,
        force: Bool
    ) -> [String] {
        var args = [
            "msa",
            "extract",
            bundleURL.path,
            "--output-kind",
            outputKind,
            "--output",
            outputURL.path,
        ]
        if let rows, rows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--rows", rows]
        }
        if let columns, columns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--columns", columns]
        }
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--name", name]
        }
        if force {
            args.append("--force")
        }
        args += ["--format", "json"]
        return args
    }

    static func buildExportArguments(
        bundleURL: URL,
        outputURL: URL,
        outputFormat: String,
        rows: String?,
        columns: String?,
        force: Bool
    ) -> [String] {
        var args = [
            "msa",
            "export",
            bundleURL.path,
            "--output-format",
            outputFormat,
            "--output",
            outputURL.path,
        ]
        if let rows, rows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--rows", rows]
        }
        if let columns, columns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--columns", columns]
        }
        if force {
            args.append("--force")
        }
        args += ["--format", "json"]
        return args
    }

    static func buildAnnotationAddArguments(
        bundleURL: URL,
        row: String,
        columns: String,
        name: String,
        type: String,
        strand: String,
        note: String?,
        qualifiers: [String]
    ) -> [String] {
        var args = [
            "msa",
            "annotate",
            "add",
            bundleURL.path,
            "--row",
            row,
            "--columns",
            columns,
            "--name",
            name,
            "--type",
            type,
            "--strand",
            strand,
        ]
        if let note, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--note", note]
        }
        for qualifier in qualifiers where qualifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--qualifier", qualifier]
        }
        args += ["--format", "json"]
        return args
    }

    static func buildAnnotationProjectArguments(
        bundleURL: URL,
        sourceAnnotationID: String,
        targetRows: String,
        conflictPolicy: String
    ) -> [String] {
        [
            "msa",
            "annotate",
            "project",
            bundleURL.path,
            "--source-annotation",
            sourceAnnotationID,
            "--target-rows",
            targetRows,
            "--conflict-policy",
            conflictPolicy,
            "--format",
            "json",
        ]
    }

    static func buildIQTreeInferenceArguments(
        bundleURL: URL,
        projectURL: URL,
        outputURL: URL,
        rows: String? = nil,
        columns: String? = nil,
        name: String?,
        model: String,
        sequenceType: String? = nil,
        bootstrap: Int?,
        alrt: Int? = nil,
        seed: Int?,
        threads: Int?,
        outgroup: [String] = [],
        safeMode: Bool = false,
        keepIdenticalSequences: Bool = false,
        extraIQTreeOptions: String? = nil,
        iqtreePath: String?,
        force: Bool
    ) -> [String] {
        // Fix F1 (m4). The order and the standardized paths follow the CLI's
        // canonicalArgv, so the recorded command equals the provenance argv.
        var args = [
            "tree",
            "infer",
            "iqtree",
            bundleURL.standardizedFileURL.path,
            "--project",
            projectURL.standardizedFileURL.path,
            "--output",
            outputURL.standardizedFileURL.path,
            "--model",
            model,
        ]
        if let sequenceType,
           sequenceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           sequenceType.lowercased() != "auto" {
            args += ["--sequence-type", sequenceType]
        }
        if let rows, rows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--rows", rows]
        }
        if let columns, columns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--columns", columns]
        }
        if let threads {
            args += ["--threads", String(threads)]
        }
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--name", name]
        }
        if let bootstrap {
            args += ["--bootstrap", String(bootstrap)]
        }
        if let alrt {
            args += ["--alrt", String(alrt)]
        }
        if let seed {
            args += ["--seed", String(seed)]
        }
        // D7, fix F1 (m6). The dialog passes row IDs, which the CLI resolves
        // before display names, so a name with a comma never reaches the list.
        let outgroupRowIDs = outgroup
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        if outgroupRowIDs.isEmpty == false {
            args += ["--outgroup", outgroupRowIDs.joined(separator: ",")]
        }
        if safeMode {
            args.append("--safe")
        }
        if keepIdenticalSequences {
            args.append("--keep-identical")
        }
        if let extraIQTreeOptions,
           extraIQTreeOptions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--extra-args", extraIQTreeOptions]
        }
        if let iqtreePath, iqtreePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--iqtree-path", iqtreePath]
        }
        if force {
            args.append("--force")
        }
        args += ["--format", "json"]
        return args
    }

    /// `msa distance` arguments for exporting the distance matrix. `--model` is always passed.
    /// `--gaps` and `--order` are passed only when they differ from the CLI defaults, matching
    /// the CLI's own canonical argv. The alphabet is never passed because the CLI reads it from
    /// the bundle manifest. Rows and columns are never restricted, so the export covers the
    /// whole alignment.
    static func buildDistanceArguments(
        bundleURL: URL,
        options: MSADistanceOptions,
        outputURL: URL,
        force: Bool = true
    ) -> [String] {
        var args = [
            "msa",
            "distance",
            bundleURL.path,
            "--model",
            options.model.rawValue,
        ]
        if options.gaps != .pairwise {
            args += ["--gaps", options.gaps.rawValue]
        }
        if options.order != .alignment {
            args += ["--order", options.order.rawValue]
        }
        args += ["--output", outputURL.path]
        if force {
            args.append("--force")
        }
        args += ["--format", "json"]
        return args
    }

    /// `msa discriminating-sites` arguments for the Inspector's Discriminating Sites
    /// section. Options at their CLI defaults are still passed for tolerance and
    /// window length, matching the CLI's own canonical argv, while the optional
    /// selections are omitted when unset so the command reads like the manual's.
    static func buildDiscriminatingSitesArguments(
        request: MSADiscriminatingSitesRequest,
        outputURL: URL,
        windowsOutputURL: URL? = nil,
        jsonOutputURL: URL? = nil,
        force: Bool = true
    ) -> [String] {
        var args = ["msa", "discriminating-sites", request.bundleURL.path]
        if let targets = request.targets, targets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--targets", targets]
        }
        if let exclusions = request.exclusions, exclusions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--exclusions", exclusions]
        }
        if let exclusionSequencesURL = request.exclusionSequencesURL {
            args += ["--exclusion-sequences", exclusionSequencesURL.path]
        }
        if let template = request.template, template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--template", template]
        }
        args += ["--target-mismatch-tolerance", String(request.targetMismatchTolerance)]
        if let minimum = request.minimumExclusionDifferences {
            args += ["--min-exclusion-differences", String(minimum)]
        }
        args += ["--window-length", String(request.windowLength)]
        args += ["--output", outputURL.path]
        if let windowsOutputURL {
            args += ["--windows-output", windowsOutputURL.path]
        }
        if let jsonOutputURL {
            args += ["--json-output", jsonOutputURL.path]
        }
        if force {
            args.append("--force")
        }
        args += ["--format", "json"]
        return args
    }

    static func displayCommand(arguments: [String]) -> String {
        guard let subcommand = arguments.first else {
            return OperationCenter.buildCLICommand(subcommand: "msa", args: [])
        }
        return OperationCenter.buildCLICommand(
            subcommand: subcommand,
            args: Array(arguments.dropFirst())
        )
    }
}
