// SPAdesCarefulModeCompatibility.swift - Which SPAdes profiles accept --careful
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Verified against SPAdes 4.3.0 on 2026-09-27: `--isolate --careful` exits 67
// with "you cannot specify --mismatch-correction or --careful in isolate
// mode!", `--meta --careful` exits 67 with "you cannot specify --careful,
// --mismatch-correction or --cov-cutoff in metagenomic mode!", and
// `--plasmid --careful` runs. The wizard's tick box and `lungfish-cli
// assemble` both consult this so the combination is refused with a clear
// message before SPAdes is launched, instead of LGE exiting 64 afterwards.

import Foundation

public enum SPAdesCarefulModeCompatibility {
    /// The SPAdes flags that `--isolate` and `--meta` reject.
    public static let carefulFlags: Set<String> = ["--careful", "--mismatch-correction"]

    /// The profile SPAdes runs when a request names none.
    public static let defaultProfileID = "isolate"

    /// Whether `--careful` may be combined with `profileID` (`nil` means the
    /// pipeline default, isolate).
    public static func supportsCareful(profileID: String?) -> Bool {
        switch profileID ?? defaultProfileID {
        case "isolate", "meta": return false
        default: return true
        }
    }

    /// The caption shown beside a disabled Careful mode tick box.
    public static func unavailableCaption(profileID: String?) -> String? {
        guard !supportsCareful(profileID: profileID) else { return nil }
        return "Careful mode is unavailable with the \(profileDisplayName(profileID)) profile: SPAdes rejects --careful in \(modeDescription(profileID)) mode."
    }

    /// Why a request cannot run, or `nil` when the combination is allowed.
    public static func rejectionMessage(profileID: String?, extraArguments: [String]) -> String? {
        guard !supportsCareful(profileID: profileID) else { return nil }
        let offending = extraArguments.filter { carefulFlags.contains($0) }
        guard let flag = offending.first else { return nil }
        return "SPAdes rejects \(flag) with the \(profileDisplayName(profileID)) profile "
            + "(\"you cannot specify --mismatch-correction or --careful in \(modeDescription(profileID)) mode!\"). "
            + "Turn off Careful mode or choose the Plasmid profile."
    }

    private static func profileDisplayName(_ profileID: String?) -> String {
        switch profileID ?? defaultProfileID {
        case "isolate": return "Isolate"
        case "meta": return "Meta"
        case "plasmid": return "Plasmid"
        case let other: return other
        }
    }

    private static func modeDescription(_ profileID: String?) -> String {
        (profileID ?? defaultProfileID) == "meta" ? "metagenomic" : "isolate"
    }
}
