// FASTQPairingOptions.swift - Shared --pairing option for fastq subcommands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// How a `fastq` subcommand should treat the records of its single input.
enum FASTQPairingArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    /// Adjacent records are the two mates of one fragment; keep or drop both.
    case interleaved
    /// Every record stands alone.
    case single
    /// Read the enclosing bundle's `pairingMode`, then inspect read names.
    case auto
}

/// The `--pairing` option shared by every subsetting and decontamination
/// subcommand that must keep mates together.
///
/// The GUI passes the bundle's recorded pairing so the CLI never guesses.
/// A bare CLI call falls back to the bundle metadata next to the input, and
/// only then to read names (`FASTQPairingModeResolver`).
struct FASTQPairingOptions: ParsableArguments {
    @Option(
        name: .customLong("pairing"),
        help: ArgumentHelp(
            "How to treat the input's records: interleaved (adjacent records are mates and are kept or dropped together), single, or auto (default: auto)",
            discussion: "auto reads the pairingMode recorded by the enclosing .lungfishfastq bundle, then inspects read names. Mates with identical names, /1 /2 suffixes, or Casava descriptions are all recognised."
        )
    )
    var pairing: FASTQPairingArgument = .auto

    /// The caller's explicit answer, or `nil` for auto detection.
    var explicitInterleaved: Bool? {
        switch pairing {
        case .interleaved: return true
        case .single: return false
        case .auto: return nil
        }
    }

    /// Resolves the effective pairing for `inputURL` and warns on stderr when
    /// a requested pairing had to fall back to single reads.
    ///
    /// - Parameter pairsByName: pass `true` only for an operation that pairs
    ///   records by fragment name, which may run pair-aware on a file that
    ///   mixes merged reads with pairs. Positional tools (`interleaved=t`, an
    ///   R1/R2 split) leave it `false` and run mixed input as single reads.
    func resolvePairing(inputURL: URL, pairsByName: Bool = false) -> FASTQPairingDecision {
        let decision = FASTQPairingModeResolver.resolvePairing(
            inputURL: inputURL,
            explicit: explicitInterleaved,
            pairsByName: pairsByName
        )
        if let warning = decision.warning {
            FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
        }
        return decision
    }

    /// The arguments to replay this option exactly (empty for the default).
    var cliArguments: [String] {
        pairing == .auto ? [] : ["--pairing", pairing.rawValue]
    }

    /// Provenance value for the option as given.
    var provenanceValue: ParameterValue {
        .string(pairing.rawValue)
    }

    /// Provenance default for the option.
    static var provenanceDefault: ParameterValue {
        .string(FASTQPairingArgument.auto.rawValue)
    }

    /// Provenance default for the resolved read layout.
    static var readLayoutProvenanceDefault: ParameterValue {
        .string(FASTQInputLayout.singleEnd.rawValue)
    }
}

extension FASTQPairingDecision {
    /// Provenance value for the resolved layout (`single_end`,
    /// `strictly_interleaved`, `mixed_merged_and_pairs`).
    var readLayoutProvenanceValue: ParameterValue {
        .string(layout.rawValue)
    }

    /// Provenance value for the plain-language reason behind the layout.
    var readLayoutReasonProvenanceValue: ParameterValue {
        .string(resolution.reason)
    }
}
