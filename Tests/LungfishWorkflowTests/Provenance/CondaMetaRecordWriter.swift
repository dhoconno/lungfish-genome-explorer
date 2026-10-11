// CondaMetaRecordWriter.swift - Fake conda-meta records for tests that read an environment's installed version
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Writes a conda-meta package record into a fake conda environment folder, shaped as micromamba writes it.
/// A real record keeps host paths (the extracted package folder and the tarball), so this one does too, under
/// the folder two levels above the environment. A test uses them to check that no path reaches a recorded line.
enum CondaMetaRecordWriter {
    /// Writes `conda-meta/<package>-<version>-<build>.json` into `environment` and returns the file.
    /// `fields` replace or add keys of the record, which lets a test damage a part of it.
    @discardableResult
    static func write(
        environment: URL,
        package: String,
        version: String,
        build: String?,
        fields: [String: Any] = [:]
    ) throws -> URL {
        let directory = environment.appendingPathComponent("conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = [package, version, build].compactMap { $0 }.joined(separator: "-")
        let packages = environment.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("pkgs", isDirectory: true)
        var record: [String: Any] = [
            "name": package, "version": version, "build_number": 0, "channel": "bioconda",
            "subdir": "osx-arm64", "fn": "\(stem).conda",
            "url": "https://conda.anaconda.org/bioconda/osx-arm64/\(stem).conda",
            "extracted_package_dir": packages.appendingPathComponent(stem).path,
            "package_tarball_full_path": packages.appendingPathComponent("\(stem).tar.bz2").path,
            "files": ["bin/\(package)"],
        ]
        if let build { record["build"] = build }
        record.merge(fields) { _, new in new }
        // A damaged field may hold a slash or a line break, which a file name cannot.
        let fileStem = stem.components(separatedBy: CharacterSet(charactersIn: "/ \n")).joined(separator: "_")
        let file = directory.appendingPathComponent("\(fileStem).json")
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
        return file
    }
}
