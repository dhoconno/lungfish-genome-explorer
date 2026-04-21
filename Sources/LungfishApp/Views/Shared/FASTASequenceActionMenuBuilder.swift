import AppKit
import ObjectiveC

@MainActor
struct FASTASequenceActionHandlers {
    var onBlast: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    var onCreateBundle: (() -> Void)?
    var onRunOperation: (() -> Void)?

    static let noop = FASTASequenceActionHandlers(
        onBlast: {},
        onCopy: {},
        onExport: {},
        onCreateBundle: {},
        onRunOperation: {}
    )
}

@MainActor
enum FASTASequenceActionMenuBuilder {
    private static let actionAssociationKey = UnsafeRawPointer(bitPattern: 0xFA57A)!

    private final class ActionTarget: NSObject {
        let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func performAction(_ sender: Any?) {
            handler()
        }
    }

    static func buildMenu(
        selectionCount: Int,
        handlers: FASTASequenceActionHandlers
    ) -> NSMenu {
        let menu = NSMenu(title: "FASTA Actions")
        buildItems(selectionCount: selectionCount, handlers: handlers).forEach(menu.addItem(_:))
        return menu
    }

    static func buildItems(
        selectionCount: Int,
        handlers: FASTASequenceActionHandlers
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let isEnabled = selectionCount > 0

        addItem(
            titled: "Verify with BLAST…",
            handler: handlers.onBlast,
            enabled: isEnabled,
            to: &items
        )
        addItem(
            titled: "Copy FASTA",
            handler: handlers.onCopy,
            enabled: isEnabled,
            to: &items
        )
        addItem(
            titled: "Export FASTA…",
            handler: handlers.onExport,
            enabled: isEnabled,
            to: &items
        )
        addItem(
            titled: "Create Bundle…",
            handler: handlers.onCreateBundle,
            enabled: isEnabled,
            to: &items
        )

        if handlers.onRunOperation != nil && !items.isEmpty {
            items.append(.separator())
        }

        addItem(
            titled: "Run Operation…",
            handler: handlers.onRunOperation,
            enabled: isEnabled,
            to: &items
        )
        return items
    }

    private static func addItem(
        titled title: String,
        handler: (() -> Void)?,
        enabled: Bool,
        to items: inout [NSMenuItem]
    ) {
        guard let handler else { return }

        let target = ActionTarget(handler: handler)
        let item = NSMenuItem(
            title: title,
            action: #selector(ActionTarget.performAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = enabled
        objc_setAssociatedObject(
            item,
            actionAssociationKey,
            target,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        items.append(item)
    }
}
