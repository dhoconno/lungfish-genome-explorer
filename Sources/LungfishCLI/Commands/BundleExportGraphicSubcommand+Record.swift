// BundleExportGraphicSubcommand+Record.swift - What the record of bundle export-graphic states
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The record fields of one figure (BIO ruling Q-G3, items 2, 3, 6 to 8, and QA ruling QA-GFX-mask, item 4). A value
/// the run took by default goes under `defaults` and never under `explicitOptions`.
struct BundleExportGraphicRecord {
    let explicitOptions: [String: ParameterValue]
    let defaults: [String: ParameterValue]
    let resolved: [String: ParameterValue]

    init(explicitOptions: [String: ParameterValue], defaults: [String: ParameterValue], resolved: [String: ParameterValue]) {
        self.explicitOptions = explicitOptions
        self.defaults = defaults
        self.resolved = resolved
    }

    init(
        settings: ViewerGraphicExport.Settings, region: ViewerGraphicRegion, trackIDs: [String],
        figure: ViewerGraphicFigure, degraded: [ViewerFigureOmission], rendering: ViewerFigureRendering,
        pixelScale: Double, outputURL: URL, force: Bool
    ) {
        let format = settings.format
        var explicit: [String: ParameterValue] = [
            "outputPath": .file(outputURL),
            "outputFormat": .string(format.rawValue),
        ]
        if let passed = settings.region {
            explicit["region"] = .string(passed)
        }
        if let regionsFile = settings.regionsFile {
            explicit["regionsFile"] = .file(URL(fileURLWithPath: regionsFile))
        }
        var defaults: [String: ParameterValue] = [:]
        func take<Value>(_ key: String, _ value: Value?, default fallback: ParameterValue?, _ wrap: (Value) -> ParameterValue) {
            if let value {
                explicit[key] = wrap(value)
            } else if let fallback {
                defaults[key] = fallback
            }
        }
        take("width", settings.width, default: .number(ViewerGraphicExport.defaultWidth)) { .number($0) }
        take("theme", settings.theme, default: .string(ViewerGraphicExport.Theme.light.rawValue)) { .string($0.rawValue) }
        take("tracks", settings.tracks.isEmpty ? nil : settings.tracks, default: .array(trackIDs.map { .string($0) })) {
            .array($0.map { .string($0) })
        }
        take("scale", settings.scale, default: format == .pdf ? nil : .integer(ViewerGraphicExport.defaultScale)) { .integer($0) }
        take("excludeFlags", settings.excludeFlags.map(Int.init),
             default: figure.drawsAlignment ? .integer(Int(ViewerGraphicExport.defaultExcludeFlags)) : nil) { .integer($0) }
        take("coverageScale", settings.coverageScale,
             default: figure.drawsAlignment ? .string(CoverageScaleMode.default.rawValue) : nil) { .string($0.rawValue) }
        take("viewState", settings.viewState, default: nil) { .file(URL(fileURLWithPath: $0)) }
        if settings.includeRuler {
            explicit["includeRuler"] = .boolean(true)
        }
        if force {
            explicit["force"] = .boolean(true)
        }

        let scene = figure.scene
        var resolved: [String: ParameterValue] = [
            "region": .string(region.display),
            "regionConvention": .string(ViewerGraphicExport.regionConvention),
            "regionLength": .integer(region.length),
            "tracks": .array(figure.tracks.map {
                .dictionary(["id": .string($0.id), "kind": .string($0.kind), "displayMode": .string($0.displayMode),
                             "height": .number($0.height)])
            }),
            "includeRuler": .boolean(settings.includeRuler),
            "theme": .string((settings.theme ?? .light).rawValue),
            "widthPoints": .number(scene.width),
            "heightPoints": .number(scene.height),
            "format": .string(format.rawValue),
            "rendererVersion": .integer(ViewerFigureRasterizer.version),
            "sceneFormatVersion": .integer(scene.formatVersion),
            "fonts": .array(scene.fonts.map {
                .dictionary(["requested": .string($0.requested), "resolved": .string($0.resolved),
                             "size": .number($0.size), "fallback": .boolean($0.fallback)])
            }),
            "hostOSBuild": .string(Self.hostOSBuild),
        ]
        if let cap = figure.readRowCap {
            resolved["readRowCap"] = .integer(cap)
            resolved["excludeFlags"] = .integer(Int(settings.excludeFlags ?? ViewerGraphicExport.defaultExcludeFlags))
            resolved["coverageScale"] = .string((settings.coverageScale ?? .default).rawValue)
        }
        if format != .pdf {
            resolved["pixelScale"] = .number(pixelScale)
            resolved["pixelWidth"] = .integer(Int((scene.width * pixelScale).rounded(.up)))
            resolved["pixelHeight"] = .integer(Int((scene.height * pixelScale).rounded(.up)))
        }
        if format == .jpeg {
            resolved["jpegQuality"] = .number(ViewerFigureRasterizer.jpegQuality)
        }
        if format == .tiff {
            resolved["tiffCompression"] = .string("lzw")
        }
        var facts: [ParameterValue] = degraded.map(Self.entry)
        if let reason = rendering.pdfKeptAsWritten {
            facts.append(.dictionary([
                "trackID": .string("figure"), "kind": .string("pdfKeptAsWritten"),
                "reason": .string(Self.pdfKeptAsWrittenFact(reason)),
            ]))
        } else if format == .pdf {
            resolved["pdfFixedMetadata"] = .dictionary(Self.pdfFixedMetadata(rendering.data))
        }
        resolved["degraded"] = .array(facts)
        self.explicitOptions = explicit
        self.defaults = defaults
        self.resolved = resolved
    }

    static func fileFormat(_ format: ViewerFigureFormat) -> FileFormat {
        FileFormat(rawValue: format.rawValue)
    }

    static func entry(_ fact: ViewerFigureOmission) -> ParameterValue {
        var entry: [String: ParameterValue] = [
            "trackID": .string(fact.trackID), "kind": .string(fact.kind.rawValue), "reason": .string(fact.reason),
        ]
        if let count = fact.count {
            entry["count"] = .integer(count)
        }
        return .dictionary(entry)
    }

    /// The warning line of one degraded fact, on standard error and in the event stream.
    static func warning(_ fact: ViewerFigureOmission) -> String {
        let count = fact.count.map { ", \($0) left out" } ?? ""
        return "track \(fact.trackID), \(fact.kind.rawValue), \(fact.reason)\(count)."
    }

    /// The degraded fact of a PDF the normalizer could not read (R-QM1, UX words).
    static func pdfKeptAsWrittenFact(_ reason: String) -> String {
        "This PDF keeps the creation date, modification date and file ID that macOS wrote, so running its command "
            + "again writes a file with a different checksum. \(pdfReasonSentence(reason))"
    }

    /// The normalizer's reason as one sentence (QA ruling item 4). The first five are the ruling's words, and the
    /// rest name the other layouts the normalizer keeps as written.
    static func pdfReasonSentence(_ reason: String) -> String {
        func count(after prefix: String) -> Int? {
            guard reason.hasPrefix(prefix) else { return nil }
            return Int(reason.dropFirst(prefix.count).prefix { $0.isNumber })
        }
        if reason == "the PDF has no trailer keyword" { return "The file has no trailer." }
        if let references = count(after: "the last trailer has ") {
            return references == 0 ? "The trailer names no document information."
                : "The trailer names more than one document information."
        }
        if reason.contains("/ID entries") {
            return (count(after: "the PDF has ") ?? 0) > 1 ? "The file has more than one file ID."
                : "The file ID is not in the expected form."
        }
        if reason.hasPrefix("the /ID is outside") { return "The file ID is outside the trailer." }
        if reason.hasSuffix("the Info object") {
            // The normalizer words this reason for any count of Info objects but one, and none is not twice (fidelity review D4).
            return (count(after: "the PDF has ") ?? 2) == 0 ? "The document information is missing."
                : "The document information appears more than once."
        }
        if reason.hasSuffix("has no endobj") { return "The document information has no end." }
        if reason.contains("Date entries") {
            return (count(after: "the PDF has ") ?? 0) > 1 ? "A date appears more than once."
                : "A date is not in the expected form."
        }
        if reason.contains("is outside the Info object") { return "A date appears outside the document information." }
        return "The file's layout is not one the rasterizer reads."
    }

    /// The dates and file ID a normalized PDF holds, as written (BIO ruling Q-G3, item 8, rider a).
    static func pdfFixedMetadata(_ data: Data) -> [String: ParameterValue] {
        let text = String(decoding: data, as: UTF8.self)
        func first(_ pattern: String) -> [String] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        var metadata: [String: ParameterValue] = [:]
        if let date = first(#"/CreationDate \(([^)]*)\)"#).first { metadata["creationDate"] = .string(date) }
        if let date = first(#"/ModDate \(([^)]*)\)"#).first { metadata["modDate"] = .string(date) }
        let ids = first(#"/ID \[\s*<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*\]"#)
        if !ids.isEmpty { metadata["fileID"] = .array(ids.map { .string($0) }) }
        return metadata
    }

    /// The macOS build, which the PDF producer string and the drawn glyphs follow (BIO ruling Q-G3, item 6).
    static var hostOSBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}
