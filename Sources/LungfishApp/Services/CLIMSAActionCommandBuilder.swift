import Foundation

enum CLIMSAActionCommandBuilder {
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
        safeMode: Bool = false,
        keepIdenticalSequences: Bool = false,
        extraIQTreeOptions: String? = nil,
        iqtreePath: String?,
        force: Bool
    ) -> [String] {
        var args = [
            "tree",
            "infer",
            "iqtree",
            bundleURL.path,
            "--project",
            projectURL.path,
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
        args += ["--model", model]
        if let sequenceType,
           sequenceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           sequenceType.lowercased() != "auto" {
            args += ["--sequence-type", sequenceType]
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
        if let threads {
            args += ["--threads", String(threads)]
        }
        if safeMode {
            args.append("--safe")
        }
        if keepIdenticalSequences {
            args.append("--keep-identical")
        }
        if let extraIQTreeOptions,
           extraIQTreeOptions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--extra-iqtree-options", extraIQTreeOptions]
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
