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
public enum ProvenanceSiteFactRows {
    /// The group row's label and value, shown before the facts.
    public static let groupLabel = "Reported by the launcher"
    public static let groupValue =
        "Passed in by the program that started the run, such as HTCondor. Lungfish shows them as given and did not check them."
    public static let notRecorded = "Not recorded"
    /// The row of the job's cluster and process ids, `<cluster>.<process>`.
    public static let jobLabel = "HTCondor job"
    static let clusterKey = "ClusterId"
    static let processKey = "ProcId"

    /// The facts the submit template asks for (C4-03's list) with their labels, in OQ-5's order.
    public static let templateLabels: [(key: String, label: String)] = [
        ("Machine", "Machine name"),
        ("OpSysAndVer", "Operating system"),
        ("OSKernelRelease", "Kernel release"),
        ("SingularityVersion", "Apptainer version"),
        ("Microarch", "CPU microarchitecture"),
        ("CondorVersion", "HTCondor version"),
        ("Cpus", "CPUs"),
        ("Memory", "Memory"),
        ("Disk", "Disk"),
    ]

    /// The unit each whole-number fact takes. HTCondor states a slot's `Memory` in MiB and its `Disk` in KiB.
    static let units = ["Memory": "MiB", "Disk": "KiB"]

    /// The rows: the group row, then one row per fact in the record's order, then each fact the template asks for that
    /// the record lacks as Not recorded. A key the template asks for shows under its label and any other key under the
    /// key as recorded. The cluster and process ids make one row. A record with no site fact gives no row, so a run
    /// from any Linux machine shows none. `missingValue` is the word the template writes for an attribute the slot
    /// lacks, and a fact that holds it shows as Not recorded.
    public static func rows(_ facts: [ProvenanceSiteFact]?, missingValue: String? = nil) -> [(label: String, value: String)] {
        guard let facts, !facts.isEmpty else { return [] }
        let labels = Dictionary(templateLabels.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        let byKey = Dictionary(facts.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        func recorded(_ key: String) -> String? {
            guard let value = byKey[key], value != missingValue else { return nil }
            return value
        }
        var rows: [(label: String, value: String)] = [(groupLabel, groupValue)]
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
        for (key, label) in templateLabels where byKey[key] == nil {
            rows.append((label, notRecorded))
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
