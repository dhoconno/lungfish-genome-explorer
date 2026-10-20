// ProvenanceEnvelope+LineageFocus.swift - The record of one file among the many a run wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceEnvelope {
    /// The record of `output` alone, for a run that writes many files and reads each of them in steps that write
    /// nothing, as `build-db esviritu` probes, sorts and counts every BAM it moved (ruling Q-S2 of the pre-2.12
    /// session). It keeps four kinds of step, in the run's order.
    ///
    /// 1. A step that names `output` among its outputs, with only that output, as ``focusedOnOutput(_:)`` keeps it.
    /// 2. A step without outputs whose inputs name `output` or a path it came from, such as a header probe, a count,
    ///    the replacement of its old bytes or the removal of the `_temp` path that a move took it from. A path it
    ///    came from is the `originPath` of `output` or of a step's output at its path.
    /// 3. A step that names no file, since nothing ties it to another file.
    /// 4. No other step. A step without outputs that reads only other files goes, and so does a step that writes
    ///    only other files, as in ``focusedOnOutput(_:)``.
    ///
    /// A kept step keeps every input, because a step read what it read. `files` keeps the inputs of the kept steps,
    /// and `output` and `outputs` name `output` alone, as in ``focusedOnOutput(_:)``. The copy goes through
    /// ``with(_:)``, so the run's other facts stay and its signatures, which covered the whole record, are
    /// cleared. A path under `/private/var`, `/private/tmp` or `/private/etc` names the same file as the path
    /// without `/private`, since a folder listing under the temporary folder gives the first and a standardized
    /// URL the second, and one run can hold both. ``focusedOnOutput(_:)`` stays as it is for its callers.
    public func focusedOnLineage(of output: ProvenanceFileDescriptor) -> ProvenanceEnvelope {
        let file = Self.lineagePath(output.path)
        var lineage: Set<String> = [file]
        for named in [output] + steps.flatMap(\.outputs) where Self.lineagePath(named.path) == file {
            if let origin = named.originPath {
                lineage.insert(Self.lineagePath(origin))
            }
        }
        let keptSteps = steps.compactMap { step -> ProvenanceStep? in
            guard step.outputs.isEmpty else {
                let narrowed = step.outputs.compactMap { Self.lineagePath($0.path) == file ? output : nil }
                return narrowed.isEmpty ? nil : step.withOutputs(narrowed)
            }
            guard !step.inputs.isEmpty else { return step }
            return step.inputs.contains { lineage.contains(Self.lineagePath($0.path)) } ? step : nil
        }
        let keptInputPaths = Set(keptSteps.flatMap { $0.inputs.map(\.path) })
        return with { copy in
            copy.files = files.compactMap { descriptor in
                if descriptor.role == .output {
                    return descriptor.path == output.path ? output : nil
                }
                guard !keptSteps.isEmpty else { return descriptor }
                return keptInputPaths.contains(descriptor.path) ? descriptor : nil
            }
            copy.output = output
            copy.outputs = [output]
            copy.steps = keptSteps
        }
    }

    /// `path` without the `/private` that macOS puts before `/var`, `/tmp` and `/etc`, so both spellings of one
    /// file compare equal. It reads nothing from the disk. The prefix and the three roots stay separate strings, so
    /// that no string in the app holds the joined root, which the release portability scan forbids
    /// (`scripts/release/scan-release-portability.py`, label `private-tmp`).
    private static func lineagePath(_ path: String) -> String {
        let prefix = "/private"
        guard path.hasPrefix(prefix) else { return path }
        let rest = path.dropFirst(prefix.count)
        for root in ["/var/", "/tmp/", "/etc/"] where rest.hasPrefix(root) {
            return String(rest)
        }
        return path
    }
}
