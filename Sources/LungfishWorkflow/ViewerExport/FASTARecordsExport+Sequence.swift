// FASTARecordsExport+Sequence.swift - The sequence view's FASTA export on the records leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The sequence view's FASTA export (Phase 2.12 lane 12.34, ARCH ruling 1.1 row A12).
///
/// The view holds one sequence in memory, which may come from a GenBank file, a bundle or a collection, so a CLI cannot
/// always read it from the document the view shows. The app stages the sequence as a one-record FASTA file in a new
/// `.lungfish-export-inputs/<UUID>/` folder beside the output before the Operations row begins. The file holds the
/// sequence's name, its description and its bases on one line, which is the data and not the wrapping. The leaf
/// `lungfish-cli extract sequence <sequence.fa> --sequence=<name> --line-width 80 -o <file>` finds the record, wraps its
/// bases at the width the command names and writes the file with its record, so the 80 columns live in the command and
/// the record, and a replay with another width writes another wrapping.
extension FASTARecordsExport {
    /// The name of the staged sequence inside the inputs folder.
    public static let stagedSequenceFileName = "sequence.fa"
    /// The line width the sequence view's FASTA export has always written.
    public static let sequenceViewLineWidth = 80

    /// The one-record FASTA text the app stages for a sequence. The header is `>name` and, when the sequence has a
    /// description, ` description`. The bases follow on one line, and a sequence with no bases is a header only.
    public static func sequenceText(name: String, description: String?, bases: String) -> String {
        var header = ">\(name)"
        if let description {
            header += " \(description)"
        }
        return bases.isEmpty ? header + "\n" : header + "\n" + bases + "\n"
    }

    /// What `--sequence` names for a sequence. The name is found as the header's first word, so a name that holds a
    /// space or a tab cannot be told from the description. Such a name is given as the whole header line, which is
    /// matched before any first word.
    public static func sequenceIdentity(name: String, description: String?) -> String {
        guard name.contains(where: { $0 == " " || $0 == "\t" }), let description else { return name }
        return "\(name) \(description)"
    }

    /// Creates a new empty `.lungfish-export-inputs/<UUID>/` folder beside `outputURL`, the folder the selection file
    /// of an export uses (ARCH ruling 1.3), and returns it. A failure leaves no folder behind.
    public static func makeInputsFolder(besideOutput outputURL: URL) throws -> URL {
        let folder = outputURL.deletingLastPathComponent()
            .appendingPathComponent(ViewerExportSelection.inputsFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// One record of a FASTA document with its bases wrapped at `lineWidth` columns. The header line is kept as
    /// stored, without a carriage return, and the sequence lines are joined and cut again, each ending in a line
    /// feed. A record with no bases is its header line. A width below 1 is read as 1.
    public static func rewrapped(_ record: Data, lineWidth: Int) -> Data {
        let width = max(lineWidth, 1)
        let bytes = Array(record)
        let headerEnd = bytes.firstIndex(of: 0x0A) ?? bytes.count
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / width + 2)
        output.append(contentsOf: bytes[..<headerEnd])
        if output.last == 0x0D {
            output.removeLast()
        }
        output.append(0x0A)
        var column = 0
        var index = headerEnd + 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x0A || byte == 0x0D { continue }
            output.append(byte)
            column += 1
            if column == width {
                output.append(0x0A)
                column = 0
            }
        }
        if column > 0 {
            output.append(0x0A)
        }
        return Data(output)
    }
}
