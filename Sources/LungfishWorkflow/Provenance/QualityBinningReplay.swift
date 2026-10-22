// QualityBinningReplay.swift - A recorded import command that names no quality binning, as its replay runs it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane C2-BINNING. `illumina4` became the default of every import route on 2026-10-22, and every command recorded
// from then on names its binning. Before that, `fastq import-ont`, `fetch sra download --bundle` and `fastq ingest`
// left the flag out when the value was `none`, their default then, so a replay of such a record would now bin. The
// replay adds the flag with the value the record states, or `none` when it states none, since such a command ran with
// no binning. `import fastq` always named the flag and `debug fastq-ingest` kept its `illumina4` default, so their
// commands go out as recorded. The record itself is never written.

import Foundation
import LungfishCore

public enum QualityBinningReplay {
    /// What a recorded import command that names no binning ran with, the default of these routes before the change.
    public static let recordedDefault = QualityBinningScheme.none

    /// The binning flag `argv` takes, or nil for a command that is not one of these import routes.
    static func flag(of argv: [String]) -> String? {
        guard let executable = argv.first,
              [CLICommandIdentity.executableName, "lungfish"].contains(URL(fileURLWithPath: executable).lastPathComponent)
        else { return nil }
        let words = Array(argv.dropFirst())
        if words.starts(with: ["fastq", "import-ont"]) { return "--quality-binning" }
        if words.starts(with: ["fetch", "sra", "download"]), words.contains("--bundle") { return "--quality-binning" }
        if words.starts(with: ["fastq", "ingest"]) { return "--binning" }
        return nil
    }

    /// `argv` as its replay runs it, with the binning flag and a value added when it is one of these import routes'
    /// commands and names no binning. `stated` is the value the record states. A value this build does not know
    /// counts as unstated.
    public static func arguments(_ argv: [String], stated: String?) -> [String] {
        guard let flag = flag(of: argv), !argv.contains(where: { $0 == flag || $0.hasPrefix(flag + "=") }) else {
            return argv
        }
        let value = stated.flatMap(QualityBinningScheme.init(rawValue:)) ?? recordedDefault
        return argv + [flag, value.rawValue]
    }

    /// The binning `options` state, under `qualityBinning` or under `fastq ingest`'s `binning`.
    public static func statedValue(in options: [String: ParameterValue]?) -> String? {
        guard let options else { return nil }
        return options["qualityBinning"]?.stringValue ?? options["binning"]?.stringValue
    }
}
