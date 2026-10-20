// ViewerFigureRasterizer.swift - Draws a viewer figure scene to PNG, JPEG, TIFF or PDF bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The file formats a figure is written in.
public enum ViewerFigureFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case png
    case jpeg
    case tiff
    case pdf

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        case .pdf: "pdf"
        }
    }

    /// The ImageIO type of a bitmap format, nil for PDF.
    var imageTypeIdentifier: CFString? {
        switch self {
        case .png: "public.png" as CFString
        case .jpeg: "public.jpeg" as CFString
        case .tiff: "public.tiff" as CFString
        case .pdf: nil
        }
    }
}

public enum ViewerFigureRasterizerError: Error, Hashable, LocalizedError {
    case invalidSize(width: Double, height: Double, pixelScale: Double)
    case contextUnavailable(ViewerFigureFormat)
    case encodingFailed(ViewerFigureFormat)
    case fontMissing(String)
    case layerWithoutFrame

    public var errorDescription: String? {
        switch self {
        case .invalidSize(let width, let height, let pixelScale):
            "A figure of \(width) by \(height) points at scale \(pixelScale) cannot be drawn."
        case .contextUnavailable(let format):
            "No \(format.rawValue) drawing context could be made for the figure."
        case .encodingFailed(let format):
            "The figure could not be written as \(format.rawValue)."
        case .fontMissing(let name):
            "The font \(name) the figure was built with is not installed."
        case .layerWithoutFrame:
            "The figure draws a track layer but holds no genomic frame to place it in."
        }
    }
}

/// The bytes of one rendered figure, and why a PDF kept the dates and file ID its writer set.
public struct ViewerFigureRendering: Sendable, Hashable {
    public let data: Data
    /// Why the PDF keeps the dates and random file ID its writer set, or nil when the figure holds
    /// none, as every bitmap and every normalized PDF holds none (QA ruling QA-GFX-mask, QM-3).
    public let pdfKeptAsWritten: String?

    public init(data: Data, pdfKeptAsWritten: String? = nil) {
        self.data = data
        self.pdfKeptAsWritten = pdfKeptAsWritten
    }
}

/// Draws a `ViewerFigureScene` with CoreGraphics, CoreText and ImageIO, which need no window
/// server, so the CLI can draw over ssh or from launchd.
///
/// Rendering is a synchronous function of its `Sendable` arguments with no shared state. It
/// draws in the sRGB space with anti-aliasing on and font smoothing off, set on the context,
/// and passes ImageIO a property dictionary that holds no time. PNG, JPEG and TIFF bytes are
/// therefore the same for the same scene on one host and build. A PDF context writes a creation
/// date, a modification date and a random file ID. The rasterizer blanks both dates and writes a
/// file ID taken from the content, so a PDF's bytes are also the same on one host and build.
public enum ViewerFigureRasterizer {
    /// The renderer version a figure's record names. Any commit that changes a rendered byte
    /// raises it (BIO 7).
    public static let version = 1
    /// The `/Creator` of a figure PDF.
    public static let pdfCreator = "Lungfish Genome Explorer"
    /// The JPEG quality, from 0 to 1.
    public static let jpegQuality = 0.9

    /// The figure in `format`. A bitmap has `pixelScale` pixels per point and a PDF is in points.
    public static func render(
        _ scene: ViewerFigureScene, format: ViewerFigureFormat, pixelScale: Double = 2
    ) throws(ViewerFigureRasterizerError) -> Data {
        try renderReporting(scene, format: format, pixelScale: pixelScale).data
    }

    /// The figure in `format`, with the reason a PDF kept its writer's dates and file ID when the
    /// normalizer could not read its layout.
    public static func renderReporting(
        _ scene: ViewerFigureScene, format: ViewerFigureFormat, pixelScale: Double = 2
    ) throws(ViewerFigureRasterizerError) -> ViewerFigureRendering {
        guard scene.width.isFinite, scene.height.isFinite, pixelScale.isFinite, scene.width > 0,
              scene.height > 0, pixelScale > 0 else {
            throw .invalidSize(width: scene.width, height: scene.height, pixelScale: pixelScale)
        }
        if let type = format.imageTypeIdentifier {
            return ViewerFigureRendering(data: try renderBitmap(scene, format: format, type: type, pixelScale: pixelScale))
        }
        return try renderPDF(scene)
    }

    /// The property dictionary every bitmap is written with. It names the resolution and
    /// orientation and, per format, the compression, and holds no time, software or host.
    public static func imageProperties(format: ViewerFigureFormat, pixelScale: Double) -> [CFString: Any] {
        let dpi = 72 * pixelScale
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyOrientation: 1,
        ]
        switch format {
        case .tiff:
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFCompression: 5,
                kCGImagePropertyTIFFResolutionUnit: 2,
                kCGImagePropertyTIFFXResolution: dpi,
                kCGImagePropertyTIFFYResolution: dpi,
            ] as [CFString: Any]
        case .jpeg:
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        case .png, .pdf:
            break
        }
        return properties
    }

    private static func renderBitmap(
        _ scene: ViewerFigureScene, format: ViewerFigureFormat, type: CFString, pixelScale: Double
    ) throws(ViewerFigureRasterizerError) -> Data {
        let widthInPixels = (scene.width * pixelScale).rounded(.up)
        let heightInPixels = (scene.height * pixelScale).rounded(.up)
        // A finite size can still overflow the pixel count, and an infinite product fails too.
        guard widthInPixels <= Double(Int32.max), heightInPixels <= Double(Int32.max) else {
            throw .invalidSize(width: scene.width, height: scene.height, pixelScale: pixelScale)
        }
        let pixelWidth = Int(widthInPixels)
        let pixelHeight = Int(heightInPixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw .contextUnavailable(format)
        }
        configure(context)
        // The pixel grid is up to one pixel larger than the scene when size times scale is not a whole
        // number, so paint the whole grid and not only the scene's rectangle.
        context.setFillColor(scene.background.color(in: scene.theme).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(pixelScale), y: CGFloat(-pixelScale))
        try draw(scene, in: context, paintsBackground: false)
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else {
            throw .encodingFailed(format)
        }
        CGImageDestinationAddImage(destination, image, imageProperties(format: format, pixelScale: pixelScale) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw .encodingFailed(format)
        }
        return data as Data
    }

    /// The PDF with its dates blanked and a file ID taken from its content (QA ruling
    /// QA-GFX-mask, QM-2), or as written with the reason when its layout is not the expected one.
    private static func renderPDF(_ scene: ViewerFigureScene) throws(ViewerFigureRasterizerError) -> ViewerFigureRendering {
        switch ViewerFigurePDFNormalizer.normalize(try pdfAsWritten(scene)) {
        case .normalized(let data):
            ViewerFigureRendering(data: data)
        case .keptAsWritten(let data, let reason):
            ViewerFigureRendering(data: data, pdfKeptAsWritten: reason)
        }
    }

    /// The PDF as the context writes it, its dates and random file ID included. Tests reach it to
    /// pin that the context still writes them.
    static func pdfAsWritten(_ scene: ViewerFigureScene) throws(ViewerFigureRasterizerError) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: scene.width, height: scene.height)
        let info = [kCGPDFContextCreator: pdfCreator] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
            throw .contextUnavailable(.pdf)
        }
        context.beginPDFPage(nil)
        configure(context)
        context.translateBy(x: 0, y: CGFloat(scene.height))
        context.scaleBy(x: 1, y: -1)
        do {
            try draw(scene, in: context, paintsBackground: true)
        } catch {
            context.endPDFPage()
            context.closePDF()
            throw error
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Sets every drawing switch that could otherwise follow a default. Tests reach it to draw a moved
    /// renderer directly in the same state.
    static func configure(_ context: CGContext) {
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.interpolationQuality = .high
        context.setLineCap(.butt)
        context.setLineJoin(.miter)
    }

    /// Draws every item, and the background when `paintsBackground` is set, in a context whose
    /// origin is the top left, in points. A bitmap paints its whole pixel grid first instead, so a
    /// translucent background is never painted twice.
    private static func draw(
        _ scene: ViewerFigureScene, in context: CGContext, paintsBackground: Bool
    ) throws(ViewerFigureRasterizerError) {
        let theme = scene.theme
        if paintsBackground {
            context.setFillColor(scene.background.color(in: theme).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: scene.width, height: scene.height))
        }
        for item in scene.items {
            switch item {
            case .fill(let rect, let paint):
                context.setFillColor(paint.color(in: theme).cgColor)
                context.fill(rect.cgRect)
            case .strokeRect(let rect, let lineWidth, let paint):
                context.setStrokeColor(paint.color(in: theme).cgColor)
                context.setLineWidth(CGFloat(lineWidth))
                context.stroke(rect.cgRect)
            case .strokeSegments(let segments, let lineWidth, let paint):
                context.setStrokeColor(paint.color(in: theme).cgColor)
                context.setLineWidth(CGFloat(lineWidth))
                context.strokeLineSegments(between: segments.flatMap { [$0.from.cgPoint, $0.to.cgPoint] })
            case .text(let text):
                try draw(text, theme: theme, in: context)
            case .layer(let layer):
                guard let frame = scene.frame else { throw .layerWithoutFrame }
                layer.draw(in: context, frame: frame, theme: theme)
            }
        }
    }

    private static func draw(
        _ text: ViewerFigureText, theme: ViewerFigureTheme, in context: CGContext
    ) throws(ViewerFigureRasterizerError) {
        guard let font = ViewerFigureFonts.font(named: text.fontName, size: text.fontSize) else {
            throw .fontMissing(text.fontName)
        }
        let line = ViewerFigureFonts.line(text.string, font: font)
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        let offset = switch text.anchor {
        case .baselineStart: 0.0
        case .baselineCenter: width / 2
        case .baselineEnd: width
        }
        context.saveGState()
        context.setFillColor(text.paint.color(in: theme).cgColor)
        context.translateBy(x: CGFloat(text.point.x - offset), y: CGFloat(text.point.y))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension ViewerFigureRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

extension ViewerFigurePoint {
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
