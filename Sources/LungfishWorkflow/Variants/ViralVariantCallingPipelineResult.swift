import Foundation
import LungfishCore
import LungfishIO
import os.log

public struct ViralVariantCallingPipelineResult: Sendable, Equatable {
    public let normalizedVCFURL: URL
    public let stagedVCFGZURL: URL
    public let stagedTabixURL: URL
    public let referenceFASTAURL: URL
    public let referenceFASTASHA256: String
    public let callerVersion: String
    public let callerParametersJSON: String
    public let commandLine: String
    public let provenanceSteps: [VariantCallingProvenanceStep]
    /// Words the person reads about the run, such as iVar's codon merging being off because the first annotation
    /// track's database is missing or cannot be read (ANNOT-EXPORT-MISSING-TRACK).
    public let notes: [String]

    public init(
        normalizedVCFURL: URL,
        stagedVCFGZURL: URL,
        stagedTabixURL: URL,
        referenceFASTAURL: URL,
        referenceFASTASHA256: String,
        callerVersion: String,
        callerParametersJSON: String,
        commandLine: String = "",
        provenanceSteps: [VariantCallingProvenanceStep] = [],
        notes: [String] = []
    ) {
        self.notes = notes
        self.normalizedVCFURL = normalizedVCFURL
        self.stagedVCFGZURL = stagedVCFGZURL
        self.stagedTabixURL = stagedTabixURL
        self.referenceFASTAURL = referenceFASTAURL
        self.referenceFASTASHA256 = referenceFASTASHA256
        self.callerVersion = callerVersion
        self.callerParametersJSON = callerParametersJSON
        self.commandLine = commandLine
        self.provenanceSteps = provenanceSteps
    }
}

extension ViralVariantCallingPipelineResult {
    /// The marker a completion message carries the run's notes after: ` notes=` and then a JSON array of strings.
    /// The app reads the notes back with ``splitNotes(fromCompletionMessage:)`` (ANNOT-EXPORT-MISSING-TRACK, row 5).
    public static let completionNotesMarker = " notes="

    /// The text to append to a completion message so that it carries `notes`, or an empty string when there are none.
    public static func completionSuffix(notes: [String]) -> String {
        guard !notes.isEmpty, let data = try? JSONEncoder().encode(notes) else { return "" }
        return completionNotesMarker + String(decoding: data, as: UTF8.self)
    }

    /// `message` without the notes it carries, and the notes. A message with no notes comes back whole.
    public static func splitNotes(fromCompletionMessage message: String) -> (message: String, notes: [String]) {
        guard let marker = message.range(of: completionNotesMarker + "[", options: .backwards) else { return (message, []) }
        let encoded = message[message.index(marker.lowerBound, offsetBy: completionNotesMarker.count)...]
        guard let notes = try? JSONDecoder().decode([String].self, from: Data(encoded.utf8)) else { return (message, []) }
        return (String(message[..<marker.lowerBound]), notes)
    }

    /// One standard error line per note.
    public static func standardErrorLines(notes: [String]) -> [String] {
        notes.map { "warning: " + $0 }
    }

    /// Writes the run's notes to standard error, one line each, and returns the result.
    public func writingNotesToStandardError() -> ViralVariantCallingPipelineResult {
        for line in Self.standardErrorLines(notes: notes) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        return self
    }
}
