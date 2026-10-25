// ProvenanceSiteFacts.swift - The site facts a launcher passed to a Linux run, kept as given, and their rows (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One `--site-fact KEY=VALUE` pair that the program that started a Linux run passed to `lungfish-executor run`, as the
/// run record keeps it. Lungfish never reads, checks or uses the value, so a record holds it as given (C4-02).
public struct ProvenanceSiteFact: Codable, Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// The label and value rows of a record's site facts, in the words of UX ruling OQ-5. The facts were reported by the
/// launcher and never observed, so their rows stand apart from what the executor observed (ARCH-r2:91-98).
///
/// The tool is generic and HTCondor is one launcher (owner O41). What belongs to HTCondor shows only for a record that
/// holds one of HTCondor's own facts, `ClusterId`, `ProcId` or `CondorVersion`: the labels and units that say a number
/// is the share of a machine that HTCondor gave the job, a Not recorded row for each fact its template asks for and the
/// record lacks, and the "HTCondor job" row. A record from any other launcher shows the facts it passed, as given.
public enum ProvenanceSiteFactRows {
    /// The group row's label, shown before the facts.
    public static let groupLabel = "Reported by the launcher"
    /// The group row's value for a record that holds none of HTCondor's facts: every fact shows as given (OQ-5).
    public static let groupValue =
        "Passed in by the program that started the run, such as HTCondor. Lungfish shows them as given and did not check them."
    /// The group row's value for a record that holds HTCondor's facts, where memory and disk gain a unit.
    public static let groupValueWithUnits = "Passed in by the program that started the run, such as HTCondor. "
        + "Lungfish shows them as given, except for the unit it adds to memory and disk, and did not check them."
    public static let notRecorded = "Not recorded"
    /// The row of the job's cluster and process ids, `<cluster>.<process>`.
    public static let jobLabel = "HTCondor job"
    static let clusterKey = "ClusterId"
    static let processKey = "ProcId"
    /// The facts only HTCondor reports: the job's two ids and HTCondor's version string. A record that holds any one of
    /// them is a record of HTCondor's.
    static let htcondorKeys: Set<String> = [clusterKey, processKey, "CondorVersion"]

    /// The label of each fact OQ-5's table names that reads the same for any launcher, and of the two other facts the
    /// CHTC submit template passes, `Arch` and `OpSysMajorVer`, in the same style.
    public static let templateLabels: [(key: String, label: String)] = [
        ("Machine", "Machine name"),
        ("Arch", "CPU architecture"),
        ("OpSysAndVer", "Operating system"),
        ("OpSysMajorVer", "Operating system major version"),
        ("OSKernelRelease", "Kernel release"),
        ("SingularityVersion", "Apptainer version"),
        ("Microarch", "CPU microarchitecture"),
        ("CondorVersion", "HTCondor version"),
    ]

    /// The label of each fact that describes the slot, the share of a machine that HTCondor gives one job, and not the
    /// machine (HTCondor's definitions of `Cpus`, `Memory` and `Disk`). A record of HTCondor's shows them under these
    /// labels, and any other record shows these keys as recorded.
    public static let slotLabels: [(key: String, label: String)] = [
        ("Cpus", "CPUs given to the job"),
        ("Memory", "Memory given to the job"),
        ("Disk", "Disk given to the job"),
    ]

    /// The machine-ad facts the CHTC submit template asks for, in its `arguments` order (lane H's
    /// `HTCondorSubmitTemplate.machineAdAttributes`). In a record of HTCondor's, each one the record lacks shows as Not
    /// recorded. The template passes no Apptainer or HTCondor version yet, so a record without them shows neither row.
    public static let templateKeys = [
        "Machine", "Arch", "Microarch", "OpSysAndVer", "OpSysMajorVer", "OSKernelRelease", "Cpus", "Memory", "Disk",
    ]

    /// The unit each whole-number fact takes in a record of HTCondor's. HTCondor states a slot's `Memory` in MiB and its
    /// `Disk` in KiB.
    static let units = ["Memory": "MiB", "Disk": "KiB"]

    /// The rows: the group row, then one row per fact in the record's order. A key the template asks for shows under its
    /// label and any other key under the key as recorded. The cluster and process ids make one row. A record with no
    /// site fact gives no row, so a run from any Linux machine shows none. A record that holds HTCondor's facts also
    /// shows the slot's labels and units, then each fact the template asks for that the record lacks as Not recorded,
    /// and the job row as Not recorded when an id is missing. A record from another launcher shows only the facts it
    /// passed. `missingValue` is the word the template writes for an attribute the slot lacks, and a fact that holds it
    /// shows as Not recorded.
    public static func rows(_ facts: [ProvenanceSiteFact]?, missingValue: String? = nil) -> [(label: String, value: String)] {
        guard let facts, !facts.isEmpty else { return [] }
        let byKey = Dictionary(facts.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let fromHTCondor = htcondorKeys.contains { byKey[$0] != nil }
        let known = fromHTCondor ? templateLabels + slotLabels : templateLabels
        let labels = Dictionary(known.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        func recorded(_ key: String) -> String? {
            guard let value = byKey[key], value != missingValue else { return nil }
            return value
        }
        var rows: [(label: String, value: String)] = [(groupLabel, fromHTCondor ? groupValueWithUnits : groupValue)]
        var jobShown = false
        for fact in facts {
            if fact.key == clusterKey || fact.key == processKey {
                guard !jobShown else { continue }
                jobShown = true
                rows.append((jobLabel, jobValue(cluster: recorded(clusterKey), process: recorded(processKey))))
                continue
            }
            guard let label = labels[fact.key] else {
                rows.append((fact.key, fact.value))
                continue
            }
            rows.append((label, recorded(fact.key).map { value(of: fact.key, $0) } ?? notRecorded))
        }
        guard fromHTCondor else { return rows }
        for key in templateKeys where byKey[key] == nil {
            rows.append((labels[key] ?? key, notRecorded))
        }
        if !jobShown { rows.append((jobLabel, notRecorded)) }
        return rows
    }

    /// "<n> MiB" or "<n> KiB" for a whole number, and the value as recorded otherwise.
    static func value(of key: String, _ value: String) -> String {
        guard let unit = units[key], !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return value }
        return "\(value) \(unit)"
    }

    static func jobValue(cluster: String?, process: String?) -> String {
        guard let cluster, let process else { return notRecorded }
        return "\(cluster).\(process)"
    }
}
