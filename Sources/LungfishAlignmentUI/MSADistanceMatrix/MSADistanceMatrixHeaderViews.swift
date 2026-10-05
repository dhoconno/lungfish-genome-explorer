// MSADistanceMatrixHeaderViews.swift - Frozen row-name gutter and rotated column header (rulings U4, U5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A virtual AX element for one row or column name.
final class MSADistanceAXHeaderElement: NSAccessibilityElement {
    nonisolated(unsafe) weak var header: MSADistanceMatrixHeaderBaseView?
    let index: Int

    @MainActor
    init(header: MSADistanceMatrixHeaderBaseView, index: Int) {
        self.header = header
        self.index = index
        super.init()
        setAccessibilityRole(.cell)
        setAccessibilityParent(header)
        setAccessibilityIndex(index)
        setAccessibilityHelp("Select Sequence in Alignment")
    }

    override func accessibilityLabel() -> String? {
        let header = self.header, index = self.index
        return axOnMain {
            guard let names = header?.names, names.indices.contains(index) else { return nil }
            return names[index]
        }
    }

    override func accessibilityFrame() -> NSRect {
        let header = self.header, index = self.index
        return axOnMain {
            guard let header else { return .zero }
            return NSAccessibility.screenRect(fromView: header, rect: header.rect(forIndex: index))
        }
    }

    override func isAccessibilitySelected() -> Bool {
        let header = self.header, index = self.index
        return axOnMain { header?.selectedSequences.contains(index) ?? false }
    }

    override func accessibilityPerformPress() -> Bool {
        let header = self.header, index = self.index
        return axOnMain {
            guard let header else { return false }
            header.onHeaderClick?(index, [])
            return true
        }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let header = self.header, index = self.index
        return axOnMain { header?.axSelectAction(for: index).map { [$0] } }
    }
}

/// Shared state of the two header views.
@MainActor
public class MSADistanceMatrixHeaderBaseView: NSView {
    public var names: [String] = [] {
        didSet {
            elements.removeAll()
            needsDisplay = true
        }
    }

    public var cellSide: CGFloat = 22 { didSet { needsDisplay = true } }
    /// Scroll offset of the grid along this header's axis.
    public var scrollOffset: CGFloat = 0 { didSet { needsDisplay = true } }
    public var font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) { didSet { needsDisplay = true } }
    public var selectedSequences = IndexSet() { didSet { needsDisplay = true } }
    public var focusedIndex: Int? { didSet { if focusedIndex != oldValue { needsDisplay = true } } }
    /// Header click with modifiers. The pane forwards it to the grid.
    public var onHeaderClick: ((Int, NSEvent.ModifierFlags) -> Void)?

    private var elements: [Int: MSADistanceAXHeaderElement] = [:]

    public override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// One AX element per name, created lazily.
    public var headerElements: [Any] {
        var result: [Any] = []
        for index in names.indices {
            if let cached = elements[index] {
                result.append(cached)
            } else {
                let element = MSADistanceAXHeaderElement(header: self, index: index)
                elements[index] = element
                result.append(element)
            }
        }
        return result
    }

    public override func accessibilityChildren() -> [Any]? { headerElements }

    func axSelectAction(for index: Int) -> NSAccessibilityCustomAction? {
        NSAccessibilityCustomAction(name: "Select Sequence in Alignment") { [weak self] in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.onHeaderClick?(index, [])
                return true
            }
        }
    }

    func rect(forIndex index: Int) -> NSRect { .zero }
    func index(at point: NSPoint) -> Int? { nil }

    func attributes(for index: Int, truncation: NSLineBreakMode) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        let selected = selectedSequences.contains(index)
        let drawnFont = selected
            ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            : NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
        return [
            .font: drawnFont,
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
    }

    func visibleIndices(length: CGFloat) -> Range<Int> {
        guard cellSide > 0, !names.isEmpty else { return 0..<0 }
        let first = max(0, Int(floor(scrollOffset / cellSide)))
        let last = min(names.count, Int(ceil((scrollOffset + length) / cellSide)))
        return first < last ? first..<last : 0..<0
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        onHeaderClick?(index, event.modifierFlags)
    }

    /// One help tag over the whole view that names whatever is under the
    /// pointer, so middle truncation never hides a name.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }
}

extension MSADistanceMatrixHeaderBaseView: NSViewToolTipOwner {
    public func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let index = index(at: point) else { return "" }
        return names[index]
    }
}

/// Row names down the left edge, truncated in the middle. Selected
/// sequences are bold with an accent bar, so state never relies on colour.
@MainActor
public final class MSADistanceMatrixRowHeaderView: MSADistanceMatrixHeaderBaseView {
    static let padding: CGFloat = 6
    static let accentBarWidth: CGFloat = 3

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("Row names")
    }

    override func rect(forIndex index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * cellSide - scrollOffset, width: bounds.width, height: cellSide)
    }

    override func index(at point: NSPoint) -> Int? {
        guard cellSide > 0 else { return nil }
        let index = Int((point.y + scrollOffset) / cellSide)
        return names.indices.contains(index) ? index : nil
    }

    /// Width that fits the widest name, capped.
    public func preferredWidth(maximum: CGFloat = 220) -> CGFloat {
        let widest = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(maximum, ceil(widest + Self.padding * 2 + Self.accentBarWidth))
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let lineHeight = font.ascender - font.descender
        for index in visibleIndices(length: bounds.height) {
            let frame = rect(forIndex: index)
            if selectedSequences.contains(index) {
                NSColor.controlAccentColor.setFill()
                NSRect(x: 0, y: frame.minY + 2, width: Self.accentBarWidth, height: frame.height - 4).fill()
            }
            let textRect = NSRect(
                x: Self.padding + Self.accentBarWidth,
                y: frame.midY - lineHeight / 2,
                width: frame.width - Self.padding * 2 - Self.accentBarWidth,
                height: lineHeight
            )
            (names[index] as NSString).draw(in: textRect, withAttributes: attributes(for: index, truncation: .byTruncatingMiddle))
            if focusedIndex == index {
                NSColor.separatorColor.setFill()
                NSRect(x: frame.maxX - 2, y: frame.minY, width: 2, height: frame.height).fill()
            }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// Column names along the top, rotated 90 degrees to read bottom to top.
/// Height follows the widest name, capped at 140pt (ruling U5).
@MainActor
public final class MSADistanceMatrixColumnHeaderView: MSADistanceMatrixHeaderBaseView {
    public static let maximumHeight: CGFloat = 140
    static let padding: CGFloat = 6
    static let accentBarHeight: CGFloat = 3

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("Column names")
    }

    override func rect(forIndex index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * cellSide - scrollOffset, y: 0, width: cellSide, height: bounds.height)
    }

    override func index(at point: NSPoint) -> Int? {
        guard cellSide > 0 else { return nil }
        let index = Int((point.x + scrollOffset) / cellSide)
        return names.indices.contains(index) ? index : nil
    }

    public func preferredHeight() -> CGFloat {
        let widest = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(Self.maximumHeight, ceil(widest + Self.padding * 2 + Self.accentBarHeight))
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let lineHeight = font.ascender - font.descender
        let available = bounds.height - Self.padding * 2 - Self.accentBarHeight
        for index in visibleIndices(length: bounds.width) {
            let frame = rect(forIndex: index)
            if selectedSequences.contains(index) {
                NSColor.controlAccentColor.setFill()
                NSRect(x: frame.minX + 2, y: bounds.maxY - Self.accentBarHeight, width: frame.width - 4, height: Self.accentBarHeight).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: frame.midX, yBy: bounds.maxY - Self.padding - Self.accentBarHeight)
            transform.rotate(byDegrees: -90)
            transform.concat()
            let textRect = NSRect(x: 0, y: -lineHeight / 2, width: max(0, available), height: lineHeight)
            (names[index] as NSString).draw(in: textRect, withAttributes: attributes(for: index, truncation: .byTruncatingMiddle))
            NSGraphicsContext.restoreGraphicsState()
            if focusedIndex == index {
                NSColor.separatorColor.setFill()
                NSRect(x: frame.minX, y: bounds.maxY - 2, width: frame.width, height: 2).fill()
            }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
