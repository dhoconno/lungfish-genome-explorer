// ReadTrackRenderer+Bases.swift - Base-level rows and base classification of the read track renderer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation
import LungfishCore
import LungfishWorkflow

extension ReadTrackRenderer {

    // MARK: - Base-Level Rendering (Tier 3)

    /// Draws reads with base-level detail: dots for matches, colored letters for mismatches.
    ///
    /// - Parameters:
    ///   - packedReads: Pre-packed reads with row assignments
    ///   - overflow: Number of reads that didn't fit
    ///   - frame: Reference frame for coordinate mapping
    ///   - referenceSequence: The reference sequence for match/mismatch detection
    ///   - referenceStart: 0-based start position of the reference sequence
    ///   - settings: Display settings controlling mismatch/softclip/indel visibility
    ///   - context: CoreGraphics context
    ///   - rect: Drawing rectangle
    public static func drawBaseReads(
        packedReads: [(row: Int, read: AlignedRead)],
        overflow: Int,
        frame: ViewerFigureFrame,
        referenceSequence: String?,
        referenceStart: Int,
        settings: DisplaySettings = DisplaySettings(),
        verticalCompress: Bool = false,
        maxRowsLimit: Int? = nil,
        maskedPositions: Set<Int> = [],
        layout: PackedReadLayout? = nil,
        clipRect: CGRect? = nil,
        mismatchCache: ReadMismatchCache? = nil,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        rect: CGRect
    ) {
        context.saveGState()
        let metrics = layoutMetrics(verticalCompress: verticalCompress)
        let readHeight = metrics.baseReadHeight

        let pixelsPerBase = 1.0 / frame.scale
        let preferredFontSize = min(13, max(7, CGFloat(pixelsPerBase) * 0.95))
        // Keep glyphs inside compressed rows so mismatch letters remain legible.
        let fontSize = max(6, min(preferredFontSize, readHeight - 1.5))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let refBytes: [UInt8]? = referenceSequence.map(uppercaseASCIIBytes)
        let cache = GlyphCache(font: font)

        // Pre-compute background colors for each strand to avoid per-read alloc
        let fwdBgTemplate = figureTheme.color(.baseReadForwardBackground).cgColor
        let revBgTemplate = figureTheme.color(.baseReadReverseBackground).cgColor
        let neutralBgTemplate = figureTheme.color(.baseReadNeutralBackground).cgColor
        let neutralStroke = figureTheme.color(.baseReadNeutralStroke).cgColor
        let useStrandColors = settings.showStrandColors
        let colorMode = settings.colorMode

        forEachVisiblePackedRead(
            packedReads: packedReads,
            layout: layout,
            frame: frame,
            rect: rect,
            clipRect: clipRect,
            readHeight: readHeight,
            rowGap: metrics.rowGap
        ) { read, y in
            let alpha = mapqAlpha(read.mapq)

            // Draw soft-clip background extensions
            if settings.showSoftClips {
                drawSoftClipExtensions(read: read, frame: frame, context: context, figureTheme: figureTheme, y: y, readHeight: readHeight, alpha: alpha)
            }

            // Draw read background
            let startPx = frame.screenPosition(for: Double(read.position))
            let endPx = frame.screenPosition(for: Double(read.alignmentEnd))
            let readRect = CGRect(x: startPx, y: y, width: endPx - startPx, height: readHeight)
            let bgAlpha = max(0.35, alpha * 0.72)
            let bgColor: CGColor
            let borderColor: CGColor
            if useStrandColors, colorMode != .strand {
                let modeColors = readColors(for: read, colorMode: colorMode, alpha: bgAlpha, figureTheme: figureTheme)
                bgColor = modeColors.fill
                borderColor = modeColors.stroke.copy(alpha: max(0.45, alpha * 0.7)) ?? modeColors.stroke
            } else if useStrandColors {
                bgColor = (read.isReverse ? revBgTemplate : fwdBgTemplate).copy(alpha: bgAlpha)!
                borderColor = figureTheme.color(read.isReverse ? .reverseReadStroke : .forwardReadStroke).withAlpha(max(0.45, alpha * 0.7)).cgColor
            } else {
                bgColor = neutralBgTemplate.copy(alpha: bgAlpha)!
                borderColor = neutralStroke.copy(alpha: max(0.45, alpha * 0.7))!
            }
            context.setFillColor(bgColor)
            context.fill(readRect)
            context.setStrokeColor(borderColor)
            context.setLineWidth(0.6)
            context.stroke(readRect.insetBy(dx: 0.25, dy: 0.25))

            // Draw bases using CTFont glyph rendering
            drawReadBases(
                read: read,
                frame: frame,
                refBytes: refBytes,
                referenceStart: referenceStart,
                showMismatches: settings.showMismatches,
                maskedPositions: maskedPositions,
                cachedMDMismatchPositions: mismatchCache?.positions(for: read),
                hasMismatchCache: mismatchCache != nil,
                context: context,
                figureTheme: figureTheme,
                y: y,
                readHeight: readHeight,
                font: font,
                glyphCache: cache,
                alpha: alpha
            )

            // Draw insertion markers
            if settings.showIndels {
                drawInsertionMarkers(read: read, frame: frame, context: context, figureTheme: figureTheme, y: y, readHeight: readHeight)
                drawDeletions(read: read, frame: frame, context: context, figureTheme: figureTheme, y: y + readHeight / 2, readHeight: readHeight)
            }
        }

        if !maskedPositions.isEmpty {
            drawMaskedColumns(maskedPositions, frame: frame, context: context, figureTheme: figureTheme, rect: rect)
        }

        // Draw overflow indicator
        if overflow > 0 {
            drawOverflowIndicator(context: context, figureTheme: figureTheme, rect: rect, overflow: overflow, maxRowsLimit: maxRowsLimit)
        }

        context.restoreGState()
    }

    // MARK: - Private Drawing Helpers

    /// Pre-computed glyph metrics for nucleotide characters, avoiding per-character CoreText layout.
    struct GlyphCache {
        let font: CTFont
        var glyphs: [UInt8: CGGlyph] = [:]      // ASCII byte -> glyph
        var advances: [UInt8: CGSize] = [:]      // ASCII byte -> glyph size
        let dotGlyph: CGGlyph
        let dotAdvance: CGSize

        init(font: CTFont) {
            self.font = font
            // Pre-compute glyphs for alphabetic bases (A-Z/a-z), covering RNA U and IUPAC codes.
            let chars = Array(UInt8(65)...UInt8(90)) + Array(UInt8(97)...UInt8(122))
            for byte in chars {
                var unichars = [UniChar(byte)]
                var glyph = CGGlyph(0)
                CTFontGetGlyphsForCharacters(font, &unichars, &glyph, 1)
                glyphs[byte] = glyph
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .default, &glyph, &advance, 1)
                advances[byte] = advance
            }
            // Dot glyph for matches
            var dotUnichars = [UniChar(46)] // "."
            var dGlyph = CGGlyph(0)
            CTFontGetGlyphsForCharacters(font, &dotUnichars, &dGlyph, 1)
            dotGlyph = dGlyph
            var dAdv = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .default, &dGlyph, &dAdv, 1)
            dotAdvance = dAdv
        }
    }

    /// Draws individual bases using CTFont glyph rendering (50-100x faster than NSString.draw).
    static func drawReadBases(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        refBytes: [UInt8]?,
        referenceStart: Int,
        showMismatches: Bool = true,
        maskedPositions: Set<Int>,
        cachedMDMismatchPositions: Set<Int>? = nil,
        hasMismatchCache: Bool = false,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        y: CGFloat,
        readHeight: CGFloat,
        font: CTFont,
        glyphCache: GlyphCache,
        alpha: CGFloat
    ) {
        let pixelsPerBase = 1.0 / frame.scale
        let cellWidth = CGFloat(pixelsPerBase)
        let cache = glyphCache
        let renderMatchesAsDots = shouldRenderMatchAsDot(showMismatches: showMismatches, pixelsPerBase: pixelsPerBase)

        // Pre-compute alpha-modulated colors (Geneious-style: all bases colored by identity)
        let mismatchAlpha = max(alpha, 0.85)
        let colorA = figureTheme.color(.readBaseA).withAlpha(mismatchAlpha).cgColor
        let colorT = figureTheme.color(.readBaseT).withAlpha(mismatchAlpha).cgColor
        let colorC = figureTheme.color(.readBaseC).withAlpha(mismatchAlpha).cgColor
        let colorG = figureTheme.color(.readBaseG).withAlpha(mismatchAlpha).cgColor
        let colorN = figureTheme.color(.readBaseN).withAlpha(mismatchAlpha).cgColor
        // Match bases: colored but slightly dimmer than mismatches
        let matchAlpha = max(alpha * 0.72, 0.48)
        let matchColorA = figureTheme.color(.readBaseA).withAlpha(matchAlpha).cgColor
        let matchColorT = figureTheme.color(.readBaseT).withAlpha(matchAlpha).cgColor
        let matchColorC = figureTheme.color(.readBaseC).withAlpha(matchAlpha).cgColor
        let matchColorG = figureTheme.color(.readBaseG).withAlpha(matchAlpha).cgColor
        let matchColorN = figureTheme.color(.readBaseN).withAlpha(matchAlpha).cgColor
        // Dot mode: use gray dots for matches (clear visual distinction)
        let matchDotAlpha = figureTheme.color(.matchDot).withAlpha(alpha).cgColor
        // Precomputed by `ReadMismatchCache` when the read batch was stored;
        // only fall back to parsing the MD tag when no cache was supplied.
        let mdMismatchPositions = hasMismatchCache
            ? cachedMDMismatchPositions
            : read.mdTag.map { mismatchPositionsFromMDTag($0, readStart: read.position) }

        // Baseline offset: center glyph vertically using ascent/descent
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let glyphHeight = ascent + descent
        let baselineY = y + (readHeight - glyphHeight) / 2 + ascent

        context.saveGState()

        // Fix glyph orientation in flipped view (isFlipped=true): CTFontDrawGlyphs renders
        // upside-down because the CTM flips glyph outlines. Text matrix is NOT part of the
        // graphics state, so we save/restore it manually.
        let savedTextMatrix = context.textMatrix
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Use UTF-8 view for zero-allocation iteration
        var seqIterator = read.sequence.utf8.makeIterator()

        var refPos = read.position
        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    guard let readByte = seqIterator.next() else { refPos += 1; continue }
                    guard !maskedPositions.contains(refPos) else {
                        refPos += 1
                        continue
                    }

                    let x = frame.screenPosition(for: Double(refPos))

                    // Resolves the render classification and the byte used for letter-mode
                    // glyph/color lookups from the RAW (unmasked) SEQ byte — this is the single
                    // source of truth the draw loop and its tests both go through, so a '=' is
                    // guaranteed to be recognized before any lossy uppercase masking happens.
                    let resolved = resolveBaseRender(
                        rawReadByte: readByte,
                        cigarOp: op.op,
                        refBytes: refBytes,
                        refPos: refPos,
                        referenceStart: referenceStart,
                        mdMismatchPositions: mdMismatchPositions
                    )
                    let renderClass = resolved.renderClass
                    let upperByte = resolved.upperByte

                    let glyph: CGGlyph
                    let glyphWidth: CGFloat
                    let color: CGColor

                    switch renderClass {
                    case .mismatch:
                        // Mismatches: colored background fill + white letter (Geneious-style)
                        let baseColor = colorForByte(upperByte, a: colorA, t: colorT, c: colorC, g: colorG, n: colorN)
                        context.setFillColor(baseColor.copy(alpha: 0.55) ?? baseColor)
                        context.fill(CGRect(x: x, y: y, width: cellWidth, height: readHeight))
                        glyph = cache.glyphs[upperByte] ?? cache.dotGlyph
                        glyphWidth = cache.advances[upperByte]?.width ?? cache.dotAdvance.width
                        // White letter on colored background for readability
                        color = CGColor(gray: 1.0, alpha: max(alpha, 0.9))
                    case .neutralN:
                        // N is always a neutral letter — never a dot, regardless of match verdict.
                        glyph = cache.glyphs[upperByte] ?? cache.dotGlyph
                        glyphWidth = cache.advances[upperByte]?.width ?? cache.dotAdvance.width
                        color = colorN
                    case .match where renderMatchesAsDots:
                        // Dot mode: matches (including SAM '=') shown as dots
                        glyph = cache.dotGlyph
                        glyphWidth = cache.dotAdvance.width
                        color = matchDotAlpha
                    case .match:
                        // Full sequence mode: matches shown as nucleotide-colored letters.
                        // A '=' has no letter identity of its own; resolveBaseRender already
                        // substituted the reference base for `upperByte` in that case.
                        glyph = cache.glyphs[upperByte] ?? cache.dotGlyph
                        glyphWidth = cache.advances[upperByte]?.width ?? cache.dotAdvance.width
                        color = colorForByte(upperByte, a: matchColorA, t: matchColorT, c: matchColorC, g: matchColorG, n: matchColorN)
                    }

                    let drawX = x + (cellWidth - glyphWidth) / 2
                    context.setFillColor(color)
                    var g = glyph
                    var pos = CGPoint(x: drawX, y: baselineY)
                    CTFontDrawGlyphs(font, &g, &pos, 1, context)

                    refPos += 1
                }

            case .softClip:
                // Soft clips are rendered by drawSoftClipExtensions; here we just advance the query index
                for _ in 0..<op.length {
                    _ = seqIterator.next()
                }

            case .insertion:
                for _ in 0..<op.length {
                    _ = seqIterator.next()
                }

            case .deletion, .skip:
                refPos += op.length

            case .hardClip, .padding:
                break
            }
        }

        context.textMatrix = savedTextMatrix
        context.restoreGState()
    }

    /// Returns color for an ASCII byte (uppercase). Zero-allocation.
    static func colorForByte(_ byte: UInt8, a: CGColor, t: CGColor, c: CGColor, g: CGColor, n: CGColor) -> CGColor {
        switch byte {
        case 65: return a  // A
        case 84, 85: return t  // T or U
        case 67: return c  // C
        case 71: return g  // G
        default: return n  // N or other
        }
    }

    /// Determines whether matched bases should be rendered as dots or letters in base-tier drawing.
    /// When bases are sufficiently wide, letters improve SNP readability.
    public static func shouldRenderMatchAsDot(showMismatches: Bool, pixelsPerBase: Double) -> Bool {
        showMismatches && pixelsPerBase < matchLetterThresholdPxPerBase
    }

    // MARK: - Base Render Classification (three-valued)

    /// The three ways a single aligned base can render in base-tier drawing.
    ///
    /// A `Bool` cannot express this: a read `N` must render as a neutral letter even when it
    /// "matches" (reference is also `N`), and a reference `N`/non-ACGTU byte is a no-call, not a
    /// mismatch. Both of those rules live outside the ordinary match/mismatch verdict.
    enum BaseRenderClass: Equatable {
        /// Colored letter (or tick, in packed mode): read base disagrees with the reference.
        case mismatch
        /// Dot (in dot mode) or dimmed letter: read base agrees with the reference.
        case match
        /// Always a neutral 'N' letter, regardless of match verdict — never a dot.
        case neutralN
    }

    /// Result of `resolveBaseRender`: the render classification plus the byte to use for
    /// letter-mode glyph/color lookups (distinct from the classification for SAM `=`, which has
    /// no letter identity of its own).
    struct ResolvedBaseRender: Equatable {
        let renderClass: BaseRenderClass
        /// Uppercased byte to key glyph/color lookups with. For SAM `=` this is the resolved
        /// reference base (or `N` when no reference base is available), NOT the masked `=` byte.
        let upperByte: UInt8
    }

    /// Production entry point for classifying one SEQ byte during base-tier drawing.
    ///
    /// This is the ONLY function the real draw loop (`drawReadBases`) calls to turn a raw SEQ
    /// byte into a render decision — tests must go through this function (not `classifyBase`
    /// directly) to exercise the same path production hits. It takes the RAW, un-masked SEQ byte
    /// and is responsible for recognizing SAM-legal `=` (0x3D) *before* any uppercase masking:
    /// `'=' & 0xDF == 0x1D`, which is not a valid ASCII letter, so masking first would both miss
    /// `classifyBase`'s `'='` guard and hand a garbage byte to glyph/color lookups keyed on
    /// uppercase ASCII.
    ///
    /// - Parameters:
    ///   - rawReadByte: The read's SEQ byte exactly as stored (NOT uppercased).
    ///   - cigarOp: The CIGAR operation covering this base.
    ///   - refBytes: Uppercased ASCII reference window, or `nil` when no reference is loaded.
    ///   - refPos: 0-based genomic position of this base.
    ///   - referenceStart: 0-based genomic start of `refBytes`.
    ///   - mdMismatchPositions: Absolute genomic mismatch positions derived from the read's MD
    ///     tag, or `nil` when the read has no MD tag.
    static func resolveBaseRender(
        rawReadByte: UInt8,
        cigarOp: CIGAROperation.Op,
        refBytes: [UInt8]?,
        refPos: Int,
        referenceStart: Int,
        mdMismatchPositions: Set<Int>?
    ) -> ResolvedBaseRender {
        // SAM-legal '=' in SEQ means "matches the reference base" — recognize it on the raw byte
        // before masking loses it.
        if rawReadByte == 0x3D {
            let refByte: UInt8? = {
                guard let refBytes else { return nil }
                let refIdx = refPos - referenceStart
                guard refIdx >= 0, refIdx < refBytes.count else { return nil }
                return refBytes[refIdx]
            }()
            return ResolvedBaseRender(renderClass: .match, upperByte: refByte ?? 0x4E)
        }

        // Uppercase: mask bit 5 (0x20) to convert lowercase ASCII to uppercase.
        let upperByte = rawReadByte & 0xDF
        let renderClass = classifyBase(
            readByte: upperByte,
            cigarOp: cigarOp,
            refBytes: refBytes,
            refPos: refPos,
            referenceStart: referenceStart,
            mdMismatchPositions: mdMismatchPositions
        )
        return ResolvedBaseRender(renderClass: renderClass, upperByte: upperByte)
    }

    /// Classifies a single aligned read base for base-tier rendering.
    ///
    /// Priority order (unchanged from the original inline logic):
    /// 1. Explicit CIGAR `=`/`X` (`cigarOp`) — authoritative, overrides any reference compare.
    /// 2. `refBytes` window compare (uppercased ASCII), when `refPos` falls inside it.
    /// 3. MD-tag derived mismatch positions (`mdMismatchPositions`), as fallback when the
    ///    refBytes window misses (e.g. `referenceStart` offset puts `refPos` out of bounds).
    /// 4. Otherwise: no reliable reference context, surface base identity as mismatch (matches
    ///    the pre-existing "show identity as letter" behavior).
    ///
    /// The read-N and reference-no-call rules apply on top of that verdict:
    /// - `readByte` (already uppercased) `== 'N'` (0x4E) always yields `.neutralN`, even if the
    ///   underlying verdict would have been a match — an N should never render as a dot.
    /// - When comparing against `refBytes`, a reference byte that is `N` or otherwise not a
    ///   concrete ACGTU/IUPAC call is a "no call": the position renders as `.match` (dot/dim),
    ///   not `.mismatch` — this prevents a false-mismatch column across assembly-gap N runs.
    /// - `readByte == '='` (0x3D) is SAM-legal shorthand for "matches the reference base" and
    ///   always classifies as `.match`.
    /// - IUPAC ambiguity codes in the reference are handled: a read base contained in the code's
    ///   expansion set classifies as `.match`.
    ///
    /// - Parameters:
    ///   - readByte: The read's SEQ byte, ALREADY uppercased (bit 0x20 masked, matching the
    ///     caller's existing `upperByte` convention).
    ///   - cigarOp: The CIGAR operation covering this base (`.seqMatch`/`.seqMismatch` are
    ///     authoritative; any other value falls through to the reference/MD comparison).
    ///   - refBytes: Uppercased ASCII reference window, or `nil` when no reference is loaded.
    ///   - refPos: 0-based genomic position of this base.
    ///   - referenceStart: 0-based genomic start of `refBytes`.
    ///   - mdMismatchPositions: Absolute genomic mismatch positions derived from the read's MD
    ///     tag, or `nil` when the read has no MD tag.
    static func classifyBase(
        readByte: UInt8,
        cigarOp: CIGAROperation.Op,
        refBytes: [UInt8]?,
        refPos: Int,
        referenceStart: Int,
        mdMismatchPositions: Set<Int>?
    ) -> BaseRenderClass {
        // Read N is always neutral, regardless of what the match verdict below would say.
        if readByte == 0x4E {
            return .neutralN
        }

        // SAM-legal '=' in SEQ always means "matches the reference base".
        if readByte == 0x3D {
            return .match
        }

        if cigarOp == .seqMismatch {
            return .mismatch
        }
        if cigarOp == .seqMatch {
            return .match
        }

        if let refBytes, refPos >= referenceStart {
            let refIdx = refPos - referenceStart
            if refIdx >= 0, refIdx < refBytes.count {
                let refByte = refBytes[refIdx]
                if refByte == 0x4E {
                    // Reference N (assembly gap): no-call, not a mismatch.
                    return .match
                }
                if isIUPACAmbiguityCode(refByte) {
                    return isEquivalentToIUPACCode(readByte, refByte) ? .match : .mismatch
                }
                if isNoCallReferenceByte(refByte) {
                    // Any other non-ACGTU/IUPAC byte (e.g. a gap character): no-call, not a
                    // mismatch — don't manufacture a false mismatch column.
                    return .match
                }
                return isEquivalentBase(readByte, refByte) ? .match : .mismatch
            } else if let mdMismatchPositions {
                return mdMismatchPositions.contains(refPos) ? .mismatch : .match
            } else {
                // refBytes window miss and no MD tag: no reliable reference context.
                return .mismatch
            }
        } else if let mdMismatchPositions {
            return mdMismatchPositions.contains(refPos) ? .mismatch : .match
        } else {
            // Without reference or MD tag, surface base identity directly.
            return .mismatch
        }
    }

    /// Returns true when a reference byte is a "no call" — an assembly gap (`N`) or any other
    /// byte that isn't a concrete ACGTU base or a recognized IUPAC ambiguity code. No-call
    /// reference positions must never manufacture a false mismatch.
    static func isNoCallReferenceByte(_ refByte: UInt8) -> Bool {
        switch refByte {
        case 0x41, 0x43, 0x47, 0x54, 0x55: // A C G T U
            return false
        case 0x4E: // N
            return true
        default:
            // Anything that isn't a recognized IUPAC ambiguity code either (R Y S W K M B D H V)
            // is also a no-call — most commonly gap characters ('-', '.') in derived references.
            return !isIUPACAmbiguityCode(refByte)
        }
    }

    /// Returns true when a read base (uppercased ASCII) is a valid expansion of an IUPAC
    /// ambiguity code reference byte. Byte-switch only — no allocations, safe for the hot draw path.
    static func isEquivalentToIUPACCode(_ readByte: UInt8, _ refByte: UInt8) -> Bool {
        switch refByte {
        case 0x52: return readByte == 0x41 || readByte == 0x47 // R = A/G
        case 0x59: return readByte == 0x43 || readByte == 0x54 || readByte == 0x55 // Y = C/T
        case 0x53: return readByte == 0x47 || readByte == 0x43 // S = G/C
        case 0x57: return readByte == 0x41 || readByte == 0x54 || readByte == 0x55 // W = A/T
        case 0x4B: return readByte == 0x47 || readByte == 0x54 || readByte == 0x55 // K = G/T
        case 0x4D: return readByte == 0x41 || readByte == 0x43 // M = A/C
        case 0x42: return readByte == 0x43 || readByte == 0x47 || readByte == 0x54 || readByte == 0x55 // B = C/G/T
        case 0x44: return readByte == 0x41 || readByte == 0x47 || readByte == 0x54 || readByte == 0x55 // D = A/G/T
        case 0x48: return readByte == 0x41 || readByte == 0x43 || readByte == 0x54 || readByte == 0x55 // H = A/C/T
        case 0x56: return readByte == 0x41 || readByte == 0x43 || readByte == 0x47 // V = A/C/G
        default: return false
        }
    }

    /// Returns true when a byte is a recognized IUPAC ambiguity code (excludes A/C/G/T/U/N,
    /// which are handled separately).
    static func isIUPACAmbiguityCode(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x52, 0x59, 0x53, 0x57, 0x4B, 0x4D, 0x42, 0x44, 0x48, 0x56: // R Y S W K M B D H V
            return true
        default:
            return false
        }
    }

    // MARK: - Degradation Badge (no reference + no MD tags)

    /// User-facing message for the "no reference, no MD tags" degradation badge.
    public static let noReferenceBadgeMessage = "No reference: all bases shown as mismatches"

    /// Tooltip detail for the "no reference, no MD tags" degradation badge: states the two
    /// actionable remedies (load a reference bundle, or re-run with `samtools calmd` MD tags).
    public static let noReferenceBadgeTooltip =
        "No reference sequence is loaded and the alignment has no MD tags, so base identity cannot be " +
        "compared against the reference — every base renders as a mismatch letter. Load the reference " +
        "bundle used for mapping, or re-run alignment with samtools calmd to add MD tags."

    /// True when reads draw with NEITHER a loaded reference NOR MD tags — the condition under
    /// which `classifyBase` degrades to calling every base a mismatch. Drives the degradation badge.
    public static func shouldShowNoReferenceBadge(hasReference: Bool, hasMDTags: Bool) -> Bool {
        !hasReference && !hasMDTags
    }
}
